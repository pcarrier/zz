package surf.zz.ui.tile

import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.BoxWithConstraints
import androidx.compose.foundation.layout.offset
import androidx.compose.foundation.layout.size
import androidx.compose.material3.MaterialTheme
import androidx.compose.runtime.Composable
import androidx.compose.ui.Modifier
import androidx.compose.ui.unit.Dp
import androidx.compose.ui.unit.dp
import surf.zz.ui.theme.accent

/**
 * Translucent accent rectangle previewing the target split region for a drag in
 * progress over a pane. Non-interactive: callers overlay it on top of the pane
 * content (the iOS `DropZoneIndicator` is wrapped in `.allowsHitTesting(false)`),
 * so this composable intentionally does not consume pointer input.
 *
 * Ported from `private struct DropZoneIndicator` in `TileView.swift`. The Swift
 * version uses a `GeometryReader` + `CGRect targetFrame(width:height:)` and places
 * the rectangle via `.frame(width:height:).position(x: midX, y: midY)`. Here
 * [BoxWithConstraints] supplies the pane's `maxWidth`/`maxHeight` in `Dp`, and the
 * fractional CGRect math is reproduced 1:1 against those `Dp` extents, with the
 * rectangle placed by its top-left `origin` via `Modifier.offset` (Compose offsets
 * from the top-left, so no mid-point conversion is needed).
 */
@Composable
fun DropZoneIndicator(zone: DropZone, modifier: Modifier = Modifier) {
    val accent = MaterialTheme.colorScheme.accent
    BoxWithConstraints(modifier = modifier) {
        val w: Dp = maxWidth
        val h: Dp = maxHeight
        val frame = targetFrame(zone, w, h)
        Box(
            Modifier
                .offset(x = frame.x, y = frame.y)
                .size(width = frame.width, height = frame.height)
                .background(accent.copy(alpha = 0.18f))
                .border(2.dp, accent),
        )
    }
}

/**
 * Top-left origin and size of the highlighted region within a pane of the given
 * [w]x[h] extent, ported verbatim from `targetFrame(width:height:)` in
 * `TileView.swift`.
 *
 * - [DropZone.CENTER]: inset by 18% on every side.
 * - edge zones: the matching half of the pane.
 */
private data class TargetFrame(val x: Dp, val y: Dp, val width: Dp, val height: Dp)

private fun targetFrame(zone: DropZone, w: Dp, h: Dp): TargetFrame =
    when (zone) {
        DropZone.CENTER -> {
            val inset = 0.18f
            TargetFrame(
                x = w * inset,
                y = h * inset,
                width = w * (1 - 2 * inset),
                height = h * (1 - 2 * inset),
            )
        }
        DropZone.TOP -> TargetFrame(x = 0.dp, y = 0.dp, width = w, height = h * 0.5f)
        DropZone.BOTTOM -> TargetFrame(x = 0.dp, y = h * 0.5f, width = w, height = h * 0.5f)
        DropZone.LEFT -> TargetFrame(x = 0.dp, y = 0.dp, width = w * 0.5f, height = h)
        DropZone.RIGHT -> TargetFrame(x = w * 0.5f, y = 0.dp, width = w * 0.5f, height = h)
    }
