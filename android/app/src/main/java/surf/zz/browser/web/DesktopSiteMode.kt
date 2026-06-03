package surf.zz.browser.web

/**
 * Pure helper for the desktop content-mode behavior. Kept free of WebView/UI
 * state so the macOS user-agent fallback string is unit-testable in isolation.
 *
 * On iOS the content mode is driven by `WKWebpagePreferences.preferredContentMode`,
 * which has no macOS equivalent; there the app falls back to spoofing a desktop
 * Safari user agent (a `nil`/`null` agent restores the platform default).
 *
 * On Android there is likewise no `preferredContentMode`; desktop mode is realized
 * by overriding `WebView.settings.userAgentString` with this value (plus
 * `useWideViewPort`/`loadWithOverviewMode`). A `null` return means "use the
 * platform default user agent".
 */
object DesktopSiteMode {
    /**
     * A Safari-on-macOS user-agent override used to request the desktop variant of
     * a site. Returns `null` when desktop mode is not requested, meaning "use the
     * platform default".
     */
    fun customUserAgent(requestsDesktop: Boolean): String? {
        if (!requestsDesktop) return null
        return "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) " +
            "AppleWebKit/605.1.15 (KHTML, like Gecko) " +
            "Version/17.0 Safari/605.1.15"
    }
}
