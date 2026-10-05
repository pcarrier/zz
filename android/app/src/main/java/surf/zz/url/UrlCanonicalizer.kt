package surf.zz.url

import android.net.Uri
import surf.zz.util.SiteVisual
import java.net.URI
import java.util.Locale

/**
 * The ONLY canonicalizer. History `record()`, suggestion dedup, and the open-tab
 * map all call it so the dedup/match key never drifts between call sites.
 *
 * Pure logic; ported 1:1 from iOS `URLCanonicalizer` (BrowserStore.swift:1319).
 *
 * Swift uses `URLComponents`; Android uses [Uri] / [URI]. The behavioral contract
 * that both sides must agree on:
 *  - collapse `http`/`https` (and `www.`) into a single canonical form,
 *  - drop default ports (80 / 443) and a single empty trailing slash,
 *  - keep the (percent-encoded) query, drop the fragment,
 *  - keep non-http(s) schemes (file/about/...) as-is,
 *  - empty input -> "" ; unparseable -> lowercased trimmed input.
 */
object UrlCanonicalizer {

    /**
     * Produces the dedup/match key. Collapses http/https + www, drops default
     * ports, drops a single empty trailing slash, keeps the query, drops the
     * fragment.
     *
     * Mirrors Swift `URLCanonicalizer.key`.
     */
    fun key(url: String): String {
        val trimmed = url.trim()
        if (trimmed.isEmpty()) return ""

        // Parse leniently like Swift's `URLComponents(string:)`. If there is no
        // host, retry with an "https://" prefix and use THAT parse for every
        // component (host, scheme, port, path, query) -- mirrors Swift, which
        // rebuilds `comps` from the prefixed string and reads everything off it.
        var effective = trimmed
        var uri: Uri = Uri.parse(trimmed)
        if (uri.host == null) {
            effective = "https://$trimmed"
            uri = Uri.parse(effective)
        }

        val rawHost = uri.host
            ?: // No host even after the prefix retry: bail out exactly like Swift.
            return trimmed.lowercase(Locale.ROOT)

        // Collapse http/https into https; keep other schemes (file/about) as-is.
        val scheme = (uri.scheme ?: "https").lowercase(Locale.ROOT)
        val normScheme = if (scheme == "http" || scheme == "https") "https" else scheme

        var host = rawHost.lowercase(Locale.ROOT)
        if (host.startsWith("www.")) host = host.substring(4)

        // Drop default ports; keep any other explicit port. Uri.port is -1 when absent.
        val port = uri.port
        val portSuffix = if (port == -1 || port == 80 || port == 443) "" else ":$port"

        // Use the percent-ENCODED path/query to match Swift's
        // `percentEncodedPath` / `percentEncodedQuery`. Both come off the same
        // effective string/Uri as the host, never a different parse.
        var path = encodedPath(effective, uri)
        if (path == "/") path = ""

        val sb = StringBuilder()
        sb.append(normScheme).append("://").append(host).append(portSuffix).append(path)

        val query = encodedQuery(effective, uri)
        if (!query.isNullOrEmpty()) {
            sb.append("?").append(query)
        }
        return sb.toString()
    }

    /**
     * Lowercased, www-stripped host for tier matching. Reuses the iOS
     * `SiteVisual.host` semantics (which prefixes "https://" for bare hosts).
     *
     * Mirrors Swift `URLCanonicalizer.host`.
     */
    fun host(url: String): String {
        var host = SiteVisual.host(url).lowercase(Locale.ROOT)
        if (host.startsWith("www.")) host = host.substring(4)
        return host
    }

    // MARK: - Helpers

    /**
     * Percent-encoded path, equivalent to `URLComponents.percentEncodedPath`.
     *
     * Prefer [URI]'s strict parser (it preserves percent-encoding via getRawPath);
     * fall back to [Uri.getEncodedPath] when the input is too loose for [URI].
     * Returns "" when there is no path component.
     */
    private fun encodedPath(effective: String, uri: Uri): String {
        runCatching {
            val raw = URI(effective).rawPath
            if (raw != null) return raw
        }
        return uri.encodedPath ?: ""
    }

    /**
     * Percent-encoded query, equivalent to `URLComponents.percentEncodedQuery`.
     * Returns null when there is no query component.
     */
    private fun encodedQuery(effective: String, uri: Uri): String? {
        runCatching {
            URI(effective).rawQuery?.let { return it }
        }
        return uri.encodedQuery
    }
}
