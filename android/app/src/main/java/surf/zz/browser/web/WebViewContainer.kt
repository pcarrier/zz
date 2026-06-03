package surf.zz.browser.web

import android.content.Context
import android.graphics.Color
import android.view.MotionEvent
import android.view.View
import android.view.ViewGroup
import android.webkit.WebView
import android.widget.FrameLayout
import androidx.core.view.ViewCompat
import androidx.core.view.WindowInsetsCompat

/**
 * The host view that reparents and frames the externally-owned [WebView] of a pane.
 *
 * Direct port of `WebView.swift`'s `ContainerView` (the `UIView` / `NSView`
 * subclass inside `_Representable`). On Android it is a [FrameLayout] subclass that
 * the Compose `HostedWebView` drives through `AndroidView(factory = { WebViewContainer(it) })`:
 * the factory builds it and `update {}` (re)applies [onInteraction] / [shouldHost] /
 * [reservesTopSafeArea] / [layoutRevision] and calls [attach].
 *
 * The WebView is owned by the [surf.zz.browser.tab.Tab] model, not by Compose, so it
 * survives pane moves / recomposition (ANDROID_ARCH.md §4). This container only
 * reparents it (the `addSubview`/`removeFromSuperview` analog: [addView]/[removeView])
 * and frames it; tearing the WebView down is the `Tab`'s job.
 *
 * What maps from the iOS `ContainerView`:
 *
 *  - **Reparent** ([attach] / [detachIfOwned] / [dismantle]) — iOS
 *    `removeFromSuperview()` + `addSubview()` keyed by [layoutRevision]; here
 *    `(webView.parent as? ViewGroup)?.removeView(webView)` then `addView(webView)`.
 *    Because the WebView fills the container, layout is done with `MATCH_PARENT`
 *    layout params (the analog of iOS `autoresizingMask = [.flexibleWidth, .flexibleHeight]`
 *    + a frame set to the container bounds), so the explicit per-layout frame math
 *    of `targetWebViewFrame()` is unnecessary on Android.
 *
 *  - **Top inset** ([reservesTopSafeArea] + [applyTopInset]) — iOS
 *    `updateContentInsets(for:)` set the scroll view's `contentInset.top` to
 *    `reservedTopPageInset` (the part of the top safe area that overlaps the status
 *    bar). Android has no `contentInset`; the equivalent is top **padding** on the
 *    container so the WebView's content starts below the status bar. The
 *    "pinned-to-top" preservation (iOS re-applied `contentOffset.y = -targetTopInset`
 *    when the page was scrolled to the very top) maps to: if the WebView is currently
 *    at the very top (`scrollY <= 0`), keep it pinned after the inset changes by
 *    re-issuing `scrollTo(scrollX, 0)`.
 *
 *  - **Click-to-focus** ([onInterceptTouchEvent]) — iOS detected focus in
 *    `hitTest(_:with:)` without installing a competing gesture recognizer, debounced
 *    so two hits within 0.1s fire [onInteraction] once. Here we observe (without
 *    consuming) `ACTION_DOWN` in [onInterceptTouchEvent] — returning `false` lets the
 *    touch continue to the WebView — debounced the same way via [System.nanoTime].
 *
 *  - **Fullscreen re-attach** — iOS observed `WKWebView.fullscreenState` via KVO and
 *    re-attached when it returned to `.notInFullscreen`. On Android element
 *    fullscreen is delivered through [surf.zz.browser.tab.TabWebChromeClient]'s
 *    `onShowCustomView`/`onHideCustomView`, which drive the `Tab`'s observable
 *    fullscreen state; the Compose host flips [shouldHost] to `false` while a custom
 *    fullscreen view is shown (so this container detaches the WebView and lets the
 *    fullscreen overlay host it) and back to `true` on exit, at which point [attach]
 *    re-hosts the WebView into this container. The container therefore needs no KVO
 *    analog — [shouldHost] is the single gate.
 *
 *  - **Drop routing** — DEFERRED in v1 (ANDROID_ARCH.md §8). iOS macOS wired the
 *    pane's drop handler onto a `PaneDropRoutingWebView`; on the mobile target this
 *    is a follow-up. [dropHandler] is carried so signatures line up but is not yet
 *    plumbed into a `setOnDragListener`. See [PaneDrop].
 */
class WebViewContainer(context: Context) : FrameLayout(context) {

    /**
     * Click-to-focus hook. Fired (debounced) on a touch that lands inside the hosted
     * WebView, so the owner can make this pane the focused/active one. Mirrors the
     * iOS `onInteraction` invoked from `hitTest`.
     */
    var onInteraction: (() -> Unit)? = null

    /**
     * Gates whether this container should host the WebView. iOS `shouldHost`: when it
     * returns `false` (e.g. the pane is being shown elsewhere, or the WebView is in a
     * fullscreen overlay) [attach] detaches the WebView instead of parenting it here.
     */
    var shouldHost: () -> Boolean = { true }

    /**
     * Whether to reserve the top safe-area (status-bar overlap) as page inset.
     * Mirrors iOS `reservesTopSafeArea`; toggling it re-applies the top inset.
     */
    var reservesTopSafeArea: Boolean = true
        set(value) {
            if (field == value) return
            field = value
            applyTopInset()
        }

    /**
     * The pane-drop contract for this pane. DEFERRED in v1 — carried so the hosting
     * signatures match iOS but not yet wired to a drag listener (ANDROID_ARCH.md §8).
     */
    var dropHandler: PaneDropHandler? = null

    /** Most recent CACurrentMediaTime-equivalent of a click-to-focus, in nanos. */
    private var lastInteractionAtNanos: Long = 0L

    /** The WebView currently hosted here (the iOS `weak hostedWebView`). */
    private var hostedWebView: WebView? = null

    /**
     * Bumped by [setLayoutRevision]; like iOS `rehostRequested`, it forces the next
     * [attach] to re-parent even if the WebView is already a child (the layout moved
     * the pane, so a re-host is required to settle WebView layout).
     */
    private var rehostRequested: Boolean = false

    /** The current top inset reserved for the status-bar overlap, in px. */
    private var reservedTopInsetPx: Int = 0

    init {
        // iOS: backgroundColor = .clear; clipsToBounds = true.
        setBackgroundColor(Color.TRANSPARENT)
        clipChildren = true
        clipToPadding = true

        // The Android analog of iOS `safeAreaInsetsDidChange`: observe WindowInsets so
        // the reserved top inset tracks the status bar without re-querying on every
        // layout pass.
        ViewCompat.setOnApplyWindowInsetsListener(this) { _, insets ->
            val top = insets.getInsets(WindowInsetsCompat.Type.statusBars()).top
            if (top != lastStatusBarInsetPx) {
                lastStatusBarInsetPx = top
                applyTopInset()
            }
            insets
        }
    }

    /** Last observed status-bar inset (px) from the window-insets listener. */
    private var lastStatusBarInsetPx: Int = 0

    /**
     * iOS `setLayoutRevision(_:)`: a changed revision means the pane layout moved, so
     * request a re-host on the next [attach]. No-op when unchanged.
     */
    fun setLayoutRevision(revision: Int) {
        if (layoutRevision == revision) return
        layoutRevision = revision
        rehostRequested = true
        requestLayout()
    }

    private var layoutRevision: Int = 0

    /**
     * Reparents the externally-owned [webView] into this container without tearing it
     * down. Faithful port of iOS `attach(_:)`:
     *
     *  - If a *different* WebView was hosted, detach it first.
     *  - If [shouldHost] is `false`, detach (do not host) and return — the WebView is
     *    being presented elsewhere (e.g. a fullscreen overlay).
     *  - If it is already our child and no re-host was requested, just re-frame
     *    (here: re-apply the top inset) and return.
     *  - Otherwise remove it from its current parent and add it as a full-size child.
     */
    fun attach(webView: WebView) {
        if (hostedWebView !== webView) {
            hostedWebView?.let { detachIfOwned(it) }
            hostedWebView = webView
        }

        if (!shouldHost()) {
            detachIfOwned(webView)
            return
        }

        if (webView.parent === this && !rehostRequested) {
            applyTopInset()
            return
        }

        (webView.parent as? ViewGroup)?.removeView(webView)
        webView.layoutParams = LayoutParams(
            LayoutParams.MATCH_PARENT,
            LayoutParams.MATCH_PARENT,
        )
        addView(webView)
        rehostRequested = false
        applyTopInset()
    }

    /**
     * iOS `dismantle()` (called from `dismantleUIView`/`dismantleNSView`): relinquish
     * the WebView without destroying it (the `Tab` owns its lifetime). Clears the drop
     * handler to break the retain cycle, mirroring the iOS macOS `detachIfOwned` note.
     */
    fun dismantle() {
        hostedWebView?.let { detachIfOwned(it) }
        hostedWebView = null
        dropHandler = null
    }

    /**
     * iOS `detachIfOwned(_:)`: remove [webView] from this container if (and only if)
     * we are its parent, clearing our reference when it is the one we track. Never
     * destroys it.
     */
    private fun detachIfOwned(webView: WebView) {
        if (hostedWebView === webView) {
            hostedWebView = null
        }
        if (webView.parent === this) {
            removeView(webView)
        }
    }

    /**
     * Applies the reserved top inset as container top padding (the iOS
     * `updateContentInsets` analog; ANDROID_ARCH.md §4 maps `contentInset` to top
     * padding). Preserves the iOS "pinned-to-top" behavior: if the page is scrolled to
     * the very top, keep it pinned after the inset changes so content does not jump.
     */
    private fun applyTopInset() {
        val target = if (reservesTopSafeArea) lastStatusBarInsetPx else 0
        if (target == reservedTopInsetPx && paddingTop == target) return

        val webView = hostedWebView
        // iOS captured `wasPinnedToTop` before mutating the inset.
        val wasPinnedToTop = webView != null && webView.scrollY <= 0

        reservedTopInsetPx = target
        setPadding(paddingLeft, target, paddingRight, paddingBottom)

        if (wasPinnedToTop && webView != null) {
            // Re-pin to the top so the freshly-inset content stays flush (the analog of
            // iOS `setContentOffset(y: -targetTopInset)`).
            webView.scrollTo(webView.scrollX, 0)
        }
    }

    /**
     * Detect a click-to-focus without consuming the touch. Port of iOS
     * `hitTest(_:with:)`: on `ACTION_DOWN` that lands inside the hosted WebView, fire
     * [onInteraction] at most once per 0.1s (debounced via [System.nanoTime], the
     * `CACurrentMediaTime()` analog). Returns `false` so the event continues to the
     * WebView for normal scrolling/tapping (we never intercept, only observe).
     */
    override fun onInterceptTouchEvent(ev: MotionEvent): Boolean {
        if (ev.actionMasked == MotionEvent.ACTION_DOWN && countsAsClickToFocus(ev)) {
            val now = System.nanoTime()
            if (now - lastInteractionAtNanos > CLICK_TO_FOCUS_DEBOUNCE_NANOS) {
                lastInteractionAtNanos = now
                onInteraction?.invoke()
            }
        }
        return false
    }

    /**
     * iOS `countsAsClickToFocus(_:)`: only genuine pointer/press input focuses the
     * pane. Android delivers touch/stylus/mouse through [MotionEvent]; any of those is
     * a click-to-focus, matching the iOS `.touches` / `.presses` cases.
     */
    private fun countsAsClickToFocus(ev: MotionEvent): Boolean {
        // A focus-only interaction is one that lands on the hosted WebView (a child),
        // mirroring iOS requiring the hit-test result to differ from `self`. iOS also
        // restricted this to genuine pointer input (`.touches` / `.presses`); on
        // Android finger / stylus / mouse all qualify, so any non-empty tool type does.
        if (hostedWebView == null) return false
        val tool = ev.getToolType(0)
        return tool == MotionEvent.TOOL_TYPE_FINGER ||
            tool == MotionEvent.TOOL_TYPE_STYLUS ||
            tool == MotionEvent.TOOL_TYPE_MOUSE
    }

    private companion object {
        /** iOS debounce: ignore a second focus within 0.1s. */
        const val CLICK_TO_FOCUS_DEBOUNCE_NANOS = 100_000_000L // 0.1s in nanos
    }
}
