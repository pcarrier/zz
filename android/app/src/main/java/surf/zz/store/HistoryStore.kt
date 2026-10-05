package surf.zz.store

import androidx.compose.runtime.mutableStateListOf
import androidx.compose.runtime.snapshots.SnapshotStateList
import java.io.File
import java.time.Instant
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.Job
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.delay
import kotlinx.coroutines.launch
import kotlinx.coroutines.runBlocking
import kotlinx.coroutines.withContext
import kotlinx.serialization.Serializable
import kotlinx.serialization.decodeFromString
import kotlinx.serialization.encodeToString
import surf.zz.omnibox.OmniboxItem
import surf.zz.omnibox.OmniboxSuggestions
import surf.zz.persistence.InstantEpochMillisSerializer
import surf.zz.persistence.PersistenceWriteOrderer
import surf.zz.persistence.ZzJson
import surf.zz.prefs.BrowserPreferences
import surf.zz.url.UrlCanonicalizer

/**
 * A single global-history entry. LRU-ordered (most-recently-visited first) by the
 * owning [HistoryStore].
 *
 * Direct 1:1 port of the iOS `HistoryEntry` struct (`BrowserStore.swift:1279`).
 *
 * Identity is the [url] itself (Swift `var id: String { url }`), matching the
 * Swift `Identifiable` conformance.
 *
 * Serialization (`@Serializable`) mirrors the Swift `Codable` keys
 * (`url, title, lastVisited, visitCount`):
 *  - [title] is nullable with a `null` default — omitted from JSON when absent
 *    (`ZzJson.explicitNulls = false`), the analog of Swift `encodeIfPresent`.
 *  - [lastVisited] uses [InstantEpochMillisSerializer] (epoch millis `Long`); see
 *    that serializer for the deliberate divergence from iOS's seconds-since-2001
 *    `Double`. Android history files are independent from iOS (fresh install), so
 *    no shared format is required (ANDROID_ARCH.md §5).
 *  - [visitCount] defaults to `1` (Swift `decodeIfPresent(...) ?? 1`).
 *
 * [canonicalKey] is the derived dedup/match key — NOT serialized (computed `get()`),
 * exactly like the Swift `var canonicalKey: String { URLCanonicalizer.key(url) }`.
 */
@Serializable
data class HistoryEntry(
    var url: String,
    var title: String? = null,
    @Serializable(with = InstantEpochMillisSerializer::class)
    var lastVisited: Instant,
    var visitCount: Int = 1,
) {
    /** Stable identity: the URL string (Swift `var id: String { url }`). */
    val id: String get() = url

    /** NOT stored/coded; derived dedup + match key. */
    val canonicalKey: String get() = UrlCanonicalizer.key(url)
}

/**
 * Global browsing history: an LRU list (most-recently-visited first), capped at
 * [LIMIT] entries, deduplicated by [HistoryEntry.canonicalKey], and persisted with
 * a 400 ms debounced atomic write to `filesDir/zz/history.json`.
 *
 * Direct port of the iOS `@MainActor @Observable final class HistoryStore`
 * (`BrowserStore.swift:1974`). Per ANDROID_ARCH.md §3, the Swift `@Observable`
 * class becomes a plain Kotlin class whose observable `entries` field is Compose
 * snapshot state ([mutableStateListOf]); all mutation happens on the main thread
 * and the disk write is dispatched to [Dispatchers.IO].
 *
 * Public surface (matching Swift):
 *  - [record] — record a visit (dedup + bump + LRU re-insert + cap), gated by
 *    [BrowserPreferences.recordsHistory].
 *  - [clear] — wipe all history.
 *  - [delete] — remove a single entry by [HistoryEntry] or by URL (canonical key).
 *  - [omniboxSuggestions] — delegate to [OmniboxSuggestions.entries].
 *
 * Persistence (ANDROID_ARCH.md §6):
 *  - Debounce 400 ms via [scope] + [saveJob] (replaces Swift's
 *    `Task { sleep; cancel }`).
 *  - The snapshot is built on the main thread after the debounce window, then the
 *    atomic write runs off-main through [PersistenceWriteOrderer] (a monotonic
 *    [saveGeneration] guards write ordering so a stale in-flight write can never
 *    overwrite a newer one — including a synchronous [flushSave] at backgrounding).
 *  - [flushSave] is synchronous (`runBlocking(Dispatchers.IO)`), invoked from the
 *    [surf.zz.ZzApplication] `ProcessLifecycleOwner` `ON_STOP` observer.
 */
class HistoryStore(filesDir: File) {

    /**
     * The history list, most-recently-visited first. Compose snapshot state
     * (the analog of Swift's `@Observable private(set) var entries`). Exposed
     * read-only; all mutation goes through [record] / [clear] / [delete].
     */
    private val _entries: SnapshotStateList<HistoryEntry> = mutableStateListOf()
    val entries: List<HistoryEntry> get() = _entries

    /** Main-thread scope owning the debounced save (ANDROID_ARCH.md §6/§7). */
    private val scope = CoroutineScope(Dispatchers.Main.immediate + SupervisorJob())

    /** The pending debounced save, cancelled and replaced on every [scheduleSave]. */
    private var saveJob: Job? = null

    /**
     * Monotonic write generation. Assigned on the main thread when a save is
     * dispatched so write ordering matches the order saves were requested; a later
     * [flushSave] gets a higher generation and wins even if an earlier off-main
     * write lands after it.
     */
    private var saveGeneration: Long = 0L

    private val file: File = File(File(filesDir, "zz"), "history.json")

    init {
        // Load the persisted history synchronously at construction, matching the
        // Swift initializer (`Data(contentsOf:)` + `JSONDecoder().decode`).
        // Unreadable/corrupt/missing files leave `entries` empty.
        runCatching {
            if (file.exists()) {
                val text = file.readText(Charsets.UTF_8)
                val decoded = ZzJson.decodeFromString<List<HistoryEntry>>(text)
                _entries.addAll(decoded)
            }
        }
    }

    /**
     * Records a visit to [url] (with an optional [title]).
     *
     * Mirrors Swift `record(url:title:)` exactly:
     *  - No-op when history recording is disabled ([BrowserPreferences.recordsHistory]).
     *  - Trims the URL; ignores empty and `about:blank`.
     *  - Dedups by [HistoryEntry.canonicalKey]: an existing entry is removed, its
     *    visit count bumped, `lastVisited` set to now, title updated when a non-empty
     *    one is supplied, and its display URL upgraded to the longer (more specific)
     *    form; then re-inserted at the front (LRU).
     *  - A new key is inserted at the front with `visitCount = 1`.
     *  - The list is capped at [LIMIT] (oldest dropped).
     */
    fun record(url: String, title: String?) {
        if (!BrowserPreferences.recordsHistory) return
        val trimmed = url.trim()
        if (trimmed.isEmpty() || trimmed.lowercase() == "about:blank") return
        val key = UrlCanonicalizer.key(trimmed)

        val copy = ArrayList(_entries)
        val idx = copy.indexOfFirst { it.canonicalKey == key }
        if (idx >= 0) {
            val existing = copy.removeAt(idx)
            existing.visitCount += 1
            existing.lastVisited = Instant.now()
            if (!title.isNullOrEmpty()) existing.title = title
            // Prefer a more specific (longer) display URL form.
            if (trimmed.length > existing.url.length) existing.url = trimmed
            copy.add(0, existing)
        } else {
            copy.add(0, HistoryEntry(url = trimmed, title = title, lastVisited = Instant.now(), visitCount = 1))
        }

        val capped = if (copy.size > LIMIT) copy.subList(0, LIMIT) else copy
        _entries.clear()
        _entries.addAll(capped)
        scheduleSave()
    }

    /** Clears all history. Mirrors Swift `clear()`. */
    fun clear() {
        _entries.clear()
        scheduleSave()
    }

    /** Removes the given [entry]. Mirrors Swift `delete(_:)`. */
    fun delete(entry: HistoryEntry) {
        delete(entry.url)
    }

    /**
     * Removes every entry whose canonical key matches [url]'s. No-op (no save) when
     * nothing matched. Mirrors Swift `delete(url:)`.
     */
    fun delete(url: String) {
        val key = UrlCanonicalizer.key(url)
        val filtered = _entries.filter { it.canonicalKey != key }
        if (filtered.size == _entries.size) return
        _entries.clear()
        _entries.addAll(filtered)
        scheduleSave()
    }

    /**
     * Ranked omnibox suggestions for [query], combining the live open-tab
     * candidates with this store's history. Pure delegation to
     * [OmniboxSuggestions.entries]. Mirrors Swift
     * `omniboxSuggestions(matching:openTabs:now:limit:)`.
     */
    fun omniboxSuggestions(
        query: String,
        openTabs: List<OmniboxSuggestions.OpenTab> = emptyList(),
        now: Instant = Instant.now(),
        limit: Int = 8,
    ): List<OmniboxItem> =
        OmniboxSuggestions.entries(
            query = query,
            history = _entries.toList(),
            openTabs = openTabs,
            now = now,
            limit = limit,
        )

    // MARK: - Persistence

    /**
     * Debounced save (400 ms). Builds the snapshot only after the debounce window
     * elapses, so a burst of [record] calls coalesces into a single main-thread
     * snapshot build, then hands the encoded bytes to the off-main
     * [PersistenceWriteOrderer]. Mirrors Swift `scheduleSave()`.
     */
    private fun scheduleSave() {
        saveJob?.cancel()
        saveJob = scope.launch {
            delay(DEBOUNCE_MS)
            val snapshot = _entries.toList()
            saveGeneration += 1
            val generation = saveGeneration
            val data = runCatching { ZzJson.encodeToString(snapshot) }.getOrNull() ?: return@launch
            withContext(Dispatchers.IO) {
                PersistenceWriteOrderer.write(data.toByteArray(Charsets.UTF_8), file, generation)
            }
        }
    }

    /**
     * Synchronous flush before the process is suspended. Cancels the debounce,
     * builds the snapshot on the calling (main) thread, and writes blocking on
     * [Dispatchers.IO]. A higher [saveGeneration] than any pending [scheduleSave]
     * ensures an in-flight off-main write cannot overwrite this flush. Mirrors
     * Swift `flushSave()`.
     */
    fun flushSave() {
        saveJob?.cancel()
        saveGeneration += 1
        val generation = saveGeneration
        val data = runCatching { ZzJson.encodeToString(_entries.toList()) }.getOrNull() ?: return
        runBlocking(Dispatchers.IO) {
            PersistenceWriteOrderer.write(data.toByteArray(Charsets.UTF_8), file, generation)
        }
    }

    /**
     * Cancels the debounce scope. Owners have no deterministic `deinit`
     * (ANDROID_ARCH.md §7); the app-global singleton lives for the process so this
     * is rarely needed, but provided for symmetry/testing.
     */
    fun close() {
        scope.coroutineContext[Job]?.cancel()
    }

    companion object {
        /** LRU cap (Swift `private let limit = 2000`). */
        const val LIMIT = 2000

        /** Debounce interval for the history store (ANDROID_ARCH.md §6). */
        private const val DEBOUNCE_MS = 400L
    }
}
