package surf.zz.ui.bottombar

import android.net.Uri
import androidx.compose.foundation.ExperimentalFoundationApi
import androidx.compose.foundation.combinedClickable
import androidx.compose.foundation.interaction.MutableInteractionSource
import androidx.compose.foundation.layout.Box
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.Close
import androidx.compose.material.icons.filled.Refresh
import androidx.compose.material3.DropdownMenu
import androidx.compose.material3.DropdownMenuItem
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.DisposableEffect
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.runtime.setValue
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.alpha
import androidx.compose.ui.graphics.vector.ImageVector
import androidx.compose.ui.text.style.TextOverflow
import kotlinx.coroutines.Job
import kotlinx.coroutines.delay
import kotlinx.coroutines.launch
import surf.zz.browser.tab.BackForwardEntry
import surf.zz.browser.tab.Tab

/**
 * Back/forward history control with a long-press history dropdown, plus the
 * reload/stop control. Port of `BottomBar.swift`'s private `HistoryMenu` and
 * `ReloadControl`.
 *
 * SwiftUI's `Menu { … } primaryAction:` (a button that fires `primaryAction` on a
 * plain tap and opens a menu on a long press / disclosure) has no direct Compose
 * equivalent, so both controls use `Modifier.combinedClickable` (onClick = primary
 * action, onLongClick = open the dropdown / force-reload). This mirrors the iOS
 * note that the keyboard/click semantics route through the same primary action.
 */

/**
 * Back- or forward-history control. Port of `BottomBar.swift`'s `HistoryMenu`.
 *
 * ```swift
 * private struct HistoryMenu: View {
 *     let tab: Tab?; let items: [WKBackForwardListItem]; let icon: String
 *     let help: String; let primaryAction: () -> Void; let enabled: Bool
 *     let onInteraction: () -> Void
 *     var body: some View {
 *         if enabled && !items.isEmpty {
 *             Menu { ForEach(items.prefix(25)) { item in
 *                 Button { onInteraction(); tab?.go(to: item) } label: { Text(label(for: item)) }
 *             } } label: { barIcon(icon) } primaryAction: { onInteraction(); primaryAction() }
 *         } else {
 *             Button { onInteraction(); primaryAction() } label: { barIcon(icon) }.disabled(!enabled)
 *         }
 *     }
 * }
 * ```
 *
 * When [enabled] and there is history, a tap fires [primaryAction] (go back/forward
 * one step) and a long-press opens a [DropdownMenu] of up to 25 entries; tapping an
 * entry routes through [Tab.go]. When there is no history (or disabled) it degrades
 * to a plain icon button firing only [primaryAction]. `.opacity(enabled ? 1 : 0.35)`
 * maps to `Modifier.alpha`.
 */
@OptIn(ExperimentalFoundationApi::class)
@Composable
fun HistoryMenu(
    tab: Tab?,
    items: List<BackForwardEntry>,
    icon: ImageVector,
    help: String,
    primaryAction: () -> Unit,
    enabled: Boolean,
    onInteraction: () -> Unit,
    modifier: Modifier = Modifier,
) {
    val hasMenu = enabled && items.isNotEmpty()
    var expanded by remember { mutableStateOf(false) }
    val interactionSource = remember { MutableInteractionSource() }

    Box(modifier = modifier.alpha(if (enabled) 1f else 0.35f)) {
        BarIcon(
            icon = icon,
            contentDescription = help,
            modifier = Modifier.combinedClickable(
                interactionSource = interactionSource,
                indication = null,
                enabled = enabled,
                onClick = {
                    onInteraction()
                    primaryAction()
                },
                onLongClick = if (hasMenu) {
                    {
                        onInteraction()
                        expanded = true
                    }
                } else null,
            ),
        )

        if (hasMenu) {
            DropdownMenu(expanded = expanded, onDismissRequest = { expanded = false }) {
                // ForEach(items.prefix(25)): cap at 25 entries.
                items.take(25).forEach { item ->
                    DropdownMenuItem(
                        text = {
                            Text(
                                text = label(item),
                                maxLines = 1,
                                overflow = TextOverflow.Ellipsis,
                            )
                        },
                        onClick = {
                            expanded = false
                            onInteraction()
                            tab?.go(item.step)
                        },
                    )
                }
            }
        }
    }
}

/**
 * Entry label, port of `HistoryMenu.label(for:)`:
 *
 * ```swift
 * if let title = item.title, !title.isEmpty { return title }
 * return item.url.host(percentEncoded: false) ?? item.url.absoluteString
 * ```
 *
 * Prefer the entry title, then the URL host, then the raw URL.
 */
private fun label(item: BackForwardEntry): String {
    val title = item.title
    if (!title.isNullOrEmpty()) return title
    return Uri.parse(item.url).host ?: item.url
}

/**
 * Reload / stop control. Port of `BottomBar.swift`'s `ReloadControl`.
 *
 * ```swift
 * private struct ReloadControl: View {
 *     let tab: Tab?; let onInteraction: () -> Void
 *     @State private var suppressNextTap = false
 *     @State private var suppressResetTask: Task<Void, Never>?
 *     var body: some View {
 *         if tab?.isLoading == true {
 *             BarIconButton(name: "xmark", …) { onInteraction(); tab?.stop() }
 *         } else {
 *             Button {
 *                 onInteraction()
 *                 if suppressNextTap { suppressNextTap = false } else { tab?.reload() }
 *             } label: { barIcon("arrow.clockwise") }
 *             .disabled(tab == nil).opacity(tab == nil ? 0.35 : 1)
 *             .simultaneousGesture(LongPressGesture(minimumDuration: 0.45).onEnded { _ in
 *                 guard tab != nil else { return }
 *                 onInteraction(); suppressNextTap = true; tab?.forceReload()
 *                 suppressResetTask?.cancel()
 *                 suppressResetTask = Task { try? await sleep(700ms);
 *                     guard !isCancelled else { return }; suppressNextTap = false }
 *             })
 *             .onChange(of: tab?.isLoading) { … reset }
 *             .onChange(of: tab?.id)        { … reset }
 *             .onDisappear { suppressResetTask?.cancel(); suppressResetTask = nil }
 *         }
 *     }
 * }
 * ```
 *
 * While loading, shows a stop button. Otherwise a reload button: a tap reloads
 * (unless suppressed by a preceding long-press), and a 0.45s long-press force-reloads
 * (cache bypass), sets [suppressNextTap] so the tap that ends the long-press does not
 * also reload, and schedules a cancellable 700ms job to clear the suppression. The
 * suppression/job is reset whenever `isLoading` or the tab id changes, and the job is
 * cancelled on disposal.
 */
@OptIn(ExperimentalFoundationApi::class)
@Composable
fun ReloadControl(
    tab: Tab?,
    onInteraction: () -> Unit,
    modifier: Modifier = Modifier,
) {
    if (tab?.isLoading == true) {
        // Stop button. `enabled: tab != nil` — tab is non-null in this branch.
        BarIconButton(
            icon = Icons.Filled.Close,
            enabled = true,
            onClick = {
                onInteraction()
                tab.stop()
            },
            modifier = modifier,
            help = "Stop",
        )
        return
    }

    // Reload button with long-press force-reload.
    val scope = rememberCoroutineScope()
    var suppressNextTap by remember { mutableStateOf(false) }
    // Holds the in-flight 700ms reset job (Swift `suppressResetTask`).
    val suppressResetJob = remember { mutableStateOf<Job?>(null) }
    val interactionSource = remember { MutableInteractionSource() }

    fun resetSuppression() {
        suppressResetJob.value?.cancel()
        suppressResetJob.value = null
        suppressNextTap = false
    }

    // .onChange(of: tab?.isLoading) and .onChange(of: tab?.id): reset on either.
    val isLoading = tab?.isLoading
    val tabId = tab?.id
    LaunchedEffect(isLoading, tabId) {
        resetSuppression()
    }

    // .onDisappear: cancel the pending reset job (without clearing suppression flag,
    // matching the Swift onDisappear which only cancels the task).
    DisposableEffect(Unit) {
        onDispose {
            suppressResetJob.value?.cancel()
            suppressResetJob.value = null
        }
    }

    BarIcon(
        icon = Icons.Filled.Refresh,
        contentDescription = "Reload (⌘R), Force Reload (long-press or ⇧⌘R)",
        modifier = modifier
            .alpha(if (tab == null) 0.35f else 1f)
            .combinedClickable(
                interactionSource = interactionSource,
                indication = null,
                enabled = tab != null,
                onClick = {
                    onInteraction()
                    if (suppressNextTap) {
                        suppressNextTap = false
                    } else {
                        tab?.reload()
                    }
                },
                onLongClick = {
                    if (tab == null) return@combinedClickable
                    onInteraction()
                    suppressNextTap = true
                    tab.forceReload()
                    suppressResetJob.value?.cancel()
                    suppressResetJob.value = scope.launch {
                        delay(700)
                        suppressNextTap = false
                    }
                },
            ),
    )
}
