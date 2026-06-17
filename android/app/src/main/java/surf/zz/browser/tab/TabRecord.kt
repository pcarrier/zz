package surf.zz.browser.tab

import kotlinx.serialization.SerialName
import kotlinx.serialization.Serializable
import surf.zz.persistence.UuidSerializer
import java.util.UUID

/**
 * Per-tab persistence DTO. Swift origin: `Tab.swift:1421` (`struct TabRecord`).
 *
 * Mirrors the Swift `Codable` shape one-to-one. Optional/defaulted fields use
 * kotlinx.serialization defaults so a missing key decodes to the same value the
 * Swift `decodeIfPresent ?? x` path produced:
 *
 * - `title` is nullable with no default; combined with `explicitNulls = false`
 *   in [surf.zz.persistence.ZzJson] this matches Swift's `encodeIfPresent` /
 *   `decodeIfPresent` (the key is omitted when null and tolerated when absent).
 * - `scrollX` / `scrollY` default to `0.0` (Swift `?? 0`).
 * - `pageZoom` defaults to [PageZoom.defaultLevel] (Swift `?? PageZoom.defaultLevel`).
 * - `requestsDesktopSite` defaults to `false` (Swift `?? false`). NB: the Swift
 *   `init(_ tab:)` factory copies the tab's live value, which itself defaults to
 *   [surf.zz.prefs.BrowserPreferences.DEFAULT_REQUESTS_DESKTOP_SITE]; only the *decode* default is
 *   `false`, matching the `false` decode default used here.
 * - `mediaSuspended` defaults to `false` (Swift `?? false`).
 *
 * DEVIATION — dropped legacy `isMuted` migration. The Swift type carried a custom
 * `init(from:)` that read a legacy `isMuted` key (from the earlier SPI-mute
 * implementation) as a fallback for `mediaSuspended`:
 *
 *     mediaSuspended = decodeIfPresent(.mediaSuspended) ?? decodeIfPresent(.isMuted) ?? false
 *
 * Android has no legacy on-device data (fresh install; per ANDROID_ARCH.md §5 the
 * Android persistence format is independent from iOS and not byte-compatible), so
 * the `isMuted` fallback is intentionally NOT ported. A single `mediaSuspended`
 * field with a `false` default is sufficient. `ignoreUnknownKeys = true` in
 * [surf.zz.persistence.ZzJson] means that even if an `isMuted`-bearing blob were
 * ever encountered, it would be ignored rather than rejected.
 *
 * Serialization uses [surf.zz.persistence.ZzJson]; `id` uses [UuidSerializer] so
 * the JSON is a lowercase-with-dashes UUID string.
 */
@Serializable
data class TabRecord(
    @Serializable(UuidSerializer::class)
    @SerialName("id")
    val id: UUID,
    @SerialName("url")
    val url: String,
    @SerialName("title")
    val title: String? = null,
    @SerialName("scrollX")
    val scrollX: Double = 0.0,
    @SerialName("scrollY")
    val scrollY: Double = 0.0,
    @SerialName("pageZoom")
    val pageZoom: Double = PageZoom.defaultLevel,
    @SerialName("requestsDesktopSite")
    val requestsDesktopSite: Boolean = false,
    @SerialName("mediaSuspended")
    val mediaSuspended: Boolean = false,
)

/**
 * Snapshot a live [Tab] into a persistable [TabRecord]. Ports the Swift
 * `TabRecord.init(_ tab: Tab)` factory: copies the tab's current URL, title,
 * scroll offset, zoom, content-mode, and media-suspension state verbatim.
 */
fun TabRecord(tab: Tab): TabRecord = TabRecord(
    id = tab.id,
    url = tab.currentUrl,
    title = tab.title,
    scrollX = tab.scrollOffset.x,
    scrollY = tab.scrollOffset.y,
    pageZoom = tab.pageZoom,
    requestsDesktopSite = tab.requestsDesktopSite,
    mediaSuspended = tab.isMediaSuspended,
)
