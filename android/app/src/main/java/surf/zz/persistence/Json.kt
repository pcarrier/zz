package surf.zz.persistence

import kotlinx.serialization.json.Json

/**
 * Shared [Json] instance used by every `@Serializable` DTO in the app.
 *
 * Mirrors the iOS `JSONEncoder`/`JSONDecoder` semantics used across the zz
 * persistence layer (window snapshots, layout presets, history, favicons):
 *
 *  - [Json.ignoreUnknownKeys] `= true`  — forward-compat decoding, the analog of
 *    Swift's `decodeIfPresent` for keys that don't exist on the DTO yet. A newer
 *    on-disk file with extra keys still decodes against an older DTO.
 *  - [Json.encodeDefaults] `= true`  — default-valued fields are still written, so
 *    a snapshot always contains the full shape (matches the explicit `encode(...)`
 *    of every Swift `Codable` field).
 *  - [Json.explicitNulls] `= false`  — null/absent optionals are omitted from the
 *    output, the analog of Swift's `encodeIfPresent` (no `"focusedTabID": null`).
 *  - [Json.classDiscriminator] `= "type"`  — used by the sealed `BspNode`
 *    hierarchy so a node serializes as `{"type":"leaf",...}` /
 *    `{"type":"split",...}`.
 *
 * This object holds no state; it is safe to share across threads.
 */
val ZzJson: Json = Json {
    ignoreUnknownKeys = true
    encodeDefaults = true
    explicitNulls = false
    classDiscriminator = "type"
}
