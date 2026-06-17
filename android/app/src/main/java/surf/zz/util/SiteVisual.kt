package surf.zz.util

import android.net.Uri

/**
 * Pure host-extraction helper shared by FaviconView, omnibox/history rows, and
 * the BottomBar. Ports `SiteVisual` from `Theme.swift:48`.
 *
 * Mirrors the Swift behavior:
 * ```
 * URL(string: url)?.host(percentEncoded: false)
 *   ?? URL(string: "https://" + url)?.host(percentEncoded: false)
 *   ?? url
 * ```
 * First try parsing the string as-is; if that yields no host (e.g. a bare
 * `"example.com"` with no scheme/authority), retry with an `https://` prefix;
 * if that still yields no host, fall back to the raw input string.
 *
 * Kept free of any state so it is pure and unit-testable.
 */
object SiteVisual {
    fun host(url: String): String {
        return parsedHost(url)
            ?: parsedHost("https://$url")
            ?: url
    }

    /**
     * Returns the host component of [value], or null if there is none.
     *
     * `Uri.parse` is lenient and never returns null, but `Uri.host` is null when
     * the string has no authority component — which is exactly when the Swift
     * `URL(string:)?.host` fallback chain advances to the next candidate. An
     * empty host is treated as absent so the retry path is taken.
     */
    private fun parsedHost(value: String): String? {
        val host = Uri.parse(value).host
        return if (host.isNullOrEmpty()) null else host
    }
}
