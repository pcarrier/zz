package surf.zz.url

import surf.zz.search.KeywordBangs
import surf.zz.search.KeywordEngine
import surf.zz.search.SearchPreferences

/**
 * Resolves raw omnibox / dropped text into a navigable URL string.
 *
 * Faithful port of the iOS `URLNormalizer` (`BrowserStore.swift:2140`). The
 * routing order is preserved exactly:
 *
 *  1. **Keyword bangs win** over everything else, but only when a keyword *and* a
 *     non-empty remaining query are present. A bare keyword falls through to the
 *     rest of the pipeline ([KeywordBangs.expand] returns `null` for it).
 *  2. **Explicit scheme allow-list:** if the input already carries a scheme,
 *     accept it verbatim only when the (case-insensitively compared) scheme is
 *     `http` / `https` / `about` / `file`. A non-web scheme (`mailto:`, `tel:`,
 *     `ftp:`, …) is never prefixed with `https://` — instead we test for a bare
 *     `host:port` authority (which the URL parser mis-reads as a scheme) and
 *     treat that as web; any other explicit scheme is rejected (`null`) so the
 *     caller can hand it off / search rather than navigate to garbage.
 *  3. **Search-vs-URL heuristic:** input containing a space, or with no dot, is a
 *     search query. Otherwise it is treated as a bare host and `https://` is
 *     prepended.
 *
 * Differences from iOS, by necessity:
 *  - Returns the resolved **URL string** (`String?`) rather than a parsed
 *    `Foundation.URL`. Android callers feed a string into `WebView.loadUrl`, and
 *    the downstream search/bang helpers ([SearchPreferences.searchURL],
 *    [KeywordBangs.expand]) likewise return `String?`. A `null` result means
 *    "could not resolve" (mirrors Swift's `URL? == nil`).
 *  - Swift's `URL(string:)` scheme extraction is replaced by a small scheme regex
 *    so malformed input never throws (`java.net.URI` would). The
 *    case-insensitive scheme comparison is preserved.
 *
 * Pure and deterministic given its injected dependencies, so it is unit-testable
 * in isolation (no `WebView`, no DataStore).
 */
object UrlNormalizer {

    /**
     * Leading-scheme matcher. A URI scheme is `ALPHA *( ALPHA / DIGIT / "+" / "-" / "." )`
     * followed by `:` (RFC 3986). We only need the scheme name, captured in group 1.
     * Matched case-insensitively; the comparison below lowercases the result anyway.
     */
    private val SCHEME_REGEX = Regex("^([A-Za-z][A-Za-z0-9+.-]*):")

    /**
     * Matches a bare `host:port` (optionally with a `/path`), e.g. `localhost:8080`,
     * `myhost:3000/path`. Anchored to the whole string. Ported verbatim from the
     * Swift `#"^[A-Za-z0-9][A-Za-z0-9.-]*:[0-9]+(/.*)?$"#`.
     */
    private val HOST_PORT_REGEX = Regex("^[A-Za-z0-9][A-Za-z0-9.-]*:[0-9]+(/.*)?$")

    /** Schemes whose `scheme:digits` shape looks like `host:port` but is a custom URI. */
    private val NON_WEB_SCHEMES = setOf(
        "tel", "sms", "mailto", "ftp", "data", "javascript", "file", "about",
    )

    /** Schemes accepted verbatim when the input already carries one. */
    private val WEB_OR_LOCAL_SCHEMES = setOf("http", "https", "about", "file")

    /**
     * Resolves [input] to a URL string, or `null` if it cannot be turned into a
     * navigable URL (the caller may then hand off the raw text or fall back).
     *
     * @param searchTemplate the active search template (`%s` placeholder), used
     *   for the search fallback. Defaults to [SearchPreferences.activeTemplate].
     * @param keywordEngines the user's keyword-bang engines, consulted first.
     *   Defaults to [SearchPreferences.keywordEngines].
     */
    fun resolve(
        input: String,
        searchTemplate: String = SearchPreferences.activeTemplate,
        keywordEngines: List<KeywordEngine> = SearchPreferences.keywordEngines,
    ): String? {
        val trimmed = input.trim()
        if (trimmed.isEmpty()) return null

        // 1. Keyword bangs win over default search/URL handling, but only when a
        //    keyword + remaining query is present. A bare keyword falls through.
        KeywordBangs.expand(trimmed, keywordEngines)?.let { return it }

        // 2. Explicit scheme: scheme comparison is case-insensitive (Foundation
        //    does NOT lowercase URL.scheme either, so we lowercase here).
        val scheme = SCHEME_REGEX.find(trimmed)?.groupValues?.get(1)?.lowercase()
        if (scheme != null) {
            if (scheme in WEB_OR_LOCAL_SCHEMES) {
                return trimmed
            }
            // The input carries an explicit, non-web scheme (mailto:, tel:, ftp:,
            // sms:, data:, javascript:, or "localhost:8080"'s bogus "localhost"…).
            // Never prepend https:// to it — that produces corrupt URLs. Detect a
            // host:port authority and treat it as web; otherwise reject so the
            // caller can hand off / search rather than navigate to garbage.
            return if (isHostPort(trimmed)) "https://$trimmed" else null
        }

        // 3. Search-vs-URL heuristic.
        if (trimmed.contains(" ") || !trimmed.contains(".")) {
            return SearchPreferences.searchURL(trimmed, searchTemplate)
        }
        return "https://$trimmed"
    }

    /**
     * True when [s] is a bare `host:port` (optionally with a `/path`), e.g.
     * `localhost:8080`, `myhost:3000/path`. These have no dot so the dot/space
     * heuristic would misroute them to search, and a URL parser reads them with a
     * bogus scheme equal to the host.
     *
     * The authority before `:` is also a valid scheme. A purely numeric body
     * (`tel:5551234`, `sms:1234`, `mailto:1234`) matches the regex but is a custom
     * URI, not a host:port — reject when the part before `:` is a known non-web
     * scheme so the caller hands it off rather than navigating to a corrupt
     * `https://scheme:number` URL.
     */
    private fun isHostPort(s: String): Boolean {
        if (!HOST_PORT_REGEX.matches(s)) return false
        val authority = s.takeWhile { it != ':' }.lowercase()
        return authority !in NON_WEB_SCHEMES
    }
}
