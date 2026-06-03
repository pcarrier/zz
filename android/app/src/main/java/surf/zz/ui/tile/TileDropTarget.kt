@file:OptIn(androidx.compose.foundation.ExperimentalFoundationApi::class)

package surf.zz.ui.tile

import android.content.ClipData
import android.content.ClipDescription
import androidx.compose.foundation.ExperimentalFoundationApi
import androidx.compose.foundation.draganddrop.dragAndDropTarget
import androidx.compose.runtime.Composable
import androidx.compose.runtime.remember
import androidx.compose.ui.Modifier
import androidx.compose.ui.draganddrop.DragAndDropEvent
import androidx.compose.ui.draganddrop.DragAndDropTarget
import androidx.compose.ui.draganddrop.toAndroidDragEvent
import androidx.compose.ui.geometry.Offset
import androidx.compose.ui.geometry.Size
import surf.zz.model.TabRef
import java.util.UUID

/**
 * The ClipData MIME types a tile accepts as a drop.
 *
 * Mirrors `TileDropDelegate.acceptedContentTypes` in `TileView.swift` (which lists
 * `.url`, `.plainText`, `.utf8PlainText`, `.text`, `.json`). On Android the URL/text
 * payloads collapse to [ClipDescription.MIMETYPE_TEXT_URILIST] and
 * [ClipDescription.MIMETYPE_TEXT_PLAIN], and the parked-tab payload (Swift's `.json`
 * carrying a `TabRef`) is the custom [TabRef.MIME_TYPE].
 */
val TileAcceptedMimeTypes: List<String> = listOf(
    ClipDescription.MIMETYPE_TEXT_URILIST,
    ClipDescription.MIMETYPE_TEXT_PLAIN,
    TabRef.MIME_TYPE,
)

/** Whether [this] carries a parked-tab ([TabRef]) payload. */
private fun ClipDescription.hasTabRefMime(): Boolean =
    hasMimeType(TabRef.MIME_TYPE)

/**
 * Drag-and-drop target wiring for a single tile. Returns a [Modifier] that accepts a
 * drop onto the pane, previews the resolved [DropZone] via [state], and on release
 * routes the payload to [onDropParked] / [onDropUrl].
 *
 * This is the Android port of `TileDropDelegate` in `TileView.swift`. The owning
 * [surf.zz.ui.tile.TileView] keeps [state]'s `size` current (via `onSizeChanged`) and
 * supplies the store-routing callbacks, mirroring the Swift delegate calling back into
 * `TileView.performPaneDrop`. The Swift `DropDelegate` callbacks map as follows:
 *
 * - `validateDrop`  -> [dragAndDropTarget]'s `shouldStartDragAndDrop`: accept only when
 *   [isMainPaneHost] is true and the clip declares an accepted MIME (see
 *   [TileAcceptedMimeTypes]).
 * - `dropEntered` / `dropUpdated` -> [DragAndDropTarget.onEntered] /
 *   [DragAndDropTarget.onMoved], which call [TileDropState.update] with the drop location
 *   so the hover indicator tracks the cursor.
 * - `dropExited` / drag-ended -> [DragAndDropTarget.onExited] /
 *   [DragAndDropTarget.onEnded], which [TileDropState.clear] the preview.
 * - `performDrop` -> [DragAndDropTarget.onDrop]: re-checks the host guard, resolves the
 *   zone at the drop location, and decodes the clip (TabRef-first, then URL/text).
 *
 * Decode order matches the Swift delegate's `performDrop`: if the clip carries a
 * parked-tab ([TabRef]) payload and it decodes to a tab id, that wins (a move); otherwise
 * the first URL/text item is taken as a dropped URL (a copy). Decoding reuses
 * [TabRef.fromClipData], which tries the JSON shape first and falls back to a bare UUID
 * string — the same two-step fallback as the Swift `loadParkedTab`.
 *
 * Compose delivers these callbacks on the main thread, so the routing callbacks (which
 * mutate the main-thread-confined [surf.zz.store.BrowserStore] per ANDROID_ARCH.md §3/§7)
 * are invoked directly — no thread hop is needed, unlike the Swift `apply(...)` which had
 * to bounce off the item-provider completion queue back to `@MainActor`.
 *
 * @param isMainPaneHost guard reporting whether this pane currently hosts a live tab;
 *   read both at accept time and again at drop time, since the layout can change in
 *   between (mirrors the Swift `validateDrop` / `performDrop` double-check).
 * @param state the tile's transient hover state, updated for the preview indicator and
 *   read for the pane size when resolving a drop location to a [DropZone].
 * @param onDropUrl routes a dropped URL/text payload to the store.
 * @param onDropParked routes a dropped parked-tab payload to the store.
 */
@Composable
fun Modifier.tileDropTarget(
    isMainPaneHost: () -> Boolean,
    state: TileDropState,
    onDropUrl: (url: String, zone: DropZone) -> Unit,
    onDropParked: (id: UUID, zone: DropZone) -> Unit,
): Modifier {
    val target = remember(state, onDropUrl, onDropParked) {
        object : DragAndDropTarget {
            override fun onMoved(event: DragAndDropEvent) {
                state.update(location = event.dropOffset())
            }

            override fun onExited(event: DragAndDropEvent) {
                state.clear()
            }

            override fun onEnded(event: DragAndDropEvent) {
                state.clear()
            }

            override fun onDrop(event: DragAndDropEvent): Boolean {
                val zone = dropZone(at = event.dropOffset(), size = state.size.toSizeF())
                state.clear()

                // performDrop re-checks the host guard: the layout can change between
                // accept and drop, so a pane that is no longer a main host rejects.
                if (!isMainPaneHost()) return false

                val androidEvent = event.toAndroidDragEvent()
                val clip: ClipData? = androidEvent.clipData
                val description: ClipDescription? = androidEvent.clipDescription

                // TabRef-first, matching the Swift `performDrop` precedence: a parked-tab
                // payload that decodes to an id is a move; everything else is a URL copy.
                if (description?.hasTabRefMime() == true) {
                    val ref = TabRef.fromClipData(clip)
                    if (ref != null) {
                        onDropParked(ref.id, zone)
                        return true
                    }
                }

                val url = clip.firstUrlOrText()
                if (url != null) {
                    onDropUrl(url, zone)
                    return true
                }
                return false
            }
        }
    }

    return this.dragAndDropTarget(
        shouldStartDragAndDrop = { event ->
            isMainPaneHost() &&
                event.mimeTypes().any { it in TileAcceptedMimeTypes }
        },
        target = target,
    )
}

/** The drop location within the pane, in px. */
private fun DragAndDropEvent.dropOffset(): Offset {
    val e = toAndroidDragEvent()
    return Offset(e.x, e.y)
}

/** The MIME types declared by the drag's clip description. */
private fun DragAndDropEvent.mimeTypes(): List<String> {
    val description = toAndroidDragEvent().clipDescription ?: return emptyList()
    return (0 until description.mimeTypeCount).map { description.getMimeType(it) }
}

/**
 * The first URL/text payload in this clip, or `null`. Prefers a parsable URI item
 * (`text/uri-list`) and otherwise falls back to the first item's plain text — the
 * Android collapse of the Swift `loadURL`/`loadText` URL-then-text cascade. Trims
 * whitespace and ignores blank items.
 */
private fun ClipData?.firstUrlOrText(): String? {
    if (this == null) return null
    for (index in 0 until itemCount) {
        val item = getItemAt(index)
        item.uri?.toString()?.trim()?.takeIf { it.isNotEmpty() }?.let { return it }
        item.text?.toString()?.trim()?.takeIf { it.isNotEmpty() }?.let { return it }
    }
    return null
}

private fun androidx.compose.ui.unit.IntSize.toSizeF(): Size =
    Size(width.toFloat(), height.toFloat())
