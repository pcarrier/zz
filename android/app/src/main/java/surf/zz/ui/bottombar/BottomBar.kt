package surf.zz.ui.bottombar

import androidx.compose.foundation.background
import androidx.compose.foundation.clickable
import androidx.compose.foundation.interaction.MutableInteractionSource
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.BoxWithConstraints
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.automirrored.filled.ArrowBack
import androidx.compose.material.icons.automirrored.filled.ArrowForward
import androidx.compose.material.icons.automirrored.filled.ViewSidebar
import androidx.compose.material.icons.filled.Close
import androidx.compose.material.icons.filled.HorizontalSplit
import androidx.compose.material.icons.filled.Inbox
import androidx.compose.material.icons.filled.VerticalSplit
import androidx.compose.material.icons.filled.ZoomInMap
import androidx.compose.material.icons.filled.ZoomOutMap
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Surface
import androidx.compose.runtime.Composable
import androidx.compose.runtime.remember
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.input.key.Key
import androidx.compose.ui.input.key.KeyEventType
import androidx.compose.ui.input.key.key
import androidx.compose.ui.input.key.onPreviewKeyEvent
import androidx.compose.ui.input.key.type
import androidx.compose.ui.platform.LocalFocusManager
import androidx.compose.ui.unit.dp
import surf.zz.browser.tab.Tab
import surf.zz.layout.BspNode
import surf.zz.omnibox.OmniboxItem
import surf.zz.store.LayoutPreset
import surf.zz.ui.LocalBrowserStore
import surf.zz.ui.omnibox.UrlBar
import java.util.UUID

/**
 * The bottom toolbar: navigation controls + the omnibox [UrlBar] + action buttons,
 * collapsing to a [MoreMenu] + sidebar button on a compact width.
 *
 * Faithful port of `BottomBar.swift`'s `struct BottomBar`. State and callbacks are
 * hoisted (the iOS `@Binding` / closures), the [surf.zz.store.BrowserStore] comes from
 * a CompositionLocal (the iOS `@Environment`), and the keyboard omnibox handling
 * (down/up/escape/enter) is reattached via [Modifier.onPreviewKeyEvent] on the URL
 * field. The nav cluster ([HistoryMenu] / [ReloadControl]) and the overflow
 * [MoreMenu] are the shared bottombar composables.
 *
 * DEVIATIONS from iOS (documented):
 *  - `horizontalSizeClass == .compact` becomes a width threshold measured by
 *    [BoxWithConstraints]: a bar narrower than [COMPACT_WIDTH] uses the compact
 *    layout. macOS forced `isCompact == false`; on a phone/tablet the width decides.
 *  - `.background(.bar, ignoresSafeAreaEdges: .bottom)` becomes a [Surface] tinted
 *    [MaterialTheme.colorScheme.surface]; edge-to-edge bottom-inset handling is the
 *    host screen's responsibility (ANDROID_ARCH.md §13).
 *  - SF Symbols map to the nearest Material icons (ANDROID_ARCH.md §11); the split
 *    glyphs use [Icons.Filled.HorizontalSplit] / [Icons.Filled.VerticalSplit].
 *  - `.help(...)` tooltips become content descriptions; the keyboard-shortcut hints
 *    in the help strings are dropped on a touch UI.
 */
@Composable
fun BottomBar(
    draft: String,
    onDraftChange: (String) -> Unit,
    urlFocused: Boolean,
    onFocusChange: (Boolean) -> Unit,
    selectedSuggestionIndex: Int?,
    setSelectedSuggestionIndex: (Int?) -> Unit,
    matches: List<OmniboxItem>,
    sidebarPresented: Boolean,
    onSidebarPresentedChange: (Boolean) -> Unit,
    settingsPresented: Boolean,
    onSettingsPresentedChange: (Boolean) -> Unit,
    historyPresented: Boolean,
    onHistoryPresentedChange: (Boolean) -> Unit,
    onSaveLayout: () -> Unit,
    onApplyLayout: (LayoutPreset) -> Unit,
    onDeleteLayout: (UUID) -> Unit,
    onOutsideUrlBarInteraction: () -> Unit,
    onCommit: (String) -> Unit,
    onSelect: (OmniboxItem) -> Unit,
    onFind: () -> Unit,
) {
    val store = LocalBrowserStore.current
    val focusManager = LocalFocusManager.current
    val tab = store.focusedTab

    // submit(): keyboard submit must route on kind exactly like click-select so an
    // open-tab row focuses rather than reloads (iOS BottomBar.submit()).
    fun submit() {
        val idx = selectedSuggestionIndex
        if (idx != null && idx >= 0 && idx < matches.size) {
            onSelect(matches[idx])
        } else {
            onCommit(draft)
        }
    }

    // moveSelection(delta): clamp into [0, matches.size-1], seeding from -1 when no
    // row is selected. Returns true when consumed (iOS KeyPress.Result).
    fun moveSelection(delta: Int): Boolean {
        if (matches.isEmpty()) return false
        val current = selectedSuggestionIndex ?: -1
        val next = current + delta
        val clamped = next.coerceIn(0, matches.size - 1)
        setSelectedSuggestionIndex(clamped)
        return true
    }

    Surface(
        color = MaterialTheme.colorScheme.surface,
        modifier = Modifier.fillMaxWidth(),
    ) {
        Box {
            BoxWithConstraints {
                val isCompact = maxWidth < COMPACT_WIDTH

                Row(
                    modifier = Modifier
                        .fillMaxWidth()
                        // contentShape(.rect) + onTapGesture { } : swallow background taps
                        // so they do not fall through to the panes behind the bar.
                        .clickable(
                            interactionSource = remember { MutableInteractionSource() },
                            indication = null,
                            onClick = {},
                        )
                        .padding(horizontal = 10.dp)
                        .padding(top = 6.dp, bottom = 2.dp),
                    horizontalArrangement = Arrangement.spacedBy(6.dp),
                    verticalAlignment = Alignment.CenterVertically,
                ) {
                    NavControls(
                        tab = tab,
                        onOutsideUrlBarInteraction = onOutsideUrlBarInteraction,
                    )

                    UrlBar(
                        text = draft,
                        onTextChange = { newDraft ->
                            onDraftChange(newDraft)
                            // onChange(of: draft): clear selection on edit.
                            setSelectedSuggestionIndex(null)
                        },
                        focused = urlFocused,
                        onFocusChange = onFocusChange,
                        findEnabled = tab != null && !tab.isBlank,
                        onFind = onFind,
                        onSubmit = { submit() },
                        modifier = Modifier
                            .weight(1f)
                            .onPreviewKeyEvent { event ->
                                if (event.type != KeyEventType.KeyDown) return@onPreviewKeyEvent false
                                when (event.key) {
                                    Key.DirectionDown -> moveSelection(+1)
                                    Key.DirectionUp -> moveSelection(-1)
                                    Key.Enter, Key.NumPadEnter -> {
                                        submit()
                                        true
                                    }
                                    Key.Escape -> {
                                        // escape: clear selection first, then drop focus.
                                        if (selectedSuggestionIndex != null) {
                                            setSelectedSuggestionIndex(null)
                                            true
                                        } else if (urlFocused) {
                                            focusManager.clearFocus()
                                            onFocusChange(false)
                                            true
                                        } else {
                                            false
                                        }
                                    }
                                    else -> false
                                }
                            },
                    )

                    if (isCompact) {
                        MoreMenu(
                            tab = tab,
                            isCompact = true,
                            onSettingsPresented = { onSettingsPresentedChange(true) },
                            onHistoryPresented = { onHistoryPresentedChange(true) },
                            onSaveLayout = onSaveLayout,
                            onApplyLayout = onApplyLayout,
                            onDeleteLayout = onDeleteLayout,
                            onOutsideUrlBarInteraction = onOutsideUrlBarInteraction,
                        )
                        BarIconButton(
                            icon = Icons.AutoMirrored.Filled.ViewSidebar,
                            enabled = store.parked.isNotEmpty(),
                            onClick = {
                                runOutsideUrlBarInteraction(onOutsideUrlBarInteraction) {
                                    onSidebarPresentedChange(true)
                                }
                            },
                            help = "Sidebar",
                        )
                    } else {
                        ActionButtons(
                            tab = tab,
                            onSettingsPresentedChange = onSettingsPresentedChange,
                            onHistoryPresentedChange = onHistoryPresentedChange,
                            onSaveLayout = onSaveLayout,
                            onApplyLayout = onApplyLayout,
                            onDeleteLayout = onDeleteLayout,
                            onOutsideUrlBarInteraction = onOutsideUrlBarInteraction,
                        )
                    }
                }
            }

            // overlay(alignment: .top) { Rectangle .separator.opacity(0.28) 0.5pt }
            Box(
                modifier = Modifier
                    .fillMaxWidth()
                    .height(0.5.dp)
                    .align(Alignment.TopCenter)
                    .background(MaterialTheme.colorScheme.onSurfaceVariant.copy(alpha = 0.28f)),
            )
        }
    }
}

/** Width below which the bottom bar collapses to the compact layout. */
private val COMPACT_WIDTH = 600.dp

/**
 * Back / forward / reload cluster. Port of `BottomBar.navButtons(tab:)`.
 *
 * Delegates to the shared [HistoryMenu] (tap = navigate one step, long-press = a
 * history dropdown) and [ReloadControl] (stop while loading, else reload /
 * long-press force-reload). The iOS `HStack(spacing: 2)` becomes a 2.dp-spaced [Row].
 */
@Composable
private fun NavControls(
    tab: Tab?,
    onOutsideUrlBarInteraction: () -> Unit,
) {
    Row(
        horizontalArrangement = Arrangement.spacedBy(2.dp),
        verticalAlignment = Alignment.CenterVertically,
    ) {
        HistoryMenu(
            tab = tab,
            items = tab?.backList ?: emptyList(),
            icon = Icons.AutoMirrored.Filled.ArrowBack,
            help = "Back",
            primaryAction = { tab?.goBack() },
            enabled = tab?.canGoBack ?: false,
            onInteraction = onOutsideUrlBarInteraction,
        )
        HistoryMenu(
            tab = tab,
            items = tab?.forwardList ?: emptyList(),
            icon = Icons.AutoMirrored.Filled.ArrowForward,
            help = "Forward",
            primaryAction = { tab?.goForward() },
            enabled = tab?.canGoForward ?: false,
            onInteraction = onOutsideUrlBarInteraction,
        )
        ReloadControl(tab = tab, onInteraction = onOutsideUrlBarInteraction)
    }
}

/**
 * Full action-button row for the wide layout. Port of `BottomBar.actionButtons(tab:)`:
 * zoom / park / horizontal-split / vertical-split / [MoreMenu] / close.
 */
@Composable
private fun ActionButtons(
    tab: Tab?,
    onSettingsPresentedChange: (Boolean) -> Unit,
    onHistoryPresentedChange: (Boolean) -> Unit,
    onSaveLayout: () -> Unit,
    onApplyLayout: (LayoutPreset) -> Unit,
    onDeleteLayout: (UUID) -> Unit,
    onOutsideUrlBarInteraction: () -> Unit,
) {
    val store = LocalBrowserStore.current
    Row(
        horizontalArrangement = Arrangement.spacedBy(2.dp),
        verticalAlignment = Alignment.CenterVertically,
    ) {
        BarIconButton(
            icon = if (store.zoomedTabID == null) Icons.Filled.ZoomOutMap else Icons.Filled.ZoomInMap,
            enabled = tab != null,
            onClick = {
                runOutsideUrlBarInteraction(onOutsideUrlBarInteraction) { store.toggleZoom() }
            },
            help = if (store.zoomedTabID == null) "Zoom focused tile" else "Restore layout",
        )
        BarIconButton(
            icon = Icons.Filled.Inbox,
            enabled = !(tab?.isBlank ?: true),
            onClick = {
                runOutsideUrlBarInteraction(onOutsideUrlBarInteraction) {
                    store.focusedTabID?.let { store.park(it) }
                }
            },
            help = "Park",
        )
        BarIconButton(
            icon = Icons.Filled.HorizontalSplit,
            enabled = store.canSplitSelection,
            onClick = {
                runOutsideUrlBarInteraction(onOutsideUrlBarInteraction) {
                    store.splitSelection(axis = BspNode.Axis.HORIZONTAL)
                }
            },
            help = "Horizontal Split",
        )
        BarIconButton(
            icon = Icons.Filled.VerticalSplit,
            enabled = store.canSplitSelection,
            onClick = {
                runOutsideUrlBarInteraction(onOutsideUrlBarInteraction) {
                    store.splitSelection(axis = BspNode.Axis.VERTICAL)
                }
            },
            help = "Vertical Split",
        )
        MoreMenu(
            tab = tab,
            isCompact = false,
            onSettingsPresented = { onSettingsPresentedChange(true) },
            onHistoryPresented = { onHistoryPresentedChange(true) },
            onSaveLayout = onSaveLayout,
            onApplyLayout = onApplyLayout,
            onDeleteLayout = onDeleteLayout,
            onOutsideUrlBarInteraction = onOutsideUrlBarInteraction,
        )
        BarIconButton(
            icon = Icons.Filled.Close,
            enabled = tab != null,
            onClick = {
                runOutsideUrlBarInteraction(onOutsideUrlBarInteraction) {
                    store.focusedTabID?.let { store.close(it) }
                }
            },
            help = "Close tile",
        )
    }
}

/**
 * Shared inline helper. Port of the file-private
 * `runOutsideURLBarInteraction(_:_:)`: notify that an interaction landed outside the
 * URL bar, then run the action. Keeps the call order identical to iOS.
 */
private inline fun runOutsideUrlBarInteraction(
    onOutsideUrlBarInteraction: () -> Unit,
    action: () -> Unit,
) {
    onOutsideUrlBarInteraction()
    action()
}
