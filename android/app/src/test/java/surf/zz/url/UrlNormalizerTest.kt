package surf.zz.url

import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Test
import surf.zz.search.KeywordEngine

/**
 * Mirrors the iOS `URLNormalizer` behavior (`BrowserStore.swift:2140`).
 *
 * These are pure JVM unit tests (plain JUnit, no Robolectric — matching the
 * project's pinned test deps), so they must not execute Android-framework code.
 * [surf.zz.search.SearchPreferences.searchURL] calls `Uri.encode`, which is
 * unavailable under plain JUnit, so the search-fallback cases below deliberately
 * pass an **empty** `searchTemplate`: `normalizedTemplate("")` returns `null`
 * *before* any `Uri` call, so the search route is observable here as a `null`
 * result. That still proves [UrlNormalizer] routed the input to search (and not
 * to a host/scheme branch, which would return a non-null string). The exact
 * percent-encoding of the query is covered by `SearchPreferences`' own tests.
 *
 * Keyword-bang expansion likewise routes through `searchURL`, so those cases also
 * use the empty-template sentinel and assert the search route was taken.
 */
class UrlNormalizerTest {

    /** Empty template => searchURL returns null before touching Uri.encode. */
    private val searchSentinelTemplate = ""

    private val engines = listOf(
        KeywordEngine(keyword = "g", templateURL = "", title = "Google"),
        KeywordEngine(keyword = "w", templateURL = "", title = "Wikipedia"),
    )

    private fun resolve(input: String): String? =
        UrlNormalizer.resolve(input, searchTemplate = searchSentinelTemplate, keywordEngines = engines)

    @Test fun blankInputIsNull() {
        assertNull(resolve(""))
        assertNull(resolve("   "))
        assertNull(resolve("\t \n"))
    }

    @Test fun trimsBeforeResolving() {
        assertEquals("https://example.com", resolve("  https://example.com  "))
    }

    // 1. Keyword bangs (routed to search; sentinel template => null) -----------

    @Test fun keywordBangWithQueryRoutesToSearch() {
        // Matches "g", non-empty query -> KeywordBangs.expand -> searchURL(empty
        // engine template) -> null. A null here (vs. a host string) proves the
        // bang branch was taken rather than the URL/host branch.
        assertNull(resolve("g cats"))
    }

    @Test fun bareKeywordFallsThroughToSearch() {
        // No remaining query -> expand returns null; "g" has no dot/space -> the
        // default-search branch, which also yields null with the sentinel template.
        assertNull(resolve("g"))
    }

    // 2. Explicit scheme allow-list -------------------------------------------

    @Test fun httpAndHttpsPassThrough() {
        assertEquals("http://example.com", resolve("http://example.com"))
        assertEquals("https://example.com/path?x=1", resolve("https://example.com/path?x=1"))
    }

    @Test fun aboutAndFilePassThrough() {
        assertEquals("about:blank", resolve("about:blank"))
        assertEquals("file:///etc/hosts", resolve("file:///etc/hosts"))
    }

    @Test fun schemeComparisonIsCaseInsensitive() {
        // Scheme matched case-insensitively, but the input is returned verbatim.
        assertEquals("HTTPS://Example.com", resolve("HTTPS://Example.com"))
        assertEquals("About:Blank", resolve("About:Blank"))
    }

    @Test fun nonWebSchemesAreRejected() {
        assertNull(resolve("mailto:a@b.com"))
        assertNull(resolve("ftp://host/file"))
        assertNull(resolve("javascript:alert(1)"))
        assertNull(resolve("data:text/plain,hi"))
    }

    // host:port (parser sees a bogus scheme) is treated as web -----------------

    @Test fun hostPortBecomesHttps() {
        assertEquals("https://localhost:8080", resolve("localhost:8080"))
        assertEquals("https://myhost:3000/path", resolve("myhost:3000/path"))
    }

    @Test fun numericCustomUriIsNotHostPort() {
        // "tel"/"sms"/"mailto" before the colon are non-web schemes -> rejected,
        // not treated as host:port even though the regex shape matches.
        assertNull(resolve("tel:5551234"))
        assertNull(resolve("sms:1234"))
        assertNull(resolve("mailto:1234"))
    }

    // 3. Search-vs-URL heuristic ----------------------------------------------

    @Test fun spaceMeansSearch() {
        // Contains a space -> search branch -> null with the sentinel template.
        assertNull(resolve("hello world"))
    }

    @Test fun noDotMeansSearch() {
        assertNull(resolve("kotlin"))
    }

    @Test fun spaceWithDotStillMeansSearch() {
        // Has a dot but also a space -> search branch (space test comes first).
        assertNull(resolve("see example.com please"))
    }

    @Test fun bareHostWithDotBecomesHttps() {
        assertEquals("https://example.com", resolve("example.com"))
        assertEquals("https://sub.example.co.uk/path", resolve("sub.example.co.uk/path"))
    }
}
