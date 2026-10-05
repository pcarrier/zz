package surf.zz.browser.tab

import android.app.DownloadManager
import android.content.Context
import android.net.Uri
import android.os.Environment
import android.util.Log
import android.webkit.CookieManager
import android.webkit.DownloadListener
import android.webkit.URLUtil
import android.webkit.WebView
import java.io.File

/**
 * Android download path for a [Tab]'s [WebView], replacing the iOS
 * `WKDownloadDelegate` / `DownloadDelegate` / `NSSavePanel` machinery in
 * `Tab.swift` (the `decidePolicyFor`/`didBecome download` plumbing and the
 * `DownloadDelegate` class, Tab.swift:1294).
 *
 * iOS owns the whole transfer itself (a retained `WKDownloadDelegate` writes the
 * bytes into `~/Downloads`, picking a non-colliding name via `uniqueDestination`).
 * Android instead hands the transfer to the system [DownloadManager], so this
 * listener's only job is to translate a [WebView]'s download trigger into a
 * [DownloadManager.Request] targeting the public Downloads collection.
 *
 * Behavior mapping vs. the Swift `DownloadDelegate`:
 *
 * - `decideDestinationUsing` → [DownloadManager.Request.setDestinationInExternalPublicDir]
 *   with [Environment.DIRECTORY_DOWNLOADS].
 * - `sanitized(suggestedFilename:)` → [sanitizedFilename]: strip path separators,
 *   trim whitespace, fall back to `"download"`. Ported 1:1.
 * - `uniqueDestination(in:filename:)` → [uniqueDestination]: on a name collision
 *   in the Downloads directory, append `" 1"`, `" 2"`, … before the extension.
 *   Ported 1:1 from the iOS branch (Tab.swift:1352).
 * - Content-Disposition: on iOS the explicit `isAttachment` check forced the load
 *   into a download; on Android the WebView's own attachment handling fires
 *   [DownloadListener.onDownloadStart], and [DownloadManager] additionally honors
 *   the response's `Content-Disposition` for naming — so it is handled by the
 *   platform and not re-implemented here.
 *
 * DEVIATIONS (Android-only, documented):
 * - There is no `NSSavePanel` equivalent; downloads go straight to the shared
 *   Downloads collection without a save dialog (matches the iOS, not macOS, path,
 *   which is the v1 target — see ANDROID_ARCH.md).
 * - [DownloadManager] performs its own collision handling, but we still apply the
 *   ported [uniqueDestination] so the on-disk naming matches the iOS behavior
 *   (`base 1.ext`, `base 2.ext`, …) rather than the platform default
 *   (`base-1.ext`). The check is best-effort against the public directory; the
 *   manager remains the final authority and will pick its own name if it must.
 * - The transfer is fully owned by the system service, so there is no per-download
 *   delegate object to retain (the Swift `downloadDelegates` map and its
 *   `onFinish` bookkeeping have no analog).
 */
class TabDownloadListener(
    private val context: Context,
    private val onDownloadEnqueued: ((downloadId: Long, filename: String) -> Unit)? = null,
) : DownloadListener {

    override fun onDownloadStart(
        url: String?,
        userAgent: String?,
        contentDisposition: String?,
        mimeType: String?,
        contentLength: Long,
    ) {
        if (url.isNullOrEmpty()) return

        val uri = try {
            Uri.parse(url)
        } catch (e: Exception) {
            Log.w(TAG, "Unparseable download URL: $url", e)
            return
        }
        // DownloadManager only knows how to fetch http(s); data:/blob: URLs and
        // other schemes cannot be enqueued, so drop them rather than crash.
        val scheme = uri.scheme?.lowercase()
        if (scheme != "http" && scheme != "https") {
            Log.w(TAG, "Unsupported download scheme '$scheme' for $url")
            return
        }

        // Let the platform derive the best name from Content-Disposition / mime /
        // URL, then run it through the same sanitize + collision logic as iOS.
        val guessed = URLUtil.guessFileName(url, contentDisposition, mimeType)
        val filename = uniqueDestination(sanitizedFilename(guessed))

        val request = DownloadManager.Request(uri).apply {
            setMimeType(mimeType)
            // Forward cookies + UA so authenticated/session-gated downloads succeed,
            // matching WKDownload inheriting the web view's session.
            CookieManager.getInstance().getCookie(url)?.let { addRequestHeader("Cookie", it) }
            if (!userAgent.isNullOrEmpty()) addRequestHeader("User-Agent", userAgent)
            setDescription(uri.host ?: "")
            setTitle(filename)
            setDestinationInExternalPublicDir(Environment.DIRECTORY_DOWNLOADS, filename)
            setNotificationVisibility(
                DownloadManager.Request.VISIBILITY_VISIBLE_NOTIFY_COMPLETED
            )
            setAllowedOverMetered(true)
            setAllowedOverRoaming(true)
        }

        val manager = context.getSystemService(Context.DOWNLOAD_SERVICE) as? DownloadManager
        if (manager == null) {
            Log.e(TAG, "DownloadManager service unavailable; dropping download for $url")
            return
        }

        val downloadId = try {
            manager.enqueue(request)
        } catch (e: Exception) {
            Log.e(TAG, "Failed to enqueue download for $url", e)
            return
        }
        onDownloadEnqueued?.invoke(downloadId, filename)
    }

    /**
     * Port of the Swift `DownloadDelegate.sanitized(_:)` (Tab.swift:1344):
     * remove any path separators so the name cannot escape the Downloads
     * directory, trim surrounding whitespace, and fall back to `"download"`
     * when the result is empty.
     */
    private fun sanitizedFilename(suggestedFilename: String): String {
        val name = suggestedFilename
            .replace("/", "")
            .replace("\\", "")
            .trim()
        return name.ifEmpty { "download" }
    }

    /**
     * Port of the iOS `DownloadDelegate.uniqueDestination(in:filename:)`
     * (Tab.swift:1352): if `filename` already exists in the public Downloads
     * directory, append `" 1"`, `" 2"`, … before the extension until a free
     * name is found. Splitting on the last `.` matches `NSString`'s
     * `deletingPathExtension` / `pathExtension`, including the empty-extension
     * branch which uses the bare `"base index"` form with no trailing dot.
     */
    private fun uniqueDestination(filename: String): String {
        val directory = Environment.getExternalStoragePublicDirectory(
            Environment.DIRECTORY_DOWNLOADS
        )
        if (!File(directory, filename).exists()) return filename

        val dotIndex = filename.lastIndexOf('.')
        val base: String
        val ext: String
        if (dotIndex <= 0) {
            // No extension (or a leading-dot dotfile, which NSString treats as
            // having no extension): keep the whole name as the base.
            base = filename
            ext = ""
        } else {
            base = filename.substring(0, dotIndex)
            ext = filename.substring(dotIndex + 1)
        }

        var index = 1
        while (true) {
            val candidate = if (ext.isEmpty()) "$base $index" else "$base $index.$ext"
            if (!File(directory, candidate).exists()) return candidate
            index++
        }
    }

    private companion object {
        const val TAG = "TabDownloadListener"
    }
}
