package surf.zz.persistence

import java.time.Instant
import kotlinx.serialization.KSerializer
import kotlinx.serialization.descriptors.PrimitiveKind
import kotlinx.serialization.descriptors.PrimitiveSerialDescriptor
import kotlinx.serialization.descriptors.SerialDescriptor
import kotlinx.serialization.encoding.Decoder
import kotlinx.serialization.encoding.Encoder

/**
 * kotlinx.serialization [KSerializer] for [java.time.Instant] that encodes to and
 * from **epoch milliseconds as a JSON `Long`**.
 *
 * Backs `HistoryEntry.lastVisited` on Android. Apply it with
 * `@Serializable(with = InstantEpochMillisSerializer::class)` on the field:
 *
 * ```kotlin
 * @Serializable
 * data class HistoryEntry(
 *     val url: String,
 *     val title: String? = null,
 *     @Serializable(with = InstantEpochMillisSerializer::class)
 *     val lastVisited: Instant,
 *     val visitCount: Int = 1,
 * )
 * ```
 *
 * ## Deliberate divergence from iOS
 *
 * The Swift source (`BrowserStore.swift`, `HistoryEntry.lastVisited: Date`) relies
 * on `JSONEncoder`'s default `Date` strategy, which writes a **`Double` of seconds
 * since the Apple reference date (2001-01-01 00:00:00 UTC)**. We intentionally do
 * NOT reproduce that encoding here.
 *
 * Rationale (see ANDROID_ARCH.md §5 "Date / Instant"): Android history files live
 * under the app's private `filesDir` and are written from a fresh install. There is
 * no shared history file and no migration path from an iOS device, so byte-level /
 * epoch-base parity with Swift buys nothing. Epoch milliseconds (the natural unit of
 * [Instant.toEpochMilli] / [Instant.ofEpochMilli] and the rest of the Android
 * platform, e.g. `System.currentTimeMillis()`) is the idiomatic, drift-free choice.
 *
 * Consequences of the divergence, made explicit:
 *  - Unit, not just epoch base, differs: iOS stores **seconds** (`Double`), Android
 *    stores **milliseconds** (`Long`). A value copied verbatim between the two
 *    platforms would be misinterpreted — they are not interchangeable.
 *  - Sub-millisecond precision is dropped (an [Instant] truncates to millis on
 *    encode). History timestamps do not need finer resolution.
 *  - Encoding as an integer keeps the on-disk JSON exact (no floating-point
 *    round-trip error) and human-readable.
 */
object InstantEpochMillisSerializer : KSerializer<Instant> {
    override val descriptor: SerialDescriptor =
        PrimitiveSerialDescriptor("surf.zz.InstantEpochMillis", PrimitiveKind.LONG)

    override fun serialize(encoder: Encoder, value: Instant) {
        encoder.encodeLong(value.toEpochMilli())
    }

    override fun deserialize(decoder: Decoder): Instant =
        Instant.ofEpochMilli(decoder.decodeLong())
}
