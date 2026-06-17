package surf.zz.browser.web

import android.webkit.WebView
import androidx.compose.runtime.Composable
import androidx.compose.ui.Modifier
import androidx.compose.ui.viewinterop.AndroidView

/**
 * Composable that hosts an **externally owned** [WebView] (owned by the `Tab` model,
 * see ANDROID_ARCH.md §4) by reparenting it into a [WebViewContainer], without ever
 * tearing the WebView down. Reparenting happens on [layoutRevision] change or when
 * [shouldHost] flips, mirroring the iOS `HostedWebView` / `_Representable.ContainerView`
 * from `WebView.swift`.
 *
 * The iOS implementation reparents the `WKWebView` between container views as panes
 * are split/moved (the WebView survives the move so its render process, scroll state
 * and back/forward list persist). Android has the same constraint: an `android.webkit.WebView`
 * is expensive and stateful, so it lives on the `Tab` and is merely re-attached into
 * whichever container is currently on screen for that tab.
 *
 * The iOS `GeometryReader { proxy ... layoutSize: proxy.size }` plumbing has no Android
 * analog here: [WebViewContainer] frames the WebView with `MATCH_PARENT` layout params
 * (the analog of iOS `autoresizingMask = [.flexibleWidth, .flexibleHeight]`), so the
 * explicit fallback-frame math the iOS container did from `layoutSize` is unnecessary
 * and the container exposes no `setLayoutSize`.
 *
 * Signature parity with iOS `HostedWebView`:
 * - `webView` — the externally owned view to host.
 * - `onInteraction` — invoked when the user touches inside the hosted content
 *   (the Android analog of the iOS `hitTest`/`NSPressGestureRecognizer` focus probe);
 *   used to focus the pane. Debounced like iOS (`> 0.1s` between fires).
 * - `dropHandler` — pane drop routing; v1 status is deferred on mobile (see §8 and
 *   [PaneDrop]). Plumbed through to the container so the contract compiles.
 * - `shouldHost` — when it returns `false` the WebView is detached from this container
 *   (e.g. the pane is occluded / parked) instead of being hosted.
 * - `reservesTopSafeArea` — when `true` the hosted content reserves the top
 *   system-overlay (status bar) inset, the Android analog of the iOS
 *   `reservedTopPageInset` scroll-view content inset.
 * - `layoutRevision` — bumped by the layout when panes are reorganized; a change
 *   forces a rehost (reparent) even if the same container instance is reused.
 */
@Composable
fun HostedWebView(
    webView: WebView,
    modifier: Modifier = Modifier,
    onInteraction: (() -> Unit)? = null,
    dropHandler: PaneDropHandler? = null,
    shouldHost: () -> Boolean = { true },
    reservesTopSafeArea: Boolean = true,
    layoutRevision: Int = 0,
) {
    AndroidView(
        modifier = modifier,
        factory = { context ->
            WebViewContainer(context).apply {
                this.onInteraction = onInteraction
                this.dropHandler = dropHandler
                this.shouldHost = shouldHost
                this.reservesTopSafeArea = reservesTopSafeArea
                setLayoutRevision(layoutRevision)
                attach(webView)
            }
        },
        update = { container ->
            // Re-apply the live closures/flags every recomposition (iOS `updateUIView`),
            // then key the rehost on layoutRevision / shouldHost via the container's
            // own change-tracking guards. `attach` is the single entry point that
            // reparents-or-detaches the passed WebView.
            container.onInteraction = onInteraction
            container.dropHandler = dropHandler
            container.shouldHost = shouldHost
            container.reservesTopSafeArea = reservesTopSafeArea
            container.setLayoutRevision(layoutRevision)
            container.attach(webView)
        },
        onReset = { container ->
            // The container is being detached for later reuse: relinquish the WebView
            // without destroying it (it is owned by the Tab).
            container.dismantle()
        },
        onRelease = { container ->
            container.dismantle()
        },
    )
}
