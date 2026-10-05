package surf.zz.ui.bottombar

/**
 * Pure per-tile menu enablement derived from a single [isBlank] input.
 *
 * Ports `TileMenuActions` from iOS `BottomBar.swift`. A blank tile (no loaded
 * content) disables every per-tile action; any non-blank tile enables them all.
 * Kept as a pure value type so it can be unit-tested in isolation, exactly like
 * the Swift original.
 */
data class TileMenuActions(val isBlank: Boolean) {
    private val hasContent: Boolean = !isBlank

    val canDuplicate: Boolean get() = hasContent
    val canCopyUrl: Boolean get() = hasContent
    val canReload: Boolean get() = hasContent
    val canPark: Boolean get() = hasContent
    val canRequestDesktopSite: Boolean get() = hasContent
    val canSuspendMedia: Boolean get() = hasContent
}
