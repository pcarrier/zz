package surf.zz.ui.bsp

import androidx.compose.foundation.border
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.BoxWithConstraints
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.material3.MaterialTheme
import androidx.compose.runtime.Composable
import androidx.compose.runtime.key
import androidx.compose.ui.Modifier
import androidx.compose.ui.platform.LocalDensity
import androidx.compose.ui.unit.dp
import surf.zz.layout.BspNode
import surf.zz.ui.LocalBrowserStore
import surf.zz.ui.PaneSelectionVisual
import surf.zz.ui.theme.textSelection
import surf.zz.ui.tile.TileView

/**
 * Touch-target thickness of the divider hit area. Ports the file-private
 * `splitHandleHitThickness: CGFloat = 14` from iOS `BSPView.swift`.
 */
private val SplitHandleHitThickness = 14.dp

/**
 * Recursive composable rendering a [BspNode] tree.
 *
 * Port of iOS `BSPView` (`ios/zz/BSPView.swift`). A leaf renders a [TileView];
 * a split renders its two children with an interposed [SplitHandle] divider and,
 * when this split is the selected group, a draw-only selection outline.
 *
 * The SwiftUI version uses a `GeometryReader` + absolute `.position(...)` offsets
 * for the two children and the handle. On Android we use the idiomatic
 * weight-based layout: a [Column] (for a [BspNode.Axis.HORIZONTAL] split, whose
 * children are stacked vertically along the height) or a [Row] (for a
 * [BspNode.Axis.VERTICAL] split, whose children sit side-by-side along the
 * width), giving the first child `weight(ratio)` and the second `weight(1-ratio)`
 * with the [SplitHandle] between them. This preserves the iOS sizing exactly
 * (first occupies `length * ratio`, second the remainder) while letting Compose
 * own the measurement.
 *
 * The divider drag math in `BrowserStore.updateRatioDrag` is expressed against
 * the split's *usable* length (the cross-axis extent of the whole split), so we
 * pass the constraint length (`maxHeight` for horizontal, `maxWidth` for
 * vertical) as `usable`, matching the iOS `length` passed to `splitHandle`.
 */
@Composable
fun BspView(
    node: BspNode,
    onOutsideUrlBarInteraction: () -> Unit = {},
) {
    when (node) {
        is BspNode.Leaf ->
            // SwiftUI `.id(tabID)`: keying on the tab id keeps each tile's
            // composition (and its hosted WebView) stable across tree rewrites.
            key(node.tabId) {
                TileView(
                    tabId = node.tabId,
                    onOutsideUrlBarInteraction = onOutsideUrlBarInteraction,
                    modifier = Modifier.fillMaxSize(),
                )
            }

        is BspNode.Split -> SplitView(node, onOutsideUrlBarInteraction)
    }
}

@Composable
private fun SplitView(
    node: BspNode.Split,
    onOutsideUrlBarInteraction: () -> Unit,
) {
    val store = LocalBrowserStore.current
    val firstWeight = node.ratio.toFloat().coerceIn(0.05f, 0.95f)
    val secondWeight = 1f - firstWeight

    BoxWithConstraints(modifier = Modifier.fillMaxSize()) {
        // `usable` is the split's extent along its dividing axis, mirroring the
        // iOS `length = axis == .horizontal ? size.height : size.width`. The
        // divider translation in BrowserStore.updateRatioDrag is interpreted
        // against this length.
        val density = LocalDensity.current
        val usable = with(density) {
            when (node.axis) {
                BspNode.Axis.HORIZONTAL -> maxHeight.toPx()
                BspNode.Axis.VERTICAL -> maxWidth.toPx()
            }
        }

        val first: @Composable () -> Unit = {
            BspView(node.first, onOutsideUrlBarInteraction)
        }
        val second: @Composable () -> Unit = {
            BspView(node.second, onOutsideUrlBarInteraction)
        }
        val handle: @Composable () -> Unit = {
            SplitHandle(
                axis = node.axis,
                // iOS passes `splitHandleHitThickness = 14` to the handle; the
                // SplitHandle default is 12, so pass 14 explicitly to match.
                thickness = SplitHandleHitThickness,
                onSelect = {
                    onOutsideUrlBarInteraction()
                    store.selectGroup(node.id)
                },
                onBegin = {
                    onOutsideUrlBarInteraction()
                    store.beginRatioDrag(node.id)
                },
                onTranslate = { translation ->
                    store.updateRatioDrag(node.id, usable = usable, translation = translation)
                },
                onEnd = { store.endRatioDrag(node.id) },
            )
        }

        when (node.axis) {
            BspNode.Axis.HORIZONTAL ->
                Column(modifier = Modifier.fillMaxSize()) {
                    Box(modifier = Modifier.fillMaxSize().weight(firstWeight)) { first() }
                    handle()
                    Box(modifier = Modifier.fillMaxSize().weight(secondWeight)) { second() }
                }
            BspNode.Axis.VERTICAL ->
                Row(modifier = Modifier.fillMaxSize()) {
                    Box(modifier = Modifier.fillMaxSize().weight(firstWeight)) { first() }
                    handle()
                    Box(modifier = Modifier.fillMaxSize().weight(secondWeight)) { second() }
                }
        }

        // Selected-group outline: draw-only (no hit testing), so it sits in the
        // overlay and never intercepts touches. iOS draws a stroked Rectangle
        // padded by 1pt; `border` on a match-parent Box is the Compose analog.
        if (store.selectedGroupID == node.id) {
            Box(
                modifier = Modifier
                    .matchParentSize()
                    .border(PaneSelectionVisual.strokeWidth, MaterialTheme.colorScheme.textSelection),
            )
        }
    }
}
