package surf.zz.browser.tab

import android.net.Uri
import android.os.Message
import android.view.View
import android.webkit.GeolocationPermissions
import android.webkit.PermissionRequest
import android.webkit.ValueCallback
import android.webkit.WebChromeClient
import android.webkit.WebView

/**
 * Bridges WebView "chrome" callbacks (progress, title, new/close window, fullscreen,
 * permission, file chooser) into the owning [Tab]'s observable state and request
 * hooks.
 *
 * Swift origin: this replaces two iOS mechanisms from `Tab.swift`:
 *
 *  1. The `estimatedProgress` / `title` KVO observers wired in `Tab.wire()`
 *     (`webView.observe(\.estimatedProgress, …)` / `webView.observe(\.title, …)`).
 *  2. The `SameWindowUIDelegate` (`WKUIDelegate`): `createWebViewWith` →
 *     [Tab.handleNewWindowRequest], `webViewDidClose` → [Tab.handleCloseWindowRequest],
 *     `requestMediaCapturePermissionFor` / `requestDeviceOrientationAndMotionPermissionFor`
 *     → `.prompt`, and the macOS `runOpenPanelWith` open-panel → SAF file chooser.
 *
 * Mapping (per ANDROID_ARCH.md §4):
 *  - [onProgressChanged] → [Tab.estimatedProgress] (Android reports 0..100 integer
 *    progress; WebKit's `estimatedProgress` is a 0..1 Double, so we normalize to
 *    keep the [Tab] field and all downstream progress UI on the iOS 0..1 scale).
 *  - [onReceivedTitle] → [Tab.title].
 *  - [onCreateWindow] (requires `settings.setSupportMultipleWindows(true)`) →
 *    [Tab.handleNewWindowRequest], routed back through the `WebView.WebViewTransport`
 *    carried by the message. This is the Android analog of `WKUIDelegate`'s
 *    `createWebViewWith:for:windowFeatures:` returning a `WKWebView`.
 *  - [onCloseWindow] → [Tab.handleCloseWindowRequest].
 *  - [onShowCustomView] / [onHideCustomView] → fullscreen enter/exit; on exit the
 *    page's `WebView` is re-hosted by clearing the [Tab]'s fullscreen state, which
 *    the Compose host observes to tear down the fullscreen overlay and reparent the
 *    `WebView` back into its tile.
 *  - [onPermissionRequest] / [onGeolocationPermissionsShowPrompt] → defer to the
 *    [Tab]'s prompt hook (the iOS `.prompt` disposition; see the DEVIATION note).
 *  - [onShowFileChooser] → SAF, via the [Tab]'s file-chooser hook.
 *
 * DEVIATION (permissions). iOS returns `WKPermissionDecision.prompt`, which makes
 * WebKit present its own system permission UI. Android's [WebChromeClient] has no
 * "ask the user" disposition — the embedder must grant or deny synchronously and is
 * responsible for any UI. We therefore route permission requests to the [Tab]'s
 * [Tab.PermissionPrompt] hook so the app layer can surface a Compose dialog and
 * grant/deny; if no hook is installed we deny (the safe default, equivalent to the
 * user dismissing the iOS prompt) via [Tab.onPermissionRequest]. The Android
 * OS-level runtime permissions
 * (CAMERA / RECORD_AUDIO / ACCESS_FINE_LOCATION) are a separate concern handled by
 * the host Activity before a grant can take effect.
 *
 * All callbacks here run on the main (UI) thread, matching the `@MainActor`
 * isolation of [Tab]; they write [Tab] snapshot state directly without re-hopping.
 */
class TabWebChromeClient(private val tab: Tab) : WebChromeClient() {

    /**
     * Maps Android's 0..100 integer progress onto WebKit's 0..1 `estimatedProgress`
     * scale that [Tab.estimatedProgress] (and the progress UI) expects.
     */
    override fun onProgressChanged(view: WebView, newProgress: Int) {
        tab.estimatedProgress = newProgress.coerceIn(0, 100) / 100.0
    }

    /**
     * Mirrors the WebKit `\.title` KVO observer, which both set [Tab.title] AND
     * recorded the page into history. We route through [Tab.onTitleChanged] so that
     * history recording (and its `isRestoring` suppression) stays in one place,
     * exactly as on iOS. The page's own URL is captured atomically from `view.url`
     * and passed as `pageUrl`, mirroring the Swift observer reading `view.url`
     * alongside the title so a title is not mis-attributed to a stale URL while the
     * URL callback lags. The title is forwarded verbatim (including empty/`null`),
     * matching WebKit's KVO forwarding `view.title`.
     */
    override fun onReceivedTitle(view: WebView, title: String?) {
        tab.onTitleChanged(title, view.url)
    }

    /**
     * Routes a `window.open` / `target=_blank` request into an app-owned pane
     * instead of letting the platform spawn a window, mirroring
     * `SameWindowUIDelegate.webView(_:createWebViewWith:for:windowFeatures:)`.
     *
     * Requires `WebView.settings.setSupportMultipleWindows(true)` and
     * `setJavaScriptCanOpenWindowsAutomatically(true)` on the owning tab's WebView,
     * otherwise this callback is never invoked.
     *
     * The owner ([surf.zz.store.BrowserStore], via [Tab.onNewWindowRequest]) decides
     * the [surf.zz.browser.web] new-window policy and returns the `WebView` that
     * should receive the navigation (sidebar / split-right create a new pane's
     * WebView; same-pane loads into the source and returns it; block returns null).
     * We hand that WebView back to the platform through the message's
     * [WebView.WebViewTransport], exactly as WebKit consumes the returned
     * `WKWebView`. Returning `false` (no target) tells the platform to ignore the
     * request — the analog of returning `nil`.
     */
    override fun onCreateWindow(
        view: WebView,
        isDialog: Boolean,
        isUserGesture: Boolean,
        resultMsg: Message,
    ): Boolean {
        val target = tab.handleNewWindowRequest(isDialog, isUserGesture)
        if (target == null) {
            // No pane was created (block policy, same-pane load, or no owner that
            // produced a WebView). Ignore the popup; nothing to transport.
            return false
        }
        val transport = resultMsg.obj as? WebView.WebViewTransport ?: return false
        transport.webView = target
        resultMsg.sendToTarget()
        return true
    }

    /**
     * The page asked to close its own window (`window.close()`), mirroring
     * `SameWindowUIDelegate.webViewDidClose`. Defers to the owner to close the pane.
     */
    override fun onCloseWindow(window: WebView) {
        tab.handleCloseWindowRequest()
    }

    /**
     * Element/document fullscreen entered (HTML5 Fullscreen API). Mirrors the iOS
     * `WKPreferences.isElementFullscreenEnabled` path. We hand the platform's
     * full-screen container view and exit callback to the [Tab], which publishes
     * them as observable fullscreen state so the Compose host can present the
     * overlay. Re-entrant requests (a new view while one is already shown) are
     * coalesced by [Tab.enterFullscreen], which dismisses the prior one first.
     */
    override fun onShowCustomView(customView: View, callback: CustomViewCallback) {
        tab.enterFullscreen(customView, callback)
    }

    /**
     * Fullscreen exited. Clearing the [Tab]'s fullscreen state drives the Compose
     * host to remove the overlay and re-host (reparent) the tab's `WebView` back
     * into its tile — the "re-host on dismiss" behavior.
     */
    override fun onHideCustomView() {
        tab.exitFullscreen()
    }

    /**
     * Media-capture / device permission requests. iOS answers `.prompt`; Android has
     * no prompt disposition, so we route to the [Tab]'s prompt hook (see the
     * DEVIATION note in the class doc). The hook is invoked asynchronously and must
     * eventually call exactly one of [PermissionRequest.grant] / [PermissionRequest.deny];
     * with no hook installed we deny immediately.
     */
    override fun onPermissionRequest(request: PermissionRequest) {
        val prompt = tab.onPermissionRequest
        if (prompt == null) {
            request.deny()
            return
        }
        prompt(request)
    }

    /**
     * Geolocation permission. Same `.prompt` semantics as [onPermissionRequest];
     * routed to the [Tab]'s geolocation hook, denying (non-retain) when unhandled.
     */
    override fun onGeolocationPermissionsShowPrompt(
        origin: String,
        callback: GeolocationPermissions.Callback,
    ) {
        val prompt = tab.onGeolocationPermissionRequest
        if (prompt == null) {
            callback.invoke(origin, /* allow = */ false, /* retain = */ false)
            return
        }
        prompt(origin, callback)
    }

    /**
     * `<input type="file">` picker, mirroring the macOS `runOpenPanelWith` open
     * panel. Routed to the [Tab]'s SAF file-chooser hook, which launches a Storage
     * Access Framework picker and invokes [filePathCallback] with the chosen URIs
     * (or `null` if cancelled). Returning `false` (no hook) lets the platform fall
     * back to its default, and we null out the callback to avoid a stuck `<input>`.
     */
    override fun onShowFileChooser(
        webView: WebView,
        filePathCallback: ValueCallback<Array<Uri>>,
        fileChooserParams: FileChooserParams,
    ): Boolean {
        val chooser = tab.onShowFileChooser
        if (chooser == null) {
            filePathCallback.onReceiveValue(null)
            return false
        }
        return chooser(filePathCallback, fileChooserParams)
    }
}
