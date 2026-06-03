package surf.zz.store

import android.content.Context
import android.util.Log
import android.webkit.WebView
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateMapOf
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.setValue
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.Job
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.delay
import kotlinx.coroutines.isActive
import kotlinx.coroutines.launch
import kotlinx.coroutines.runBlocking
import kotlinx.coroutines.withContext
import kotlinx.serialization.SerialName
import kotlinx.serialization.Serializable
import surf.zz.browser.tab.PageZoom
import surf.zz.browser.tab.ScrollOffset
import surf.zz.browser.tab.Tab
import surf.zz.browser.tab.TabRecord
import surf.zz.favicon.FaviconStore
import surf.zz.layout.BspNode
import surf.zz.layout.Direction
import surf.zz.layout.SplitSide
import surf.zz.model.WindowID
import surf.zz.omnibox.OmniboxSuggestions
import surf.zz.persistence.PersistenceWriteOrderer
import surf.zz.persistence.UuidSerializer
import surf.zz.persistence.ZzJson
import surf.zz.prefs.BrowserPreferences
import surf.zz.prefs.NewWindowPolicy
import surf.zz.ui.tile.DropZone
import surf.zz.url.DroppedUrl
import java.io.File
import java.util.UUID

/**
 * Per-window persistence shape. Private DTO mirroring the iOS `WindowSnapshot`
 * (`BrowserStore.swift:375`).
 *
 * Optional/defaulted fields use kotlinx.serialization defaults so a missing key
 * decodes to the same value Swift's `decodeIfPresent ?? x` produced:
 *  - `focusedTabId` nullable, no default (omitted when null via `explicitNulls = false`).
 *  - `parked` defaults to `[]` (Swift `?? []`).
 *  - `tabs` defaults to `[]` (Swift `?? []`).
 *  - `sidebarWidth` defaults to `220.0` (Swift `?? 220`).
 *
 * The Swift key was `focusedTabID`; we keep that on-disk key via [SerialName] so the
 * shape stays stable regardless of the Kotlin property name.
 */
@Serializable
private data class WindowSnapshot(
    val root: BspNode,
    @Serializable(UuidSerializer::class)
    @SerialName("focusedTabID")
    val focusedTabId: UUID? = null,
    val parked: List<@Serializable(UuidSerializer::class) UUID> = emptyList(),
    val tabs: List<TabRecord> = emptyList(),
    val sidebarWidth: Double = 220.0,
)

/**
 * Per-window state owner: the BSP layout tree, the live [Tab] map, focus / group
 * selection / zoom / sidebar geometry, debounced atomic JSON persistence, the
 * WebView new-window bridge, transient drag-gesture state, and layout-preset
 * capture/apply.
 *
 * Faithful port of the iOS `@MainActor @Observable final class BrowserStore`
 * (`BrowserStore.swift:408`). The `@Observable` fields become Compose snapshot
 * state so reading them inside composition tracks them exactly like SwiftUI
 * (ANDROID_ARCH.md §3); `@ObservationIgnored` fields are plain `private var`s.
 *
 * Threading: like the Swift `@MainActor` original, all snapshot-state mutation
 * happens on the main thread (every public method is called from Compose / the
 * main-thread WebView callbacks). The unbounded atomic disk write runs off-main
 * (`Dispatchers.IO`), ordered by a monotonic generation through
 * [PersistenceWriteOrderer] so a stale debounced write can never land after a newer
 * one (e.g. a synchronous [flushSave] at backgrounding).
 *
 * DEVIATIONS from iOS (documented):
 *  - The constructor takes a `favicons` store and a `context` (Android needs a
 *    [Context] to build [Tab]s / their WebViews and to resolve `filesDir`); iOS
 *    `Tab` built its own `WKWebView` from process state.
 *  - The new-window bridge: Android's `WebChromeClient.onCreateWindow` carries no
 *    `WKWebViewConfiguration` / `WKNavigationAction` and no target URL, so
 *    [handleNewWindowRequest] cannot inspect a request URL. The `.samePane` policy
 *    therefore cannot pre-load a URL (it returns the source pane's WebView so the
 *    platform loads the popup target into it); see [handleNewWindowRequest].
 */
class BrowserStore(
    val windowId: WindowID,
    history: HistoryStore,
    private val favicons: FaviconStore,
    private val context: Context,
) {

    // MARK: Observed snapshot state (@Observable in Swift)

    var root: BspNode by mutableStateOf(BspNode.Leaf(UUID.randomUUID()))
        private set

    var focusedTabID: UUID? by mutableStateOf(null)
        private set

    var selectedGroupID: UUID? by mutableStateOf(null)
        private set

    var parked: List<UUID> by mutableStateOf(emptyList())
        private set

    var sidebarWidth: Double by mutableStateOf(220.0)
        private set

    /** Live tabs keyed by id. `mutableStateMapOf` mirrors the Swift `[UUID: Tab]` `@Observable` dict. */
    val tabs = mutableStateMapOf<UUID, Tab>()

    /**
     * One-shot trigger to focus the URL bar. Swift used `focusURLBarTrigger &+= 1`
     * read by a SwiftUI `.onChange`; here it is observed via a `LaunchedEffect(key =
     * focusUrlBarTrigger)`. Bump with `++` (the `&+=` overflow-add is just `++`).
     */
    var focusUrlBarTrigger: Int by mutableStateOf(0)
        private set

    var zoomedTabID: UUID? by mutableStateOf(null)
        private set

    // MARK: @ObservationIgnored (plain, non-observed)

    private val history: HistoryStore = history

    private var paneLayoutRevisions: MutableMap<UUID, Int> = mutableMapOf()

    private var saveJob: Job? = null
    private var saveGeneration: Long = 0

    private var dragInitialRatios: MutableMap<UUID, Double> = mutableMapOf()
    private var dragInitialSidebarWidth: Double? = null

    /** Owns the debounced save coroutines; cancelled in [dispose]. */
    private val scope = CoroutineScope(Dispatchers.Main.immediate + SupervisorJob())

    init {
        val file = snapshotFile(windowId)
        val snap: WindowSnapshot? = runCatching {
            if (file.exists()) ZzJson.decodeFromString<WindowSnapshot>(file.readText()) else null
        }.getOrNull()

        if (snap != null) {
            val loadedTabs = mutableMapOf<UUID, Tab>()
            for (record in snap.tabs) {
                val tab = Tab(
                    context = context,
                    id = record.id,
                    url = record.url,
                    title = record.title,
                    scrollOffset = ScrollOffset(record.scrollX, record.scrollY),
                    pageZoom = record.pageZoom,
                    requestsDesktopSite = record.requestsDesktopSite,
                    mediaSuspended = record.mediaSuspended,
                    history = history,
                )
                loadedTabs[tab.id] = tab
            }
            tabs.putAll(loadedTabs)

            val seenLeafIDs = mutableSetOf<UUID>()
            root = snap.root.deduplicatingLeafIDs(seenLeafIDs)
            sidebarWidth = snap.sidebarWidth.coerceIn(0.0, 520.0)

            // Back any leaf with no restored record by a blank tab (e.g. ids minted
            // by deduplicatingLeafIDs), exactly like iOS session restore.
            for (tabID in root.tabIDs()) {
                if (tabs[tabID] == null) {
                    tabs[tabID] = Tab(context = context, id = tabID, history = history)
                }
            }

            parked = sanitizedParkedIDs(snap.parked, tabs, root)

            val focused = snap.focusedTabId
            focusedTabID = if (focused != null && root.contains(focused) && tabs[focused] != null) {
                focused
            } else {
                root.tabIDs().firstOrNull { tabs[it] != null }
            }

            // Drop any tab not referenced by the tree or the parked list.
            val referenced = (root.tabIDs() + parked).toSet()
            for (key in tabs.keys.toList()) {
                if (key !in referenced) tabs.remove(key)
            }
        } else {
            val tab = Tab(
                context = context,
                requestsDesktopSite = BrowserPreferences.requestsDesktopSite,
                history = history,
            )
            tabs[tab.id] = tab
            root = BspNode.Leaf(tab.id)
            parked = emptyList()
            focusedTabID = tab.id
            sidebarWidth = 220.0
        }

        installTabCallbacks()
    }

    // MARK: Tab callbacks

    private fun installTabCallbacks() {
        for (tab in tabs.values) {
            attachCallbacks(tab)
        }
    }

    private fun attachCallbacks(tab: Tab) {
        tab.onPersistenceChange = { scheduleSave() }
        tab.onNewWindowRequest = { _, _ -> handleNewWindowRequest(tab.id) }
        tab.onCloseWindowRequest = { closeOrDiscard(tab.id) }
    }

    companion object {
        private const val TAG = "BrowserStore"

        /**
         * Removes ids that no longer have a live tab, that are also in the layout
         * tree (root/parked must stay disjoint), or that repeat. Ports the Swift
         * `sanitizedParkedIDs`.
         */
        private fun sanitizedParkedIDs(parked: List<UUID>, tabs: Map<UUID, Tab>, root: BspNode): List<UUID> {
            val seen = mutableSetOf<UUID>()
            return parked.filter { tabID ->
                if (tabs[tabID] == null || root.contains(tabID) || tabID in seen) {
                    false
                } else {
                    seen.add(tabID)
                    true
                }
            }
        }
    }

    // MARK: Accessors

    fun tab(id: UUID): Tab? = tabs[id]

    fun paneLayoutRevision(tabID: UUID): Int = paneLayoutRevisions[tabID] ?: 0

    fun isMainPaneHost(tabID: UUID): Boolean =
        tabs[tabID] != null && root.contains(tabID) && tabID !in parked

    fun isSidebarPreviewHost(tabID: UUID): Boolean =
        tabs[tabID] != null && tabID in parked && !root.contains(tabID)

    val focusedTab: Tab?
        get() = focusedTabID?.let { tabs[it] }

    val canSplitSelection: Boolean
        get() {
            val sel = selectedGroupID
            if (sel != null && root.containsSplit(sel)) return true
            val focused = focusedTabID ?: return false
            return tabs[focused] != null && root.contains(focused)
        }

    val canSelectParentGroup: Boolean
        get() {
            val sel = selectedGroupID
            if (sel != null && root.containsSplit(sel)) {
                return root.parentSplitID(containingSplit = sel) != null
            }
            val focused = focusedTabID ?: return false
            return root.parentSplitID(containingTab = focused) != null
        }

    val canTransformSelectedGroup: Boolean
        get() = targetGroupID() != null

    /**
     * Open-tab candidates for the omnibox: every tab in the layout + parked,
     * excluding the focused main-pane tab and blank / about:blank tabs. Ports
     * `BrowserStore.openTabSuggestions()`; the result feeds [OmniboxSuggestions].
     */
    fun openTabSuggestions(): List<OmniboxSuggestions.OpenTab> {
        val focused = focusedTabID
        val seen = mutableSetOf<UUID>()
        val result = mutableListOf<OmniboxSuggestions.OpenTab>()
        for (id in root.tabIDs() + parked) {
            if (!seen.add(id)) continue
            if (id == focused && isMainPaneHost(id)) continue
            val tab = tabs[id] ?: continue
            val url = tab.currentUrl.trim()
            if (url.isEmpty() || url.lowercase() == "about:blank") continue
            result.add(OmniboxSuggestions.OpenTab(url = url, title = tab.title, tabId = id))
        }
        return result
    }

    // MARK: Tabs / focus / group selection

    private fun makeBlankTab(): UUID {
        val tab = Tab(
            context = context,
            requestsDesktopSite = BrowserPreferences.requestsDesktopSite,
            history = history,
        )
        attachCallbacks(tab)
        tabs[tab.id] = tab
        return tab.id
    }

    /**
     * Creates a pane-owned WebView (the new-window target) without a configuration.
     * Android's `onCreateWindow` supplies no configuration; the platform attaches
     * the popup navigation to the returned WebView via `WebViewTransport`.
     */
    private fun makeBlankTabForPopup(): UUID = makeBlankTab()

    fun focus(tabID: UUID) {
        selectedGroupID = null
        focusedTabID = tabID
        scheduleSave()
    }

    fun selectGroup(splitID: UUID) {
        if (!root.containsSplit(splitID)) return
        selectedGroupID = splitID
    }

    fun selectParentGroup() {
        val sel = selectedGroupID
        if (sel != null && root.containsSplit(sel)) {
            val parentID = root.parentSplitID(containingSplit = sel) ?: return
            selectedGroupID = parentID
            return
        }
        val focused = focusedTabID ?: return
        val parentID = root.parentSplitID(containingTab = focused) ?: return
        selectedGroupID = parentID
    }

    fun equalizeSelectedGroup() {
        val splitID = targetGroupID() ?: return
        val resizedTabIDs = root.tabIDs(inSplit = splitID) ?: return
        root = root.equalizingRatios(inSplit = splitID)
        selectedGroupID = splitID
        markPaneLayoutsChanged(resizedTabIDs)
        scheduleSave()
    }

    fun rotateSelectedGroup() {
        val splitID = targetGroupID() ?: return
        val resizedTabIDs = root.tabIDs(inSplit = splitID) ?: return
        root = root.togglingAxis(forSplit = splitID)
        selectedGroupID = splitID
        markPaneLayoutsChanged(resizedTabIDs)
        scheduleSave()
    }

    private fun targetGroupID(): UUID? {
        val sel = selectedGroupID
        if (sel != null && root.containsSplit(sel)) return sel
        val focused = focusedTabID ?: return null
        return root.parentSplitID(containingTab = focused)
    }

    fun splitSelection(
        axis: BspNode.Axis,
        side: SplitSide = SplitSide.AFTER,
        loadURL: String? = null,
    ): UUID? {
        val sel = selectedGroupID
        if (sel != null && root.containsSplit(sel)) {
            return splitGroup(sel, axis = axis, side = side, loadURL = loadURL)
        }
        val focused = focusedTabID ?: return null
        return split(focused, axis = axis, side = side, loadURL = loadURL)
    }

    fun split(
        tabID: UUID,
        axis: BspNode.Axis,
        side: SplitSide = SplitSide.AFTER,
        loadURL: String? = null,
    ): UUID? {
        if (tabs[tabID] == null || !root.contains(tabID)) return null

        val newID = makeBlankTab()
        if (loadURL != null) tabs[newID]?.load(loadURL)
        root = root.splitting(tabID, axis = axis, newTabID = newID, side = side)
        focusedTabID = newID
        selectedGroupID = null
        if (zoomedTabID != null) zoomedTabID = null
        if (loadURL == null) focusUrlBarTrigger++
        markPaneLayoutsChanged(listOf(tabID))
        scheduleSave()
        return newID
    }

    fun splitGroup(
        splitID: UUID,
        axis: BspNode.Axis,
        side: SplitSide = SplitSide.AFTER,
        loadURL: String? = null,
    ): UUID? {
        if (!root.containsSplit(splitID)) return null
        val resizedTabIDs = root.tabIDs(inSplit = splitID) ?: return null

        val newID = makeBlankTab()
        if (loadURL != null) tabs[newID]?.load(loadURL)
        root = root.splittingGroup(splitID, axis = axis, newTabID = newID, side = side)
        focusedTabID = newID
        selectedGroupID = null
        if (zoomedTabID != null) zoomedTabID = null
        if (loadURL == null) focusUrlBarTrigger++
        markPaneLayoutsChanged(resizedTabIDs)
        scheduleSave()
        return newID
    }

    fun dropURL(urlString: String, on: UUID, zone: DropZone): Boolean {
        val tabID = on
        if (tabs[tabID] == null || !root.contains(tabID)) return false
        val droppedURL = DroppedUrl.string(fromText = urlString) ?: return false

        return when (zone) {
            DropZone.CENTER -> {
                tabs[tabID]?.load(droppedURL)
                focusedTabID = tabID
                selectedGroupID = null
                scheduleSave()
                true
            }
            DropZone.TOP -> split(tabID, axis = BspNode.Axis.HORIZONTAL, side = SplitSide.BEFORE, loadURL = droppedURL) != null
            DropZone.BOTTOM -> split(tabID, axis = BspNode.Axis.HORIZONTAL, side = SplitSide.AFTER, loadURL = droppedURL) != null
            DropZone.LEFT -> split(tabID, axis = BspNode.Axis.VERTICAL, side = SplitSide.BEFORE, loadURL = droppedURL) != null
            DropZone.RIGHT -> split(tabID, axis = BspNode.Axis.VERTICAL, side = SplitSide.AFTER, loadURL = droppedURL) != null
        }
    }

    fun dropParked(parkedTabID: UUID, on: UUID, zone: DropZone): Boolean {
        val targetTabID = on
        val parkedIdx = parked.indexOf(parkedTabID)
        if (parkedIdx < 0 ||
            tabs[parkedTabID] == null ||
            tabs[targetTabID] == null ||
            !root.contains(targetTabID) ||
            root.contains(parkedTabID) ||
            parkedTabID == targetTabID
        ) {
            return false
        }

        val mutableParked = parked.toMutableList()

        when (zone) {
            DropZone.CENTER -> {
                val targetTab = tabs[targetTabID]
                root = root.replacingLeaf(targetTabID, with = parkedTabID)
                if (zoomedTabID == targetTabID) zoomedTabID = null
                if (targetTab?.isBlank ?: true) {
                    mutableParked.removeAt(parkedIdx)
                    tabs.remove(targetTabID)
                } else {
                    mutableParked[parkedIdx] = targetTabID
                }
            }
            DropZone.TOP -> {
                root = root.splitting(targetTabID, axis = BspNode.Axis.HORIZONTAL, newTabID = parkedTabID, side = SplitSide.BEFORE)
                mutableParked.removeAt(parkedIdx)
                markPaneLayoutsChanged(listOf(targetTabID))
            }
            DropZone.BOTTOM -> {
                root = root.splitting(targetTabID, axis = BspNode.Axis.HORIZONTAL, newTabID = parkedTabID, side = SplitSide.AFTER)
                mutableParked.removeAt(parkedIdx)
                markPaneLayoutsChanged(listOf(targetTabID))
            }
            DropZone.LEFT -> {
                root = root.splitting(targetTabID, axis = BspNode.Axis.VERTICAL, newTabID = parkedTabID, side = SplitSide.BEFORE)
                mutableParked.removeAt(parkedIdx)
                markPaneLayoutsChanged(listOf(targetTabID))
            }
            DropZone.RIGHT -> {
                root = root.splitting(targetTabID, axis = BspNode.Axis.VERTICAL, newTabID = parkedTabID, side = SplitSide.AFTER)
                mutableParked.removeAt(parkedIdx)
                markPaneLayoutsChanged(listOf(targetTabID))
            }
        }

        parked = mutableParked
        focusedTabID = parkedTabID
        selectedGroupID = null
        scheduleSave()
        return true
    }

    fun close(tabID: UUID) {
        if (zoomedTabID == tabID) zoomedTabID = null
        selectedGroupID = null
        val expandedTabIDs = root.tabIDsExpandedByRemoving(tabID)
        val focusAfterClose = root.tabIDToFocusAfterRemoving(tabID)
        val newRoot = root.removing(tabID)
        if (newRoot != null) {
            root = newRoot
            tabs.remove(tabID)?.close()
            if (focusedTabID == tabID) {
                focusedTabID = focusAfterClose ?: newRoot.tabIDs().firstOrNull()
            }
        } else {
            tabs.remove(tabID)?.close()
            val newID = makeBlankTab()
            root = BspNode.Leaf(newID)
            focusedTabID = newID
        }
        markPaneLayoutsChanged(expandedTabIDs)
        scheduleSave()
    }

    // MARK: Divider (ratio) drag

    fun beginRatioDrag(splitID: UUID) {
        selectGroup(splitID)
        // Re-capture the baseline at the start of every gesture: the gesture's
        // translation is cumulative-from-start, so each new drag needs the divider's
        // current ratio as its baseline. Capturing only when null would reuse a stale
        // ratio if a prior drag was cancelled without endRatioDrag firing.
        root.ratio(forSplit = splitID)?.let { dragInitialRatios[splitID] = it }
            ?: dragInitialRatios.remove(splitID)
    }

    fun updateRatioDrag(splitID: UUID, usable: Float, translation: Float) {
        val initial = dragInitialRatios[splitID] ?: return
        if (usable <= 0f) return
        val newSize = usable * initial + translation
        val newRatio = (newSize / usable).coerceIn(0.05, 0.95)
        root = root.settingRatio(newRatio, forSplit = splitID)
    }

    fun endRatioDrag(splitID: UUID) {
        dragInitialRatios.remove(splitID)
        scheduleSave()
    }

    // MARK: Focus movement / sidebar / zoom

    fun moveFocus(direction: Direction) {
        val current = focusedTabID ?: return
        val next = root.neighbor(of = current, direction = direction) ?: return
        selectedGroupID = null
        focusedTabID = next
        if (zoomedTabID != null) zoomedTabID = null
        scheduleSave()
    }

    fun setSidebarWidth(width: Double) {
        sidebarWidth = width.coerceIn(0.0, 520.0)
        scheduleSave()
    }

    fun beginSidebarDrag() {
        if (dragInitialSidebarWidth == null) {
            dragInitialSidebarWidth = sidebarWidth
        }
    }

    fun updateSidebarDrag(translation: Float) {
        val initial = dragInitialSidebarWidth ?: return
        sidebarWidth = (initial - translation.toDouble()).coerceIn(0.0, 520.0)
    }

    fun endSidebarDrag() {
        dragInitialSidebarWidth = null
        scheduleSave()
    }

    // MARK: Focused-tab proxies

    fun reloadFocused() = focusedTab?.reload() ?: Unit
    fun forceReloadFocused() = focusedTab?.forceReload() ?: Unit
    fun backFocused() = focusedTab?.goBack() ?: Unit
    fun forwardFocused() = focusedTab?.goForward() ?: Unit
    fun findInFocused() = focusedTab?.find() ?: Unit
    fun focusURLBar() { focusUrlBarTrigger++ }

    fun zoomInFocused() {
        val tab = focusedTab ?: return
        tab.setPageZoom(PageZoom.zoomedIn(tab.pageZoom))
    }

    fun zoomOutFocused() {
        val tab = focusedTab ?: return
        tab.setPageZoom(PageZoom.zoomedOut(tab.pageZoom))
    }

    fun resetZoomFocused() {
        focusedTab?.setPageZoom(PageZoom.defaultLevel)
    }

    fun toggleZoom() {
        if (zoomedTabID != null) {
            zoomedTabID = null
        } else {
            focusedTabID?.let { zoomedTabID = it }
        }
        selectedGroupID = null
        scheduleSave()
    }

    fun openExternalURL(urlString: String) {
        val tab = focusedTab ?: return
        if (tab.isBlank) {
            tab.load(urlString)
        } else {
            focusedTabID?.let { split(it, axis = BspNode.Axis.VERTICAL, side = SplitSide.AFTER, loadURL = urlString) }
        }
    }

    // MARK: New-window bridge (WebChromeClient.onCreateWindow)

    /**
     * Decides how a page's "open in new window" request (`window.open` /
     * `target=_blank`, surfaced by `WebChromeClient.onCreateWindow`) is handled,
     * returning the [WebView] that should receive the popup navigation, or `null` to
     * suppress it. Ports `BrowserStore.handleNewWindowRequest(from:configuration:
     * navigationAction:)`, routed via [Tab.onNewWindowRequest].
     *
     * DEVIATION (see class doc): Android delivers no request URL or configuration at
     * this point. `.samePane` cannot pre-load the popup target into the source pane;
     * it returns the source pane's own WebView so the platform attaches the popup
     * navigation to it (the same observable effect as the iOS same-pane load). The
     * other policies match iOS: `.sidebar` parks a fresh tab, `.splitRight` splits a
     * fresh pane beside the source, `.block` returns null.
     */
    fun handleNewWindowRequest(sourceTabID: UUID): WebView? =
        when (BrowserPreferences.newWindowPolicy) {
            NewWindowPolicy.SIDEBAR -> openNewWindowInSidebar()
            NewWindowPolicy.SPLIT_RIGHT -> openNewWindowBeside(sourceTabID)
            NewWindowPolicy.SAME_PANE -> tabs[sourceTabID]?.webView
            NewWindowPolicy.BLOCK -> null
        }

    private fun openNewWindowInSidebar(): WebView? {
        val newID = makeBlankTabForPopup()
        parked = listOf(newID) + parked
        if (zoomedTabID != null) zoomedTabID = null
        scheduleSave()
        return tabs[newID]?.webView
    }

    private fun openNewWindowBeside(sourceTabID: UUID): WebView? {
        if (tabs[sourceTabID] == null || !root.contains(sourceTabID)) {
            return openNewWindowInSidebar()
        }
        val newID = makeBlankTabForPopup()
        root = root.splitting(sourceTabID, axis = BspNode.Axis.VERTICAL, newTabID = newID, side = SplitSide.AFTER)
        focusedTabID = newID
        selectedGroupID = null
        if (zoomedTabID != null) zoomedTabID = null
        markPaneLayoutsChanged(listOf(sourceTabID))
        scheduleSave()
        return tabs[newID]?.webView
    }

    // MARK: Parking

    fun parkFocused() {
        val id = focusedTabID ?: return
        park(id)
    }

    fun park(tabID: UUID) {
        val tab = tabs[tabID] ?: return
        if (tab.isBlank || !root.contains(tabID)) return
        if (zoomedTabID == tabID) zoomedTabID = null
        val newID = makeBlankTab()
        root = root.replacingLeaf(tabID, with = newID)
        parked = listOf(tabID) + parked
        focusedTabID = newID
        selectedGroupID = null
        focusUrlBarTrigger++
        scheduleSave()
    }

    fun swapParkedWithFocused(parkedTabID: UUID) {
        val focusedID = focusedTabID ?: return
        dropParked(parkedTabID, on = focusedID, zone = DropZone.CENTER)
    }

    fun discardParked(parkedTabID: UUID) {
        if (zoomedTabID == parkedTabID) zoomedTabID = null
        parked = parked.filter { it != parkedTabID }
        tabs.remove(parkedTabID)?.close()
        scheduleSave()
    }

    private fun closeOrDiscard(tabID: UUID) {
        when {
            tabID in parked -> discardParked(tabID)
            root.contains(tabID) -> close(tabID)
        }
    }

    /**
     * Moves a parked tab from index [from] to before index [to]. Ports the Swift
     * `parked.move(fromOffsets:toOffset:)` (single-element move) semantics: SwiftUI's
     * `toOffset` is the destination index in the pre-removal list, so when moving
     * downward the effective insertion index is one less after removal.
     */
    fun reorderParked(from: Int, to: Int) {
        if (from < 0 || from >= parked.size) return
        val list = parked.toMutableList()
        val item = list.removeAt(from)
        val insertAt = (if (to > from) to - 1 else to).coerceIn(0, list.size)
        list.add(insertAt, item)
        parked = list
        scheduleSave()
    }

    // MARK: Pane-layout revisions

    /**
     * Bumps the host-revision counter for each still-hosted tab so the Compose
     * WebView host knows to re-measure/reparent. Ports `markPaneLayoutsChanged`.
     */
    private fun markPaneLayoutsChanged(tabIDs: Iterable<UUID>) {
        for (tabID in tabIDs) {
            if (tabs[tabID] != null && root.contains(tabID) && tabID !in parked) {
                paneLayoutRevisions[tabID] = (paneLayoutRevisions[tabID] ?: 0) + 1
            }
        }
    }

    // MARK: Persistence

    private fun currentSnapshot(): WindowSnapshot {
        val visibleTabIDs = root.tabIDs()
        val validParked = sanitizedParkedIDs(parked, tabs, root)
        val referenced = (visibleTabIDs + validParked).toSet()
        val focused = focusedTabID
        val validFocusedTabID: UUID? =
            if (focused != null && root.contains(focused) && tabs[focused] != null) {
                focused
            } else {
                visibleTabIDs.firstOrNull { tabs[it] != null }
            }
        val tabRecords = referenced.mapNotNull { id -> tabs[id]?.let { TabRecord(it) } }
        return WindowSnapshot(
            root = root,
            focusedTabId = validFocusedTabID,
            parked = validParked,
            tabs = tabRecords,
            sidebarWidth = sidebarWidth,
        )
    }

    /**
     * Debounced save. Ports the Swift `scheduleSave()`: cancel any pending save,
     * wait 250ms, then build the snapshot on Main (coalescing a burst of persistence
     * notifications into one build), assign the generation on Main so write ordering
     * matches request order, encode, and hand the bytes to the off-main ordered
     * writer.
     */
    private fun scheduleSave() {
        saveJob?.cancel()
        val file = snapshotFile(windowId)
        saveJob = scope.launch {
            delay(250)
            if (!isActive) return@launch
            val snapshot = currentSnapshot()
            saveGeneration += 1
            val generation = saveGeneration
            val data = runCatching { ZzJson.encodeToString(snapshot).toByteArray(Charsets.UTF_8) }
                .getOrNull() ?: return@launch
            withContext(Dispatchers.IO) {
                PersistenceWriteOrderer.write(data, file, generation)
            }
        }
    }

    /**
     * Synchronous flush, for app backgrounding / termination. Ports the Swift
     * `flushSave()`: cancel the debounce, take a higher generation than any pending
     * scheduleSave (so an in-flight off-main write cannot overwrite us), build +
     * encode on Main, and write blocking on the IO dispatcher.
     */
    fun flushSave() {
        saveJob?.cancel()
        saveGeneration += 1
        val generation = saveGeneration
        val data = runCatching { ZzJson.encodeToString(currentSnapshot()).toByteArray(Charsets.UTF_8) }
            .getOrNull() ?: return
        runBlocking(Dispatchers.IO) {
            PersistenceWriteOrderer.write(data, snapshotFile(windowId), generation)
        }
    }

    private fun snapshotFile(windowID: WindowID): File =
        File(context.filesDir, "zz/windows/${windowID.id}/state.json")

    /**
     * Removes this window's entire persisted-state directory. Call ONLY on an
     * intentional user-initiated window close, never on backgrounding/termination.
     * Ports the Swift `deleteSnapshot()`; cancels the in-flight debounced save first
     * so it cannot recreate the file.
     */
    fun deleteSnapshot() {
        saveJob?.cancel()
        val dir = snapshotFile(windowId).parentFile ?: return
        runCatching { dir.deleteRecursively() }
            .onFailure { Log.e(TAG, "deleteSnapshot failed: ${it.message}") }
    }

    /**
     * Cancels the save scope and disposes every live tab. The Android analog of the
     * Swift `deinit` (which had no deterministic equivalent); the owner calls this
     * when tearing down the window (ANDROID_ARCH.md §7).
     */
    fun dispose() {
        saveJob?.cancel()
        scope.coroutineContext[Job]?.cancel()
        for (tab in tabs.values) tab.close()
    }

    // MARK: Layout presets

    /**
     * Captures the current window's arrangement (BSP root + the visible tabs'
     * records) as a named, restorable [LayoutPreset]. Mirrors [currentSnapshot]'s
     * validation so a preset never references a tab that no longer exists. Ports
     * `BrowserStore.captureLayoutPreset(named:)`.
     */
    fun captureLayoutPreset(name: String): LayoutPreset {
        val visibleTabIDs = root.tabIDs()
        val referenced = visibleTabIDs.toSet()
        val focused = focusedTabID
        val validFocusedTabID: UUID? =
            if (focused != null && root.contains(focused) && tabs[focused] != null) {
                focused
            } else {
                visibleTabIDs.firstOrNull { tabs[it] != null }
            }
        val tabRecords = referenced.mapNotNull { id -> tabs[id]?.let { TabRecord(it) } }
        return LayoutPreset(
            name = name,
            root = root,
            focusedTabID = validFocusedTabID,
            tabs = tabRecords,
        )
    }

    /**
     * Restores a preset INTO the current window, fully replacing the current
     * arrangement (parked tabs are window-local and kept). Rebuilds live [Tab]s from
     * the stored records with the same logic as session restore (including
     * deduplicatingLeafIDs), then swaps root/tabs/focus atomically. Ports
     * `BrowserStore.applyLayoutPreset(_:)`.
     */
    fun applyLayoutPreset(preset: LayoutPreset) {
        val loadedTabs = mutableMapOf<UUID, Tab>()
        for (record in preset.tabs) {
            val tab = Tab(
                context = context,
                id = record.id,
                url = record.url,
                title = record.title,
                scrollOffset = ScrollOffset(record.scrollX, record.scrollY),
                pageZoom = record.pageZoom,
                requestsDesktopSite = record.requestsDesktopSite,
                mediaSuspended = record.mediaSuspended,
                history = history,
            )
            attachCallbacks(tab)
            loadedTabs[tab.id] = tab
        }

        val seenLeafIDs = mutableSetOf<UUID>()
        val newRoot = preset.root.deduplicatingLeafIDs(seenLeafIDs)

        // deduplicatingLeafIDs may mint fresh ids for repeated leaves; back those with
        // blank tabs so every leaf has a live Tab, exactly like session restore.
        for (tabID in newRoot.tabIDs()) {
            if (loadedTabs[tabID] == null) {
                val tab = Tab(context = context, id = tabID, history = history)
                attachCallbacks(tab)
                loadedTabs[tabID] = tab
            }
        }

        // Drop any record not referenced by the deduplicated tree.
        val referenced = newRoot.tabIDs().toSet()
        for (key in loadedTabs.keys.toList()) {
            if (key !in referenced) loadedTabs.remove(key)?.close()
        }

        zoomedTabID = null
        selectedGroupID = null
        // Parked tabs are window-local, not part of a preset; leave them intact.
        // Drop every currently-live tab that is not parked, disposing it, then splice
        // in the loaded preset tabs. (Swift: `tabs = tabs.filter { parked.contains }`.)
        val parkedSet = parked.toSet()
        for (key in tabs.keys.toList()) {
            if (key !in parkedSet) tabs.remove(key)?.close()
        }
        for ((id, tab) in loadedTabs) tabs[id] = tab
        root = newRoot
        // A preset may reference a tab id that is currently parked. After the swap such
        // an id lives in both root and parked, violating disjointness; reconcile parked
        // so the loaded leaf wins and the stale parked entry is dropped.
        parked = sanitizedParkedIDs(parked, tabs, root)
        val focused = preset.focusedTabID
        focusedTabID = if (focused != null && newRoot.contains(focused) && tabs[focused] != null) {
            focused
        } else {
            newRoot.tabIDs().firstOrNull { tabs[it] != null }
        }
        focusUrlBarTrigger++
        scheduleSave()
    }
}
