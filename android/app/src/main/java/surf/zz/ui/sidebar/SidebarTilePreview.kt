package surf.zz.ui.sidebar

import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.widthIn
import androidx.compose.foundation.layout.wrapContentSize
import androidx.compose.runtime.Composable
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.RectangleShape
import androidx.compose.ui.input.pointer.pointerInput
import androidx.compose.ui.text.font.FontFamily
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.Dp
import androidx.compose.ui.unit.dp
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Text
import surf.zz.browser.tab.Tab
import surf.zz.browser.web.HostedWebView
import surf.zz.favicon.Favicon
import surf.zz.favicon.FaviconForUrl
import surf.zz.ui.theme.canvas
import surf.zz.ui.theme.canvasSecondary
import surf.zz.util.SiteVisual

/**
 * Reusable parked-tab tile: a square live (or static) preview, with a favicon +
 * title + monospaced host caption beneath it.
 *
 * Ports `SidebarTilePreview` / `StaticSidebarPreview` from `ios/zz/SidebarView.swift`.
 *
 * The square is `max(80.dp, sidebarWidth - 16)`. When [isLive] is true the tile hosts
 * the tab's live [Tab.webView] via [HostedWebView], gated by [shouldHostLiveView] so
 * only the single owning host actually reparents the WebView (matches
 * `store.isSidebarPreviewHost(tabID)` on iOS). Touches on the live content are absorbed
 * by an overlay so taps fall through to the parent row's gesture (the iOS
 * `.allowsHitTesting(false)`). When [isLive] is false a static placeholder
 * ([StaticSidebarPreview]) is shown instead — used for the drag-preview snapshot.
 *
 * @param tab the parked tab to preview.
 * @param sidebarWidth the effective sidebar width in dp; drives the square edge length.
 * @param isLive whether to host the live WebView (`true`) or render the static preview.
 * @param shouldHostLiveView gate forwarded to [HostedWebView]'s `shouldHost`; returning
 *   `false` detaches the WebView from this container so only one host owns it at a time.
 */
@Composable
fun SidebarTilePreview(
    tab: Tab,
    sidebarWidth: Dp,
    isLive: Boolean = true,
    shouldHostLiveView: () -> Boolean = { true },
    modifier: Modifier = Modifier,
) {
    // contentWidth = max(80, sidebarWidth - 16)
    val contentWidth: Dp = maxOf(80.dp, sidebarWidth - 16.dp)

    val title = tab.title
    val host = SiteVisual.host(tab.currentUrl)
    // displayTitle: tab.title if non-empty, else the host.
    val displayTitle = if (!title.isNullOrEmpty()) title else host
    val hairline = MaterialTheme.colorScheme.outlineVariant.copy(alpha = 0.5f)

    Column(
        modifier = modifier
            .wrapContentSize(align = Alignment.TopStart, unbounded = false),
        verticalArrangement = Arrangement.spacedBy(6.dp),
        horizontalAlignment = Alignment.Start,
    ) {
        // Square preview, clipped to a rect with a 0.5dp hairline border overlay.
        Box(
            modifier = Modifier
                .size(width = contentWidth, height = contentWidth)
                .border(0.5.dp, hairline, RectangleShape),
        ) {
            if (isLive) {
                LivePreview(tab = tab, shouldHostLiveView = shouldHostLiveView)
            } else {
                StaticSidebarPreview(host = host)
            }
        }

        // Favicon + title + monospaced host row.
        Row(
            modifier = Modifier.widthIn(max = contentWidth),
            horizontalArrangement = Arrangement.spacedBy(6.dp),
            verticalAlignment = Alignment.Top,
        ) {
            FaviconForUrl(
                url = tab.currentUrl,
                size = 14.dp,
                // .padding(.top, 1) on iOS
            )
            Column(
                modifier = Modifier.padding(top = 1.dp),
                verticalArrangement = Arrangement.spacedBy(1.dp),
            ) {
                Text(
                    text = displayTitle,
                    style = MaterialTheme.typography.bodySmall,
                    fontWeight = FontWeight.Medium,
                    maxLines = 1,
                    overflow = TextOverflow.Ellipsis,
                )
                Text(
                    text = host,
                    style = MaterialTheme.typography.labelSmall.copy(
                        fontFamily = FontFamily.Monospace,
                    ),
                    color = MaterialTheme.colorScheme.onSurfaceVariant,
                    maxLines = 1,
                    overflow = TextOverflow.Ellipsis,
                )
            }
        }
    }
}

/**
 * Live preview content: `Color.canvas` backdrop with the hosted WebView on top.
 * The hosting is gated by [shouldHostLiveView] (forwarded to [HostedWebView.shouldHost])
 * so only one container owns the WebView at a time. A transparent overlay [Box]
 * consumes pointer events so taps do not interact with the page — the iOS
 * `.allowsHitTesting(false)` — letting the enclosing sidebar row handle taps/swipes.
 */
@Composable
private fun LivePreview(
    tab: Tab,
    shouldHostLiveView: () -> Boolean,
) {
    Box(
        modifier = Modifier
            .fillMaxSize()
            .background(MaterialTheme.colorScheme.canvas),
    ) {
        HostedWebView(
            webView = tab.webView,
            shouldHost = shouldHostLiveView,
            reservesTopSafeArea = false,
            modifier = Modifier.fillMaxSize(),
        )
        // Absorb all touches so the live preview is non-interactive (taps/swipes
        // belong to the parent row). awaitPointerEvent consumes events before the
        // hosted WebView ever sees them.
        Box(
            modifier = Modifier
                .fillMaxSize()
                .pointerInput(Unit) {
                    awaitPointerEventScope {
                        while (true) {
                            val event = awaitPointerEvent()
                            event.changes.forEach { it.consume() }
                        }
                    }
                },
        )
    }
}

/**
 * Static placeholder preview (no WebView): a [canvasSecondary] backdrop with a
 * centered favicon and the host label. Ports `StaticSidebarPreview`.
 */
@Composable
private fun StaticSidebarPreview(host: String) {
    Box(
        modifier = Modifier
            .fillMaxSize()
            .background(MaterialTheme.colorScheme.canvasSecondary),
        contentAlignment = Alignment.Center,
    ) {
        Column(
            verticalArrangement = Arrangement.spacedBy(8.dp),
            horizontalAlignment = Alignment.CenterHorizontally,
        ) {
            Favicon(host = host, size = 32.dp)
            Text(
                text = host,
                style = MaterialTheme.typography.bodySmall,
                color = MaterialTheme.colorScheme.onSurfaceVariant,
                maxLines = 1,
                overflow = TextOverflow.Ellipsis,
                modifier = Modifier.padding(horizontal = 8.dp),
            )
        }
    }
}
