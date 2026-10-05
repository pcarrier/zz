package surf.zz.browser.web

import androidx.compose.ui.geometry.Offset
import androidx.compose.ui.geometry.Size
import java.util.UUID

/**
 * The contract types shared by the pane-hosting web view and the tile drop layer
 * when a drag is dropped onto a pane. Ported 1:1 from `WebView.swift`'s
 * `PaneDropPayload` / `PaneDropHandler`.
 *
 * v1 status (see ANDROID_ARCH.md §8): pane-reorg drag-and-drop is deferred on the
 * mobile target. These types are ported as plain data so the surrounding
 * signatures (`HostedWebView`, the tile drop targets) compile; the actual drag
 * wiring (`Modifier.dragAndDropTarget` plumbing into these lambdas) is a
 * follow-up. No behavior is dropped from the contract itself.
 */

/**
 * What is being dropped onto a pane.
 *
 * Mirrors Swift's `enum PaneDropPayload { case url(String); case parkedTab(UUID) }`.
 * A [Url] drop copies a link/address into the pane; a [ParkedTab] drop moves a
 * previously parked tab (identified by its id) back into the layout.
 */
sealed interface PaneDropPayload {
    /** A dropped URL/link string (a copy operation). */
    data class Url(val url: String) : PaneDropPayload

    /** A parked tab being moved back into a pane, identified by its tab id. */
    data class ParkedTab(val id: UUID) : PaneDropPayload
}

/**
 * The callbacks a pane exposes to the drag layer, mirroring Swift's
 * `struct PaneDropHandler { var update; var perform; var end }`.
 *
 * Geometry uses Compose's [Offset] (the drop location within the pane, in px) and
 * [Size] (the pane's bounds, in px) — the analogues of Swift's `CGPoint` / `CGSize`.
 *
 * @param update Called repeatedly as a drag hovers over the pane, with the current
 *   drop location and the pane size, so the pane can preview which [DropZone] would
 *   receive the drop. (Swift: `update: (CGPoint, CGSize) -> Void`.)
 * @param perform Called once when the drag is released over the pane, with the
 *   resolved payload, the drop location, and the pane size. (Swift:
 *   `perform: (PaneDropPayload, CGPoint, CGSize) -> Void`.)
 * @param end Called when the drag leaves the pane or finishes, so any in-progress
 *   drop preview can be cleared. (Swift: `end: () -> Void`.)
 */
class PaneDropHandler(
    val update: (Offset, Size) -> Unit,
    val perform: (PaneDropPayload, Offset, Size) -> Unit,
    val end: () -> Unit,
)
