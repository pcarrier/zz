package surf.zz.ui

import androidx.activity.compose.BackHandler
import androidx.compose.foundation.background
import androidx.compose.foundation.gestures.detectTapGestures
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxHeight
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.layout.widthIn
import androidx.compose.material3.AlertDialog
import androidx.compose.material3.ExperimentalMaterial3Api
import androidx.compose.material3.ModalBottomSheet
import androidx.compose.material3.OutlinedTextField
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.rememberModalBottomSheetState
import androidx.compose.material3.windowsizeclass.ExperimentalMaterial3WindowSizeClassApi
import androidx.compose.material3.windowsizeclass.WindowWidthSizeClass
import androidx.compose.material3.windowsizeclass.calculateWindowSizeClass
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.runtime.snapshotFlow
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.focus.FocusRequester
import androidx.compose.ui.input.pointer.pointerInput
import androidx.compose.ui.unit.dp
import androidx.lifecycle.DefaultLifecycleObserver
import androidx.lifecycle.LifecycleOwner
import androidx.lifecycle.compose.LocalLifecycleOwner
import androidx.activity.ComponentActivity
import androidx.compose.ui.platform.LocalContext
import java.util.UUID
import kotlinx.coroutines.flow.collectLatest
import kotlinx.coroutines.flow.distinctUntilChanged
import surf.zz.favicon.FaviconStore
import surf.zz.layout.BspNode
import surf.zz.model.WindowID
import surf.zz.omnibox.OmniboxItem
import surf.zz.omnibox.OmniboxRoute
import surf.zz.store.HistoryStore
import surf.zz.store.LayoutPresetLogic
import surf.zz.store.LayoutPresetStore
import surf.zz.ui.bottombar.BottomBar
import surf.zz.ui.bsp.BspView
import surf.zz.ui.bsp.SplitHandle
import surf.zz.ui.history.HistoryScreen
import surf.zz.ui.omnibox.SuggestionList
import surf.zz.ui.settings.SettingsScreen
import surf.zz.ui.sidebar.SidebarView
import surf.zz.ui.tile.TileView
import surf.zz.ui.theme.canvas

/**
 * The single-window UI shell. Direct port of the SwiftUI `BrowserScene`
 * (`ios/zz/ContentView.swift`).
 *
 * Ownership / state model (ANDROID_ARCH.md §3):
 *  - The per-window [BrowserStore] is created/remembered at the Activity root
 *    ([surf.zz.MainActivity]) and provided through [LocalBrowserStore]; this screen
 *    reads it (the analog of the Swift `@State private var store` + `.environment`).
 *    The Swift `BrowserScene.init` created the store; on Android creation moves up to
 *    the Activity so it survives recomposition, so this screen receives it via the
 *    CompositionLocal and the global stores as parameters (matching how `MainActivity`
 *    calls `App(...)`).
 *  - Local omnibox UI state (`draft`, `selectedSuggestionIndex`, `urlEditingTabId`,
 *    sheet/dialog flags, `saveLayoutName`, `matches`, `omniboxOpen`) is `remember {}`
 *    `mutableStateOf` — the analog of the Swift `@State` properties.
 *  - `urlFocused` (`@FocusState`) → a [FocusRequester] on the URL field plus an
 *    `omniboxOpen`-mirroring `urlFocused` flag updated from `onFocusChanged`.
 *
 * The Swift `.onChange(...)` reactive chain maps to [LaunchedEffect]/[snapshotFlow]
 * effects below; the `matchesInputKey`-driven recompute is one such effect. Sheets
 * (`sidebar`/`settings`/`history`) map to [ModalBottomSheet]; the Save-Layout alert to
 * an [AlertDialog] + [OutlinedTextField]. The floating [SuggestionList] is a
 * `Box(BottomCenter)` overlay capped at 720.dp.
 *
 * Layout (Swift `usesCompactLayout = horizontalSizeClass == .compact`): a Compact
 * width class renders a single pane with the sidebar as a [ModalBottomSheet]; any
 * larger class renders a [Row] with the main pane and a resizable sidebar separated by
 * a [SplitHandle] whose drag is fed to `begin/update/endSidebarDrag`.
 *
 * Deviations from iOS (documented in [App]/ANDROID_ARCH.md §9/§10): macOS-only
 * `HistoryMouseButtonLayer`/`CloseTileKeyLayer`/multi-window `openWindow`/`dismissWindow`
 * have no Android v1 equivalent; the system Back gesture maps to [BrowserStore.backFocused]
 * via [BackHandler], and keyboard shortcuts move to a single [KeyboardShortcuts] handler
 * (attached at the [App] root).
 */
@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun BrowserScreen(
    windowId: WindowID,
    history: HistoryStore,
    favicons: FaviconStore,
    layouts: LayoutPresetStore,
) {
    val store = LocalBrowserStore.current

    // --- Local UI state (Swift @State) -------------------------------------

    var draft by remember { mutableStateOf("") }
    var selectedSuggestionIndex by remember { mutableStateOf<Int?>(null) }
    // The edit target is pinned at omnibox-open time (see commit() / the focus
    // effects) and deliberately NOT retargeted when focusedTabID changes while the
    // omnibox is open — a suggestion click can leak a tap to the pane behind it.
    var urlEditingTabId by remember { mutableStateOf<UUID?>(null) }

    var sidebarPresented by remember { mutableStateOf(false) }
    var settingsPresented by remember { mutableStateOf(false) }
    var historyPresented by remember { mutableStateOf(false) }
    var saveLayoutPromptPresented by remember { mutableStateOf(false) }
    var saveLayoutName by remember { mutableStateOf("") }

    var matches by remember { mutableStateOf<List<OmniboxItem>>(emptyList()) }

    // The suggestion list stays open while EITHER the URL field has focus or the
    // list itself is being interacted with. Tracked separately from `urlFocused`
    // because tapping/scrolling the list steals focus from the text field; tying
    // visibility to focus alone would dismiss the list mid-tap. Closed only by an
    // explicit dismiss (commit / select / outside).
    var omniboxOpen by remember { mutableStateOf(false) }

    // Swift `@FocusState private var urlFocused`. The boolean mirror tracks the
    // field's reported focus; the requester drives focus from the focus trigger.
    var urlFocused by remember { mutableStateOf(false) }
    val urlFocusRequester = remember { FocusRequester() }

    val widthSizeClass = currentWindowWidthSizeClass()
    val usesCompactLayout = widthSizeClass == WindowWidthSizeClass.Compact

    // --- Cached omnibox matches (Swift computedMatches/refreshMatches) ------

    // Ranking the full history per read is expensive, so the result is cached in
    // `matches` and recomputed only when an input that affects it changes.
    fun computedMatches(): List<OmniboxItem> {
        if (!omniboxOpen) return emptyList()
        return history.omniboxSuggestions(
            query = draft,
            openTabs = store.openTabSuggestions(),
            now = java.time.Instant.now(),
            limit = 100,
        )
    }

    // Recompute the cached suggestions and, if the item under the highlighted index
    // changed (reorder/content change at the same count), clear the stale selection
    // so Return doesn't commit the wrong suggestion. (Swift refreshMatches.)
    fun refreshMatches() {
        val oldIds = matches.map { it.id }
        val new = computedMatches()
        val newIds = new.map { it.id }
        if (oldIds != newIds) matches = new
        val idx = selectedSuggestionIndex
        if (idx != null &&
            (idx >= newIds.size || idx >= oldIds.size || oldIds[idx] != newIds[idx])
        ) {
            selectedSuggestionIndex = null
        }
    }

    // --- Omnibox open / commit / dismiss -----------------------------------

    // Commit target: prefer the pinned edit target, else the focused tab, but only
    // when that tab is a main-pane host (Swift tabIDForCommit). Pure read.
    fun tabIdForCommit(): UUID? {
        urlEditingTabId?.let { if (store.isMainPaneHost(it)) return it }
        store.focusedTabID?.let { if (store.isMainPaneHost(it)) return it }
        return null
    }

    fun commit(value: String) {
        val trimmed = value.trim()
        if (trimmed.isEmpty()) return
        val targetId = tabIdForCommit() ?: return
        val tab = store.tab(targetId) ?: return
        store.focus(targetId)
        tab.load(trimmed)
        draft = tab.currentUrl
        omniboxOpen = false
        urlFocused = false
        urlEditingTabId = targetId
        selectedSuggestionIndex = null
        tab.focusForBrowsing()
    }

    fun selectSuggestion(item: OmniboxItem) {
        when (val route = OmniboxRoute.route(item)) {
            is OmniboxRoute.Focus -> {
                val tab = store.tab(route.tabId)
                if (tab == null) {
                    commit(item.url)
                    return
                }
                store.focus(route.tabId)
                omniboxOpen = false
                urlFocused = false
                selectedSuggestionIndex = null
                tab.focusForBrowsing()
            }
            is OmniboxRoute.Load -> commit(route.url)
        }
    }

    // Dismiss without clearing `urlEditingTabId`: selecting a suggestion can leak a
    // tap to the pane behind the list, whose onInteraction calls this dismiss AND
    // refocuses that pane before the row's tap-up commit; clearing the target would
    // make commit fall back to that wrongly focused pane. The target only matters at
    // commit and is re-captured on the next open, so a stale value here is harmless.
    fun dismissOmnibox() {
        if (!omniboxOpen && !urlFocused && selectedSuggestionIndex == null) return
        omniboxOpen = false
        urlFocused = false
        selectedSuggestionIndex = null
        draft = store.focusedTab?.currentUrl ?: ""
    }

    // --- Reactive onChange chain (Swift .onChange / .task) ------------------

    // Initial draft (Swift `.task { draft = store.focusedTab?.currentURL ?? "" }`).
    LaunchedEffect(Unit) {
        draft = store.focusedTab?.currentUrl ?: ""
    }

    // onChange(of: store.focusedTabID): refresh draft when not editing; clear stale
    // selection. Deliberately does NOT retarget `urlEditingTabId` (see its decl).
    LaunchedEffect(store) {
        snapshotFlow { store.focusedTabID }
            .distinctUntilChanged()
            .collectLatest {
                if (!urlFocused) draft = store.focusedTab?.currentUrl ?: ""
                selectedSuggestionIndex = null
            }
    }

    // onChange(of: store.focusedTab?.currentURL): mirror the focused tab's URL into
    // the draft when the field is not being edited.
    LaunchedEffect(store) {
        snapshotFlow { store.focusedTab?.currentUrl ?: "" }
            .distinctUntilChanged()
            .collectLatest { new ->
                if (!urlFocused) draft = new
            }
    }

    // onChange(of: store.focusURLBarTrigger): pin the edit target and request focus.
    LaunchedEffect(store) {
        snapshotFlow { store.focusUrlBarTrigger }
            .distinctUntilChanged()
            .collectLatest {
                urlEditingTabId = store.focusedTabID
                if (!urlFocused) urlFocusRequester.requestFocus()
            }
    }

    // onChange(of: urlFocused): opening pins target + seeds draft; losing focus only
    // clears the selection (NOT the open flag — see `omniboxOpen` decl).
    LaunchedEffect(urlFocused) {
        if (urlFocused) {
            omniboxOpen = true
            urlEditingTabId = store.focusedTabID
            draft = store.focusedTab?.currentUrl ?: ""
        } else {
            selectedSuggestionIndex = null
        }
    }

    // onChange(of: matchesInputKey): recompute cached suggestions whenever any
    // ranking input changes. The key mirrors the Swift `matchesInputKey`: focus,
    // draft, history size, and each open-tab suggestion's id|url|title.
    LaunchedEffect(store, history) {
        snapshotFlow {
            buildList {
                add(omniboxOpen.toString())
                add(draft)
                add(history.entries.size.toString())
                for (s in store.openTabSuggestions()) {
                    add("${s.tabId}|${s.url}|${s.title ?: ""}")
                }
            }
        }
            .distinctUntilChanged()
            .collectLatest { refreshMatches() }
    }

    // onChange(of: store.parked.count): in compact layout, auto-present the sidebar
    // sheet when a tab is parked (the count grows).
    LaunchedEffect(store) {
        var previous = store.parked.size
        snapshotFlow { store.parked.size }
            .collectLatest { newCount ->
                if (usesCompactLayout && newCount > previous) sidebarPresented = true
                previous = newCount
            }
    }

    // Lifecycle flush: ON_STOP flushes every store (Swift `scenePhase != .active`).
    val lifecycleOwner = LocalLifecycleOwner.current
    LifecycleStopFlush(lifecycleOwner) {
        store.flushSave()
        history.flushSave()
        favicons.flushSave()
        layouts.flushSave()
    }

    // Deep-link handling lives in MainActivity (ACTION_VIEW → store.openExternalURL),
    // the Android analog of the Swift `.onOpenURL`. Documented here for parity.

    // System Back → in-app back navigation (ANDROID_ARCH.md §10: `BackHandler ->
    // store.backFocused`). Mirrors the macOS Back-arrow shortcut. `backFocused()` is a
    // no-op when the focused tab can't go back. This screen-level handler nests under
    // (and so takes precedence over) the identical Activity-level handler in
    // MainActivity; both delegate to the same store method.
    BackHandler(enabled = true) {
        store.backFocused()
    }

    // --- View hierarchy (Swift body ZStack(alignment: .bottom)) -------------

    Box(modifier = Modifier.fillMaxSize()) {
        // Color.canvas.ignoresSafeArea() — the canvas background.
        Box(
            modifier = Modifier
                .fillMaxSize()
                .background(MaterialTheme.colorScheme.canvas),
        )

        // mainContent.environment(store)
        MainContent(
            usesCompactLayout = usesCompactLayout,
            onOutsideUrlBarInteraction = ::dismissOmnibox,
        )

        // Floating suggestion list (Swift: ZStack bottom overlay, maxWidth 720,
        // padding(.horizontal, 16), padding(.bottom, 6)). A tap on the margin is
        // swallowed so it doesn't fall through to the focused pane.
        if (omniboxOpen && matches.isNotEmpty()) {
            Box(
                modifier = Modifier
                    .align(Alignment.BottomCenter)
                    .fillMaxWidth()
                    .padding(horizontal = 16.dp, vertical = 6.dp),
                contentAlignment = Alignment.BottomCenter,
            ) {
                Box(
                    modifier = Modifier
                        .widthIn(max = 720.dp)
                        .fillMaxWidth()
                        // Keep margin taps from falling through to the focused pane
                        // (Swift `.contentShape(.rect).onTapGesture {}`).
                        .pointerInput(Unit) { detectTapGestures { /* swallow */ } },
                ) {
                    SuggestionList(
                        suggestions = matches,
                        selectedIndex = selectedSuggestionIndex,
                        onSelect = ::selectSuggestion,
                    )
                }
            }
        }

        // Bottom bar (Swift .safeAreaInset(edge: .bottom)). It owns the URL field
        // (wired to `urlFocusRequester` / `urlFocused`) and the chrome buttons.
        Box(modifier = Modifier.align(Alignment.BottomCenter)) {
            BottomBar(
                draft = draft,
                onDraftChange = { draft = it },
                urlFocused = urlFocused,
                onFocusChange = { focused -> urlFocused = focused },
                selectedSuggestionIndex = selectedSuggestionIndex,
                setSelectedSuggestionIndex = { selectedSuggestionIndex = it },
                matches = matches,
                sidebarPresented = sidebarPresented,
                onSidebarPresentedChange = { sidebarPresented = it },
                settingsPresented = settingsPresented,
                onSettingsPresentedChange = { settingsPresented = it },
                historyPresented = historyPresented,
                onHistoryPresentedChange = { historyPresented = it },
                onSaveLayout = {
                    saveLayoutName = ""
                    saveLayoutPromptPresented = true
                },
                onApplyLayout = { store.applyLayoutPreset(it) },
                onDeleteLayout = { layouts.delete(it) },
                onOutsideUrlBarInteraction = ::dismissOmnibox,
                onCommit = ::commit,
                onSelect = ::selectSuggestion,
                onFind = { store.focusedTab?.find() },
            )
        }
    }

    // --- Sheets / dialogs (Swift .sheet / .alert) --------------------------

    if (sidebarPresented) {
        val sheetState = rememberModalBottomSheetState(skipPartiallyExpanded = true)
        ModalBottomSheet(
            onDismissRequest = { sidebarPresented = false },
            sheetState = sheetState,
        ) {
            SidebarView(
                onSelect = { sidebarPresented = false },
                onInteraction = ::dismissOmnibox,
            )
        }
    }

    if (settingsPresented) {
        val sheetState = rememberModalBottomSheetState(skipPartiallyExpanded = true)
        ModalBottomSheet(
            onDismissRequest = { settingsPresented = false },
            sheetState = sheetState,
        ) {
            SettingsScreen(onDismiss = { settingsPresented = false })
        }
    }

    if (historyPresented) {
        val sheetState = rememberModalBottomSheetState(skipPartiallyExpanded = true)
        ModalBottomSheet(
            onDismissRequest = { historyPresented = false },
            sheetState = sheetState,
        ) {
            HistoryScreen(onOpen = { url ->
                historyPresented = false
                commit(url)
            }, onDismiss = { historyPresented = false })
        }
    }

    if (saveLayoutPromptPresented) {
        AlertDialog(
            onDismissRequest = { saveLayoutPromptPresented = false },
            title = { Text("Save Layout") },
            text = {
                Column {
                    Text("Name this pane arrangement so you can restore it later.")
                    OutlinedTextField(
                        value = saveLayoutName,
                        onValueChange = { saveLayoutName = it },
                        singleLine = true,
                        placeholder = { Text("Layout name") },
                    )
                }
            },
            confirmButton = {
                TextButton(onClick = {
                    val name = LayoutPresetLogic.normalizedName(saveLayoutName)
                    layouts.add(store.captureLayoutPreset(name))
                    saveLayoutPromptPresented = false
                }) { Text("Save") }
            },
            dismissButton = {
                TextButton(onClick = { saveLayoutPromptPresented = false }) {
                    Text("Cancel")
                }
            },
        )
    }
}

/**
 * The main content area below the floating overlay (Swift `mainContent`).
 *
 * Compact width → a single main pane (the sidebar is reached via the bottom-sheet,
 * presented from [BrowserScreen]). Larger width → a [Row] with the main pane, a
 * draggable [SplitHandle] feeding the store's sidebar-drag transforms, and the inline
 * [SidebarView] sized to `store.sidebarWidth`. The handle + sidebar are shown only
 * when there are parked tabs and nothing is zoomed (Swift guard).
 *
 * `mainPaneContent` (the zoomed tile vs. the BSP tree) is delegated to the bsp/tile
 * units; here we render the structural shell and pin the per-pane content via
 * [MainPaneContent].
 */
@Composable
private fun MainContent(
    usesCompactLayout: Boolean,
    onOutsideUrlBarInteraction: () -> Unit,
) {
    val store = LocalBrowserStore.current

    if (usesCompactLayout) {
        Box(modifier = Modifier.fillMaxSize()) {
            MainPaneContent(onOutsideUrlBarInteraction = onOutsideUrlBarInteraction)
        }
    } else {
        Row(modifier = Modifier.fillMaxSize(), horizontalArrangement = Arrangement.Start) {
            Box(modifier = Modifier.weight(1f).fillMaxHeight()) {
                MainPaneContent(onOutsideUrlBarInteraction = onOutsideUrlBarInteraction)
            }
            if (store.parked.isNotEmpty() && store.zoomedTabID == null) {
                SplitHandle(
                    axis = BspNode.Axis.VERTICAL,
                    onBegin = {
                        onOutsideUrlBarInteraction()
                        store.beginSidebarDrag()
                    },
                    onTranslate = { translation -> store.updateSidebarDrag(translation) },
                    onEnd = { store.endSidebarDrag() },
                )
                Box(modifier = Modifier.width(store.sidebarWidth.dp).fillMaxHeight()) {
                    SidebarView(
                        onSelect = {},
                        onInteraction = onOutsideUrlBarInteraction,
                    )
                }
            }
        }
    }
}

/**
 * The focused pane content (Swift `mainPaneContent`): a single zoomed tile when
 * `zoomedTabID` resolves to a live tab, otherwise the BSP tree rooted at `store.root`.
 *
 * The concrete tile / BSP rendering lives in the `ui/tile` and `ui/bsp` units; this
 * composable is the dispatch point that mirrors the Swift `@ViewBuilder`. It is kept
 * here (rather than in MainContent.kt) so the zoom/tree decision and the
 * `onOutsideUrlBarInteraction` plumbing stay co-located with the shell that owns the
 * dismiss handler.
 */
@Composable
private fun MainPaneContent(
    onOutsideUrlBarInteraction: () -> Unit,
) {
    val store = LocalBrowserStore.current
    val zoomedId = store.zoomedTabID
    if (zoomedId != null && store.tab(zoomedId) != null) {
        TileView(
            tabId = zoomedId,
            onOutsideUrlBarInteraction = onOutsideUrlBarInteraction,
        )
    } else {
        BspView(
            node = store.root,
            onOutsideUrlBarInteraction = onOutsideUrlBarInteraction,
        )
    }
}

/**
 * Registers a lifecycle observer that runs [onStop] on `ON_STOP` and removes it on
 * dispose. The Android analog of reacting to `scenePhase` leaving `.active`
 * (ANDROID_ARCH.md §6). Idempotent with the Activity-level flush in
 * [surf.zz.MainActivity].
 */
@Composable
private fun LifecycleStopFlush(owner: LifecycleOwner, onStop: () -> Unit) {
    androidx.compose.runtime.DisposableEffect(owner) {
        val observer = object : DefaultLifecycleObserver {
            override fun onStop(o: LifecycleOwner) = onStop()
        }
        owner.lifecycle.addObserver(observer)
        onDispose { owner.lifecycle.removeObserver(observer) }
    }
}

/**
 * Resolves the current window width-size class. v1 has no `WindowSizeClass`
 * CompositionLocal wired by ancestors, so we compute it from the host Activity. Falls
 * back to [WindowWidthSizeClass.Compact] when the context is not an Activity (e.g.
 * previews), matching the iOS phone default of a compact layout.
 */
@OptIn(ExperimentalMaterial3WindowSizeClassApi::class)
@Composable
private fun currentWindowWidthSizeClass(): WindowWidthSizeClass {
    val context = LocalContext.current
    val activity = context as? ComponentActivity
        ?: return WindowWidthSizeClass.Compact
    return calculateWindowSizeClass(activity).widthSizeClass
}
