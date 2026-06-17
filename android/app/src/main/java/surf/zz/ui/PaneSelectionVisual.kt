package surf.zz.ui

import androidx.compose.ui.unit.Dp
import androidx.compose.ui.unit.dp

/**
 * Pane-selection stroke geometry constants.
 *
 * Ports `enum PaneSelectionVisual` from iOS `Theme.swift`. The Swift `CGFloat`
 * constants become Compose [Dp] per the Android arch doc (§11 Theming & colors).
 *
 * `reservedInset` is the layout inset reserved for the selection stroke so the
 * stroke can be drawn inside a pane without overlapping its content; it equals
 * [strokeWidth].
 */
object PaneSelectionVisual {
    val strokeWidth: Dp = 1.dp
    val reservedInset: Dp = strokeWidth
}
