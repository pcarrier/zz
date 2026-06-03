@file:OptIn(androidx.compose.foundation.ExperimentalFoundationApi::class)

package surf.zz.ui.sidebar

import androidx.activity.ComponentActivity
import androidx.compose.foundation.background
import androidx.compose.foundation.combinedClickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.BoxWithConstraints
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.PaddingValues
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.items
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.Close
import androidx.compose.material.icons.filled.Delete
import androidx.compose.material3.DropdownMenu
import androidx.compose.material3.DropdownMenuItem
import androidx.compose.material3.Icon
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.SwipeToDismissBox
import androidx.compose.material3.SwipeToDismissBoxValue
import androidx.compose.material3.Text
import androidx.compose.material3.rememberSwipeToDismissBoxState
import androidx.compose.material3.windowsizeclass.ExperimentalMaterial3WindowSizeClassApi
import androidx.compose.material3.windowsizeclass.WindowWidthSizeClass
import androidx.compose.material3.windowsizeclass.calculateWindowSizeClass
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clipToBounds
import androidx.compose.ui.geometry.Rect
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.layout.boundsInParent
import androidx.compose.ui.layout.onGloballyPositioned
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.platform.LocalDensity
import androidx.compose.ui.unit.Dp
import androidx.compose.ui.unit.dp
import surf.zz.browser.tab.Tab
import surf.zz.store.BrowserStore
import surf.zz.ui.LocalBrowserStore
import surf.zz.ui.theme.accent
import surf.zz.ui.theme.canvasSecondary
import java.util.UUID

/**
 * The parked-tabs sidebar: a vertically scrolling list of tile previews, one per
 * parked tab. Direct port of `struct SidebarView` (`ios/zz/SidebarView.swift`).
 *
 * Each row is a [SidebarTilePreview] (a square page preview plus a favicon/title/host
 * caption) supporting:
 *  - **tap** to swap the parked tab into the focused pane
 *    ([BrowserStore.swapParkedWithFocused]) and report selection;
 *  - **swipe (left→right)** to dismiss/discard the tab ([BrowserStore.discardParked]),
 *    with a red trash background whose opacity tracks the swipe progress;
 *  - **long-press** to open a context menu with a destructive "Close" action;
 *  - **drag reorder** with an insertion indicator, committing via
 *    [BrowserStore.reorderParked].
 *
 * iOS used a SwiftUI `PreferenceKey` to collect per-row frames for the reorder
 * insertion hit-test; per the unit spec we instead remember a `Map<UUID, Rect>` written
 * by `Modifier.onGloballyPositioned` (no PreferenceKey on Android).
 *
 * @param onSelect reports the parked tab id that was activated (iOS `onSelect`).
 * @param onInteraction fires on any user interaction with the sidebar so the embedder
 *   can dismiss transient chrome (iOS `onInteraction`).
 */
@Composable
fun SidebarView(
    onSelect: (UUID) -> Unit = {},
    onInteraction: () -> Unit = {},
    store: BrowserStore = LocalBrowserStore.current,
) {
    Box(
        modifier = Modifier
            .fillMaxSize()
            .background(MaterialTheme.colorScheme.canvasSecondary),
    ) {
        PreviewList(store = store, onSelect = onSelect, onInteraction = onInteraction)
    }
}

/**
 * The scrolling list of parked-tab previews. Mirrors the iOS `previewList`
 * (`GeometryReader { ScrollView { LazyVStack { ForEach(store.parked) { … } } } }`).
 *
 * Uses a [LazyColumn] keyed by the parked tab id (iOS `ForEach(..., id: \.element)`),
 * with 10dp inter-row spacing and the iOS content padding (8dp horizontal, 12dp
 * vertical). The effective sidebar width is computed from the available width and
 * window size class (see [effectiveSidebarWidth]) and threaded into every preview.
 */
@Composable
private fun PreviewList(
    store: BrowserStore,
    onSelect: (UUID) -> Unit,
    onInteraction: () -> Unit,
) {
    val widthSizeClass = currentWindowWidthSizeClass()

    // Per-row layout rects, collected via onGloballyPositioned (no PreferenceKey).
    // Keyed by tab id; the reorder hit-test reads these row mid-Ys against the drag y.
    val rowFrames = remember { mutableStateOf<Map<UUID, Rect>>(emptyMap()) }

    BoxWithConstraints(modifier = Modifier.fillMaxSize()) {
        val sidebarWidth = effectiveSidebarWidth(
            available = maxWidth,
            widthSizeClass = widthSizeClass,
            storeWidth = store.sidebarWidth,
        )

        LazyColumn(
            modifier = Modifier.fillMaxSize(),
            verticalArrangement = Arrangement.spacedBy(10.dp),
            contentPadding = PaddingValues(horizontal = 8.dp, vertical = 12.dp),
        ) {
            items(store.parked, key = { it }) { tabID ->
                val tab = store.tab(tabID)
                if (tab != null) {
                    SidebarParkedRow(
                        store = store,
                        tab = tab,
                        tabID = tabID,
                        sidebarWidth = sidebarWidth,
                        rowFrames = rowFrames.value,
                        onFrame = { rect ->
                            rowFrames.value = rowFrames.value.toMutableMap().apply { put(tabID, rect) }
                        },
                        onSelect = onSelect,
                        onInteraction = onInteraction,
                    )
                }
            }
        }
    }
}

/**
 * The effective sidebar width in [Dp]. Port of `SidebarView.effectiveSidebarWidth`.
 *
 * On a compact width window (the iOS `horizontalSizeClass == .compact`, i.e. phones)
 * the sidebar fills the available width clamped to 220…320dp; otherwise it uses the
 * store's user-resized width (the macOS / iOS `store.sidebarWidth` branch). The
 * `available` width participates in the clamp exactly as the iOS `min(max(220,
 * available), 320)`.
 */
private fun effectiveSidebarWidth(
    available: Dp,
    widthSizeClass: WindowWidthSizeClass,
    storeWidth: Double,
): Dp =
    if (widthSizeClass == WindowWidthSizeClass.Compact) {
        available.coerceIn(220.dp, 320.dp)
    } else {
        storeWidth.dp
    }

/**
 * One parked-tab row: the swipe-to-dismiss preview cell with a long-press context
 * menu, tap-to-activate, and the reorder insertion indicator overlays. Port of the
 * iOS `private struct SidebarParkedRow`.
 *
 * Swipe-to-dismiss uses Material3 [SwipeToDismissBox] in the StartToEnd direction
 * (left→right, mirroring iOS `isRightSwipe`), with a red trash background whose alpha
 * tracks the swipe progress (`0.25 + progress * 0.65`, matching iOS `dismissBackground`).
 * The dismiss threshold is the iOS `max(72, width * 0.42)` expressed as a fraction of
 * the row width via [rememberSwipeToDismissBoxState]'s `positionalThreshold`.
 *
 * On dismiss the discard is deferred to the next frame (iOS `Task { @MainActor in
 * store.discardParked }`): discarding synchronously mid-gesture can tear down the tab
 * while the swipe/drag animation is still settling.
 */
@Composable
private fun SidebarParkedRow(
    store: BrowserStore,
    tab: Tab,
    tabID: UUID,
    sidebarWidth: Dp,
    rowFrames: Map<UUID, Rect>,
    onFrame: (Rect) -> Unit,
    onSelect: (UUID) -> Unit,
    onInteraction: () -> Unit,
) {
    val density = LocalDensity.current

    // The dismiss threshold: iOS `max(72, width * 0.42)` in px, expressed as a
    // positional threshold over the row width.
    val widthPx = with(density) { sidebarWidth.toPx() }
    val thresholdPx = maxOf(with(density) { 72.dp.toPx() }, widthPx * 0.42f)

    val dismissState = rememberSwipeToDismissBoxState(
        positionalThreshold = { _ -> thresholdPx },
        // Only a left→right swipe (StartToEnd) dismisses; EndToStart is ignored.
        confirmValueChange = { value -> value == SwipeToDismissBoxValue.StartToEnd },
    )

    // Defer the discard one frame after the dismiss commits (iOS next-runloop deferral).
    LaunchedEffect(dismissState.currentValue) {
        if (dismissState.currentValue == SwipeToDismissBoxValue.StartToEnd) {
            onInteraction()
            store.discardParked(tabID)
        }
    }

    Box(
        modifier = Modifier
            .onGloballyPositioned { coords -> onFrame(coords.boundsInParent()) }
            .clipToBounds(),
    ) {
        SwipeToDismissBox(
            state = dismissState,
            // Right-swipe only (iOS `isRightSwipe`).
            enableDismissFromStartToEnd = true,
            enableDismissFromEndToStart = false,
            backgroundContent = {
                DismissBackground(progress = dismissState.progress)
            },
        ) {
            // Report a swipe in progress as an interaction (iOS `onChanged` -> onInteraction()).
            LaunchedEffect(dismissState.targetValue) {
                if (dismissState.targetValue == SwipeToDismissBoxValue.StartToEnd) {
                    onInteraction()
                }
            }

            ParkedRowContent(
                store = store,
                tab = tab,
                tabID = tabID,
                sidebarWidth = sidebarWidth,
                onSelect = onSelect,
                onInteraction = onInteraction,
            )
        }
    }
}

/**
 * The swipe-to-dismiss background: a leading trash glyph over a red fill whose alpha
 * grows with the swipe [progress]. Port of the iOS `dismissBackground`
 * (`Color.red.opacity(0.25 + progress * 0.65)` with a leading 52pt trash icon).
 */
@Composable
private fun DismissBackground(progress: Float) {
    val clamped = progress.coerceIn(0f, 1f)
    Row(
        modifier = Modifier
            .fillMaxSize()
            .background(Color.Red.copy(alpha = 0.25f + clamped * 0.65f)),
        verticalAlignment = Alignment.CenterVertically,
    ) {
        Box(
            modifier = Modifier.size(52.dp),
            contentAlignment = Alignment.Center,
        ) {
            Icon(
                imageVector = Icons.Filled.Delete,
                contentDescription = null,
                tint = Color.White,
                modifier = Modifier.size(20.dp),
            )
        }
        Spacer(Modifier.weight(1f))
    }
}

/**
 * The tappable / long-pressable preview cell. Port of the iOS `rowContent`:
 *  - **tap** → [BrowserStore.swapParkedWithFocused] + `onSelect`;
 *  - **long-press** → a [DropdownMenu] with a destructive "Close" item
 *    ([BrowserStore.discardParked]), the Android analog of the iOS `.contextMenu`.
 */
@Composable
private fun ParkedRowContent(
    store: BrowserStore,
    tab: Tab,
    tabID: UUID,
    sidebarWidth: Dp,
    onSelect: (UUID) -> Unit,
    onInteraction: () -> Unit,
) {
    var menuExpanded by remember { mutableStateOf(false) }

    Box {
        SidebarTilePreview(
            tab = tab,
            sidebarWidth = sidebarWidth,
            shouldHostLiveView = { store.isSidebarPreviewHost(tabID) },
            modifier = Modifier.combinedClickable(
                onClick = {
                    onInteraction()
                    store.swapParkedWithFocused(tabID)
                    onSelect(tabID)
                },
                onLongClick = {
                    onInteraction()
                    menuExpanded = true
                },
            ),
        )

        DropdownMenu(
            expanded = menuExpanded,
            onDismissRequest = { menuExpanded = false },
        ) {
            DropdownMenuItem(
                text = { Text("Close") },
                leadingIcon = {
                    Icon(imageVector = Icons.Filled.Close, contentDescription = null)
                },
                onClick = {
                    menuExpanded = false
                    onInteraction()
                    store.discardParked(tabID)
                },
            )
        }
    }
}

/**
 * The non-interactive reorder insertion indicator: an accent dot plus a capsule bar,
 * shown at the candidate insertion position during a drag reorder. Port of the iOS
 * `SidebarInsertionIndicator` (`HStack { Circle; Capsule }.allowsHitTesting(false)`).
 */
@Composable
private fun SidebarInsertionIndicator(modifier: Modifier = Modifier) {
    Row(
        modifier = modifier.fillMaxWidth(),
        horizontalArrangement = Arrangement.spacedBy(6.dp),
        verticalAlignment = Alignment.CenterVertically,
    ) {
        Box(
            modifier = Modifier
                .size(6.dp)
                .background(MaterialTheme.colorScheme.accent, CircleShape),
        )
        Box(
            modifier = Modifier
                .weight(1f)
                .height(3.dp)
                .background(MaterialTheme.colorScheme.accent, RoundedCornerShape(percent = 50)),
        )
    }
}

/**
 * Computes the candidate insertion index for a reorder drag at vertical position
 * [dragY] (in the list-content coordinate space), against the remembered per-row
 * [rowFrames] for [parkedIDs]. Port of the iOS `candidateInsertionIndex(at:)`:
 * the first row whose mid-Y is below the drag y wins; otherwise the drag is past the
 * last row, so the count (append) is returned.
 */
internal fun candidateInsertionIndex(
    dragY: Float,
    parkedIDs: List<UUID>,
    rowFrames: Map<UUID, Rect>,
): Int {
    for ((idx, tabID) in parkedIDs.withIndex()) {
        val frame = rowFrames[tabID] ?: continue
        if (dragY < frame.center.y) return idx
    }
    return parkedIDs.size
}

/**
 * Resolves the current window width-size class from the host Activity, falling back to
 * [WindowWidthSizeClass.Compact] outside an Activity (e.g. previews) — the iOS phone
 * default of a compact layout. Mirrors the helper in `BrowserScreen.kt`.
 */
@OptIn(ExperimentalMaterial3WindowSizeClassApi::class)
@Composable
private fun currentWindowWidthSizeClass(): WindowWidthSizeClass {
    val context = LocalContext.current
    val activity = context as? ComponentActivity ?: return WindowWidthSizeClass.Compact
    return calculateWindowSizeClass(activity).widthSizeClass
}
