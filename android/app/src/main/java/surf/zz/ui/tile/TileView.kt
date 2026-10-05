package surf.zz.ui.tile

import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.gestures.detectTapGestures
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.PauseCircle
import androidx.compose.material3.Icon
import androidx.compose.material3.MaterialTheme
import androidx.compose.runtime.Composable
import androidx.compose.runtime.DisposableEffect
import androidx.compose.runtime.remember
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clipToBounds
import androidx.compose.ui.geometry.Size
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.input.pointer.pointerInput
import androidx.compose.ui.layout.onSizeChanged
import androidx.compose.ui.unit.IntSize
import androidx.compose.ui.unit.dp
import surf.zz.browser.tab.Tab
import surf.zz.browser.web.HostedWebView
import surf.zz.browser.web.PaneDropHandler
import surf.zz.browser.web.PaneDropPayload
import surf.zz.ui.LocalBrowserStore
import surf.zz.ui.PaneSelectionVisual
import surf.zz.ui.theme.accent
import surf.zz.ui.theme.canvas
import surf.zz.ui.theme.textSelection
import java.util.UUID

/**
 * A single pane: the leaf of the BSP layout. Direct port of `struct TileView`
 * (`ios/zz/TileView.swift`).
 *
 * Renders one of three content states for the tab identified by [tabId]:
 *  - **missing** (the tab no longer exists) — a bare [ColorScheme.canvas] fill;
 *  - **blank** (`tab.isBlank`) — the [EmptyTileState], whose tap focuses the pane
 *    and opens the URL bar;
 *  - **web** — the externally-owned [Tab.webView] hosted via [HostedWebView].
 *
 * On top of the content (none of which hit-tests) it layers, in iOS order:
 *  1. a thin top **loading bar** scaled to `estimatedProgress` while the page is
 *     mid-load (progress strictly between 0 and 1);
 *  2. a **media badge** (pause icon on a translucent circle, bottom-trailing) when
 *     the pane's media is user-suspended;
 *  3. a **drop-zone indicator** previewing the split a hovering drag would create;
 *  4. an **active-pane outline** when this pane is the focused leaf.
 *
 * The whole tile is tappable (focuses the pane) and is a drag-and-drop target for
 * URLs / parked tabs (see [tileDropTarget]). Pane size is tracked into the
 * [TileDropState] so a drop location resolves to the right [DropZone].
 *
 * @param tabId the tab whose pane this renders.
 * @param onOutsideUrlBarInteraction invoked when the user interacts with the page
 *   itself (a web interaction that should dismiss the omnibox); the iOS
 *   `onOutsideURLBarInteraction`.
 */
@Composable
fun TileView(
    tabId: UUID,
    modifier: Modifier = Modifier,
    onOutsideUrlBarInteraction: () -> Unit = {},
) {
    val store = LocalBrowserStore.current
    val tab = store.tab(tabId)

    if (tab == null) {
        // Missing tab: a bare canvas fill (iOS `Color.canvas`).
        Box(modifier.fillMaxSize().background(MaterialTheme.colorScheme.canvas))
        return
    }

    // Transient drop-hover state, owned per-tile (iOS `@State private var dropState`).
    val dropState = remember { TileDropState() }

    // Clear the hover highlight when the pane leaves composition (iOS `.onDisappear`).
    DisposableEffect(Unit) {
        onDispose { dropState.clear() }
    }

    val canvas = MaterialTheme.colorScheme.canvas
    // Active == this leaf is focused and no group (split) is selected. iOS:
    // `store.focusedTabID == tabID && store.selectedGroupID == nil`.
    val active = store.focusedTabID == tabId && store.selectedGroupID == null

    Box(
        modifier = modifier
            .padding(PaneSelectionVisual.reservedInset)
            .background(canvas)
            .clipToBounds()
            // Track the pane size so a drop location resolves to a zone (iOS tracked
            // it through a background GeometryReader writing `dropState.size`).
            .onSizeChanged { dropState.size = it }
            // Tapping anywhere in the pane focuses it (iOS `.onTapGesture`).
            .pointerInput(tabId) {
                detectTapGestures(onTap = { store.focus(tabId) })
            }
            // URL / parked-tab drop target (iOS `.onDrop(...)`). The target itself
            // re-checks `isMainPaneHost` and routes to `store.dropURL`/`dropParked`.
            .tileDropTarget(
                isMainPaneHost = { store.isMainPaneHost(tabId) },
                state = dropState,
                onDropUrl = { url, zone -> store.dropURL(url, on = tabId, zone = zone) },
                onDropParked = { parkedId, zone -> store.dropParked(parkedId, on = tabId, zone = zone) },
            ),
    ) {
        // ---- Content ----------------------------------------------------------
        if (tab.isBlank) {
            EmptyTileState {
                store.focus(tabId)
                store.focusURLBar()
            }
        } else {
            HostedWebView(
                webView = tab.webView,
                onInteraction = {
                    store.focus(tabId)
                    onOutsideUrlBarInteraction()
                },
                dropHandler = PaneDropHandler(
                    update = { location, size ->
                        dropState.update(location = location, size = size.toIntSize())
                    },
                    perform = { payload, location, size ->
                        dropState.size = size.toIntSize()
                        val zone = dropZone(at = location, size = size)
                        performPaneDrop(store, tabId, payload, zone)
                        dropState.clear()
                    },
                    end = { dropState.clear() },
                ),
                shouldHost = { store.isMainPaneHost(tabId) },
                layoutRevision = store.paneLayoutRevision(tabId),
            )
        }

        // ---- Overlays (no hit testing) ---------------------------------------

        // 1. Top loading bar, scaled to progress while loading (iOS `.overlay(.top)`).
        if (tab.isLoading && tab.estimatedProgress > 0.0 && tab.estimatedProgress < 1.0) {
            Box(
                Modifier
                    .align(Alignment.TopStart)
                    .fillMaxWidth(tab.estimatedProgress.toFloat())
                    .height(2.dp)
                    .background(MaterialTheme.colorScheme.accent),
            )
        }

        // 2. Media badge, bottom-trailing, when this pane's media is suspended.
        if (tab.isMediaSuspended) {
            MediaIndicator(
                modifier = Modifier
                    .align(Alignment.BottomEnd)
                    .padding(8.dp),
            )
        }

        // 3. Drop-zone preview while a drag hovers.
        dropState.zone?.let { zone ->
            DropZoneIndicator(zone = zone, modifier = Modifier.fillMaxSize())
        }

        // 4. Active-pane outline.
        if (active) {
            ActivePaneOutline()
        }
    }
}

/**
 * Performs a resolved pane drop against the store. Port of the iOS
 * `performPaneDrop(_:zone:)` switch over [PaneDropPayload].
 */
private fun performPaneDrop(
    store: surf.zz.store.BrowserStore,
    tabId: UUID,
    payload: PaneDropPayload,
    zone: DropZone,
) {
    when (payload) {
        is PaneDropPayload.Url -> store.dropURL(payload.url, on = tabId, zone = zone)
        is PaneDropPayload.ParkedTab -> store.dropParked(payload.id, on = tabId, zone = zone)
    }
}

/**
 * The small media-suspension badge: a pause glyph on a 55%-opaque black circle.
 * Port of iOS `private struct MediaIndicator` (SF Symbol `pause.circle.fill`).
 * Non-interactive — overlaid above page content (iOS `.allowsHitTesting(false)`).
 */
@Composable
private fun MediaIndicator(modifier: Modifier = Modifier) {
    Box(
        modifier = modifier
            .background(Color.Black.copy(alpha = 0.55f), CircleShape)
            .padding(6.dp),
    ) {
        Icon(
            imageVector = Icons.Filled.PauseCircle,
            contentDescription = null,
            tint = Color.White,
            modifier = Modifier.size(18.dp),
        )
    }
}

/**
 * The focused-leaf selection outline: a 1dp [ColorScheme.textSelection] stroked
 * border filling the pane. Port of iOS `private struct ActivePaneOutline`
 * (`Rectangle().strokeBorder(.textSelection, lineWidth: strokeWidth)`).
 * Non-interactive.
 */
@Composable
private fun ActivePaneOutline() {
    Box(
        Modifier
            .fillMaxSize()
            .border(PaneSelectionVisual.strokeWidth, MaterialTheme.colorScheme.textSelection),
    )
}

/**
 * The blank-pane placeholder: a faint secondary-tinted fill that focuses the pane
 * and opens the URL bar when tapped. Port of iOS `private struct EmptyTileState`
 * (`Color.secondary.opacity(0.05)` + `.onTapGesture`).
 */
@Composable
private fun EmptyTileState(onTap: () -> Unit) {
    Box(
        Modifier
            .fillMaxSize()
            .background(MaterialTheme.colorScheme.onSurface.copy(alpha = 0.05f))
            .pointerInput(Unit) {
                detectTapGestures(onTap = { onTap() })
            },
    )
}

/** Compose `Size` (px floats) → [IntSize] for [TileDropState]. */
private fun Size.toIntSize(): IntSize = IntSize(width.toInt(), height.toInt())
