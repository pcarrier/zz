package surf.zz.persistence

import java.util.UUID
import kotlinx.serialization.KSerializer
import kotlinx.serialization.descriptors.PrimitiveKind
import kotlinx.serialization.descriptors.PrimitiveSerialDescriptor
import kotlinx.serialization.descriptors.SerialDescriptor
import kotlinx.serialization.encoding.Decoder
import kotlinx.serialization.encoding.Encoder

/**
 * Serializes [UUID] as its canonical lowercase, dash-separated string form
 * (e.g. `f81d4fae-7dec-11d0-a765-00a0c91e6bf6`).
 *
 * This mirrors Swift's `UUID.uuidString` JSON shape so on-disk snapshots stay
 * structurally compatible with the iOS encoding for every `UUID` field.
 *
 * Apply with `@Serializable(with = UuidSerializer::class)` on each `UUID`
 * property (or pass it explicitly where a serializer is required).
 *
 * Note: `UUID.toString()` already emits the lowercase canonical form, and
 * `UUID.fromString(...)` accepts it (and is case-insensitive on decode).
 */
object UuidSerializer : KSerializer<UUID> {
    override val descriptor: SerialDescriptor =
        PrimitiveSerialDescriptor("surf.zz.persistence.UuidSerializer", PrimitiveKind.STRING)

    override fun serialize(encoder: Encoder, value: UUID) {
        encoder.encodeString(value.toString())
    }

    override fun deserialize(decoder: Decoder): UUID =
        UUID.fromString(decoder.decodeString())
}
