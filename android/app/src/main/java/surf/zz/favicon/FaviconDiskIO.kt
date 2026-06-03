package surf.zz.favicon

import android.util.Log
import kotlinx.coroutines.CoroutineDispatcher
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.withContext
import surf.zz.persistence.AtomicFile
import surf.zz.persistence.PersistenceWriteOrderer
import java.io.File

/**
 * Serialized favicon image-file IO plus the generation-ordered index writer.
 *
 * Ports the `FaviconDiskIO` actor and `FaviconMapWriteOrderer` from `Theme.swift`.
 *
 * ## Why serialize image IO
 *
 * Favicon filenames are deterministic (FNV-1a of the host, see
 * [FaviconLogic.fileName]), so a host's image always lives at the same path. If
 * a stale debounced *delete* and a fresh *write* of the same path were dispatched
 * as independent jobs they could reorder, leaving the index referencing a file
 * whose bytes were deleted last. The Swift code prevents this with an `actor`
 * (one serial executor). On Android we mirror that with a single-parallelism IO
 * dispatcher: every [writeImage]/[removeImage] runs on
 * `Dispatchers.IO.limitedParallelism(1)`, so operations on the same filename run
 * in enqueue order. Callers preserve enqueue order by `await`ing each call in
 * sequence (FaviconStore chains them off a single tail job, the analog of the
 * Swift `imageIOTail`).
 *
 * ## Index writer
 *
 * The host -> filename index (`index.json`) is written through
 * [PersistenceWriteOrderer], which drops a write whose generation is `<=` one
 * already committed for that path. That is the Android analog of Swift's
 * dedicated `FaviconMapWriteOrderer`: a stale, already-in-flight debounced map
 * write can never overwrite a newer `flushSave` performed at backgrounding. The
 * physical write runs while the orderer's lock is held so the atomic rename and
 * the last-committed-generation bookkeeping stay consistent.
 *
 * This object is a process-wide singleton (the Swift `FaviconDiskIO.shared` /
 * `FaviconMapWriteOrderer.shared`): a single serial queue across the whole app is
 * what guarantees ordering, and no other store writes the favicon index.
 */
object FaviconDiskIO {

    private const val TAG = "Favicons"

    /**
     * Single-threaded IO dispatcher. The whole point is exactly one in-flight
     * image operation at a time so writes/deletes for the same deterministic
     * filename cannot reorder — the coroutine equivalent of the Swift `actor`'s
     * serial executor.
     */
    @OptIn(kotlinx.coroutines.ExperimentalCoroutinesApi::class)
    private val imageIoDispatcher: CoroutineDispatcher =
        Dispatchers.IO.limitedParallelism(1)

    /**
     * Atomically write [bytes] for a host image named [name] into [dir]. Ports
     * `FaviconDiskIO.write(_:name:dir:)`: creates the directory if missing, writes
     * atomically, and logs+swallows failures (never crashes the caller). Runs on
     * the serial image-IO dispatcher.
     */
    suspend fun writeImage(bytes: ByteArray, name: String, dir: File) {
        withContext(imageIoDispatcher) {
            try {
                if (!dir.exists()) dir.mkdirs()
                AtomicFile.write(File(dir, name), bytes)
            } catch (e: Exception) {
                Log.e(TAG, "Favicon image write failed: ${e.message}")
            }
        }
    }

    /**
     * Remove the host image named [name] from [dir]. Ports
     * `FaviconDiskIO.remove(name:dir:)` (`try?` removeItem). Runs on the serial
     * image-IO dispatcher so a delete cannot overtake a queued write of the same
     * path. Missing files are ignored.
     */
    suspend fun removeImage(name: String, dir: File) {
        withContext(imageIoDispatcher) {
            try {
                File(dir, name).delete()
            } catch (e: Exception) {
                Log.e(TAG, "Favicon image remove failed: ${e.message}")
            }
        }
    }

    /**
     * Write the favicon [indexFile] (`index.json`) atomically, guarded by
     * [generation]. Drops the write if a generation `>=` [generation] has already
     * been committed for that path — the verbatim guard from Swift's
     * `FaviconMapWriteOrderer.write(_:to:generation:)`, delegated to the shared
     * [PersistenceWriteOrderer].
     *
     * Synchronous (not dispatched here): the caller decides whether to invoke it
     * from a background context (debounced save) or block on it (flushSave at
     * backgrounding). The orderer's own lock makes the rename + bookkeeping
     * atomic regardless of caller thread.
     */
    fun writeIndex(bytes: ByteArray, indexFile: File, generation: Long) {
        PersistenceWriteOrderer.write(bytes, indexFile, generation)
    }
}
