package surf.zz.ui.bottombar

import android.widget.Toast
import androidx.compose.foundation.layout.Box
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.automirrored.filled.OpenInNew
import androidx.compose.material.icons.automirrored.filled.RotateRight
import androidx.compose.material.icons.automirrored.filled.ViewQuilt
import androidx.compose.material.icons.filled.Add
import androidx.compose.material.icons.filled.ContentCopy
import androidx.compose.material.icons.filled.Close
import androidx.compose.material.icons.filled.Dashboard
import androidx.compose.material.icons.filled.Delete
import androidx.compose.material.icons.filled.DesktopWindows
import androidx.compose.material.icons.filled.GridView
import androidx.compose.material.icons.filled.History
import androidx.compose.material.icons.filled.MoreHoriz
import androidx.compose.material.icons.filled.PanTool
import androidx.compose.material.icons.filled.PauseCircle
import androidx.compose.material.icons.filled.PlayCircle
import androidx.compose.material.icons.filled.Refresh
import androidx.compose.material.icons.filled.Settings
import androidx.compose.material.icons.filled.VerticalSplit
import androidx.compose.material.icons.filled.HorizontalSplit
import androidx.compose.material.icons.filled.Inbox
import androidx.compose.material.icons.filled.Layers
import androidx.compose.material.icons.filled.SaveAlt
import androidx.compose.material3.DropdownMenu
import androidx.compose.material3.DropdownMenuItem
import androidx.compose.material3.HorizontalDivider
import androidx.compose.material3.Icon
import androidx.compose.material3.LocalContentColor
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Switch
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.CompositionLocalProvider
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.vector.ImageVector
import androidx.compose.ui.platform.LocalClipboardManager
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.text.AnnotatedString
import surf.zz.browser.tab.Tab
import surf.zz.layout.BspNode
import surf.zz.layout.SplitSide
import surf.zz.prefs.BrowserPreferences
import surf.zz.store.LayoutPreset
import surf.zz.ui.LocalBrowserStore
import surf.zz.ui.LocalHistoryStore
import surf.zz.ui.LocalLayoutPresetStore
import java.util.UUID

/**
 * Overflow ("More") menu for the bottom bar.
 *
 * Faithful port of the private `MoreMenu` view in iOS `BottomBar.swift`. The SwiftUI
 * `Menu { ... }` becomes a Material3 [DropdownMenu] anchored to an ellipsis
 * [BarIconButton]; nested `Menu { ... }` (Layout / Layouts / Privacy & History, and
 * the per-preset Apply/Delete submenus) become nested [DropdownMenu]s opened from a
 * trailing-caret [DropdownMenuItem]. SwiftUI `Toggle` items become a
 * [DropdownMenuItem] with a trailing [Switch]; `Button(role: .destructive)` items
 * render in [MaterialTheme.colorScheme.error] (ANDROID_ARCH.md §11). `Divider()` maps
 * to [HorizontalDivider].
 *
 * Stores are read through CompositionLocals (ANDROID_ARCH.md §3) rather than SwiftUI
 * `@Environment`. The `@AppStorage(recordHistoryKey)` binding maps to
 * [BrowserPreferences.recordsHistory] (SharedPreferences-backed); because that is not
 * Compose snapshot state, the toggle keeps a local mirror seeded from the pref and
 * writes through it (the iOS `@AppStorage` two-way binding equivalent).
 *
 * DEVIATIONS (documented, see ANDROID_ARCH.md §9):
 *  - "New Window" has no v1 Android equivalent (single Activity / single window), so
 *    it shows a Toast instead of `openWindow(value: WindowID())`.
 *  - "Copy URL" uses [LocalClipboardManager] (the Compose analog of
 *    `UIPasteboard`/`NSPasteboard`).
 *  - macOS-only `.help(...)` tooltips and `.keyboardShortcut` hints are dropped from
 *    the menu labels (they were advisory text in the SF menu).
 */
@Composable
fun MoreMenu(
    tab: Tab?,
    isCompact: Boolean,
    onSettingsPresented: () -> Unit,
    onHistoryPresented: () -> Unit,
    onSaveLayout: () -> Unit,
    onApplyLayout: (LayoutPreset) -> Unit,
    onDeleteLayout: (UUID) -> Unit,
    onOutsideUrlBarInteraction: () -> Unit,
    modifier: Modifier = Modifier,
) {
    val store = LocalBrowserStore.current
    val history = LocalHistoryStore.current
    val layouts = LocalLayoutPresetStore.current
    val context = LocalContext.current
    val clipboard = LocalClipboardManager.current

    var expanded by remember { mutableStateOf(false) }

    // Local mirror of the tri-state `recordHistory` AppStorage pref. Seeded from the
    // pref and written through on toggle (BrowserPreferences is not snapshot state, so
    // the menu owns the observed copy — the iOS `@AppStorage` two-way binding analog).
    var recordHistory by remember { mutableStateOf(BrowserPreferences.recordsHistory) }

    // Helper mirroring `zz.runOutsideURLBarInteraction(_:_:)`: notify, then run, then
    // close this menu (the SwiftUI Menu auto-dismisses on tap; DropdownMenu does not).
    fun runOutside(action: () -> Unit) {
        onOutsideUrlBarInteraction()
        action()
        expanded = false
    }

    Box(modifier = modifier) {
        BarIconButton(
            icon = Icons.Filled.MoreHoriz,
            enabled = true,
            onClick = { expanded = true },
            help = "More",
        )

        DropdownMenu(expanded = expanded, onDismissRequest = { expanded = false }) {
            // New Window — v1 deviation: no multi-window, show a toast.
            DropdownMenuItem(
                text = { Text("New Window") },
                leadingIcon = { MenuIcon(Icons.AutoMirrored.Filled.OpenInNew) },
                onClick = {
                    runOutside {
                        Toast.makeText(
                            context,
                            "New Window is not available in this version",
                            Toast.LENGTH_SHORT,
                        ).show()
                    }
                },
            )

            if (tab != null) {
                HorizontalDivider()
                FocusedPaneActions(
                    tab = tab,
                    store = store,
                    onOutsideUrlBarInteraction = onOutsideUrlBarInteraction,
                    runOutside = ::runOutside,
                    copyUrl = { clipboard.setText(AnnotatedString(it)) },
                )
                HorizontalDivider()
            }

            LayoutSubmenu(
                store = store,
                isCompact = isCompact,
                runOutside = ::runOutside,
            )
            LayoutsSubmenu(
                layouts = layouts,
                onSaveLayout = onSaveLayout,
                onApplyLayout = onApplyLayout,
                onDeleteLayout = onDeleteLayout,
                runOutside = ::runOutside,
            )
            PrivacyHistorySubmenu(
                recordHistory = recordHistory,
                onToggleRecordHistory = {
                    onOutsideUrlBarInteraction()
                    recordHistory = it
                    BrowserPreferences.recordsHistory = it
                },
                onClearHistory = { runOutside { history.clear() } },
            )

            HorizontalDivider()

            DropdownMenuItem(
                text = { Text("History") },
                leadingIcon = { MenuIcon(Icons.Filled.History) },
                onClick = { runOutside { onHistoryPresented() } },
            )
            DropdownMenuItem(
                text = { Text("Settings") },
                leadingIcon = { MenuIcon(Icons.Filled.Settings) },
                onClick = { runOutside { onSettingsPresented() } },
            )
        }
    }
}

/**
 * Per-focused-pane actions section. Ports the private `focusedPaneActions` view: it
 * is only emitted when there is both a focused [tab] and a `store.focusedTabID`, and
 * each item is gated by the pure [TileMenuActions] derived from `tab.isBlank`.
 */
@Composable
private fun FocusedPaneActions(
    tab: Tab,
    store: surf.zz.store.BrowserStore,
    onOutsideUrlBarInteraction: () -> Unit,
    runOutside: (() -> Unit) -> Unit,
    copyUrl: (String) -> Unit,
) {
    val tabId = store.focusedTabID ?: return
    val actions = TileMenuActions(isBlank = tab.isBlank)

    if (actions.canDuplicate) {
        DropdownMenuItem(
            text = { Text("Duplicate Tile") },
            leadingIcon = { MenuIcon(Icons.Filled.Add) },
            onClick = {
                runOutside {
                    store.split(tabId, axis = BspNode.Axis.VERTICAL, side = SplitSide.AFTER, loadURL = tab.currentUrl)
                }
            },
        )
    }

    if (actions.canCopyUrl) {
        DropdownMenuItem(
            text = { Text("Copy URL") },
            leadingIcon = { MenuIcon(Icons.Filled.ContentCopy) },
            onClick = { runOutside { copyUrl(tab.currentUrl) } },
        )
    }

    if (actions.canReload) {
        DropdownMenuItem(
            text = { Text("Reload") },
            leadingIcon = { MenuIcon(Icons.Filled.Refresh) },
            onClick = { runOutside { tab.reload() } },
        )
    }

    if (actions.canRequestDesktopSite) {
        ToggleMenuItem(
            label = "Request Desktop Site",
            icon = Icons.Filled.DesktopWindows,
            checked = tab.requestsDesktopSite,
            onCheckedChange = {
                onOutsideUrlBarInteraction()
                tab.setRequestsDesktopSite(it, reload = true)
            },
        )
    }

    if (actions.canSuspendMedia) {
        ToggleMenuItem(
            label = if (tab.isMediaSuspended) "Resume Media" else "Suspend Media",
            icon = if (tab.isMediaSuspended) Icons.Filled.PlayCircle else Icons.Filled.PauseCircle,
            checked = tab.isMediaSuspended,
            onCheckedChange = {
                onOutsideUrlBarInteraction()
                tab.updateMediaSuspended(it)
            },
        )
    }

    if (actions.canPark) {
        DropdownMenuItem(
            text = { Text("Park") },
            leadingIcon = { MenuIcon(Icons.Filled.Inbox) },
            onClick = { runOutside { store.park(tabId) } },
        )
    }

    if (actions.canPark || actions.canCopyUrl) {
        HorizontalDivider()
    }

    DestructiveMenuItem(
        label = "Close",
        icon = Icons.Filled.Close,
        onClick = { runOutside { store.close(tabId) } },
    )
}

/** "Layout" submenu: select-parent / equalize / rotate, plus splits in compact mode. */
@Composable
private fun LayoutSubmenu(
    store: surf.zz.store.BrowserStore,
    isCompact: Boolean,
    runOutside: (() -> Unit) -> Unit,
) {
    var open by remember { mutableStateOf(false) }
    SubmenuAnchor(
        label = "Layout",
        icon = Icons.AutoMirrored.Filled.ViewQuilt,
        open = open,
        onOpenChange = { open = it },
    ) {
        DropdownMenuItem(
            text = { Text("Select Parent Group") },
            leadingIcon = { MenuIcon(Icons.Filled.Layers) },
            enabled = store.canSelectParentGroup,
            onClick = {
                open = false
                runOutside { store.selectParentGroup() }
            },
        )
        DropdownMenuItem(
            text = { Text("Equalize Group") },
            leadingIcon = { MenuIcon(Icons.Filled.GridView) },
            enabled = store.canTransformSelectedGroup,
            onClick = {
                open = false
                runOutside { store.equalizeSelectedGroup() }
            },
        )
        DropdownMenuItem(
            text = { Text("Rotate Group") },
            leadingIcon = { MenuIcon(Icons.AutoMirrored.Filled.RotateRight) },
            enabled = store.canTransformSelectedGroup,
            onClick = {
                open = false
                runOutside { store.rotateSelectedGroup() }
            },
        )

        if (isCompact) {
            HorizontalDivider()
            DropdownMenuItem(
                text = { Text("Horizontal Split") },
                leadingIcon = { MenuIcon(Icons.Filled.HorizontalSplit) },
                enabled = store.canSplitSelection,
                onClick = {
                    open = false
                    runOutside { store.splitSelection(axis = BspNode.Axis.HORIZONTAL) }
                },
            )
            DropdownMenuItem(
                text = { Text("Vertical Split") },
                leadingIcon = { MenuIcon(Icons.Filled.VerticalSplit) },
                enabled = store.canSplitSelection,
                onClick = {
                    open = false
                    runOutside { store.splitSelection(axis = BspNode.Axis.VERTICAL) }
                },
            )
        }
    }
}

/** "Layouts" submenu: save current layout + per-preset Apply/Delete sub-submenus. */
@Composable
private fun LayoutsSubmenu(
    layouts: surf.zz.store.LayoutPresetStore,
    onSaveLayout: () -> Unit,
    onApplyLayout: (LayoutPreset) -> Unit,
    onDeleteLayout: (UUID) -> Unit,
    runOutside: (() -> Unit) -> Unit,
) {
    var open by remember { mutableStateOf(false) }
    SubmenuAnchor(
        label = "Layouts",
        icon = Icons.Filled.GridView,
        open = open,
        onOpenChange = { open = it },
    ) {
        DropdownMenuItem(
            text = { Text("Save Current Layout…") },
            leadingIcon = { MenuIcon(Icons.Filled.SaveAlt) },
            onClick = {
                open = false
                runOutside { onSaveLayout() }
            },
        )

        if (layouts.presets.isNotEmpty()) {
            HorizontalDivider()
            // forEach over presets — each preset becomes a nested Apply/Delete submenu.
            layouts.presets.forEach { preset ->
                PresetSubmenu(
                    preset = preset,
                    onApply = {
                        open = false
                        runOutside { onApplyLayout(preset) }
                    },
                    onDelete = {
                        open = false
                        runOutside { onDeleteLayout(preset.id) }
                    },
                )
            }
        }
    }
}

/** A single layout preset's Apply/Delete nested submenu. */
@Composable
private fun PresetSubmenu(
    preset: LayoutPreset,
    onApply: () -> Unit,
    onDelete: () -> Unit,
) {
    var open by remember { mutableStateOf(false) }
    SubmenuAnchor(
        label = preset.name,
        icon = null,
        open = open,
        onOpenChange = { open = it },
    ) {
        DropdownMenuItem(
            text = { Text("Apply") },
            leadingIcon = { MenuIcon(Icons.Filled.Dashboard) },
            onClick = onApply,
        )
        DestructiveMenuItem(
            label = "Delete",
            icon = Icons.Filled.Delete,
            onClick = onDelete,
        )
    }
}

/** "Privacy & History" submenu: Record History toggle + destructive Clear History. */
@Composable
private fun PrivacyHistorySubmenu(
    recordHistory: Boolean,
    onToggleRecordHistory: (Boolean) -> Unit,
    onClearHistory: () -> Unit,
) {
    var open by remember { mutableStateOf(false) }
    SubmenuAnchor(
        label = "Privacy & History",
        icon = Icons.Filled.PanTool,
        open = open,
        onOpenChange = { open = it },
    ) {
        ToggleMenuItem(
            label = "Record History",
            icon = null,
            checked = recordHistory,
            onCheckedChange = onToggleRecordHistory,
        )
        DestructiveMenuItem(
            label = "Clear History",
            icon = Icons.Filled.Delete,
            onClick = onClearHistory,
        )
    }
}

// MARK: - Reusable menu primitives

/**
 * A submenu entry: a [DropdownMenuItem] with a trailing caret that, when tapped,
 * opens a nested [DropdownMenu] containing [content]. This is the Material analog of
 * SwiftUI's nested `Menu { ... } label: { Label(...) }`.
 */
@Composable
private fun SubmenuAnchor(
    label: String,
    icon: ImageVector?,
    open: Boolean,
    onOpenChange: (Boolean) -> Unit,
    content: @Composable () -> Unit,
) {
    Box {
        DropdownMenuItem(
            text = { Text(label) },
            leadingIcon = icon?.let { { MenuIcon(it) } },
            trailingIcon = { MenuIcon(Icons.AutoMirrored.Filled.OpenInNew) },
            onClick = { onOpenChange(true) },
        )
        DropdownMenu(expanded = open, onDismissRequest = { onOpenChange(false) }) {
            content()
        }
    }
}

/** A `Toggle`-style menu row: label (+ optional icon) with a trailing [Switch]. */
@Composable
private fun ToggleMenuItem(
    label: String,
    icon: ImageVector?,
    checked: Boolean,
    onCheckedChange: (Boolean) -> Unit,
) {
    DropdownMenuItem(
        text = { Text(label) },
        leadingIcon = icon?.let { { MenuIcon(it) } },
        trailingIcon = {
            Switch(checked = checked, onCheckedChange = null)
        },
        onClick = { onCheckedChange(!checked) },
    )
}

/**
 * A `Button(role: .destructive)` menu row, tinted with
 * [MaterialTheme.colorScheme.error] for both label and icon.
 */
@Composable
private fun DestructiveMenuItem(
    label: String,
    icon: ImageVector,
    onClick: () -> Unit,
) {
    val error = MaterialTheme.colorScheme.error
    DropdownMenuItem(
        text = {
            CompositionLocalProvider(LocalContentColor provides error) {
                Text(label)
            }
        },
        leadingIcon = { MenuIcon(icon, tint = error) },
        onClick = onClick,
    )
}

@Composable
private fun MenuIcon(icon: ImageVector, tint: androidx.compose.ui.graphics.Color = LocalContentColor.current) {
    Icon(imageVector = icon, contentDescription = null, tint = tint)
}
