package surf.zz.omnibox

import surf.zz.search.KeywordBangs
import surf.zz.search.KeywordEngine
import surf.zz.search.SearchPreferences
import surf.zz.store.HistoryEntry
import surf.zz.url.UrlCanonicalizer
import surf.zz.url.UrlNormalizer
import java.time.Instant
import java.util.UUID

/**
 * Composes the omnibox suggestion list from open-tab + history candidates.
 *
 * Faithful 1:1 port of the iOS `OmniboxSuggestions` enum (`BrowserStore.swift:1749`).
 * Pure logic: given the query, the history snapshot, the current open-tab values,
 * and an injected `now`, it produces a deterministic, deduplicated, ranked list of
 * [OmniboxItem]s. It depends only on [UrlCanonicalizer], [OmniboxRanker],
 * [UrlNormalizer], the search/keyword preferences, and the [OmniboxItem] value
 * types — never on `BrowserStore` itself (open tabs are injected as [OpenTab]).
 *
 * Pipeline (matching the Swift exactly):
 *  1. Direct entry (the typed URL/search) is always candidate index 0 — unless it
 *     is suppressed in step 6.
 *  2. Open tabs become Tier-0 (highest) candidates when their host prefix-matches
 *     or their title contains the query.
 *  3. History entries become gated-tier candidates via [OmniboxRanker.classify].
 *  4. Candidates are deduped by `canonicalKey`, keeping the highest-ranked
 *     (open-tab wins ties at equal score because of the deterministic comparator).
 *  5. The deduped set is sorted by the fully deterministic [isHigher] total order.
 *  6. The synthetic direct row is suppressed when the top real candidate shares its
 *     canonicalKey and is a Tier-4/5 history match or an open tab, so Return focuses
 *     the existing tab instead of reloading the URL in the current pane.
 *
 * Determinism: [isHigher] is a strict, total comparison-key chain (never a float
 * alone): score desc, visitCount desc, lastVisited desc, canonicalLength asc, key
 * asc. Unit-tested in `OmniboxSuggestionsTest` for comparator determinism.
 */
object OmniboxSuggestions {

    /**
     * An open-tab candidate injected by the store. Mirrors the Swift tuple
     * `(url: String, title: String?, tabID: UUID)` produced by
     * `BrowserStore.openTabSuggestions()`.
     */
    data class OpenTab(
        val url: String,
        val title: String?,
        val tabId: UUID,
    )

    /** A scored, ranked candidate prior to total-order sorting. */
    private data class Scored(
        val item: OmniboxItem,
        val canonicalKey: String,
        val tier: Int,
        val score: Int,
        val visitCount: Int,
        val lastVisited: Instant,
        val canonicalLength: Int,
    )

    /**
     * Builds the ranked suggestion list for [query].
     *
     * Mirrors Swift `OmniboxSuggestions.entries(matching:history:openTabs:now:limit:
     * searchTemplate:keywordEngines:)`.
     */
    fun entries(
        query: String,
        history: List<HistoryEntry>,
        openTabs: List<OpenTab> = emptyList(),
        now: Instant = Instant.now(),
        limit: Int,
        searchTemplate: String = SearchPreferences.activeTemplate,
        keywordEngines: List<KeywordEngine> = SearchPreferences.keywordEngines,
    ): List<OmniboxItem> {
        val trimmed = query.trim()

        // Empty query: skip tiering, return open tabs then history by frecency.
        if (trimmed.isEmpty()) {
            return emptyQueryEntries(history = history, openTabs = openTabs, now = now, limit = limit)
        }

        val norm = OmniboxRanker.normalize(query)

        // 1. Direct entry (typed URL/search), always candidate index 0.
        val direct = directItem(
            query = trimmed,
            searchTemplate = searchTemplate,
            keywordEngines = keywordEngines,
        )
        val directKey = direct?.let { UrlCanonicalizer.key(it.url) }

        // 2. Open tabs -> Tier-0 candidates.
        val scored = ArrayList<Scored>()
        for (tab in openTabs) {
            val host = UrlCanonicalizer.host(tab.url)
            val titleMatches = tab.title?.lowercase()?.contains(norm.q) ?: false
            val hostMatches = norm.qHost.isNotEmpty() && host.startsWith(norm.qHost)
            if (!hostMatches && !titleMatches) continue
            val key = UrlCanonicalizer.key(tab.url)

            // Borrow frecency from a coinciding history entry if present.
            val coincide = history.firstOrNull { it.canonicalKey == key }
            val visitCount = coincide?.visitCount ?: 1
            val lastVisited = coincide?.lastVisited ?: now

            // Trim once so range offsets and the displayed string share an index space.
            val trimmedTitle = tab.title?.trim()
            var titleRanges: List<IntRange> = emptyList()
            var urlRanges: List<IntRange> = emptyList()
            val cls = OmniboxRanker.classify(query = norm, host = host, url = tab.url, title = trimmedTitle)
            if (cls != null) {
                titleRanges = cls.titleRanges
                urlRanges = cls.urlRanges
            } else if (titleMatches && trimmedTitle != null) {
                val idx = trimmedTitle.indexOf(norm.q, ignoreCase = true)
                if (idx >= 0) titleRanges = listOf(idx until idx + norm.q.length)
            }

            val item = OmniboxItem(
                id = key,
                url = tab.url,
                title = trimmedTitle,
                kind = SuggestionKind.OPEN_TAB,
                tabId = tab.tabId,
                titleRanges = titleRanges,
                urlRanges = urlRanges,
            )
            val canonicalLength = UrlCanonicalizer.key(tab.url).length
            val s = OmniboxRanker.finalScore(
                tier = OmniboxRanker.tierOpenTab,
                visitCount = visitCount,
                lastVisited = lastVisited,
                now = now,
                matchStart = 0,
                canonicalLength = canonicalLength,
                includeEarliness = false,
            )
            scored.add(
                Scored(
                    item = item,
                    canonicalKey = key,
                    tier = OmniboxRanker.tierOpenTab,
                    score = s,
                    visitCount = visitCount,
                    lastVisited = lastVisited,
                    canonicalLength = canonicalLength,
                )
            )
        }

        // 3. History -> gated-tier candidates.
        for (entry in history) {
            val host = UrlCanonicalizer.host(entry.url)
            // Trim once so range offsets and the displayed string share an index space.
            val trimmedTitle = entry.title?.trim()
            val cls = OmniboxRanker.classify(
                query = norm,
                host = host,
                url = entry.url,
                title = trimmedTitle,
            ) ?: continue
            val key = entry.canonicalKey
            val canonicalLength = key.length
            val includeEarliness = cls.tier != OmniboxRanker.tierFuzzy
            val s = OmniboxRanker.finalScore(
                tier = cls.tier,
                visitCount = entry.visitCount,
                lastVisited = entry.lastVisited,
                now = now,
                matchStart = cls.matchStart,
                canonicalLength = canonicalLength,
                includeEarliness = includeEarliness,
            )
            val item = OmniboxItem(
                id = key,
                url = entry.url,
                title = trimmedTitle,
                kind = SuggestionKind.HISTORY,
                titleRanges = cls.titleRanges,
                urlRanges = cls.urlRanges,
            )
            scored.add(
                Scored(
                    item = item,
                    canonicalKey = key,
                    tier = cls.tier,
                    score = s,
                    visitCount = entry.visitCount,
                    lastVisited = entry.lastVisited,
                    canonicalLength = canonicalLength,
                )
            )
        }

        // 4. Dedup by canonicalKey, keeping the highest-ranked; open-tab wins ties.
        val bestByKey = LinkedHashMap<String, Scored>()
        for (cand in scored) {
            val existing = bestByKey[cand.canonicalKey]
            if (existing == null || isHigher(cand, existing)) {
                bestByKey[cand.canonicalKey] = cand
            }
        }
        val ranked = ArrayList(bestByKey.values)

        // 5. Sort by deterministic total order.
        ranked.sortWith(Comparator { a, b -> if (isHigher(a, b)) -1 else if (isHigher(b, a)) 1 else 0 })

        // 6. directEntry suppression: drop synthetic direct when the top real
        // candidate has the same canonicalKey and is either a Tier 4/5 history
        // match or an open tab. Surfacing the open-tab row lets Return focus the
        // existing tab instead of reloading the URL in the current pane.
        var keepDirect = direct != null
        val top = ranked.firstOrNull()
        if (directKey != null && top != null &&
            top.canonicalKey == directKey &&
            (top.tier == OmniboxRanker.tierHostPrefix ||
                top.tier == OmniboxRanker.tierPrefix ||
                top.tier == OmniboxRanker.tierOpenTab)
        ) {
            keepDirect = false
        }

        val result = ArrayList<OmniboxItem>()
        if (keepDirect && direct != null) result.add(direct)
        for (cand in ranked) {
            // When a synthetic direct row is shown it already represents its
            // canonicalKey; skip any ranked candidate sharing that key so the
            // same URL is never rendered twice (regardless of the candidate's
            // tier or differing item id, e.g. a trailing-slash variant).
            if (keepDirect && directKey != null && cand.canonicalKey == directKey) continue
            result.add(cand.item)
            if (result.size >= limit) break
        }
        return result.take(limit)
    }

    private fun emptyQueryEntries(
        history: List<HistoryEntry>,
        openTabs: List<OpenTab>,
        now: Instant,
        limit: Int,
    ): List<OmniboxItem> {
        val result = ArrayList<OmniboxItem>()
        val seen = HashSet<String>()
        for (tab in openTabs) {
            val key = UrlCanonicalizer.key(tab.url)
            if (!seen.add(key)) continue
            result.add(
                OmniboxItem(
                    id = key,
                    url = tab.url,
                    title = tab.title,
                    kind = SuggestionKind.OPEN_TAB,
                    tabId = tab.tabId,
                )
            )
        }
        val sortedHistory = history.sortedWith(Comparator { a, b ->
            val fa = OmniboxRanker.frecency(a.visitCount, a.lastVisited, now)
            val fb = OmniboxRanker.frecency(b.visitCount, b.lastVisited, now)
            if (fa != fb) return@Comparator fb.compareTo(fa)
            if (a.visitCount != b.visitCount) return@Comparator b.visitCount.compareTo(a.visitCount)
            if (a.lastVisited != b.lastVisited) return@Comparator b.lastVisited.compareTo(a.lastVisited)
            a.canonicalKey.compareTo(b.canonicalKey)
        })
        for (entry in sortedHistory) {
            val key = entry.canonicalKey
            if (!seen.add(key)) continue
            result.add(
                OmniboxItem(
                    id = key,
                    url = entry.url,
                    title = entry.title,
                    kind = SuggestionKind.HISTORY,
                )
            )
            if (result.size >= limit) break
        }
        return result.take(limit)
    }

    /**
     * Fully deterministic comparison: returns `true` iff [a] ranks strictly higher
     * than [b]. Comparison-key chain (never floats alone):
     * score desc, visitCount desc, lastVisited desc, canonicalLength asc, key asc.
     */
    private fun isHigher(a: Scored, b: Scored): Boolean {
        if (a.score != b.score) return a.score > b.score
        if (a.visitCount != b.visitCount) return a.visitCount > b.visitCount
        if (a.lastVisited != b.lastVisited) return a.lastVisited.isAfter(b.lastVisited)
        if (a.canonicalLength != b.canonicalLength) return a.canonicalLength < b.canonicalLength
        return a.canonicalKey < b.canonicalKey
    }

    /**
     * Builds the synthetic "direct entry" row for the typed [query] (a typed URL or
     * a search), or `null` when the query cannot be resolved into a navigable URL.
     *
     * Mirrors Swift `OmniboxSuggestions.directItem(for:searchTemplate:keywordEngines:)`.
     */
    fun directItem(
        query: String,
        searchTemplate: String = SearchPreferences.activeTemplate,
        keywordEngines: List<KeywordEngine> = SearchPreferences.keywordEngines,
    ): OmniboxItem? {
        val trimmed = query.trim()
        if (trimmed.isEmpty()) return null
        val resolved = UrlNormalizer.resolve(
            input = trimmed,
            searchTemplate = searchTemplate,
            keywordEngines = keywordEngines,
        ) ?: return null
        val url = resolved
        // An active keyword bang (keyword + query) renders as a search row labeled
        // with the matched engine, e.g. "Search GitHub" — but only when expansion
        // actually produced the engine's URL. A malformed template (no "%s") makes
        // expand return null and resolve falls through to the default engine, so we
        // must not mislabel the row in that case.
        val m = KeywordBangs.match(trimmed, keywordEngines)
        if (m != null && m.query.isNotEmpty()) {
            val expanded = KeywordBangs.expand(trimmed, keywordEngines)
            if (expanded != null && expanded == resolved) {
                val engineTitle = m.engine.title.trim()
                val label = if (engineTitle.isEmpty()) m.engine.keyword else engineTitle
                return OmniboxItem(
                    id = url,
                    url = url,
                    title = "Search $label",
                    kind = SuggestionKind.SEARCH,
                )
            }
        }
        val isSearch = directIsSearch(query = trimmed, resolved = resolved, searchTemplate = searchTemplate)
        return OmniboxItem(
            id = url,
            url = url,
            title = if (isSearch) "Search" else "Open",
            kind = if (isSearch) SuggestionKind.SEARCH else SuggestionKind.OPEN,
        )
    }

    private fun directIsSearch(query: String, resolved: String, searchTemplate: String): Boolean {
        val searchURL = SearchPreferences.searchURL(query, searchTemplate) ?: return false
        return searchURL == resolved
    }
}
