package surf.zz.model

import kotlinx.serialization.Serializable
import surf.zz.persistence.UuidSerializer
import java.util.UUID

/**
 * Per-window identity that keys the on-disk snapshot file
 * (`filesDir/zz/windows/<id>/state.json`).
 *
 * Ports `struct WindowID: Hashable, Codable` (BrowserStore.swift:368). The Swift
 * type is a single-field value type with a defaulted initializer; here it is a
 * Kotlin `data class`, which provides the equivalent value semantics (`equals`,
 * `hashCode`) the Swift `Hashable` conformance gave for free.
 *
 * Serialization stays string-compatible with Swift's `UUID` (lowercase,
 * dash-separated) via [UuidSerializer]; the JSON is a single `{"id":"..."}` object,
 * matching Swift's default Codable encoding for a one-field struct.
 *
 * v1 deviation (§9): SwiftUI's `WindowGroup(for: WindowID.self)` auto-restored
 * multi-window has no Android equivalent. MainActivity mints exactly one fixed
 * `WindowID` (persisted in DataStore so the same window restores on relaunch) and
 * "New Window" / `openWindow(value:)` is a no-op in v1.
 */
@Serializable
data class WindowID(
    @Serializable(UuidSerializer::class)
    val id: UUID = UUID.randomUUID(),
)
