package surf.zz.url

import android.util.Patterns
import java.util.regex.Matcher

/**
 * Extracts a URL string from dropped or pasted text.
 *
 * Port of `DroppedURL` from `BrowserStore.swift:2191`.
 *
 * Strategy (matches iOS):
 *  1. Trim leading/trailing whitespace and newlines; reject empty.
 *  2. Detect the first link embedded anywhere in the text (iOS `NSDataDetector`
 *     with the `.link` checking type → Android [Patterns.WEB_URL]) and, if found,
 *     return its absolute string form.
 *  3. Otherwise fall back to [UrlNormalizer]: if the trimmed text resolves to a
 *     navigable URL, return the trimmed text; if not, return `null`.
 *
 * Pure logic — no Android UI / context dependencies beyond the static
 * [Patterns.WEB_URL] regex.
 */
object DroppedUrl {

    fun string(fromText: String): String? {
        val trimmed = fromText.trim()
        if (trimmed.isEmpty()) return null

        firstLink(trimmed)?.let { return it }

        // No embedded link detected — defer to the normalizer. If the whole
        // trimmed input resolves to something navigable, hand back the raw
        // trimmed text (the normalizer/loader will re-resolve it); otherwise
        // reject so the caller can search or hand it off.
        return if (UrlNormalizer.resolve(trimmed) != null) trimmed else null
    }

    /**
     * Returns the absolute-string form of the first web link found anywhere in
     * [text], or `null` if none.
     *
     * Mirrors iOS `NSDataDetector(.link).firstMatch(...).url.absoluteString`.
     * [Patterns.WEB_URL] matches bare hosts (e.g. "example.com") without a
     * scheme, so a scheme is prepended when absent to produce an absolute URL
     * comparable to `NSDataDetector`'s output.
     */
    private fun firstLink(text: String): String? {
        val matcher: Matcher = Patterns.WEB_URL.matcher(text)
        if (!matcher.find()) return null
        val match = matcher.group() ?: return null
        return absolutize(match)
    }

    /** Prepends `https://` when the match carries no explicit scheme. */
    private fun absolutize(match: String): String {
        // A scheme is "<alpha><alphanum|+|-|.>*://" at the very start.
        return if (SCHEME_PREFIX.containsMatchIn(match)) match else "https://$match"
    }

    private val SCHEME_PREFIX = Regex("^[A-Za-z][A-Za-z0-9+.-]*://")
}
