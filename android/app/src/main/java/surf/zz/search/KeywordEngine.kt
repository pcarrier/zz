package surf.zz.search

import java.util.UUID
import kotlinx.serialization.Serializable
import surf.zz.persistence.UuidSerializer

/**
 * A user-defined keyword ("bang") search engine.
 *
 * The [keyword] is the first whitespace-delimited token typed in the omnibox;
 * the remaining query is substituted into [templateURL] using the same `%s`
 * machinery as the custom search template (see `SearchPreferences.searchURL`).
 *
 * Pure value type so it can cross thread boundaries for JSON encode/decode off
 * the main thread and live in default-argument expressions / sort comparators.
 *
 * ## Back-compat (port of Swift's custom `init(from:)`)
 *
 * The Swift type implements a hand-written decoder that uses `decodeIfPresent`
 * for every field, tolerating records that predate any of these keys:
 *
 * ```swift
 * id = try c.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
 * keyword = try c.decodeIfPresent(String.self, forKey: .keyword) ?? ""
 * templateURL = try c.decodeIfPresent(String.self, forKey: .templateURL) ?? ""
 * title = try c.decodeIfPresent(String.self, forKey: .title) ?? ""
 * ```
 *
 * On Android this is reproduced declaratively: every property has a default
 * value, and the shared `ZzJson` instance is configured with
 * `ignoreUnknownKeys = true`. A missing key falls back to its default
 * (`UUID.randomUUID()` / `""`), exactly matching the iOS `?? …` fallbacks; an
 * unexpected extra key is dropped rather than throwing. This makes decoding
 * forward- and backward-compatible without a custom serializer.
 *
 * The Swift `id` default is a fresh `UUID()`; here `UUID.randomUUID()` is
 * evaluated per-instance when the key is absent, matching that behavior.
 */
@Serializable
data class KeywordEngine(
    @Serializable(UuidSerializer::class) val id: UUID = UUID.randomUUID(),
    val keyword: String = "",
    val templateURL: String = "",
    val title: String = "",
)
