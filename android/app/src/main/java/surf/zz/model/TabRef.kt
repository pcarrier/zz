package surf.zz.model

import android.content.ClipData
import android.content.ClipDescription
import kotlinx.serialization.Serializable
import kotlinx.serialization.decodeFromString
import kotlinx.serialization.encodeToString
import surf.zz.persistence.UuidSerializer
import surf.zz.persistence.ZzJson
import java.util.UUID

/**
 * Drag payload wrapping a tab's UUID. Used for sidebar reorder (parked-tab list)
 * and pane drops.
 *
 * Ported from the iOS `TabRef` (`SidebarView.swift`), a `Codable & Transferable`
 * carried as a JSON item on the drag pasteboard. On Android the equivalent is a
 * [ClipData] item with the custom MIME type [MIME_TYPE]; the payload itself is the
 * JSON encoding of this type (via [ZzJson]), matching the iOS
 * `CodableRepresentation(contentType: .json)`.
 *
 * Decoding mirrors the iOS fallback used in both `SidebarReorderDropDelegate.tabRef(from:)`
 * and `PaneDropRoutingWebView.draggedTabID(from:)`: try the JSON decode first, then
 * fall back to interpreting the raw text as a bare UUID string.
 */
@Serializable
data class TabRef(
    @Serializable(UuidSerializer::class) val id: UUID,
) {
    companion object {
        /**
         * Custom MIME type identifying a [TabRef] drag item. Distinct from the URL
         * payloads ([android.net.Uri] / `text/plain`) handled by pane drops so a
         * parked-tab drag is never mistaken for a dropped URL.
         */
        const val MIME_TYPE: String = "text/x-zz-tabref"

        /**
         * Wraps this reference in a [ClipData] tagged with [MIME_TYPE]. The clip's
         * single item carries the JSON encoding of the [TabRef] as its text, so a
         * receiver can decode it with [fromClipText] (or fall back to the bare
         * UUID string).
         */
        fun clipData(id: UUID): ClipData {
            val description = ClipDescription("zz tab", arrayOf(MIME_TYPE))
            val item = ClipData.Item(ZzJson.encodeToString(TabRef(id)))
            return ClipData(description, item)
        }

        /**
         * Decodes a [TabRef] from the text carried by a drag item.
         *
         * Tries the JSON shape first (the value produced by [clipData] /
         * [toClipText]); if that fails, falls back to parsing the trimmed text as a
         * bare UUID string. Returns `null` when neither form is valid.
         */
        fun fromClipText(text: CharSequence?): TabRef? {
            val raw = text?.toString() ?: return null
            runCatching { ZzJson.decodeFromString<TabRef>(raw) }
                .getOrNull()
                ?.let { return it }
            return runCatching { UUID.fromString(raw.trim()) }
                .getOrNull()
                ?.let { TabRef(it) }
        }

        /**
         * Decodes a [TabRef] from a [ClipData] regardless of which item declared the
         * tabref MIME type. Returns `null` when no item yields a valid reference.
         */
        fun fromClipData(clip: ClipData?): TabRef? {
            if (clip == null) return null
            for (index in 0 until clip.itemCount) {
                fromClipText(clip.getItemAt(index).text)?.let { return it }
            }
            return null
        }
    }

    /** JSON text payload for a [ClipData.Item], matching the iOS `.json` representation. */
    fun toClipText(): String = ZzJson.encodeToString(this)
}
