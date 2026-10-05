package surf.zz.ui.theme

import androidx.compose.foundation.text.selection.TextSelectionColors
import androidx.compose.material3.ColorScheme
import androidx.compose.ui.graphics.Color

/**
 * Semantic color mapping ported from the iOS `extension Color` in `Theme.swift`.
 *
 * On iOS these are dynamic system colors that resolve differently for light/dark
 * appearance. On Android the equivalent adaptivity is provided by the active
 * [ColorScheme] (light vs. dark `colorScheme`), so the UIKit/AppKit `#if` branches
 * collapse into a single mapping onto Material3 roles:
 *
 * | Swift                       | Compose                                              |
 * |-----------------------------|------------------------------------------------------|
 * | `Color.canvas`              | `colorScheme.background`                              |
 * | `Color.canvasSecondary`     | `colorScheme.surfaceVariant`                          |
 * | `Color.textSelection`       | `colorScheme.primary` (+ `LocalTextSelectionColors`) |
 * | `Color.secondaryLabelText`  | `colorScheme.onSurfaceVariant`                        |
 * | `Color.accent`              | `colorScheme.primary`                                 |
 */

/** The primary window/content background. Swift: `Color.canvas`. */
val ColorScheme.canvas: Color
    get() = background

/** The secondary/recessed surface (sidebar, chrome). Swift: `Color.canvasSecondary`. */
val ColorScheme.canvasSecondary: Color
    get() = surfaceVariant

/**
 * Text-selection highlight tint. Swift: `Color.textSelection` (systemBlue /
 * selectedTextBackgroundColor). Mapped to the primary role; see also
 * [textSelectionColors] for wiring `LocalTextSelectionColors`.
 */
val ColorScheme.textSelection: Color
    get() = primary

/**
 * Concrete secondary-label color. Swift: `Color.secondaryLabelText`.
 *
 * The Swift comment notes this must be a *concrete* color (not the semantic
 * `Color.secondary`) so it resolves correctly as an `AttributedString` foreground.
 * The Compose analog is the concrete `onSurfaceVariant` role, which renders
 * correctly inside an `AnnotatedString` `SpanStyle(color = ...)`.
 */
val ColorScheme.secondaryLabelText: Color
    get() = onSurfaceVariant

/** Accent tint. Swift: SwiftUI `Color.accentColor`. */
val ColorScheme.accent: Color
    get() = primary

/**
 * `TextSelectionColors` derived from [textSelection], to install via
 * `CompositionLocalProvider(LocalTextSelectionColors provides colorScheme.textSelectionColors)`
 * so selection handles and highlight backgrounds match the iOS `textSelection` color.
 */
val ColorScheme.textSelectionColors: TextSelectionColors
    get() = TextSelectionColors(
        handleColor = textSelection,
        backgroundColor = textSelection.copy(alpha = 0.4f),
    )
