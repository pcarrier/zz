package surf.zz.omnibox

/**
 * Subsequence fuzzy scorer + greedy match positions with boundary/streak bonuses.
 *
 * Ported 1:1 from iOS `BrowserStore.swift:2084` (`enum FuzzyMatch`). Pure logic; no
 * platform dependencies. Operates on lowercased UTF-16 char arrays so that the integer
 * positions returned by [matchPositions] line up with Compose `AnnotatedString` offsets.
 */
object FuzzyMatch {

    /**
     * Returns a match score for [needle] occurring as a subsequence of [haystack], or
     * `null` if [needle] is not a subsequence (or is empty / longer than [haystack]).
     *
     * Higher is better. Bonuses: +8 for a match at a fuzzy boundary, +(4 + streak) for
     * consecutive matches, with a small length penalty `haystack.length / 32`.
     */
    fun score(needle: String, haystack: String): Int? {
        val n = needle.lowercase().toCharArray()
        val h = haystack.lowercase().toCharArray()
        if (n.isEmpty()) return null
        if (n.size > h.size) return null

        var ni = 0
        var score = 0
        var prevMatch = -2
        var streak = 0
        for (i in h.indices) {
            val c = h[i]
            if (ni < n.size && c == n[ni]) {
                val isBoundary = i == 0 || h[i - 1].isFuzzyBoundary
                score += 1
                if (isBoundary) score += 8
                if (i == prevMatch + 1) {
                    streak += 1
                    score += 4 + streak
                } else {
                    streak = 0
                }
                prevMatch = i
                ni += 1
            }
        }
        if (ni != n.size) return null
        score -= h.size / 32
        return score
    }

    /**
     * Greedy left-to-right subsequence match positions (indices into the lowercased
     * haystack), or `null` if the needle isn't a subsequence. Used by the gated Tier-1
     * fallback for its quality floor + highlight ranges.
     */
    fun matchPositions(needle: String, haystack: String): List<Int>? {
        val n = needle.lowercase().toCharArray()
        val h = haystack.lowercase().toCharArray()
        if (n.isEmpty() || n.size > h.size) return null
        var ni = 0
        val positions = ArrayList<Int>(n.size)
        for (i in h.indices) {
            val c = h[i]
            if (ni < n.size && c == n[ni]) {
                positions.add(i)
                ni += 1
            }
        }
        return if (ni == n.size) positions else null
    }
}

/**
 * Punctuation/separator test used to award the word-boundary bonus in [FuzzyMatch.score].
 * Mirrors the iOS `Character.isFuzzyBoundary` extension exactly.
 */
internal val Char.isFuzzyBoundary: Boolean
    get() = this == ' ' || this == '/' || this == '.' || this == '-' ||
        this == '_' || this == ':' || this == '?' || this == '&' ||
        this == '=' || this == '#'
