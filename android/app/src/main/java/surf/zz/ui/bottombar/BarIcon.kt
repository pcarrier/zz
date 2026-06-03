package surf.zz.ui.bottombar

import androidx.compose.foundation.layout.size
import androidx.compose.material3.ExperimentalMaterial3Api
import androidx.compose.material3.Icon
import androidx.compose.material3.PlainTooltip
import androidx.compose.material3.TooltipBox
import androidx.compose.material3.TooltipDefaults
import androidx.compose.material3.Text
import androidx.compose.material3.rememberTooltipState
import androidx.compose.runtime.Composable
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.alpha
import androidx.compose.ui.graphics.vector.ImageVector
import androidx.compose.foundation.clickable
import androidx.compose.foundation.interaction.MutableInteractionSource
import androidx.compose.runtime.remember
import androidx.compose.ui.unit.dp

/**
 * Reusable bar icon.
 *
 * Port of `BottomBar.swift`'s private `barIcon(_:)` helper:
 *
 * ```swift
 * private func barIcon(_ name: String) -> some View {
 *     Image(systemName: name)
 *         .font(.system(size: 14, weight: .medium))
 *         .frame(width: 30, height: 30)
 *         .contentShape(.rect)
 * }
 * ```
 *
 * SF Symbol name strings become Material `ImageVector`s (see ANDROID_ARCH.md §11).
 * The 14pt symbol inside a 30x30 frame maps to a 30.dp box with the icon centered;
 * `Icon` defaults to ~24.dp glyph which reads as the medium-weight bar glyph.
 */
@Composable
fun BarIcon(
    icon: ImageVector,
    modifier: Modifier = Modifier,
    contentDescription: String? = null,
) {
    Icon(
        imageVector = icon,
        contentDescription = contentDescription,
        modifier = modifier.size(30.dp),
    )
}

/**
 * Disabled-dimmable icon button.
 *
 * Port of `BottomBar.swift`'s private `BarIconButton`:
 *
 * ```swift
 * private struct BarIconButton: View {
 *     let name: String
 *     let enabled: Bool
 *     let action: () -> Void
 *     var help: String = ""
 *     var body: some View {
 *         Button(action: action) { barIcon(name) }
 *             .buttonStyle(.plain)
 *             .disabled(!enabled)
 *             .opacity(enabled ? 1 : 0.35)
 *             .help(help)
 *     }
 * }
 * ```
 *
 * `.opacity(enabled ? 1 : 0.35)` maps to `Modifier.alpha`. `.help(...)` maps to an
 * optional Material3 [PlainTooltip] (only attached when [help] is non-empty, matching
 * the Swift default of `""` meaning "no tooltip").
 */
@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun BarIconButton(
    icon: ImageVector,
    enabled: Boolean,
    onClick: () -> Unit,
    modifier: Modifier = Modifier,
    help: String = "",
) {
    val dimmed = if (enabled) 1f else 0.35f
    val interactionSource = remember { MutableInteractionSource() }

    val button: @Composable () -> Unit = {
        BarIcon(
            icon = icon,
            contentDescription = help.ifEmpty { null },
            modifier = Modifier
                .alpha(dimmed)
                .clickable(
                    interactionSource = interactionSource,
                    indication = null,
                    enabled = enabled,
                    onClick = onClick,
                ),
        )
    }

    if (help.isEmpty()) {
        button()
    } else {
        TooltipBox(
            positionProvider = TooltipDefaults.rememberPlainTooltipPositionProvider(),
            tooltip = { PlainTooltip { Text(help) } },
            state = rememberTooltipState(),
            modifier = modifier,
        ) {
            button()
        }
    }
}
