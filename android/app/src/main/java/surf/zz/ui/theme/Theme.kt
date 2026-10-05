package surf.zz.ui.theme

import android.os.Build
import androidx.compose.foundation.isSystemInDarkTheme
import androidx.compose.foundation.text.selection.LocalTextSelectionColors
import androidx.compose.material3.ColorScheme
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Typography
import androidx.compose.material3.darkColorScheme
import androidx.compose.material3.dynamicDarkColorScheme
import androidx.compose.material3.dynamicLightColorScheme
import androidx.compose.material3.lightColorScheme
import androidx.compose.runtime.Composable
import androidx.compose.runtime.CompositionLocalProvider
import androidx.compose.ui.platform.LocalContext

/**
 * Composition-root theme for zz. Wraps [MaterialTheme] and installs the zz
 * text-selection colors. Invoked from `MainActivity.setContent` (see
 * `MainActivity.ZzTheme { ... }`).
 *
 * ## Why this exists / what it ports
 *
 * The iOS app (`zzApp.swift`) has no explicit theme wrapper: SwiftUI views read
 * dynamic system colors (`Color(.systemBackground)`, `UIColor.secondaryLabel`,
 * `UIColor.systemBlue`, …) directly via the `extension Color` in `Theme.swift`,
 * and the system resolves them for light/dark appearance automatically. On
 * Android that same adaptivity is provided by handing Compose an explicit
 * light-vs-dark [ColorScheme]; the semantic Swift colors are mapped onto
 * Material3 roles in `ThemeColors.kt` (`ColorScheme.canvas`,
 * `.canvasSecondary`, `.textSelection`, `.secondaryLabelText`, `.accent`).
 *
 * ## Day/night and dynamic color
 *
 * - The light/dark choice follows the system setting via
 *   [isSystemInDarkTheme], mirroring the iOS automatic light/dark resolution.
 * - On Android 12+ (API 31, [Build.VERSION_CODES.S]) we prefer Material You
 *   *dynamic* color derived from the user's wallpaper, which is the closest
 *   platform-idiomatic analog to iOS's "use the system's own colors". On older
 *   devices we fall back to the fixed zz [lightColorScheme]/[darkColorScheme].
 * - `dynamicColor` is overridable so previews/tests can pin a deterministic
 *   scheme.
 *
 * ## Deviations from iOS (documented)
 *
 * - iOS resolves each semantic color independently from the OS; Android needs a
 *   single coherent [ColorScheme]. The exact RGB values therefore differ — the
 *   *roles* (background / surfaceVariant / primary / onSurfaceVariant) match the
 *   mapping table in `ThemeColors.kt`.
 * - `Color.textSelection` on iOS is `systemBlue` /
 *   `selectedTextBackgroundColor`; here it maps to the scheme `primary` and is
 *   wired through [LocalTextSelectionColors] so text-field selection handles and
 *   highlight backgrounds pick it up (the Android analog of the system-wide
 *   selection tint iOS gets for free).
 * - Typography: iOS uses the system font (`.font(.system(...))`) throughout;
 *   Android's default Material3 [Typography] is the platform-idiomatic
 *   equivalent, so v1 uses it unchanged rather than bundling a custom type scale.
 */
@Composable
fun ZzTheme(
    darkTheme: Boolean = isSystemInDarkTheme(),
    // Material You wallpaper-derived color, available on Android 12+.
    dynamicColor: Boolean = true,
    content: @Composable () -> Unit,
) {
    val colorScheme = resolveColorScheme(darkTheme = darkTheme, dynamicColor = dynamicColor)

    MaterialTheme(
        colorScheme = colorScheme,
        typography = ZzTypography,
    ) {
        // Install the zz selection tint so text fields (the omnibox URL bar,
        // editable content) match the iOS `textSelection` color.
        CompositionLocalProvider(
            LocalTextSelectionColors provides colorScheme.textSelectionColors,
        ) {
            content()
        }
    }
}

/**
 * Picks the active [ColorScheme]: Material You dynamic color on API 31+ when
 * [dynamicColor] is set, otherwise the fixed zz day/night schemes.
 */
@Composable
private fun resolveColorScheme(darkTheme: Boolean, dynamicColor: Boolean): ColorScheme {
    if (dynamicColor && Build.VERSION.SDK_INT >= Build.VERSION_CODES.S) {
        val context = LocalContext.current
        return if (darkTheme) dynamicDarkColorScheme(context) else dynamicLightColorScheme(context)
    }
    return if (darkTheme) ZzDarkColorScheme else ZzLightColorScheme
}

/**
 * Fixed fallback color schemes used pre-API-31 (or when dynamic color is
 * disabled). Kept as the default Material3 baseline schemes so the role mapping
 * in `ThemeColors.kt` resolves sensibly in both appearances; the iOS app never
 * defined bespoke brand colors, so there is nothing brand-specific to port here.
 */
private val ZzLightColorScheme: ColorScheme = lightColorScheme()
private val ZzDarkColorScheme: ColorScheme = darkColorScheme()

/**
 * zz type scale. iOS uses the system font via `.font(.system(...))`, so the
 * platform-default Material3 [Typography] is the faithful Android analog; v1
 * ships it unchanged rather than introducing a custom font.
 */
private val ZzTypography: Typography = Typography()
