package surf.zz.search

/**
 * Built-in search providers.
 *
 * Ported from `ios/zz/SearchEngine.swift` (`enum SearchEngine: String`). The Swift
 * enum was a `String`-raw-value enum conforming to `CaseIterable`/`Identifiable`;
 * on Android those drop away — iterate with [entries] and identify by [rawValue].
 *
 * The [rawValue] strings MUST stay byte-identical to the Swift raw values
 * ("duckDuckGo", "google", "custom") so the persisted `searchEngine` preference
 * round-trips and prefs written by either platform remain compatible.
 */
enum class SearchEngine(val rawValue: String, val displayName: String, val template: String?) {
    DUCK_DUCK_GO("duckDuckGo", "DuckDuckGo", "https://duckduckgo.com/?q=%s"),
    GOOGLE("google", "Google", "https://www.google.com/search?q=%s"),
    CUSTOM("custom", "Custom", null);

    companion object {
        /** Mirrors Swift's `SearchEngine(rawValue:)`; returns null for unknown raw values. */
        fun fromRawValue(rawValue: String?): SearchEngine? =
            entries.firstOrNull { it.rawValue == rawValue }
    }
}
