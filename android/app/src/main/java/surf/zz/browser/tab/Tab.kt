package surf.zz.browser.tab

import android.annotation.SuppressLint
import android.content.Context
import android.os.Build
import android.util.Log
import android.view.View
import android.webkit.GeolocationPermissions
import android.webkit.HttpAuthHandler
import android.webkit.PermissionRequest
import android.webkit.ValueCallback
import android.webkit.WebChromeClient
import android.webkit.WebView
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.setValue
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.cancel
import kotlinx.coroutines.delay
import kotlinx.coroutines.launch
import surf.zz.browser.auth.HttpAuthCredential
import surf.zz.browser.auth.HttpAuthCredentialStore
import surf.zz.browser.auth.HttpAuthKey
import surf.zz.browser.auth.HttpAuthPendingCompletions
import surf.zz.browser.auth.StoredHttpAuthCredential
import surf.zz.browser.web.DesktopSiteMode
import surf.zz.prefs.BrowserPreferences
import surf.zz.store.HistoryStore
import surf.zz.url.UrlNormalizer
import java.lang.ref.WeakReference
import java.util.UUID

/**
 * A persisted scroll position in WebView pixels. The Android analog of the iOS
 * `CGPoint` used for `Tab.scrollOffset` / `TabRecord.scroll{X,Y}`. Kept as
 * `Double` (not Compose `Offset`'s `Float`) so the persisted value round-trips
 * losslessly through [TabRecord].
 */
data class ScrollOffset(val x: Double = 0.0, val y: Double = 0.0) {
    val isZero: Boolean get() = x == 0.0 && y == 0.0

    companion object {
        val Zero = ScrollOffset(0.0, 0.0)
    }
}

/**
 * Per-pane web-engine model owning a single [WebView]. Direct port of the iOS
 * `@MainActor @Observable final class Tab` (`ios/zz/Tab.swift:147`).
 *
 * The WebView is owned by this model (not by Compose) so it survives pane moves
 * and recomposition (ANDROID_ARCH.md §4). All observable fields are Compose
 * snapshot state; `@ObservationIgnored` fields become plain `private var`s. All
 * mutation happens on the main thread (the `@MainActor` analog); the WebView
 * clients invoke these methods on the UI thread.
 *
 * KVO observers from `wire()` are replaced by [TabWebViewClient] (page/url/title/
 * nav-state/error/auth/render-gone) and [TabWebChromeClient] (progress/title/
 * new-window/close-window/fullscreen/permission/file-chooser). Those clients
 * write this model's snapshot state directly.
 *
 * NB on the iOS `didSet` recursion warnings: under `@Observable`, assigning to
 * `pageZoom` / `requestsDesktopSite` / `isMediaSuspended` inside their own `didSet`
 * would re-enter the setter and recurse infinitely. Kotlin's `mutableStateOf` has
 * no `didSet`, so the side effects (apply + persistence notify) are driven from
 * explicit setter functions ([setPageZoom] / [setRequestsDesktopSite] /
 * [setMediaSuspended]) that the owner ([surf.zz.store.BrowserStore]) calls, each
 * guarding `newValue != oldValue` exactly as the Swift `didSet` did.
 *
 * There is no `deinit`; [close] cancels the scope, drains pending auth, and
 * destroys the WebView (ANDROID_ARCH.md §7).
 */
class Tab(
    context: Context,
    val id: UUID = UUID.randomUUID(),
    url: String = "",
    title: String? = null,
    scrollOffset: ScrollOffset = ScrollOffset.Zero,
    pageZoom: Double = PageZoom.defaultLevel,
    requestsDesktopSite: Boolean = BrowserPreferences.DEFAULT_REQUESTS_DESKTOP_SITE,
    mediaSuspended: Boolean = false,
    history: HistoryStore? = null,
    /**
     * Durable, encrypted HTTP-auth store (the iOS Keychain analog). Optional so a
     * Tab can be constructed in tests / previews without a Keystore; when null,
     * stored-credential lookups and saves are skipped (matching a Keychain miss).
     */
    private val authCredentialStore: HttpAuthCredentialStore? = null,
) {

    // ---- Observable snapshot state (Swift `@Observable var`) ------------------

    var currentUrl: String by mutableStateOf(url)
        private set

    var title: String? by mutableStateOf(title)

    var canGoBack: Boolean by mutableStateOf(false)

    var canGoForward: Boolean by mutableStateOf(false)

    var isLoading: Boolean by mutableStateOf(false)

    var estimatedProgress: Double by mutableStateOf(0.0)

    /**
     * CSS-zoom level. Set via [setPageZoom]; the owner clamps at the assignment
     * sites (init and `BrowserStore.zoomIn/Out/resetFocused`), mirroring the iOS
     * note that clamping must not happen inside the `didSet`.
     */
    var pageZoom: Double by mutableStateOf(PageZoom.defaultLevel)
        private set

    /** "Request Desktop Site" content mode. Set via [setRequestsDesktopSite]. */
    var requestsDesktopSite: Boolean by mutableStateOf(BrowserPreferences.DEFAULT_REQUESTS_DESKTOP_SITE)
        private set

    /**
     * Per-pane media suspension. Set via [setMediaSuspended]. Pauses/resumes all
     * media in the WebView; mirrors the iOS `setAllMediaPlaybackSuspended(_:)`.
     */
    var isMediaSuspended: Boolean by mutableStateOf(false)
        private set

    /** Scroll position captured from the WebView; persisted into [TabRecord]. */
    var scrollOffset: ScrollOffset by mutableStateOf(ScrollOffset.Zero)
        private set

    /**
     * Element/document-fullscreen state. When non-null the Compose host presents
     * an overlay hosting [FullscreenSession.view]; exiting clears it and re-hosts
     * the WebView back into its tile. (Android analog of the iOS
     * `isElementFullscreenEnabled` path surfaced through [TabWebChromeClient].)
     */
    var fullscreen: FullscreenSession? by mutableStateOf(null)
        private set

    val isBlank: Boolean get() = currentUrl.isEmpty()

    // ---- @ObservationIgnored (plain vars) -------------------------------------

    private var pendingScrollRestore: ScrollOffset? = null

    private var lastScrollOffset: ScrollOffset = ScrollOffset.Zero

    // Set by the scroll observer when a genuine (non-navigation) user scroll lands;
    // checked by the deferred scroll-restore so a user scroll within the 150ms
    // restore delay is not snapped back.
    private var userScrolledSinceFinish: Boolean = false

    // True while a navigation is in flight (or the render process is being
    // recovered). WebView resets scroll to zero during these transitions, so zero
    // offsets are ignored only while this is set.
    private var isNavigationInFlight: Boolean = false

    // True while performing the initial programmatic load of a restored tab.
    // Suppresses history recording so session restore does not reorder the LRU.
    // didFinish schedules a short deferred clear (see restoreClearGeneration).
    private var isRestoring: Boolean = false

    // Bumped whenever isRestoring is set or force-cleared; the deferred clear only
    // clears if its captured generation still matches.
    private var restoreClearGeneration: Int = 0

    // Bumped on each deferred scroll-restore; the delayed restore only fires if its
    // captured generation still matches (replaces the Swift weak-self re-check).
    private var scrollRestoreGeneration: Int = 0

    private val httpAuthCredentials: MutableMap<HttpAuthKey, HttpAuthCredential> = mutableMapOf()

    private val lastHttpAuthCredentialsTried: MutableMap<HttpAuthKey, HttpAuthCredential> =
        mutableMapOf()

    private val pendingHttpAuthCompletions: MutableMap<HttpAuthKey, HttpAuthPendingCompletions> =
        mutableMapOf()

    private var fullscreenCallback: WebChromeClient.CustomViewCallback? = null

    private val history: WeakReference<HistoryStore> = WeakReference(history)

    /** Main-thread scope for the debounced scroll-restore / restore-clear delays. */
    private val scope = CoroutineScope(Dispatchers.Main.immediate + SupervisorJob())

    private var closed = false

    // ---- Callbacks (function-type vars; Swift `@ObservationIgnored var on…`) ---

    /** Called whenever a field that affects the persisted snapshot changes. */
    var onPersistenceChange: (() -> Unit)? = null

    /**
     * New-window (`window.open` / target=_blank) request hook. The owner decides
     * the new-window policy and returns the [WebView] that should receive the
     * navigation (sidebar/split-right create a pane's WebView; same-pane loads into
     * the source and returns it; block returns null). Port of the iOS
     * `onNewWindowRequest` returning a `WKWebView?`.
     *
     * DEVIATION: iOS passed the `WKWebViewConfiguration` / `WKNavigationAction`;
     * Android's `onCreateWindow` carries no configuration or target URL (see
     * ANDROID_ARCH.md §4 / BrowserStore), so the owner ignores both arguments and
     * decides purely from the source pane it already knows. The `onCreateWindow`
     * dialog/user-gesture flags are forwarded for parity but the owner discards them.
     */
    var onNewWindowRequest: ((isDialog: Boolean, isUserGesture: Boolean) -> WebView?)? = null

    /** The page asked to close its own window (`window.close()`). */
    var onCloseWindowRequest: (() -> Unit)? = null

    /** Media-capture / device permission prompt (see [TabWebChromeClient]). */
    var onPermissionRequest: ((PermissionRequest) -> Unit)? = null

    /** Geolocation permission prompt (see [TabWebChromeClient]). */
    var onGeolocationPermissionRequest:
        ((origin: String, callback: GeolocationPermissions.Callback) -> Unit)? = null

    /** `<input type="file">` SAF chooser hook (see [TabWebChromeClient]). */
    var onShowFileChooser: (
        (
            filePathCallback: ValueCallback<Array<android.net.Uri>>,
            params: WebChromeClient.FileChooserParams,
        ) -> Boolean
    )? = null

    // ---- The owned WebView ----------------------------------------------------

    @SuppressLint("SetJavaScriptEnabled")
    val webView: WebView = WebView(context.applicationContext).also { view ->
        view.settings.apply {
            javaScriptEnabled = true
            domStorageEnabled = true
            databaseEnabled = true
            mediaPlaybackRequiresUserGesture = false
            // Enable target=_blank / window.open routing through onCreateWindow.
            setSupportMultipleWindows(true)
            javaScriptCanOpenWindowsAutomatically = true
            // Wide viewport so desktop-mode pages lay out at their natural width.
            useWideViewPort = true
            loadWithOverviewMode = true
            builtInZoomControls = true
            displayZoomControls = false
            // Allow inline media playback (iOS `allowsInlineMediaPlayback`).
            allowFileAccess = false
            allowContentAccess = false
        }
    }

    init {
        webView.webViewClient = TabWebViewClient(this)
        webView.webChromeClient = TabWebChromeClient(this)
        webView.setDownloadListener(TabDownloadListener(context.applicationContext))
        installScrollListener()

        // Restore the persisted zoom level. onPersistenceChange is still null here,
        // so the persistence notify in setPageZoom is a no-op during construction.
        setPageZoom(PageZoom.clamp(pageZoom))
        applyPageZoom()
        // Restore the persisted content mode without an explicit reload: the initial
        // load below already picks it up, and a blank tab has nothing to reload.
        setRequestsDesktopSite(requestsDesktopSite, reload = false)
        applyDesktopSitePreference(reload = false)
        // Restore the persisted media-suspension state.
        setMediaSuspended(mediaSuspended)
        applyMediaSuspension()

        if (url.isNotEmpty()) {
            val target = UrlNormalizer.resolve(url)
            if (target != null) {
                if (!scrollOffset.isZero) {
                    pendingScrollRestore = scrollOffset
                    lastScrollOffset = scrollOffset
                    this.scrollOffset = scrollOffset
                }
                // Initial load from session restore, not user navigation: suppress
                // history recording until the restore settles.
                isRestoring = true
                restoreClearGeneration += 1
                isNavigationInFlight = true
                webView.loadUrl(target)
            }
        }
    }

    // ---- Public navigation API ------------------------------------------------

    fun reload() {
        isNavigationInFlight = true
        webView.reload()
    }

    fun forceReload() {
        isNavigationInFlight = true
        if (webView.url != null) {
            // Ignore cache (iOS reloadFromOrigin). WebView has no direct API; clear
            // the in-memory cache then reload from origin.
            webView.clearCache(false)
            webView.reload()
        } else {
            val target = UrlNormalizer.resolve(currentUrl)
            if (target != null) {
                webView.clearCache(false)
                webView.loadUrl(target)
            }
        }
    }

    fun goBack() {
        isNavigationInFlight = true
        webView.goBack()
    }

    fun goForward() {
        isNavigationInFlight = true
        webView.goForward()
    }

    fun stop() {
        webView.stopLoading()
    }

    /**
     * Make the WebView the focused view so keyboard input goes to the page (the
     * Android analog of iOS `focusForBrowsing()` making the WKContent view first
     * responder). Posted so it runs after the current layout pass.
     */
    fun focusForBrowsing() {
        webView.post {
            webView.requestFocus(View.FOCUS_DOWN)
        }
    }

    /**
     * In-page find. Android shows no built-in find bar UI, so this starts an
     * async text search across the page; the embedder hosts the result-count UI
     * via [WebView.setFindListener]. Port of iOS `find()` (which presents the
     * platform find navigator).
     */
    fun find(query: String = "") {
        if (query.isEmpty()) {
            webView.clearMatches()
        } else {
            webView.findAllAsync(query)
        }
    }

    /**
     * Navigate to a specific back-forward history entry by signed step (negative =
     * back, positive = forward), the Android analog of iOS `go(to: item)`. WebView
     * exposes steps rather than item objects, so [backList]/[forwardList] return
     * steps and this consumes one.
     */
    fun go(steps: Int) {
        if (steps == 0 || !webView.canGoBackOrForward(steps)) return
        isNavigationInFlight = true
        webView.goBackOrForward(steps)
    }

    /**
     * Back-history entries as signed steps relative to the current item, most
     * recent first (e.g. [-1, -2, …]). Android's `WebBackForwardList` is index
     * based; iOS exposes opaque `WKBackForwardListItem`s, so we surface the steps
     * the UI needs to drive [go].
     */
    val backList: List<BackForwardEntry>
        get() {
            val list = webView.copyBackForwardList()
            val current = list.currentIndex
            return (current - 1 downTo 0).map { index ->
                BackForwardEntry(
                    step = index - current,
                    url = list.getItemAtIndex(index)?.url ?: "",
                    title = list.getItemAtIndex(index)?.title,
                )
            }
        }

    /** Forward-history entries as signed steps, nearest first (e.g. [1, 2, …]). */
    val forwardList: List<BackForwardEntry>
        get() {
            val list = webView.copyBackForwardList()
            val current = list.currentIndex
            return (current + 1 until list.size).map { index ->
                BackForwardEntry(
                    step = index - current,
                    url = list.getItemAtIndex(index)?.url ?: "",
                    title = list.getItemAtIndex(index)?.title,
                )
            }
        }

    /**
     * Routes a new-window request. The owner ([surf.zz.store.BrowserStore]) handles
     * every policy itself: sidebar/split-right create and return a WebView,
     * same-pane loads into the source pane, and block suppresses the popup — all
     * returning null for the latter two on purpose. With no owner installed there
     * is no source URL available at this layer (Android only delivers it after the
     * transport navigates), so we simply return null. Port of iOS
     * `handleNewWindowRequest`.
     */
    fun handleNewWindowRequest(isDialog: Boolean, isUserGesture: Boolean): WebView? {
        val handler = onNewWindowRequest ?: return null
        return handler(isDialog, isUserGesture)
    }

    fun handleCloseWindowRequest() {
        onCloseWindowRequest?.invoke()
    }

    /**
     * Explicit user load. Trims input; an empty string clears the URL. Resolves via
     * [UrlNormalizer]; a genuine navigation stops history suppression even if the
     * restore's initial load has not finished. Port of iOS `load(_:)`.
     */
    fun load(urlString: String) {
        val trimmed = urlString.trim()
        if (trimmed.isEmpty()) {
            currentUrl = ""
            return
        }
        val target = UrlNormalizer.resolve(trimmed) ?: return
        pendingScrollRestore = null
        isNavigationInFlight = true
        // An explicit user load is genuine navigation: stop suppressing history.
        // Bumping the generation also voids any deferred restore-clear still pending.
        isRestoring = false
        restoreClearGeneration += 1
        currentUrl = target
        notifyPersistenceChanged()
        webView.loadUrl(target)
    }

    // ---- Zoom / desktop / media setters (Swift `didSet` side effects) ---------

    /**
     * Sets [pageZoom] and applies the side effects, guarding `new != old` exactly
     * like the iOS `didSet`. The caller clamps (the iOS note: never clamp inside
     * the setter to avoid re-entrant recursion).
     */
    fun setPageZoom(level: Double) {
        if (pageZoom == level) return
        pageZoom = level
        applyPageZoom()
        notifyPersistenceChanged()
    }

    /** Sets [requestsDesktopSite] and applies the content mode. Mirrors iOS `didSet`. */
    fun setRequestsDesktopSite(value: Boolean, reload: Boolean = true) {
        if (requestsDesktopSite == value) return
        requestsDesktopSite = value
        applyDesktopSitePreference(reload = reload)
        notifyPersistenceChanged()
    }

    /** Sets [isMediaSuspended] and applies the suspension. Mirrors iOS `didSet`. */
    fun setMediaSuspended(value: Boolean) {
        if (isMediaSuspended == value) return
        isMediaSuspended = value
        applyMediaSuspension()
        notifyPersistenceChanged()
    }

    /**
     * Pushes the current [pageZoom] onto the WebView via CSS `zoom` on the document
     * element (the iOS-path mapping; re-applied in [didFinishNavigation] since CSS
     * zoom is reset by each navigation). Mirrors iOS `applyPageZoom()` iOS branch.
     */
    fun applyPageZoom() {
        webView.evaluateJavascript(
            "document.documentElement.style.zoom='$pageZoom';",
            null,
        )
    }

    /**
     * Pushes the current [requestsDesktopSite] content mode onto the WebView. There
     * is no `preferredContentMode` on Android, so (matching the iOS macOS fallback)
     * we spoof a desktop user agent via [DesktopSiteMode] and toggle the wide
     * viewport, then reload so it takes effect. Port of iOS `applyDesktopSitePreference`.
     */
    fun applyDesktopSitePreference(reload: Boolean) {
        webView.settings.apply {
            userAgentString = DesktopSiteMode.customUserAgent(requestsDesktopSite)
            useWideViewPort = true
            loadWithOverviewMode = requestsDesktopSite
        }
        if (reload && webView.url != null) {
            // Mark the navigation in flight so the scroll observer ignores WebView's
            // reset-to-zero during this reload; otherwise the spurious zero is
            // treated as a user scroll and persisted as scrollY=0, losing position.
            isNavigationInFlight = true
            webView.reload()
        }
    }

    /**
     * Suspends or resumes all media in the WebView. Android has no all-frames
     * "suspend media" API, so (per ANDROID_ARCH.md §4, an imperfect mapping) we
     * pause/resume the whole WebView timers + a JS pause-all-media injection.
     * Port of iOS `applyMediaSuspension()`.
     */
    fun applyMediaSuspension() {
        if (isMediaSuspended) {
            webView.onPause()
            webView.pauseTimers()
            webView.evaluateJavascript(MEDIA_PAUSE_JS, null)
        } else {
            webView.resumeTimers()
            webView.onResume()
        }
    }

    // ---- Navigation lifecycle (called from the WebView clients) ---------------

    /**
     * A navigation finished (or a same-document navigation landed). Port of iOS
     * `didFinishNavigation()`: clears the in-flight flag, defers clearing
     * `isRestoring` (so a late title does not re-stamp the LRU), re-applies zoom +
     * media suspension, and schedules the deferred scroll-restore.
     */
    fun didFinishNavigation() {
        isNavigationInFlight = false
        // Defer clearing isRestoring: the title often arrives in a later callback
        // after onPageFinished, and clearing synchronously would let that late title
        // record the restored URL and re-stamp the history LRU. The deferred clear
        // no-ops if a newer navigation bumped restoreClearGeneration, and always
        // clears so the flag never sticks even for title-less pages.
        if (isRestoring) {
            val generation = restoreClearGeneration
            scope.launch {
                delay(RESTORE_CLEAR_DELAY_MS)
                if (restoreClearGeneration == generation) {
                    isRestoring = false
                }
            }
        }
        // CSS zoom is reset by each navigation; re-apply.
        applyPageZoom()
        // Media suspension does not survive a cross-document navigation; re-apply so
        // a suspended pane stays quiet.
        applyMediaSuspension()

        val pending = pendingScrollRestore ?: return
        pendingScrollRestore = null
        // Start the restore window with a clean slate; the scroll observer flips this
        // true if the user scrolls before the deferred restore fires.
        userScrolledSinceFinish = false
        scrollRestoreGeneration += 1
        val generation = scrollRestoreGeneration
        scope.launch {
            delay(SCROLL_RESTORE_DELAY_MS)
            if (scrollRestoreGeneration != generation) return@launch
            // A genuine user scroll during the delay takes precedence; snapping back
            // would discard their interaction.
            if (userScrolledSinceFinish) return@launch
            // A new navigation started during the delay; `pending` is the stale
            // offset of the previous page and must not be snapped onto the new one.
            if (isNavigationInFlight) return@launch
            webView.scrollTo(pending.x.toInt(), pending.y.toInt())
        }
    }

    /**
     * A navigation failed / was cancelled / became a download. Port of iOS
     * `handleNavigationFailure()`: clears the in-flight + restore flags so they do
     * not stick true, voids any pending restore-clear, and drops the stale scroll
     * restore. (didFinish is the only other place these clear.)
     */
    fun handleNavigationFailure() {
        isNavigationInFlight = false
        isRestoring = false
        restoreClearGeneration += 1
        pendingScrollRestore = null
    }

    /**
     * Recover after the render process was killed. Port of iOS
     * `recoverFromTermination()`: re-arm the pending scroll restore from the last
     * known offset, mark the navigation in flight, and reload — re-issuing the
     * original load when there is no committed entry (so a process death during the
     * initial provisional load still navigates rather than leaving a blank pane).
     */
    fun recoverFromTermination() {
        if (!lastScrollOffset.isZero) {
            pendingScrollRestore = lastScrollOffset
        }
        isNavigationInFlight = true
        val committed = webView.url
        if (committed == null) {
            val target = UrlNormalizer.resolve(currentUrl)
            if (target != null) {
                webView.loadUrl(target)
            }
        } else {
            webView.reload()
        }
    }

    // ---- URL / title / nav-state writes (called from TabWebViewClient) --------

    /**
     * Called when the committed URL changes (iOS `\.url` KVO). Records into history
     * unless restoring, then notifies persistence. Port of the `\.url` observer.
     */
    fun onUrlChanged(urlString: String?) {
        if (urlString.isNullOrEmpty()) return
        currentUrl = urlString
        if (urlString != "about:blank" && !isRestoring) {
            history.get()?.record(urlString, title)
        }
        notifyPersistenceChanged()
    }

    /**
     * Called when the document title changes (iOS `\.title` KVO). The page the
     * title belongs to is passed explicitly ([pageUrl]) so a title is not
     * mis-attributed to a previously-recorded URL while the URL callback lags.
     * Port of the `\.title` observer.
     */
    fun onTitleChanged(newTitle: String?, pageUrl: String?) {
        title = newTitle
        val recordUrl = if (!pageUrl.isNullOrEmpty()) pageUrl else currentUrl
        if (recordUrl.isNotEmpty() && recordUrl != "about:blank" && !isRestoring) {
            history.get()?.record(recordUrl, newTitle)
        }
        notifyPersistenceChanged()
    }

    /** Refreshes [canGoBack]/[canGoForward] from the WebView (iOS canGo* KVO). */
    fun refreshNavigationState() {
        canGoBack = webView.canGoBack()
        canGoForward = webView.canGoForward()
    }

    /** Sets [isLoading] (iOS `\.isLoading` KVO). */
    fun setLoading(loading: Boolean) {
        isLoading = loading
    }

    // ---- Scroll capture -------------------------------------------------------

    /**
     * Wires the scroll listener (iOS `scrollView.observe(\.contentOffset)`).
     * WebView resets scroll to zero while a navigation/recovery is in flight, so
     * those spurious zeros are ignored; a genuine user scroll flags
     * [userScrolledSinceFinish] (so the deferred restore does not snap it back) and
     * schedules a debounced snapshot save.
     */
    private fun installScrollListener() {
        webView.setOnScrollChangeListener { _, scrollX, scrollY, _, _ ->
            val offset = ScrollOffset(scrollX.toDouble(), scrollY.toDouble())
            if (offset.isZero && isNavigationInFlight) return@setOnScrollChangeListener
            if (!isNavigationInFlight) {
                userScrolledSinceFinish = true
            }
            lastScrollOffset = offset
            scrollOffset = offset
            // Persist the scroll position; otherwise scrollX/scrollY only get written
            // when some unrelated event triggers a save, leaving the restored offset
            // stale (often pre-scroll zero).
            notifyPersistenceChanged()
        }
    }

    // ---- Fullscreen (called from TabWebChromeClient) --------------------------

    /**
     * Enter element/document fullscreen. Coalesces a re-entrant request by exiting
     * the prior session first. Publishes observable [fullscreen] state for the
     * Compose host to present an overlay.
     */
    fun enterFullscreen(view: View, callback: WebChromeClient.CustomViewCallback) {
        if (fullscreen != null) {
            exitFullscreen()
        }
        fullscreenCallback = callback
        fullscreen = FullscreenSession(view)
    }

    /**
     * Exit fullscreen: invoke the platform's exit callback (once), clear the
     * observable state (so the host re-hosts the WebView into its tile).
     */
    fun exitFullscreen() {
        val callback = fullscreenCallback
        fullscreenCallback = null
        fullscreen = null
        callback?.onCustomViewHidden()
    }

    // ---- HTTP auth ------------------------------------------------------------

    /**
     * Responds to an HTTP-auth challenge. Faithful port of iOS
     * `respondToHTTPAuthenticationChallenge`, adapted to Android's
     * [HttpAuthHandler] (one per challenge): tries the in-memory, durable-store, and
     * WebView-cache credentials in order on a first attempt; on a retry
     * (`useHttpAuthUsernamePassword == false`) it offers the stored credential once
     * if it differs from what was last tried, else clears it; if nothing applies it
     * queues the completion against one shared prompt (created via [onShowAuthPrompt]).
     *
     * @param host the challenge host (Android `onReceivedHttpAuthRequest` host).
     * @param realm the challenge realm.
     * @param isRetry true when this is a repeat challenge for a failed credential
     *   (Android: `!handler.useHttpAuthUsernamePassword()`).
     * @param proceed proceed with these credentials.
     * @param cancel cancel the challenge.
     */
    fun respondToHttpAuthChallenge(
        host: String,
        realm: String?,
        isRetry: Boolean,
        proceed: (HttpAuthCredential) -> Unit,
        cancel: () -> Unit,
    ) {
        val key = HttpAuthKey(host = host, port = 0, realm = realm ?: "")
        val storedCredential = authCredentialStore?.credential(key)?.toCredential()

        // The completion the auth machinery routes to (proceed-or-cancel). A null
        // HttpAuthCredential means cancel; non-null means proceed.
        val completion: (HttpAuthCredential?) -> Unit = { credential ->
            if (credential != null) proceed(credential) else cancel()
        }

        if (isRetry) {
            if (storedCredential != null &&
                !credentialsMatch(storedCredential, null) &&
                !credentialsMatch(storedCredential, lastHttpAuthCredentialsTried[key])
            ) {
                useHttpAuthCredential(storedCredential, key, remember = true, completion)
                return
            }
            clearHttpAuthCredential(key, removeStored = true)
        } else {
            lastHttpAuthCredentialsTried.remove(key)

            httpAuthCredentials[key]?.let { credential ->
                useHttpAuthCredential(credential, key, remember = false, completion)
                return
            }
            if (storedCredential != null) {
                useHttpAuthCredential(storedCredential, key, remember = true, completion)
                return
            }
            // WebView's own in-process credential cache (the URLCredentialStorage
            // analog).
            webViewCachedCredential(host, realm)?.let { credential ->
                useHttpAuthCredential(credential, key, remember = false, completion)
                return
            }
        }

        // Coalesce onto a single in-flight prompt per protection space.
        pendingHttpAuthCompletions[key]?.let { existing ->
            existing.append(completion)
            return
        }

        val pending = HttpAuthPendingCompletions(completion)
        pendingHttpAuthCompletions[key] = pending

        val prompt = onShowAuthPrompt
        if (prompt == null) {
            // No prompt UI installed: cancel (the analog of iOS having no presenter,
            // which performs default handling — for Android `proceed`-less = cancel).
            completeHttpAuthChallenge(key, credential = null)
            return
        }
        prompt(
            HttpAuthPrompt(
                host = if (host.isNotEmpty()) host else (realm ?: ""),
                realm = realm,
                isRetry = isRetry,
                onSubmit = { user, password ->
                    // Treat an empty username/password as a cancel so a fumbled dialog
                    // does not persist an empty credential that auto-fails each restart.
                    if (user.isEmpty() && password.isEmpty()) {
                        completeHttpAuthChallenge(key, credential = null)
                    } else {
                        completeHttpAuthChallenge(
                            key,
                            credential = HttpAuthCredential(user, password),
                        )
                    }
                },
                onCancel = { completeHttpAuthChallenge(key, credential = null) },
            ),
        )
    }

    /** Prompt hook surfaced to the app layer to present an auth dialog. */
    var onShowAuthPrompt: ((HttpAuthPrompt) -> Unit)? = null

    private fun useHttpAuthCredential(
        credential: HttpAuthCredential,
        key: HttpAuthKey,
        remember: Boolean,
        completion: (HttpAuthCredential?) -> Unit,
    ) {
        httpAuthCredentials[key] = credential
        lastHttpAuthCredentialsTried[key] = credential
        if (remember) {
            authCredentialStore?.set(credential.toStored(), key)
        }
        primeWebViewCache(key, credential)
        completion(credential)
    }

    private fun completeHttpAuthChallenge(key: HttpAuthKey, credential: HttpAuthCredential?) {
        if (credential != null) {
            httpAuthCredentials[key] = credential
            lastHttpAuthCredentialsTried[key] = credential
            authCredentialStore?.set(credential.toStored(), key)
            primeWebViewCache(key, credential)
        }
        val pending = pendingHttpAuthCompletions.remove(key)
        pending?.drain(credential)
    }

    private fun clearHttpAuthCredential(key: HttpAuthKey, removeStored: Boolean) {
        httpAuthCredentials.remove(key)
        lastHttpAuthCredentialsTried.remove(key)
        if (removeStored) {
            authCredentialStore?.remove(key)
        }
    }

    private fun credentialsMatch(lhs: HttpAuthCredential?, rhs: HttpAuthCredential?): Boolean {
        if (lhs == null || rhs == null) return false
        return lhs.user == rhs.user && lhs.password == rhs.password
    }

    /**
     * Reads WebView's own credential cache (the `URLCredentialStorage` analog).
     * Uses the non-deprecated [WebView.getHttpAuthUsernamePassword] on API 26+.
     */
    private fun webViewCachedCredential(host: String, realm: String?): HttpAuthCredential? {
        val pair: Array<String>? =
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
                webView.getHttpAuthUsernamePassword(host, realm ?: "")
            } else {
                null
            }
        val user = pair?.getOrNull(0) ?: return null
        val password = pair.getOrNull(1) ?: return null
        if (user.isEmpty() && password.isEmpty()) return null
        return HttpAuthCredential(user, password)
    }

    /** Mirrors writes into WebView's in-process cache (iOS URLCredentialStorage set). */
    private fun primeWebViewCache(key: HttpAuthKey, credential: HttpAuthCredential) {
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            webView.setHttpAuthUsernamePassword(
                key.host,
                key.realm,
                credential.user,
                credential.password,
            )
        }
    }

    // ---- Teardown -------------------------------------------------------------

    /**
     * Releases everything (no `deinit` on Android). Cancels the scope, drains every
     * pending auth completion with a cancel (so queued WebView challenges do not
     * hang — drain is idempotent), exits any fullscreen, detaches the WebView from
     * its parent, and destroys it. Idempotent. Port of the iOS `deinit` + teardown.
     */
    fun close() {
        if (closed) return
        closed = true
        scope.cancel()
        for (pending in pendingHttpAuthCompletions.values) {
            pending.drain(null)
        }
        pendingHttpAuthCompletions.clear()
        fullscreenCallback?.onCustomViewHidden()
        fullscreenCallback = null
        fullscreen = null
        try {
            webView.stopLoading()
            webView.webChromeClient = null
            (webView.parent as? android.view.ViewGroup)?.removeView(webView)
            webView.destroy()
        } catch (e: Exception) {
            Log.w(TAG, "Error destroying WebView for tab $id", e)
        }
    }

    private fun notifyPersistenceChanged() {
        onPersistenceChange?.invoke()
    }

    private fun HttpAuthCredential.toStored() = StoredHttpAuthCredential(user, password)

    private fun StoredHttpAuthCredential.toCredential() = HttpAuthCredential(user, password)

    private companion object {
        const val TAG = "Tab"

        /** Matches the iOS 250ms deferred restore-clear. */
        const val RESTORE_CLEAR_DELAY_MS = 250L

        /** Matches the iOS 150ms deferred scroll-restore. */
        const val SCROLL_RESTORE_DELAY_MS = 150L

        /**
         * Best-effort all-frames media pause (the imperfect Android analog of iOS's
         * `setAllMediaPlaybackSuspended(true)`): pause every audio/video element in
         * the top document.
         */
        const val MEDIA_PAUSE_JS =
            "(function(){var m=document.querySelectorAll('video,audio');" +
                "for(var i=0;i<m.length;i++){try{m[i].pause();}catch(e){}}})();"
    }
}

/**
 * A single back-forward history entry surfaced to the UI as a signed [step] for
 * [Tab.go]. The Android analog of iOS's opaque `WKBackForwardListItem`.
 */
data class BackForwardEntry(
    val step: Int,
    val url: String,
    val title: String?,
)

/**
 * Observable element-fullscreen state. Holds the platform-provided full-screen
 * [view] the Compose host presents in an overlay while fullscreen is active.
 */
data class FullscreenSession(val view: View)

/**
 * A pending HTTP-auth prompt handed to the app layer (the Android analog of the
 * iOS `UIAlertController` two-field sign-in alert). Exactly one of [onSubmit] /
 * [onCancel] must eventually be invoked.
 */
class HttpAuthPrompt(
    val host: String,
    val realm: String?,
    val isRetry: Boolean,
    val onSubmit: (user: String, password: String) -> Unit,
    val onCancel: () -> Unit,
)
