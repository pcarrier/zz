package surf.zz.favicon

import androidx.compose.foundation.Image
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.size
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.Public
import androidx.compose.material3.Icon
import androidx.compose.material3.MaterialTheme
import androidx.compose.runtime.Composable
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.FilterQuality
import androidx.compose.ui.graphics.asImageBitmap
import androidx.compose.ui.graphics.vector.ImageVector
import androidx.compose.ui.layout.ContentScale
import androidx.compose.ui.unit.Dp
import androidx.compose.ui.unit.dp
import androidx.compose.foundation.shape.RoundedCornerShape
import surf.zz.ui.LocalFaviconStore
import surf.zz.url.UrlCanonicalizer

/**
 * Shows the favicon for a host with a graceful fallback icon while loading or on
 * failure. Reads [FaviconStore] reactively via [LocalFaviconStore] so it refreshes
 * when an icon arrives.
 *
 * Ports `FaviconView` from `Theme.swift:425`. The Swift view took a `host` plus
 * `size`/`fallbackSymbol`, with two initializers (one deriving the host from a url
 * via `URLCanonicalizer.host`, one taking the host directly). Here that maps to two
 * `@Composable` overloads of [Favicon].
 */

/**
 * Favicon for an already-extracted [host].
 *
 * @param host canonical host (lowercased by the store when looked up).
 * @param size rendered side length; the rounded-corner radius is `size * 0.18`.
 * @param fallback icon shown while loading or when no favicon could be fetched.
 */
@Composable
fun Favicon(
    host: String,
    size: Dp = 16.dp,
    fallback: ImageVector = Icons.Default.Public,
) {
    val favicons = LocalFaviconStore.current
    // Reading the store's snapshot-backed image map inside composition tracks it,
    // so the view recomposes when an icon arrives (mirrors the iOS @Observable read).
    val bitmap = favicons.imageForHost(host)

    if (bitmap != null) {
        Image(
            bitmap = bitmap.asImageBitmap(),
            contentDescription = null,
            modifier = Modifier
                .size(size)
                .clip(RoundedCornerShape(size * 0.18f)),
            contentScale = ContentScale.Fit,
            filterQuality = FilterQuality.High,
        )
    } else {
        // Swift draws the SF Symbol at `size * 0.85` centered in a `size`-square
        // frame (`.font(.system(size: size * 0.85)).frame(width: size, height: size)`).
        // Mirror that here: the layout box reserves `size`, the glyph fills 85%.
        Box(modifier = Modifier.size(size), contentAlignment = Alignment.Center) {
            Icon(
                imageVector = fallback,
                contentDescription = null,
                tint = MaterialTheme.colorScheme.onSurfaceVariant,
                modifier = Modifier.size(size * 0.85f),
            )
        }
    }
}

/**
 * Favicon for a full [url], deriving the host via [UrlCanonicalizer.host]
 * (which delegates to `SiteVisual.host`, matching the Swift initializer that
 * built `host` from `URLCanonicalizer.host(url)`).
 *
 * Distinct name because Kotlin cannot overload on argument label alone — the
 * Swift `init(url:)` / `init(host:)` pair has the same erased signature here.
 * Call sites that have a full URL use [FaviconForUrl]; those that already hold a
 * host use [Favicon] directly.
 */
@Composable
fun FaviconForUrl(
    url: String,
    size: Dp = 16.dp,
    fallback: ImageVector = Icons.Default.Public,
) {
    Favicon(host = UrlCanonicalizer.host(url), size = size, fallback = fallback)
}
