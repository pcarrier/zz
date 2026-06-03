package surf.zz.ui.bsp

import androidx.compose.foundation.background
import androidx.compose.foundation.gestures.detectDragGestures
import androidx.compose.foundation.gestures.detectTapGestures
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.fillMaxHeight
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.layout.height
import androidx.compose.material3.MaterialTheme
import androidx.compose.runtime.Composable
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.input.pointer.pointerInput
import androidx.compose.ui.unit.Dp
import androidx.compose.ui.unit.dp
import surf.zz.layout.BspNode

/**
 * Reusable draggable divider between the two children of a BSP split.
 *
 * Mirrors the SwiftUI `SplitHandle`:
 *  - a tap selects the owning split group (`onSelect`),
 *  - a drag resizes the split. The baseline ratio is captured exactly once per
 *    gesture (`onBegin`), then every frame reports the *cumulative* translation
 *    from the gesture start (`onTranslate`). This reproduces the SwiftUI
 *    `DragGesture(coordinateSpace: .global)` behavior where `value.translation`
 *    is measured from the gesture's origin, not the previous frame — calling
 *    `onBegin` each frame would re-capture an already-moved ratio and double-count
 *    the translation (divider runaway).
 *
 * Compose's `detectDragGestures` reports *incremental* deltas per frame, so we
 * accumulate them into a running cumulative value to match the SwiftUI semantics.
 *
 * A ~1/60s throttle (via `System.nanoTime()`) limits how often `onTranslate`
 * fires, matching the iOS throttle that avoids hammering WebView relayout.
 *
 * macOS `NSCursor` resize hover is dropped (mobile target). A desktop build could
 * add a `PointerIcon` on hover.
 */
@Composable
fun SplitHandle(
    axis: BspNode.Axis,
    thickness: Dp = 12.dp,
    onSelect: () -> Unit = {},
    onBegin: () -> Unit = {},
    onTranslate: (Float) -> Unit,
    onEnd: () -> Unit = {},
) {
    val separatorColor = MaterialTheme.colorScheme.outlineVariant

    // The hit area fills the cross axis and is `thickness` along the split axis.
    val hitModifier = when (axis) {
        BspNode.Axis.HORIZONTAL -> Modifier.fillMaxWidth().height(thickness)
        BspNode.Axis.VERTICAL -> Modifier.fillMaxHeight().width(thickness)
    }

    Box(
        modifier = hitModifier.pointerInput(axis) {
            detectTapGestures(onTap = { onSelect() })
        }.pointerInput(axis) {
            // Cumulative translation along the split axis, accumulated from the
            // per-frame incremental deltas Compose hands us. Reset at each
            // gesture start so the next gesture re-captures a fresh baseline.
            var cumulative = 0f
            var didBegin = false
            var lastEmitNanos = 0L

            detectDragGestures(
                onDragStart = {
                    cumulative = 0f
                    didBegin = false
                    lastEmitNanos = 0L
                },
                onDrag = { change, dragAmount ->
                    change.consume()
                    cumulative += when (axis) {
                        BspNode.Axis.HORIZONTAL -> dragAmount.y
                        BspNode.Axis.VERTICAL -> dragAmount.x
                    }
                    // Throttle WebView relayout during drag (~60Hz).
                    val now = System.nanoTime()
                    if (now - lastEmitNanos < 16_666_666L) return@onDrag
                    lastEmitNanos = now
                    // Capture the baseline exactly once per gesture. onDrag fires
                    // every frame; calling onBegin each frame would re-capture an
                    // already-moved ratio and double-count the translation.
                    if (!didBegin) {
                        didBegin = true
                        onBegin()
                    }
                    onTranslate(cumulative)
                },
                onDragEnd = {
                    // Mirror SwiftUI's .onEnded exactly: emit the final cumulative
                    // translation, then end. We deliberately do NOT call onBegin()
                    // here if the throttle never let onDrag fire (sub-frame flick):
                    // in that case the store never captured a baseline, so
                    // updateRatioDrag (onTranslate) is a no-op and endRatioDrag
                    // (onEnd) just clears an already-absent entry — matching iOS.
                    onTranslate(cumulative)
                    onEnd()
                    didBegin = false
                },
                onDragCancel = {
                    // Gesture preempted/cancelled. Mirrors SwiftUI, where a
                    // cancelled drag never reaches `.onEnded`: we only clear the
                    // begin flag (the analog of @GestureState resetting to false)
                    // so the next gesture re-captures a fresh baseline. `onEnd` is
                    // deliberately NOT called; the store reconciles drag state on
                    // the next `onBegin`.
                    didBegin = false
                },
            )
        },
        contentAlignment = Alignment.Center,
    ) {
        // Hairline separator centered in the hit area.
        val lineModifier = when (axis) {
            BspNode.Axis.HORIZONTAL -> Modifier.fillMaxWidth().height(0.5.dp)
            BspNode.Axis.VERTICAL -> Modifier.fillMaxHeight().width(0.5.dp)
        }
        Box(modifier = lineModifier.background(separatorColor))
    }
}
