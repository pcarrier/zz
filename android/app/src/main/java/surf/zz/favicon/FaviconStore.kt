package surf.zz.favicon

import android.graphics.Bitmap
import androidx.compose.runtime.mutableStateMapOf
import androidx.compose.runtime.snapshots.SnapshotStateMap
import java.io.File
import java.net.HttpURLConnection
import java.net.URL
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.Job
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.delay
import kotlinx.coroutines.launch
import kotlinx.coroutines.runBlocking
import kotlinx.coroutines.withContext
import kotlinx.serialization.SerialName
import kotlinx.serialization.Serializable
import kotlinx.serialization.decodeFromString
import kotlinx.serialization.encodeToString
import surf.zz.persistence.ZzJson

/**
 * In-memory + on-disk favicon cache keyed by canonical host. Fetches happen off
 * the main thread; decoded images and the host->filename map live on the main
 * thread and drive Compose snapshot-state updates so views refresh when an icon
 * arrives. Disk writes are debounced like the other stores.
 *
 * Direct port of `Theme.swift`'s `@MainActor @Observable final class FaviconStore`.
 *
 * State model (ANDROID_ARCH.md §3):
 *  - [images] is the only observed field — a [SnapshotStateMap] (`mutableStateMapOf`),
 *    the analog of the Swift `private var images` whose mutation republishes to
 *    `@Observable` observers. Reading it inside composition tracks it, so
 *    [imageForHost] called from a composable recomposes when an icon arrives.
 *  - [order] / [fileNames] / [inFlight] / [failed] / [saveJob] / [saveGeneration] /
 *    [imageIOTail] are plain fields (the Swift `@ObservationIgnored` members).
 *
 * Threading (ANDROID_ARCH.md §6/§7): all mutation of the fields above happens on
 * the main thread via [scope] (`Dispatchers.Main.immediate`). Network fetches hop
 * to [Dispatchers.IO]; image-file IO + the index write are delegated to the serial
 * [FaviconDiskIO] singleton; results post back on the main scope.
 *
 * The app-global singleton is created in [surf.zz.ZzApplication].
 */
class FaviconStore(filesDir: File) {

    /** On-disk image directory: `filesDir/zz/favicons` (per host `*.img` files). */
    private val imageDir: File = File(File(filesDir, "zz"), "favicons")

    /** Persisted ordered index: `filesDir/zz/favicons/index.json`. */
    private val mapFile: File = File(imageDir, "index.json")

    /** Main-thread scope owning observed-state mutation + the debounced save. */
    private val scope = CoroutineScope(Dispatchers.Main.immediate + SupervisorJob())

    /**
     * IO-thread scope that hosts the serial image-IO tail chain. Kept off the main
     * dispatcher so [flushSave]'s blocking `join()` on the chain cannot deadlock the
     * main thread (the chain's continuations never need the main dispatcher — the
     * analog of the Swift note that `imageIOTail` "never hops to MainActor").
     */
    private val imageIOScope = CoroutineScope(Dispatchers.IO + SupervisorJob())

    /**
     * Decoded images by canonical host — the single observed field. Mutating it
     * republishes to Compose readers (Swift `private var images: [String: PlatformImage]`).
     */
    val images: SnapshotStateMap<String, Bitmap> = mutableStateMapOf()

    /** Insertion / most-recent-use order for LRU eviction (oldest first). */
    private val order: MutableList<String> = mutableListOf()

    /** Persisted host -> on-disk filename map. */
    private val fileNames: MutableMap<String, String> = mutableMapOf()

    /** Hosts with an in-flight or already-attempted fetch, to avoid duplicates. */
    private val inFlight: MutableSet<String> = mutableSetOf()

    /** Hosts whose fetch failed entirely; don't keep retrying within a session. */
    private val failed: MutableSet<String> = mutableSetOf()

    /** The pending debounced index save, cancelled/replaced on every schedule. */
    private var saveJob: Job? = null

    /**
     * Monotonic per-store generation so a stale, already-in-flight debounced map
     * write cannot overwrite a newer [flushSave] at backgrounding (matches the
     * invariant used by BrowserStore/HistoryStore/LayoutPresetStore).
     */
    private var saveGeneration: Long = 0L

    /**
     * Serial tail for image-file IO. Each write/delete chains off the previous one
     * (`previous.join()`) so operations on the same deterministic filename run in
     * enqueue order — the analog of the Swift `imageIOTail` Task chain. The actual
     * file work runs on [FaviconDiskIO]'s single-parallelism dispatcher; this tail
     * job only enforces enqueue ordering and gives [flushSave] something to join.
     */
    private var imageIOTail: Job = Job().apply { complete() }

    /**
     * One persisted host->filename pair. Persisting an ordered array of these
     * (oldest first) preserves LRU recency across launches, which a bare map
     * cannot since map key order is unspecified. Ports the Swift `struct Entry`.
     *
     * The JSON field is `name` (Swift `Entry.name`), kept stable so the on-disk
     * shape does not depend on the Kotlin property name.
     */
    @Serializable
    private data class Entry(
        val host: String,
        @SerialName("name") val fileName: String,
    )

    init {
        // Hydrate the ordered index from disk. Prefer the ordered `[Entry]` form;
        // fall back to a legacy bare `{host: name}` map once (subsequent saves
        // rewrite the ordered form). Mirrors the Swift `init()` decode.
        val text = runCatching { mapFile.readText(Charsets.UTF_8) }.getOrNull()
        if (text != null) {
            val entries = runCatching { ZzJson.decodeFromString<List<Entry>>(text) }.getOrNull()
            if (entries != null) {
                for (e in entries) {
                    fileNames[e.host] = e.fileName
                    touch(e.host) // uniquing: last write wins, with one LRU slot
                }
            } else {
                val legacy = runCatching {
                    ZzJson.decodeFromString<Map<String, String>>(text)
                }.getOrNull()
                if (legacy != null) {
                    fileNames.putAll(legacy)
                    order.addAll(legacy.keys)
                }
            }
        }
    }

    /**
     * Ordered snapshot for persistence, oldest first. Hosts present in [order]
     * that still have a filename are written; this is the authoritative LRU
     * sequence used on restore. Ports Swift `entriesForSave()`.
     */
    private fun entriesForSave(): List<Entry> =
        order.mapNotNull { host -> fileNames[host]?.let { Entry(host, it) } }

    /**
     * Returns the cached image for [rawHost], hydrating lazily from disk and
     * kicking off a network fetch when absent. Must be called on the main thread
     * (it reads/writes observed snapshot state); reading [images] inside
     * composition tracks it so the caller recomposes when an icon arrives. Ports
     * Swift `image(forHost:)`.
     */
    fun imageForHost(rawHost: String): Bitmap? {
        val host = rawHost.lowercase()
        if (host.isEmpty()) return null

        images[host]?.let { img ->
            touch(host)
            return img
        }

        // Lazily hydrate from disk if we have a stored file for this host. Return
        // the decoded image immediately, but defer the observed write to `images`
        // to the next runloop tick: mutating tracked state inside the current
        // composition/view-body evaluation is undefined behavior.
        val name = fileNames[host]
        if (name != null) {
            val data = runCatching { File(imageDir, name).readBytes() }.getOrNull()
            val img = data?.let { FaviconLogic.decode(it) }
            if (img != null) {
                scope.launch {
                    if (images[host] == null) {
                        store(image = img, host = host, persist = false)
                    }
                }
                return img
            }
        }

        fetchIfNeeded(host)
        return null
    }

    /**
     * Starts an off-main `/favicon.ico` fetch for [host] unless one is already
     * in flight or has previously failed this session. Ports Swift `fetchIfNeeded`.
     */
    private fun fetchIfNeeded(host: String) {
        if (inFlight.contains(host) || failed.contains(host)) return
        inFlight.add(host)
        val candidates = FaviconLogic.candidateURLs(host)
        if (candidates.isEmpty()) {
            inFlight.remove(host)
            return
        }
        scope.launch {
            val data = withContext(Dispatchers.IO) { fetch(candidates) }
            // Back on the main scope: apply the result to observed state.
            inFlight.remove(host)
            val img = data?.let { FaviconLogic.decode(it) }
            if (data != null && img != null) {
                store(image = img, host = host, persist = true, data = data)
            } else {
                failed.add(host)
            }
        }
    }

    /** Promote [host] to most-recently-used (move to end of [order]). */
    private fun touch(host: String) {
        order.removeAll { it == host }
        order.add(host)
    }

    /**
     * Inserts a decoded image for [host], optionally persisting its bytes + index.
     * Ports Swift `store(image:for:persist:data:)`.
     */
    private fun store(image: Bitmap, host: String, persist: Boolean, data: ByteArray? = null) {
        images[host] = image
        touch(host)
        if (persist) {
            val name = fileNames[host] ?: FaviconLogic.fileName(host)
            fileNames[host] = name
            if (data != null) {
                writeImageOffMain(data, name)
            }
            scheduleSaveMap()
        }
        evictIfNeeded()
    }

    /**
     * Evicts the oldest hosts beyond the cap from memory + disk and schedules an
     * index save when anything was removed. Ports Swift `evictIfNeeded()`.
     */
    private fun evictIfNeeded() {
        val victims = FaviconLogic.hostsToEvict(order, MAX_ENTRIES)
        if (victims.isEmpty()) return
        for (host in victims) {
            images.remove(host)
            fileNames.remove(host)?.let { name -> removeImageOffMain(name) }
        }
        // order.removeFirst(victims.count) — drop the evicted prefix.
        repeat(victims.size) { order.removeAt(0) }
        scheduleSaveMap()
    }

    /**
     * Debounced (500 ms) index write. Cancels any pending save, snapshots the
     * ordered entries on the main thread, then assigns the generation + encodes +
     * writes off-main via [FaviconDiskIO.writeIndex] (which delegates to the shared
     * generation-ordered writer). Ports Swift `scheduleSaveMap()`.
     */
    private fun scheduleSaveMap() {
        saveJob?.cancel()
        // Snapshot the ordered entries now (on the main thread), matching the
        // Swift capture before the sleep.
        val snapshot = entriesForSave()
        saveJob = scope.launch {
            delay(DEBOUNCE_MS)
            // Assign the generation on the main thread so write ordering matches
            // the order saves were requested; a later flushSave gets a higher
            // generation and will win even if this off-main write lands after it.
            saveGeneration += 1
            val generation = saveGeneration
            val data = runCatching { ZzJson.encodeToString(snapshot) }.getOrNull() ?: return@launch
            withContext(Dispatchers.IO) {
                FaviconDiskIO.writeIndex(data.toByteArray(Charsets.UTF_8), mapFile, generation)
            }
        }
    }

    /**
     * Synchronous flush before the process is suspended. Drains any enqueued
     * image-byte writes first so `index.json` cannot reference a filename whose
     * bytes never landed, then writes the index blocking on [Dispatchers.IO] with
     * a generation higher than any pending [scheduleSaveMap]. Invoked from the
     * `ProcessLifecycleOwner` observer in [surf.zz.ZzApplication]. Ports Swift
     * `flushSave()`.
     */
    fun flushSave() {
        saveJob?.cancel()
        // Drain enqueued image IO before persisting the map. The chain only runs
        // on FaviconDiskIO's IO dispatcher and never hops back to the main thread,
        // so blocking here cannot deadlock. Captured before computing the map so
        // every file the snapshot references is committed first.
        val pendingImageIO = imageIOTail
        runBlocking { pendingImageIO.join() }

        saveGeneration += 1
        val generation = saveGeneration
        val data = runCatching { ZzJson.encodeToString(entriesForSave()) }.getOrNull() ?: return
        runBlocking(Dispatchers.IO) {
            FaviconDiskIO.writeIndex(data.toByteArray(Charsets.UTF_8), mapFile, generation)
        }
    }

    // MARK: Off-main IO (only ByteArray/String cross the boundary)

    /**
     * Fetches the first candidate that returns decodable image bytes with a 2xx
     * status, 8 s timeout, on the IO dispatcher. Returns null if none succeed.
     * Ports Swift `static func fetch(candidates:)`.
     */
    private fun fetch(candidates: List<String>): ByteArray? {
        for (urlString in candidates) {
            try {
                val conn = (URL(urlString).openConnection() as HttpURLConnection).apply {
                    connectTimeout = TIMEOUT_MS
                    readTimeout = TIMEOUT_MS
                    requestMethod = "GET"
                    instanceFollowRedirects = true
                }
                try {
                    val code = conn.responseCode
                    if (code !in 200..299) continue
                    val data = conn.inputStream.use { it.readBytes() }
                    if (FaviconLogic.decode(data) != null) return data
                } finally {
                    conn.disconnect()
                }
            } catch (_: Exception) {
                continue
            }
        }
        return null
    }

    /**
     * Enqueues an atomic image-bytes write onto the serial [imageIOTail] chain,
     * delegating the file work to [FaviconDiskIO.writeImage] (single-parallelism
     * dispatcher). Ports Swift `writeImageOffMain`.
     */
    private fun writeImageOffMain(data: ByteArray, name: String) {
        val previous = imageIOTail
        imageIOTail = imageIOScope.launch {
            previous.join()
            FaviconDiskIO.writeImage(data, name, imageDir)
        }
    }

    /**
     * Enqueues an image-file delete onto the serial [imageIOTail] chain so a stale
     * delete cannot reorder ahead of a fresh write of the same path, delegating to
     * [FaviconDiskIO.removeImage]. Ports Swift `removeImageOffMain`.
     */
    private fun removeImageOffMain(name: String) {
        val previous = imageIOTail
        imageIOTail = imageIOScope.launch {
            previous.join()
            FaviconDiskIO.removeImage(name, imageDir)
        }
    }

    /**
     * Cancels the debounce/IO scope. The app-global singleton lives for the
     * process, so this is rarely needed; provided for symmetry/testing
     * (ANDROID_ARCH.md §7 — no deterministic `deinit`).
     */
    fun close() {
        scope.coroutineContext[Job]?.cancel()
        imageIOScope.coroutineContext[Job]?.cancel()
    }

    companion object {
        /** Cap on cached hosts kept in memory and on disk (Swift `maxEntries`). */
        const val MAX_ENTRIES = 400

        /** Favicon index debounce interval (Swift 500 ms; ANDROID_ARCH.md §6). */
        private const val DEBOUNCE_MS = 500L

        /** Per-request fetch timeout (Swift `request.timeoutInterval = 8`). */
        private const val TIMEOUT_MS = 8_000
    }
}
