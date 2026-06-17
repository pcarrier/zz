package surf.zz.omnibox

import surf.zz.url.UrlCanonicalizer
import java.time.Duration
import java.time.Instant
import kotlin.math.ceil
import kotlin.math.ln
import kotlin.math.min
import kotlin.math.roundToInt

/**
 * Deterministic, tiered "frecency" ranker.
 *
 * Faithful 1:1 port of the iOS `OmniboxRanker` enum (`BrowserStore.swift:1411`). Pure
 * over in-memory data plus injected open-tab values and an injected [now]; never imports
 * the store. Consumed by [OmniboxSuggestions].
 *
 * Highlight ranges are emitted as half-open [IntRange] char (UTF-16) offsets — i.e. a
 * Swift `start..<end` becomes `start until end` so a Compose `AnnotatedString.addStyle(
 * start, end)` lines up directly (see ANDROID_ARCH.md §5 "String highlight ranges"). A
 * single-character Swift range `s..<(s+1)` therefore becomes `s until s+1` (a one-element
 * [IntRange] whose `last` is `s`). All `String.Index`/`distance` arithmetic in the Swift
 * original collapses to plain char-offset `Int` arithmetic here.
 */
object OmniboxRanker {
    // Tier bases. Gap = 2000 so any higher tier always beats any lower tier
    // regardless of frecency/earliness (bounded < 2000 by construction).
    const val tierOpenTab = 12000    // 0
    const val tierHostPrefix = 10000 // 5
    const val tierPrefix = 8000      // 4
    const val tierWordStart = 6000   // 3
    const val tierSubstring = 4000   // 2
    const val tierFuzzy = 1000       // 1

    /** Trimmed/lowercased query plus a scheme/`www`-stripped host form. */
    data class Normalized(
        val q: String,     // trimmed, lowercased
        val qHost: String, // scheme + www stripped (for host comparisons)
    )

    fun normalize(query: String): Normalized {
        val q = query.trim().lowercase()
        var qHost = q
        for (scheme in listOf("https://", "http://")) {
            if (qHost.startsWith(scheme)) {
                qHost = qHost.substring(scheme.length)
                break
            }
        }
        if (qHost.startsWith("www.")) qHost = qHost.substring(4)
        return Normalized(q = q, qHost = qHost)
    }

    /**
     * A classification result: the winning tier plus matched ranges against the
     * ORIGINAL (non-lowercased) displayed strings.
     */
    data class Classification(
        val tier: Int,
        val titleRanges: List<IntRange>,
        val urlRanges: List<IntRange>,
        val matchStart: Int, // for earliness
    )

    fun classify(
        query: Normalized,
        host: String,
        url: String,
        title: String?,
    ): Classification? {
        val norm = query
        val q = norm.q
        if (q.isEmpty()) return null
        val displayTitle = title ?: ""
        val canonical = UrlCanonicalizer.key(url)
        val lowerTitle = displayTitle.lowercase()
        val lowerHost = host.lowercase()
        val lowerCanonical = canonical.lowercase()

        // Tier 5 — host prefix.
        if (norm.qHost.isNotEmpty() && lowerHost.startsWith(norm.qHost)) {
            var titleRanges: List<IntRange> = emptyList()
            var urlRanges: List<IntRange> = emptyList()
            // Mirror the host prefix onto the displayed URL where the host sits.
            val r = rangeOfHostPrefix(url = url, host = host, length = norm.qHost.length)
            if (r != null) urlRanges = listOf(r)
            if (lowerTitle.startsWith(q)) {
                val tr = prefixRange(displayTitle, q.length)
                if (tr != null) titleRanges = listOf(tr)
            }
            return Classification(
                tier = tierHostPrefix,
                titleRanges = titleRanges,
                urlRanges = urlRanges,
                matchStart = 0,
            )
        }

        // Tier 4 — URL/title prefix.
        if (lowerCanonical.startsWith(norm.q) || lowerTitle.startsWith(q)) {
            var titleRanges: List<IntRange> = emptyList()
            var urlRanges: List<IntRange> = emptyList()
            if (lowerCanonical.startsWith(norm.q)) {
                val r = rangeOfSubstring(norm.q, url, 0)
                if (r != null) urlRanges = listOf(r)
            }
            if (lowerTitle.startsWith(q)) {
                val tr = prefixRange(displayTitle, q.length)
                if (tr != null) titleRanges = listOf(tr)
            }
            return Classification(
                tier = tierPrefix,
                titleRanges = titleRanges,
                urlRanges = urlRanges,
                matchStart = 0,
            )
        }

        // Tier 3 — word-start / boundary contiguous match, plus acronym match.
        val ws = wordStartMatch(q, host = host, url = url, title = displayTitle)
        if (ws != null) return ws

        // Tier 2 — contiguous substring anywhere in canonical url or title.
        run {
            var titleRanges: List<IntRange> = emptyList()
            var urlRanges: List<IntRange> = emptyList()
            var start = Int.MAX_VALUE
            val cIdx = lowerCanonical.indexOf(q)
            if (cIdx >= 0) {
                start = min(start, cIdx)
                val r = rangeOfSubstring(q, url, 0)
                if (r != null) urlRanges = listOf(r)
            }
            val tIdx = lowerTitle.indexOf(q)
            if (tIdx >= 0) {
                start = min(start, tIdx)
                val r = rangeOfSubstring(q, displayTitle, 0)
                if (r != null) titleRanges = listOf(r)
            }
            if (titleRanges.isNotEmpty() || urlRanges.isNotEmpty()) {
                return Classification(
                    tier = tierSubstring,
                    titleRanges = titleRanges,
                    urlRanges = urlRanges,
                    matchStart = if (start == Int.MAX_VALUE) 0 else start,
                )
            }
        }

        // Tier 1 — gated fuzzy fallback (only reached if nothing above matched).
        val fuzzy = gatedFuzzy(q, url = url, title = displayTitle)
        if (fuzzy != null) return fuzzy

        return null
    }

    // MARK: Tier helpers

    private fun wordStartMatch(
        q: String,
        host: String,
        url: String,
        title: String,
    ): Classification? {
        // Contiguous boundary-start match in host, path, or title.
        val canonical = UrlCanonicalizer.key(url)
        val fields = listOf(host, canonical, title)
        for ((fieldIndex, field) in fields.withIndex()) {
            val r = boundaryContiguous(q, field)
            if (r != null) {
                val offset = r.first
                if (fieldIndex == 2) { // field === title
                    return Classification(
                        tier = tierWordStart,
                        titleRanges = listOf(r),
                        urlRanges = emptyList(),
                        matchStart = offset,
                    )
                } else {
                    // Map onto displayed url when the field is host/canonical.
                    val matched = field.substring(r.first, r.last + 1)
                    val ur = rangeOfSubstring(matched.lowercase(), url, 0)
                    if (ur != null) {
                        return Classification(
                            tier = tierWordStart,
                            titleRanges = emptyList(),
                            urlRanges = listOf(ur),
                            matchStart = offset,
                        )
                    }
                    return Classification(
                        tier = tierWordStart,
                        titleRanges = emptyList(),
                        urlRanges = emptyList(),
                        matchStart = offset,
                    )
                }
            }
        }

        // Acronym: chars of q match first letters of consecutive boundary-delimited
        // segments of host or title.
        val rt = acronymRanges(q, title)
        if (rt != null) {
            return Classification(
                tier = tierWordStart,
                titleRanges = rt,
                urlRanges = emptyList(),
                matchStart = 0,
            )
        }
        val rh = acronymRanges(q, host)
        if (rh != null) {
            // Map per-letter ranges onto the displayed url. Anchor the search at
            // the host's position in the url and advance monotonically so each
            // letter lands on its real host segment rather than an earlier
            // coincidental occurrence (e.g. inside the scheme).
            val hostIdx = url.indexOf(host, ignoreCase = true)
            val hostStart = if (hostIdx >= 0) hostIdx else 0
            var cursor = hostStart
            val urlRanges = ArrayList<IntRange>()
            for (seg in rh) {
                // Offset of this letter within the host.
                val segOffset = seg.first
                val ch = host.substring(seg.first, seg.last + 1).lowercase()
                val searchFrom = maxOf(cursor, hostStart + segOffset)
                val ur = rangeOfSubstring(ch, url, searchFrom)
                if (ur != null) {
                    urlRanges.add(ur)
                    cursor = ur.last + 1
                }
            }
            return Classification(
                tier = tierWordStart,
                titleRanges = emptyList(),
                urlRanges = urlRanges,
                matchStart = 0,
            )
        }
        return null
    }

    /** Matches [q] contiguously starting at a boundary char (or string start). */
    private fun boundaryContiguous(q: String, field: String): IntRange? {
        if (q.isEmpty() || field.isEmpty()) return null
        val lowerChars = field.lowercase().toCharArray()
        val qChars = q.toCharArray()
        val qLen = qChars.size
        var i = 0
        while (i + qLen <= lowerChars.size) {
            val isBoundary = i == 0 || lowerChars[i - 1].isFuzzyBoundary
            if (isBoundary) {
                var matched = true
                for (j in qChars.indices) {
                    if (lowerChars[i + j] != qChars[j]) {
                        matched = false
                        break
                    }
                }
                if (matched) return i until i + qLen
            }
            i += 1
        }
        return null
    }

    /** Acronym match: [q]'s chars are the first letters of consecutive segments. */
    private fun acronymRanges(q: String, field: String): List<IntRange>? {
        if (q.length < 2 || field.isEmpty()) return null
        val chars = field.toCharArray()
        // Collect segment-start indices (string start or after a boundary).
        val starts = ArrayList<Int>()
        for (i in chars.indices) {
            if (i == 0 || chars[i - 1].isFuzzyBoundary) {
                if (!chars[i].isFuzzyBoundary) starts.add(i)
            }
        }
        val qChars = q.lowercase().toCharArray()
        if (starts.size < qChars.size) return null
        // Match q against consecutive segment starts.
        outer@ for (offset in 0..(starts.size - qChars.size)) {
            val ranges = ArrayList<IntRange>(qChars.size)
            for (k in qChars.indices) {
                val pos = starts[offset + k]
                if (chars[pos].lowercaseChar() != qChars[k]) continue@outer
                ranges.add(pos until pos + 1)
            }
            return ranges
        }
        return null
    }

    private fun gatedFuzzy(q: String, url: String, title: String): Classification? {
        val candidates = listOf(url, title)
        var bestPositions: List<Int>? = null
        var bestField: String? = null
        var bestScore = Int.MIN_VALUE
        for (field in candidates) {
            val positions = FuzzyMatch.matchPositions(q, field) ?: continue
            // Quality floor.
            val lowerChars = field.lowercase().toCharArray()
            val boundaryHits = positions.count { p ->
                p == 0 || (p - 1 >= 0 && lowerChars[p - 1].isFuzzyBoundary)
            }
            val needBoundary = ceil(q.length.toDouble() / 2.0).toInt()
            if (boundaryHits < needBoundary) continue
            val first = positions.firstOrNull() ?: continue
            val last = positions.lastOrNull() ?: continue
            val span = last - first + 1
            if (span > 3 * q.length) continue
            val score = FuzzyMatch.score(q, field) ?: Int.MIN_VALUE
            if (score > bestScore) {
                bestScore = score
                bestPositions = positions
                bestField = field
            }
        }
        val positions = bestPositions ?: return null
        val field = bestField ?: return null
        val ranges = positions.mapNotNull { p ->
            if (p < field.length) p until p + 1 else null
        }
        return if (field === title) {
            Classification(tier = tierFuzzy, titleRanges = ranges, urlRanges = emptyList(), matchStart = 0)
        } else {
            Classification(tier = tierFuzzy, titleRanges = emptyList(), urlRanges = ranges, matchStart = 0)
        }
    }

    // MARK: Range mapping helpers (against ORIGINAL displayed strings)

    private fun prefixRange(s: String, length: Int): IntRange? {
        if (length <= 0 || s.length < length) return null
        return 0 until length
    }

    private fun rangeOfSubstring(needleLower: String, s: String, from: Int): IntRange? {
        if (needleLower.isEmpty()) return null
        if (from > s.length) return null
        val idx = s.indexOf(needleLower, startIndex = from, ignoreCase = true)
        if (idx < 0) return null
        return idx until idx + needleLower.length
    }

    /** Locate the leading [length] chars of the host within the displayed url. */
    private fun rangeOfHostPrefix(url: String, host: String, length: Int): IntRange? {
        if (length <= 0 || host.length < length) return null
        val prefix = host.substring(0, length)
        // Anchor at the host's position so the prefix lands on the real host
        // and not an earlier coincidental occurrence (e.g. "http" inside the
        // "https://" scheme of "https://httpstat.us").
        val hostIdx = url.indexOf(host, ignoreCase = true)
        val from = if (hostIdx >= 0) hostIdx else 0
        return rangeOfSubstring(prefix.lowercase(), url, from)
    }

    // MARK: Scoring

    private fun recencyWeight(lastVisited: Instant, now: Instant): Int {
        val age = Duration.between(lastVisited, now).seconds.toDouble()
        if (age < 3600) return 600
        if (age < 86_400) return 400
        if (age < 604_800) return 250
        if (age < 2_592_000) return 120
        return 40
    }

    fun frequencyWeight(visitCount: Int): Int {
        val v = maxOf(0, visitCount)
        val raw = 40.0 * (ln(1.0 + v.toDouble()) / ln(2.0))
        return min(raw.roundToInt(), 400)
    }

    private fun earliness(matchStart: Int): Int = maxOf(0, 200 - matchStart * 8)

    fun frecency(visitCount: Int, lastVisited: Instant, now: Instant): Int =
        recencyWeight(lastVisited, now) + frequencyWeight(visitCount)

    fun finalScore(
        tier: Int,
        visitCount: Int,
        lastVisited: Instant,
        now: Instant,
        matchStart: Int,
        canonicalLength: Int,
        includeEarliness: Boolean,
    ): Int {
        val frec = frecency(visitCount = visitCount, lastVisited = lastVisited, now = now)
        val early = if (includeEarliness) earliness(matchStart) else 0
        val lengthPenalty = min(canonicalLength, 120)
        return tier + frec + early - lengthPenalty
    }
}
