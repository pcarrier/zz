package surf.zz.persistence

import android.util.Log
import java.io.File
import java.io.IOException
import java.nio.file.AtomicMoveNotSupportedException
import java.nio.file.Files
import java.nio.file.StandardCopyOption

/**
 * Atomic file-write helper. Replaces Swift's `Data.write(to:options:.atomic)`
 * (and the `FileManager.createDirectory(withIntermediateDirectories:)` that
 * precedes every store write in [PersistenceWriteOrderer] / the favicon IO).
 *
 * The write goes to a sibling `<name>.tmp` file first, then is atomically
 * renamed onto the destination via [Files.move] with [StandardCopyOption.ATOMIC_MOVE]
 * (falling back to a plain rename / copy when the filesystem refuses an atomic
 * move). Parent directories are created up front with [File.mkdirs].
 *
 * Used by all the JSON snapshot stores (BrowserStore, LayoutPresetStore,
 * HistoryStore, FaviconStore index) and by the per-host favicon image IO.
 */
object AtomicFile {
    private const val TAG = "Persistence"

    /** UTF-8 text convenience: `AtomicFile.write(file, ZzJson.encodeToString(payload))`. */
    fun write(file: File, content: String) {
        write(file, content.toByteArray(Charsets.UTF_8))
    }

    /**
     * Atomically write [bytes] to [file]. Creates parent directories if missing.
     * Logs and swallows IO errors (mirrors the Swift writers, which log and
     * continue rather than crash the app on a failed background save).
     */
    fun write(file: File, bytes: ByteArray) {
        val parent = file.parentFile
        if (parent != null && !parent.exists()) {
            parent.mkdirs()
        }

        // Unique-enough temp sibling in the same directory so the rename is a
        // same-filesystem move (required for ATOMIC_MOVE on internal storage).
        val tmp = File(parent, "${file.name}.tmp")
        try {
            tmp.outputStream().use { out ->
                out.write(bytes)
                out.flush()
                out.fd.sync()
            }
            moveAtomically(tmp, file)
        } catch (e: IOException) {
            Log.e(TAG, "save failed: ${e.message}")
            // Best-effort cleanup so a stale temp file doesn't linger.
            tmp.delete()
        }
    }

    /** Ensure [dir] (and parents) exist. Returns true if the directory exists afterward. */
    fun mkdirs(dir: File): Boolean = dir.exists() || dir.mkdirs()

    private fun moveAtomically(from: File, to: File) {
        try {
            Files.move(
                from.toPath(),
                to.toPath(),
                StandardCopyOption.ATOMIC_MOVE,
                StandardCopyOption.REPLACE_EXISTING,
            )
            return
        } catch (_: AtomicMoveNotSupportedException) {
            // Fall through to non-atomic fallbacks below.
        } catch (_: UnsupportedOperationException) {
            // Some filesystems reject the option combination; fall through.
        } catch (_: IOException) {
            // Fall through to renameTo / copy below.
        }

        // Fallback 1: plain rename (atomic on most local filesystems).
        if (from.renameTo(to)) return

        // Fallback 2: REPLACE_EXISTING move (non-atomic but still replaces).
        try {
            Files.move(from.toPath(), to.toPath(), StandardCopyOption.REPLACE_EXISTING)
            return
        } catch (_: IOException) {
            // Fall through to copy below.
        }

        // Fallback 3: copy bytes then drop the temp.
        from.copyTo(to, overwrite = true)
        from.delete()
    }
}
