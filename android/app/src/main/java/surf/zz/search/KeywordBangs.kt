package surf.zz.search

/**
 * Pure, testable keyword-bang detection + expansion.
 *
 * Faithful port of the iOS `KeywordBangs` enum (`ios/zz/SearchEngine.swift:134`).
 * Kept free of UI / preferences plumbing so the matching rules are unit-testable
 * with an injected engine list — the [engines] argument is dependency-injected by
 * callers (`UrlNormalizer` defaults it to `SearchPreferences.keywordEngines`).
 *
 * ## Behavior parity with iOS
 *
 *  - The input is trimmed of surrounding whitespace/newlines; empty input never
 *    matches.
 *  - The first run of whitespace splits the input into a `keyword` token and the
 *    remainder. Swift splits on `' '` or `'\t'` with `maxSplits: 1`; here we use
 *    `split(Regex("[ \\t]+"), limit = 2)` after trimming, which collapses the
 *    first space/tab run identically for the keyword/remainder boundary. The
 *    separator class is deliberately limited to space + tab (NOT Kotlin's `\s`,
 *    which also matches `\n`/`\r`/`\f`) to match Swift's `whereSeparator` exactly.
 *  - Keyword comparison is **case-insensitive**, and empty engine keywords never
 *    match (mirrors `!keyword.isEmpty && keyword.lowercased() == token`).
 *  - The remainder is itself trimmed; a **bare keyword** (no remaining query)
 *    still *matches* with an empty [Match.query] (so [match] callers can route
 *    it), but does **not** *expand* ([expand] returns `null` for it, falling
 *    through to normal handling / the engine's base host).
 *
 * ## Differences from iOS, by necessity
 *
 *  - [expand] returns a URL **string** (`String?`) rather than a parsed
 *    `Foundation.URL`, because Android navigation consumes a `String`
 *    (`WebView.loadUrl`) and `SearchPreferences.searchURL` likewise returns
 *    `String?`. A `null` result means "no expandable bang" (mirrors `URL? == nil`).
 */
object KeywordBangs {

    /** Result of matching the input's first token against a keyword engine. */
    data class Match(
        val engine: KeywordEngine,
        /** The remaining query after the keyword (may be empty for a bare keyword). */
        val query: String,
    )

    /** Separator run used to split keyword from remainder (mirrors Swift's `' '`/`'\t'`). */
    private val SEPARATOR = Regex("[ \\t]+")

    /**
     * Returns the matching engine + remaining query when the input's first
     * whitespace-delimited token equals an engine keyword (case-insensitive).
     * Returns `null` when no keyword matches. A bare keyword (no remaining query)
     * still matches, with an empty [Match.query], so callers can decide how to
     * route.
     */
    fun match(input: String, engines: List<KeywordEngine>): Match? {
        val trimmed = input.trim()
        if (trimmed.isEmpty()) return null

        // Split on the first run of whitespace into keyword + remainder.
        val parts = trimmed.split(SEPARATOR, limit = 2)
        val token = parts.first().lowercase()
        if (token.isEmpty()) return null

        val engine = engines.firstOrNull {
            it.keyword.isNotEmpty() && it.keyword.lowercase() == token
        } ?: return null

        val remainder = if (parts.size > 1) parts[1].trim() else ""
        return Match(engine = engine, query = remainder)
    }

    /**
     * Expands [input] against [engines], returning a URL string when a keyword
     * matches AND there is a non-empty remaining query. A bare keyword returns
     * `null` here (callers fall through to normal handling / the engine's base
     * host).
     */
    fun expand(input: String, engines: List<KeywordEngine>): String? {
        val m = match(input, engines) ?: return null
        if (m.query.isEmpty()) return null
        return SearchPreferences.searchURL(m.query, m.engine.templateURL)
    }
}
