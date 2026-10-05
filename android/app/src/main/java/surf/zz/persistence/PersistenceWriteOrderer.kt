package surf.zz.persistence

import android.util.Log
import java.io.File

/**
 * Orders atomic disk writes per file by a monotonic generation so a stale,
 * already-in-flight debounced write cannot land after a newer one (e.g. a
 * synchronous flushSave at backgrounding). The write physically runs while the
 * lock is held: that keeps the atomic rename and the last-committed-generation
 * bookkeeping consistent, and the per-file writes here are small + infrequent.
 *
 * Port of BrowserStore.swift `PersistenceWriteOrderer` (the `OSAllocatedUnfairLock`
 * over `[URL: UInt64]`). On Android we key the committed-generation map by the
 * file's absolute path (the analog of the Swift `URL`) and guard it with a
 * `synchronized` monitor — the equivalent of holding the unfair lock for the
 * duration of the write.
 *
 * `FaviconMapWriteOrderer` reuses this contract.
 */
object PersistenceWriteOrderer {

    private const val TAG = "Persistence"

    // Last-committed generation per absolute file path. Guarded by `lock`.
    private val committed = mutableMapOf<String, Long>()
    private val lock = Any()

    /**
     * Writes [data] atomically to [file], dropping the write if a generation
     * `>=` [generation] has already been committed for that file. Mirrors the
     * Swift `write(_:to:generation:)`: the physical write runs while the lock is
     * held so the rename and the bookkeeping stay consistent.
     */
    fun write(data: ByteArray, file: File, generation: Long) {
        synchronized(lock) {
            val key = file.absolutePath
            val last = committed[key]
            if (last != null && last >= generation) return
            committed[key] = generation
            try {
                AtomicFile.write(file, data)
            } catch (e: Exception) {
                Log.e(TAG, "save failed: ${e.message}")
            }
        }
    }
}
