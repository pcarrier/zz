package surf.zz.ui

import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxHeight
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.width
import androidx.compose.runtime.Composable
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clipToBounds
import androidx.compose.ui.platform.LocalDensity
import androidx.compose.ui.unit.dp
import surf.zz.layout.BspNode
import surf.zz.ui.bsp.BspView
import surf.zz.ui.bsp.SplitHandle
import surf.zz.ui.sidebar.SidebarView
import surf.zz.ui.tile.TileView

/**
 * Main content area of the browser window.
 *
 * Ports the `mainContent` / `mainPaneContent` view builders of `BrowserScene`
 * (iOS `ContentView.swift`). The choice between the two builders:
 *
 *  - **`mainPaneContent`**: if [BrowserStore.zoomedTabID] names an existing tab,
 *    show that single [TileView] zoomed full-bleed; otherwise show the BSP pane
 *    tree rooted at [BrowserStore.root] via [BspView].
 *  - **`mainContent`**: on a compact width the pane content fills the window. On a
 *    regular width, if there are parked tabs AND nothing is zoomed, a resizable
 *    sidebar is laid out to the right of the pane content, separated by a
 *    vertical [SplitHandle] that drives [BrowserStore.beginSidebarDrag] /
 *    `updateSidebarDrag` / `endSidebarDrag`.
 *
 * The compact-vs-regular decision is made by the caller (`BrowserScreen`, the
 * Android analog of `BrowserScene`) — on iOS this is
 * `horizontalSizeClass == .compact` — and passed in as [compact]. On macOS the
 * Swift code forces `usesCompactLayout == false`; Android has no macOS target so
 * the value comes purely from the window width size class.
 *
 * @param compact whether the current window width is the compact size class. When
 *   `true` the pane content fills the window and no sidebar is shown (the parked
 *   tabs are reached through the bottom-bar / sheet sidebar instead). When `false`
 *   (regular width) the sidebar is laid out inline.
 * @param onOutsideUrlBarInteraction forwarded to the tile / pane tree / sidebar so
 *   any interaction with the web content or the sidebar dismisses the omnibox; the
 *   [SplitHandle]'s drag-begin also invokes it (mirrors the iOS `dismissOmnibox`
 *   call inside `onBegin`).
 */
@Composable
fun MainContent(
    compact: Boolean,
    onOutsideUrlBarInteraction: () -> Unit,
    modifier: Modifier = Modifier,
) {
    val store = LocalBrowserStore.current

    if (compact) {
        // Compact: the pane content fills the available space; no sidebar.
        Box(modifier = modifier.fillMaxSize()) {
            MainPaneContent(onOutsideUrlBarInteraction = onOutsideUrlBarInteraction)
        }
    } else {
        // Regular: pane content on the left, optional resizable sidebar on the right.
        // The sidebar appears only when there are parked tabs and nothing is zoomed
        // (matches `!store.parked.isEmpty && store.zoomedTabID == nil`).
        val showSidebar = store.parked.isNotEmpty() && store.zoomedTabID == null

        Row(modifier = modifier.fillMaxSize()) {
            Box(modifier = Modifier.weight(1f).fillMaxHeight()) {
                MainPaneContent(onOutsideUrlBarInteraction = onOutsideUrlBarInteraction)
            }

            if (showSidebar) {
                val density = LocalDensity.current
                SplitHandle(
                    axis = BspNode.Axis.VERTICAL,
                    onBegin = {
                        onOutsideUrlBarInteraction()
                        store.beginSidebarDrag()
                    },
                    // SwiftUI's SplitHandle reports a translation; on Android the
                    // drag delta arrives in pixels, so convert to dp-space points
                    // to match `updateSidebarDrag(translation:)`, which subtracts a
                    // point translation from the initial point width.
                    onTranslate = { translationPx ->
                        val translationDp = with(density) { translationPx.toDp().value }
                        store.updateSidebarDrag(translation = translationDp)
                    },
                    onEnd = { store.endSidebarDrag() },
                )

                // SidebarView has no `modifier` parameter (it owns its own root
                // modifier), so the iOS `.frame(width:).clipped()` is applied by
                // wrapping it in a sized, clipped Box — the Compose analog.
                val sidebarWidth = store.sidebarWidth.dp
                Box(
                    modifier = Modifier
                        .width(sidebarWidth)
                        .fillMaxHeight()
                        .clipToBounds(),
                ) {
                    SidebarView(onInteraction = onOutsideUrlBarInteraction)
                }
            }
        }
    }
}

/**
 * Ports `mainPaneContent`: a single zoomed [TileView] when a valid
 * [BrowserStore.zoomedTabID] is set, otherwise the BSP pane tree.
 *
 * The `.id(zoomedID)` in SwiftUI forces a fresh identity per zoomed tab; in
 * Compose the equivalent is reading [BrowserStore.zoomedTabID] here (a snapshot
 * read) so swapping the zoomed tab recomposes [TileView] with the new id.
 */
@Composable
private fun MainPaneContent(onOutsideUrlBarInteraction: () -> Unit) {
    val store = LocalBrowserStore.current
    val zoomedId = store.zoomedTabID

    if (zoomedId != null && store.tab(zoomedId) != null) {
        TileView(
            tabId = zoomedId,
            onOutsideUrlBarInteraction = onOutsideUrlBarInteraction,
        )
    } else {
        BspView(
            node = store.root,
            onOutsideUrlBarInteraction = onOutsideUrlBarInteraction,
        )
    }
}
