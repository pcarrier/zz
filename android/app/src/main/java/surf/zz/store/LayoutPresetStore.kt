package surf.zz.store

import androidx.compose.runtime.mutableStateListOf
import java.io.File
import java.util.UUID
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.Job
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.delay
import kotlinx.coroutines.isActive
import kotlinx.coroutines.launch
import kotlinx.coroutines.runBlocking
import kotlinx.coroutines.withContext
import kotlinx.serialization.SerialName
import kotlinx.serialization.Serializable
import kotlinx.serialization.builtins.ListSerializer
import surf.zz.browser.tab.TabRecord
import surf.zz.layout.BspNode
import surf.zz.persistence.PersistenceWriteOrderer
import surf.zz.persistence.UuidSerializer
import surf.zz.persistence.ZzJson

/**
 * A named, restorable pane arrangement. Direct port of the Swift `LayoutPreset`
 * struct (`ios/zz/BrowserStore.swift:1157`).
 *
 * Reuses the same `@Serializable` [BspNode] / [TabRecord] shapes as the per-window
 * snapshot. New fields MUST decode with a default value so older saved presets keep
 * loading — the Kotlin analog of the Swift `decodeIfPresent ?? x` custom decoder:
 *
 *  - `id` defaults to a fresh [UUID] (Swift `?? UUID()`). With [ZzJson]'s
 *    `encodeDefaults = true` the field is always written, so on a round trip the id
 *    is stable; the default only fires for a legacy blob that predates the field.
 *  - `name` defaults to `"Layout"` (Swift `?? "Layout"`).
 *  - `root` has NO default: it is required, matching the Swift `decode` (not
 *    `decodeIfPresent`). A preset with no tree is meaningless.
 *  - `focusedTabID` is nullable with no default; with `explicitNulls = false` in
 *    [ZzJson] this matches Swift's `decodeIfPresent` (key omitted when null).
 *  - `tabs` defaults to the empty list (Swift `?? []`).
 *
 * Serialized through the shared [ZzJson]; UUID fields use [UuidSerializer] so the
 * JSON is a lowercase-with-dashes UUID string. As with the other Android DTOs this
 * is a fresh JSON shape (not byte-identical to the Swift Codable encoding); fine
 * because Android starts with no saved presets.
 */
@Serializable
data class LayoutPreset(
    @Serializable(UuidSerializer::class)
    @SerialName("id")
    val id: UUID = UUID.randomUUID(),
    @SerialName("name")
    val name: String = "Layout",
    @SerialName("root")
    val root: BspNode,
    @Serializable(UuidSerializer::class)
    @SerialName("focusedTabID")
    val focusedTabID: UUID? = null,
    @SerialName("tabs")
    val tabs: List<TabRecord> = emptyList(),
)

/**
 * Pure, testable transforms over the preset list. Direct port of the Swift
 * `LayoutPresetLogic` enum (`ios/zz/BrowserStore.swift:1190`).
 *
 * Kept free of any store/UI state so add/delete behavior is unit-testable in
 * isolation. The Swift `nonisolated enum` of `static func`s becomes a Kotlin
 * `object` of pure functions.
 */
object LayoutPresetLogic {

    /**
     * Normalizes a user-entered preset name: trims whitespace and falls back to
     * "Layout" for an all-whitespace name so a preset is never nameless.
     *
     * Swift trimmed `.whitespacesAndNewlines`; [String.isBlank]/[String.trim] uses
     * Unicode whitespace (incl. newlines), the closest Kotlin analog.
     */
    fun normalizedName(name: String): String {
        val trimmed = name.trim()
        return if (trimmed.isEmpty()) "Layout" else trimmed
    }

    fun adding(preset: LayoutPreset, to: List<LayoutPreset>): List<LayoutPreset> =
        to + preset

    fun removing(id: UUID, from: List<LayoutPreset>): List<LayoutPreset> =
        from.filter { it.id != id }
}

/**
 * Persisted, named pane layouts. Direct port of the Swift `LayoutPresetStore`
 * `@MainActor @Observable final class` (`ios/zz/BrowserStore.swift:1212`).
 *
 * Mirrors the other stores (see ANDROID_ARCH.md §3/§6/§7):
 *
 *  - The observable `presets` list is Compose snapshot state ([mutableStateListOf]),
 *    so reading it inside composition tracks it exactly like the Swift `@Observable`
 *    `presets` property. All mutation happens on the main thread.
 *  - A 300ms debounce coalesces a burst of add/delete calls into a single snapshot
 *    build + atomic disk write (matches the Swift `Task { sleep(.milliseconds(300)) }`).
 *  - Encoding happens on the main thread (cheap, coalesced by the debounce); the
 *    unbounded atomic write is handed off to [Dispatchers.IO] via the shared
 *    [PersistenceWriteOrderer], which drops a stale write whose generation is
 *    `<=` an already-committed one.
 *  - [flushSave] runs synchronously (called from a lifecycle `ON_STOP` observer in
 *    [surf.zz.ZzApplication]) with a higher generation than any pending debounce so
 *    an in-flight off-main write cannot overwrite it.
 *
 * @param filesDir the app's `Context.filesDir`; the preset file is `zz/layouts.json`
 *   beneath it (ANDROID_ARCH.md §6).
 */
class LayoutPresetStore(filesDir: File) {

    /** The persisted presets. Compose snapshot state (Swift `private(set) var presets`). */
    val presets: MutableList<LayoutPreset> = mutableStateListOf()

    private val file: File = File(File(filesDir, "zz"), "layouts.json")

    // All snapshot-state mutation + the debounce live on the main thread; the disk
    // write is dispatched to Dispatchers.IO from within the launched job.
    private val scope = CoroutineScope(Dispatchers.Main.immediate + SupervisorJob())

    private var saveJob: Job? = null
    private var saveGeneration: Long = 0

    init {
        // Load synchronously at construction (the store is created in
        // ZzApplication.onCreate; the file is small). Mirrors the Swift `init`
        // that reads + decodes the file eagerly. A missing or malformed file
        // leaves `presets` empty.
        runCatching {
            if (file.exists()) {
                val text = file.readText(Charsets.UTF_8)
                val decoded = ZzJson.decodeFromString(
                    ListSerializer(LayoutPreset.serializer()),
                    text,
                )
                presets.addAll(decoded)
            }
        }
    }

    /** Appends [preset] and schedules a debounced save. Swift `add(_:)`. */
    fun add(preset: LayoutPreset) {
        // Replace contents wholesale so the transform stays the single source of
        // truth (matches Swift `presets = LayoutPresetLogic.adding(...)`).
        val updated = LayoutPresetLogic.adding(preset, presets.toList())
        presets.clear()
        presets.addAll(updated)
        scheduleSave()
    }

    /**
     * Removes the preset with [id], scheduling a save only if something changed.
     * Swift `delete(id:)`.
     */
    fun delete(id: UUID) {
        val updated = LayoutPresetLogic.removing(id, presets.toList())
        if (updated.size == presets.size) return
        presets.clear()
        presets.addAll(updated)
        scheduleSave()
    }

    private fun scheduleSave() {
        saveJob?.cancel()
        saveJob = scope.launch {
            delay(DEBOUNCE_MILLIS)
            if (!isActive) return@launch
            // Build the snapshot only after the debounce window elapses so a burst
            // of add/delete calls coalesces into one snapshot build + write.
            val snapshot = presets.toList()
            // Assign the generation on the main thread so write ordering matches the
            // order saves were requested; a later flushSave gets a higher generation
            // and wins even if this off-main write lands after it.
            saveGeneration += 1
            val generation = saveGeneration
            val data = runCatching {
                ZzJson.encodeToString(ListSerializer(LayoutPreset.serializer()), snapshot)
                    .toByteArray(Charsets.UTF_8)
            }.getOrNull() ?: return@launch
            withContext(Dispatchers.IO) {
                PersistenceWriteOrderer.write(data, file, generation)
            }
        }
    }

    /**
     * Synchronously persist the current presets before the process is suspended.
     * Cancels the pending debounce and writes with a higher generation than any
     * scheduled save so an in-flight off-main write cannot overwrite this flush.
     * Swift `flushSave()`.
     */
    fun flushSave() {
        saveJob?.cancel()
        saveGeneration += 1
        val generation = saveGeneration
        val data = runCatching {
            ZzJson.encodeToString(ListSerializer(LayoutPreset.serializer()), presets.toList())
                .toByteArray(Charsets.UTF_8)
        }.getOrNull() ?: return
        runBlocking(Dispatchers.IO) {
            PersistenceWriteOrderer.write(data, file, generation)
        }
    }

    private companion object {
        // LayoutPresetStore debounce interval (ANDROID_ARCH.md §6).
        const val DEBOUNCE_MILLIS = 300L
    }
}
