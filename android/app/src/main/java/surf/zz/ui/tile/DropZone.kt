package surf.zz.ui.tile

import androidx.compose.ui.geometry.Offset
import androidx.compose.ui.geometry.Size

/**
 * The five regions a drag can resolve to within a tile. Dropping in [CENTER]
 * replaces the pane's content; the four edge zones split the pane along the
 * matching side.
 *
 * Ported verbatim from `TileView.swift`'s `enum DropZone`.
 */
enum class DropZone { TOP, BOTTOM, LEFT, RIGHT, CENTER }

/**
 * Resolves a drop [location] within a pane of the given [size] to a [DropZone].
 *
 * A drop lands in [DropZone.CENTER] when it is more than 15% of the pane's
 * extent away from every edge; otherwise it snaps to the nearest edge. Ties
 * resolve in the order top, bottom, left, right (matching the Swift cascade of
 * `if minDist == ...` checks).
 *
 * Pure geometry — ported 1:1 from `dropZone(at:in:)` in `TileView.swift`.
 */
fun dropZone(at: Offset, size: Size): DropZone {
    if (size.width <= 0f || size.height <= 0f) return DropZone.CENTER

    val xFrac = at.x / size.width
    val yFrac = at.y / size.height

    val dLeft = xFrac
    val dRight = 1f - xFrac
    val dTop = yFrac
    val dBottom = 1f - yFrac
    val minDist = minOf(dLeft, dRight, dTop, dBottom)

    if (minDist > 0.15f) return DropZone.CENTER
    if (minDist == dTop) return DropZone.TOP
    if (minDist == dBottom) return DropZone.BOTTOM
    if (minDist == dLeft) return DropZone.LEFT
    return DropZone.RIGHT
}
