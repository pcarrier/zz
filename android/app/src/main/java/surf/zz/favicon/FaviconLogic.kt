package surf.zz.favicon

import android.graphics.Bitmap
import android.graphics.BitmapFactory

/**
 * Pure helpers for the favicon cache: candidate fetch URLs, the on-disk
 * filename for a host, decoding bytes to a [Bitmap], and LRU eviction.
 *
 * Kept free of any state/IO so they are unit-testable. Ports `FaviconLogic`
 * from `Theme.swift` 1:1.
 */
object FaviconLogic {

    /**
     * Candidate URL(s) to try for a host: only the site's own `/favicon.ico`,
     * so no hostname is ever leaked to a third party. Returns empty for an
     * empty host.
     */
    fun candidateURLs(host: String): List<String> {
        val trimmed = host.trim().lowercase()
        if (trimmed.isEmpty()) return emptyList()
        return listOf("https://$trimmed/favicon.ico")
    }

    /**
     * Stable, filesystem-safe filename for a host's cached image. Hashing keeps
     * it free of path-hostile characters (`:`, `/`, …) and bounded in length.
     *
     * FNV-1a 64-bit over the lowercased host's UTF-8 bytes. Kotlin [Long] is
     * signed 64-bit; the arithmetic wraps with two's-complement overflow
     * exactly like Swift's `UInt64` `&^`/`&*`, so the rendered `%016x` is
     * identical and on-disk names stay stable.
     */
    fun fileName(host: String): String {
        val normalized = host.lowercase()
        // FNV-1a 64-bit offset basis is 14695981039346656037 (0xcbf29ce484222325),
        // which exceeds Long.MAX_VALUE and cannot be written as a positive Long
        // literal. This is its two's-complement signed form (same 64 bits); the
        // xor/multiply below wrap mod 2^64 exactly like Swift's UInt64 `^`/`&*`.
        var hash = -3_750_763_034_362_895_579L
        for (byte in normalized.toByteArray(Charsets.UTF_8)) {
            hash = hash xor (byte.toLong() and 0xFF)
            hash *= 1099511628211L // FNV prime; signed multiply wraps like UInt64 &*
        }
        // Unsigned, zero-padded 16-hex-digit rendering matches Swift's "%016llx".
        return hash.toULong().toString(16).padStart(16, '0') + ".img"
    }

    /**
     * Decode raw bytes into a [Bitmap], returning null on bad/empty data. Never
     * throws so the caller can simply fall back to an icon.
     */
    fun decode(data: ByteArray): Bitmap? {
        if (data.isEmpty()) return null
        return runCatching { BitmapFactory.decodeByteArray(data, 0, data.size) }.getOrNull()
    }

    /**
     * Given the current insertion-ordered keys and a cap, return the hosts that
     * should be evicted (oldest first) to bring the count back within [cap].
     */
    fun hostsToEvict(order: List<String>, cap: Int): List<String> {
        if (cap <= 0 || order.size <= cap) return emptyList()
        return order.take(order.size - cap)
    }
}
