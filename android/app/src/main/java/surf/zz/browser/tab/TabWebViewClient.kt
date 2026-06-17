package surf.zz.browser.tab

import android.graphics.Bitmap
import android.webkit.HttpAuthHandler
import android.webkit.RenderProcessGoneDetail
import android.webkit.WebResourceError
import android.webkit.WebResourceRequest
import android.webkit.WebResourceResponse
import android.webkit.WebView
import android.webkit.WebViewClient

/**
 * [WebViewClient] that bridges WebView navigation / auth / render-process callbacks
 * into the owning [Tab].
 *
 * ## Swift origin
 *
 * This replaces TWO things from `ios/zz/Tab.swift`:
 *
 *  1. **`TabNavigationDelegate`** (the `WKNavigationDelegate`, Tab.swift:1156): the
 *     `didFinish` / `didSameDocumentNavigation` / `didFail*` / `didReceive challenge`
 *     / `webViewWebContentProcessDidTerminate` callbacks. Each one hopped onto the
 *     main actor and forwarded to the `owner` [Tab]; we do the same here. WebView
 *     callbacks already arrive on the main (UI) thread, which is the Android analog
 *     of `@MainActor`, so no extra dispatch is needed (ANDROID_ARCH.md §4: "these
 *     callbacks write the Tab's snapshot state on the main thread").
 *
 *  2. **The KVO observers wired in `Tab.wire()`** (Tab.swift:812) for `url`,
 *     `title`, `canGoBack`, `canGoForward`, and `isLoading`. Android has no KVO on
 *     `WebView`; the equivalent signal arrives through the navigation lifecycle
 *     callbacks (`onPageStarted` / `doUpdateVisitedHistory` / `onPageFinished`),
 *     where we read `view.url` / `view.title` and **poll** `canGoBack` /
 *     `canGoForward` off the WebView (ANDROID_ARCH.md §4: "canGoBack/canGoForward
 *     are polled from the WebView in those callbacks").
 *
 * All mutation of the [Tab]'s snapshot state happens on the main thread; the
 * lifecycle bookkeeping (`isRestoring` history suppression, `isNavigationInFlight`
 * scroll-zero guarding, deferred restore-clear) lives inside [Tab] exactly as it
 * does on iOS — this client only forwards the platform events into the [Tab]
 * methods that mirror the iOS `owner.*` calls.
 *
 * ## Callback mapping
 *
 * | iOS (`WKNavigationDelegate` / KVO)        | Android (`WebViewClient`)            |
 * |-------------------------------------------|--------------------------------------|
 * | KVO `isLoading` -> true (load begins)     | [onPageStarted]                      |
 * | KVO `url` observer + history record       | [onPageStarted] / [doUpdateVisitedHistory] |
 * | KVO `title` observer + history record     | title read in the lifecycle callbacks |
 * | KVO `canGoBack` / `canGoForward`          | polled in every lifecycle callback   |
 * | `didFinish` / `didSameDocumentNavigation` | [onPageFinished]                     |
 * | `didFail` / `didFailProvisionalNavigation`| [onReceivedError]                    |
 * | `didReceive challenge` (HTTP auth)        | [onReceivedHttpAuthRequest]          |
 * | `webViewWebContentProcessDidTerminate`    | [onRenderProcessGone]                |
 *
 * `decidePolicyFor navigationResponse` (the download interception) and the
 * `didBecome download` plumbing live in [surf.zz.browser.tab.TabDownloadListener]
 * (`WebView.setDownloadListener`), not here, because Android surfaces downloads
 * through a separate `DownloadListener` rather than the navigation delegate.
 */
class TabWebViewClient(private val tab: Tab) : WebViewClient() {

    /**
     * A navigation committed and started painting. Mirrors WebKit flipping
     * `isLoading` to true plus the first `url` KVO fire: push the loading flag,
     * update [Tab.currentUrl] from the live WebView, and resync the back/forward
     * affordances.
     *
     * History is NOT recorded here. On iOS the `url`/`title` KVO observers record
     * history once a page has a real URL/title; [onPageStarted] fires before the
     * document settles, so we defer history recording to [doUpdateVisitedHistory]
     * (a committed visit) / [onPageFinished], matching the iOS timing where
     * recording is gated on `!isRestoring` and a settled load.
     */
    override fun onPageStarted(view: WebView, url: String?, favicon: Bitmap?) {
        tab.updateLoading(true)
        syncNavigationState(view, url)
    }

    /**
     * The session history changed (a real visit was committed, including SPA
     * `history.pushState` and in-page fragment navigations). This is Android's
     * closest analog to the iOS `url` KVO observer firing for a committed page, so
     * record history here. The recording itself lives inside [Tab.onUrlChanged] /
     * [Tab.onTitleChanged] (gated by `isRestoring`, matching iOS); this callback
     * just resyncs, which triggers it.
     *
     * @param isReload true when the URL change is a reload of the current entry;
     *   unused here because [Tab] applies the same `isRestoring` gate regardless.
     */
    override fun doUpdateVisitedHistory(view: WebView, url: String?, isReload: Boolean) {
        // syncNavigationState forwards the URL/title to Tab.onUrlChanged /
        // Tab.onTitleChanged, which is where history recording happens (gated by the
        // tab's isRestoring flag and the about:blank/empty skip), exactly mirroring
        // the iOS url/title KVO observers. So this committed visit is recorded as a
        // side effect of the resync; there is no separate record call.
        syncNavigationState(view, url)
    }

    /**
     * A navigation finished. Mirrors `WKNavigationDelegate.didFinish` /
     * `didSameDocumentNavigation` (Tab.swift:1170, 1176): both forwarded to
     * `owner.didFinishNavigation()`, which clears `isNavigationInFlight`, schedules
     * the deferred `isRestoring` clear, and **re-applies CSS zoom + media-suspend +
     * the deferred scroll restore**. We keep that whole sequence inside
     * [Tab.didFinishNavigation] so the generation/scroll bookkeeping stays in one
     * place, and only do the snapshot resync (URL/title/back-forward/loading) here,
     * which on iOS came from the KVO observers.
     */
    override fun onPageFinished(view: WebView, url: String?) {
        tab.updateLoading(false)
        syncNavigationState(view, url)
        // Re-applies pageZoom + media suspension + the deferred scroll restore, and
        // clears the in-flight / restoring flags (with the deferred restore-clear).
        tab.didFinishNavigation()
    }

    /**
     * A resource load failed. We forward to [Tab.handleNavigationFailure] only for
     * **main-frame** errors, matching the iOS `didFail` / `didFailProvisionalNavigation`
     * callbacks, which fire only for the page navigation itself — not for every
     * failed subresource (image/script/xhr), which `onReceivedError` also reports on
     * Android. Without the main-frame guard a single broken image would clear the
     * in-flight flags mid-load and let a stale scroll-zero be persisted.
     */
    override fun onReceivedError(
        view: WebView,
        request: WebResourceRequest,
        error: WebResourceError,
    ) {
        if (request.isForMainFrame) {
            tab.handleNavigationFailure()
        }
    }

    /**
     * An HTTP error status (>= 400) for a main-frame load. WebKit surfaces these as
     * a completed navigation (WebKit renders the server's error body), so iOS did
     * NOT treat them as `didFail`; Android delivers them through this callback. We
     * deliberately do not clear the in-flight flags here — [onPageFinished] still
     * fires for an HTTP-error page that renders a body, so treating it as a failure
     * would double-clear and could drop a legitimate scroll restore. (Left as an
     * explicit no-op override only for documentation; remove if churn matters.)
     */
    override fun onReceivedHttpError(
        view: WebView,
        request: WebResourceRequest,
        errorResponse: WebResourceResponse,
    ) {
        // Intentionally no-op: see KDoc. onPageFinished handles the settled state.
    }

    /**
     * An HTTP authentication challenge (Basic/Digest/NTLM/Negotiate). Mirrors
     * `TabNavigationDelegate.webView(_:didReceive:completionHandler:)` (Tab.swift:1263),
     * which filtered to the HTTP-auth methods and then forwarded to
     * `owner.respondToHTTPAuthenticationChallenge(_:completionHandler:)`.
     *
     * On Android `WebView` only ever raises this callback for the HTTP-auth methods
     * (Basic/Digest), so the method allow-list filter from iOS is implicit; there is
     * no `performDefaultHandling` disposition to fall back to. We bridge the
     * per-challenge [HttpAuthHandler] into the proceed/cancel callbacks [Tab] expects
     * and forward the protection-space identity (`host` / `realm`) plus the retry
     * flag. [Tab] consults the [surf.zz.browser.auth.HttpAuthCredentialStore], reuses
     * an in-memory / stored / WebView-cached credential when one is available, and
     * otherwise presents a prompt whose completions are queued through
     * [surf.zz.browser.auth.HttpAuthPendingCompletions].
     *
     * `isRetry` maps the iOS `challenge.previousFailureCount > 0`: Android signals a
     * repeat challenge for a failed credential with
     * `handler.useHttpAuthUsernamePassword() == false`.
     *
     * @param handler the WebView's per-challenge handler. On proceed we call
     *   `handler.proceed(user, password)`; on cancel `handler.cancel()` (the Android
     *   analogs of `.useCredential` / `.cancelAuthenticationChallenge`).
     */
    override fun onReceivedHttpAuthRequest(
        view: WebView,
        handler: HttpAuthHandler,
        host: String,
        realm: String,
    ) {
        tab.respondToHttpAuthChallenge(
            host = host,
            realm = realm,
            isRetry = !handler.useHttpAuthUsernamePassword(),
            proceed = { credential -> handler.proceed(credential.user, credential.password) },
            cancel = { handler.cancel() },
        )
    }

    /**
     * The WebView's renderer process died. Mirrors
     * `webViewWebContentProcessDidTerminate` (Tab.swift:1286) ->
     * `owner.recoverFromTermination()`, which stashes the last scroll offset as a
     * pending restore, marks a navigation in flight, and reloads (or re-issues the
     * original load when there is no committed entry yet).
     *
     * Returning `true` tells the framework we handled the loss and the [WebView] can
     * keep being used; returning `false` (or not handling it) would let the system
     * destroy the WebView. We must keep the WebView alive because it is owned by the
     * [Tab], not by Compose (ANDROID_ARCH.md §4). We only recover when the renderer
     * crashed (`didCrash`); if the system killed it to reclaim memory we still
     * recover, since either way the page must be reloaded to be usable again.
     *
     * @return `true` always — we handle the loss and reload in place.
     */
    override fun onRenderProcessGone(view: WebView, detail: RenderProcessGoneDetail?): Boolean {
        // detail.didCrash() distinguishes a true renderer crash from a system kill;
        // both leave the WebView blank and unusable, so recover in either case.
        tab.recoverFromTermination()
        return true
    }

    /**
     * Pushes the WebView's live `url` / `title` / `canGoBack` / `canGoForward` into
     * the [Tab]'s snapshot state. This is the Android stand-in for the five KVO
     * observers iOS wired in `Tab.wire()`: they each fired independently, but on
     * Android the values are all readable together at every lifecycle callback, so
     * we poll and forward them in one pass.
     *
     * The URL is read from the [callbackUrl] the framework handed us when present
     * (it is the navigation's URL), falling back to `view.url`. An empty/blank URL
     * is dropped, matching the iOS `url` observer's `!urlString.isEmpty` guard so a
     * transient blank does not wipe [Tab.currentUrl].
     */
    private fun syncNavigationState(view: WebView, callbackUrl: String?) {
        val url = callbackUrl?.takeIf { it.isNotEmpty() } ?: view.url
        if (!url.isNullOrEmpty()) {
            tab.onUrlChanged(url)
        }
        // view.title can momentarily be the raw URL before the document's <title>
        // arrives; forward it regardless (iOS forwarded WebKit's title verbatim,
        // including nil). Pass the page's own URL alongside (the same URL we just
        // synced) so a lagging title is attributed to the right page, mirroring the
        // iOS title observer capturing view.url atomically with the title.
        tab.onTitleChanged(view.title, url)
        // Tab reads canGoBack/canGoForward straight off the WebView (the iOS canGo*
        // KVO analog), so no values are passed in.
        tab.refreshNavigationState()
    }

}
