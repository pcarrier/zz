import SwiftUI

struct ContentView: View {
    let windowID: WindowID
    @Environment(HistoryStore.self) private var history

    init(windowID: WindowID?) {
        self.windowID = windowID ?? WindowID()
    }

    var body: some View {
        BrowserScene(windowID: windowID, history: history)
    }
}

private struct BrowserScene: View {
    let windowID: WindowID
    @State private var store: BrowserStore
    @State private var draft: String = ""
    @State private var selectedSuggestionIndex: Int? = nil
    @State private var urlEditingTabID: UUID?
    @State private var sidebarPresented: Bool = false
    @State private var settingsPresented: Bool = false
    @State private var historyPresented: Bool = false
    @State private var saveLayoutPromptPresented: Bool = false
    @State private var saveLayoutName: String = ""
    @State private var matches: [OmniboxItem] = []
    // The suggestion list stays open while EITHER the URL field has focus or the
    // list itself is being interacted with. Tracked separately from urlFocused
    // because clicking/scrolling the list with a pointer steals first-responder
    // from the text field; tying visibility to urlFocused alone would dismiss the
    // list mid-click. Closed only by an explicit dismiss (commit/select/outside).
    @State private var omniboxOpen = false
    @FocusState private var urlFocused: Bool

    @Environment(HistoryStore.self) private var history
    @Environment(FaviconStore.self) private var favicons
    @Environment(LayoutPresetStore.self) private var layouts
    @Environment(\.openWindow) private var openWindow
    @Environment(\.dismissWindow) private var dismissWindow
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    @Environment(\.scenePhase) private var scenePhase

    init(windowID: WindowID, history: HistoryStore) {
        self.windowID = windowID
        _store = State(initialValue: BrowserStore(windowID: windowID, history: history))
    }

    // Ranking the full history (up to ~2000 entries) per read is expensive, so
    // the result is cached in `matches` and only recomputed when an input that
    // affects it changes (draft / focus / open tabs / history). body, BottomBar
    // and the stale-selection check all read the cached value.
    private func computedMatches() -> [OmniboxItem] {
        guard omniboxOpen else { return [] }
        // Fetch up to 100; the suggestion list caps the visible rows and
        // makes the rest scrollable.
        return history.omniboxSuggestions(
            matching: draft,
            openTabs: store.openTabSuggestions(),
            now: .now,
            limit: 100
        )
    }

    // A stable identity for every input that affects `matches`: focus, the typed
    // draft, the open-tab suggestions (a background tab finishing a load shifts
    // its suggestion) and the history size. Driving a single onChange off this
    // keeps the body's modifier chain short enough to type-check.
    private var matchesInputKey: [String] {
        var key = ["\(omniboxOpen)", draft, "\(history.entries.count)"]
        for s in store.openTabSuggestions() {
            key.append("\(s.tabID)|\(s.url)|\(s.title ?? "")")
        }
        return key
    }

    // Recompute the cached suggestions and, if the item under the highlighted
    // index changed (reorder/content change at the same count), clear the stale
    // selection so Return doesn't commit the wrong suggestion. Mutating tracked
    // @State during body evaluation is undefined (gotcha #5), so callers defer
    // this to a Task.
    private func refreshMatches() {
        let oldIDs = matches.map(\.id)
        let new = computedMatches()
        let newIDs = new.map(\.id)
        if oldIDs != newIDs { matches = new }
        if let idx = selectedSuggestionIndex,
           idx >= newIDs.count || idx >= oldIDs.count || oldIDs[idx] != newIDs[idx] {
            selectedSuggestionIndex = nil
        }
    }

    var body: some View {
        ZStack(alignment: .bottom) {
            Color.canvas.ignoresSafeArea()
            mainContent
                .environment(store)

            if omniboxOpen && !matches.isEmpty {
                SuggestionList(
                    suggestions: matches,
                    selectedIndex: selectedSuggestionIndex,
                    onSelect: selectSuggestion
                )
                .frame(maxWidth: 720)
                .padding(.horizontal, 16)
                .padding(.bottom, 6)
                // Keep margin taps from falling through to the focused pane.
                .contentShape(.rect)
                .onTapGesture { }
            }

            ShortcutLayer(
                store: store,
                urlFocused: urlFocused,
                newWindow:    { openWindow(value: WindowID()) },
                closeWindow:  { dismissWindow(value: windowID) }
            )

            #if os(macOS)
            HistoryMouseButtonLayer(
                onBack: {
                    guard store.focusedTab?.canGoBack == true else { return false }
                    store.backFocused()
                    return true
                },
                onForward: {
                    guard store.focusedTab?.canGoForward == true else { return false }
                    store.forwardFocused()
                    return true
                }
            )
            .frame(width: 0, height: 0)
            .accessibilityHidden(true)

            // Plain Cmd-W closes the focused tile. The standard WindowGroup
            // "Close Window" menu item is also bound to Cmd-W and would
            // otherwise win, closing the whole window; a window-scoped local
            // key monitor runs ahead of main-menu key-equivalent dispatch so
            // the tile close wins. Cmd-Shift-W is left to fall through to the
            // standard close.
            CloseTileKeyLayer(
                onCloseTile: {
                    guard let id = store.focusedTabID else { return false }
                    store.close(id)
                    return true
                }
            )
            .frame(width: 0, height: 0)
            .accessibilityHidden(true)
            #endif
        }
        .ignoresTopSafeAreaIfAvailable()
        .safeAreaInset(edge: .bottom, spacing: 0) {
            BottomBar(
                draft: $draft,
                urlFocused: $urlFocused,
                selectedSuggestionIndex: $selectedSuggestionIndex,
                matches: matches,
                sidebarPresented: $sidebarPresented,
                settingsPresented: $settingsPresented,
                historyPresented: $historyPresented,
                onSaveLayout: { saveLayoutName = ""; saveLayoutPromptPresented = true },
                onApplyLayout: { store.applyLayoutPreset($0) },
                onDeleteLayout: { layouts.delete(id: $0) },
                onOutsideURLBarInteraction: dismissOmnibox,
                onCommit: commit,
                onSelect: selectSuggestion
            )
            .environment(store)
            .environment(layouts)
        }
        .statusBarHiddenIfAvailable()
        .onChange(of: store.focusedTabID) { _, _ in
            if !urlFocused { draft = store.focusedTab?.currentURL ?? "" }
            // Deliberately do NOT retarget urlEditingTabID here. While the omnibox
            // is open, clicking a suggestion can leak a mouse-down through to the
            // pane behind it (the WKWebView focus gesture fires), changing
            // focusedTabID; retargeting would then commit the URL into that pane
            // instead of the one active when the omnibox opened. The edit target
            // is pinned at open time (urlFocused/focusURLBarTrigger onChange).
            selectedSuggestionIndex = nil
        }
        .onChange(of: store.focusedTab?.currentURL ?? "") { _, new in
            if !urlFocused { draft = new }
        }
        .onChange(of: store.focusURLBarTrigger) { _, _ in
            urlEditingTabID = store.focusedTabID
            if !urlFocused { urlFocused = true }
        }
        .onChange(of: urlFocused) { _, focused in
            if focused {
                omniboxOpen = true
                urlEditingTabID = store.focusedTabID
                draft = store.focusedTab?.currentURL ?? ""
            } else {
                // Do NOT close the list here: losing first-responder to the list
                // itself (pointer click/scroll) must keep it open. It closes only
                // via an explicit dismiss (commit / select / outside interaction).
                selectedSuggestionIndex = nil
            }
        }
        // Recompute the cached suggestions whenever any ranking input changes.
        // matches can reorder/change content while keeping the same count (e.g. a
        // background tab finishes loading and its open-tab suggestion shifts);
        // refreshMatches clears the highlighted index if the item under it
        // changed so Return doesn't commit the wrong suggestion. Deferred to a
        // Task because mutating tracked @State during body eval is undefined.
        .onChange(of: matchesInputKey) { _, _ in
            Task { @MainActor in refreshMatches() }
        }
        .onChange(of: store.parked.count) { oldCount, newCount in
            if usesCompactLayout && newCount > oldCount {
                sidebarPresented = true
            }
        }
        .sheet(isPresented: $sidebarPresented) {
            SidebarView(
                onSelect: { _ in sidebarPresented = false },
                onInteraction: dismissOmnibox
            )
                .environment(store)
                .environment(favicons)
        }
        .sheet(isPresented: $settingsPresented) {
            SettingsView()
                .environment(history)
        }
        .sheet(isPresented: $historyPresented) {
            HistoryView(onOpen: commit)
                .environment(history)
                .environment(favicons)
        }
        .alert("Save Layout", isPresented: $saveLayoutPromptPresented) {
            TextField("Layout name", text: $saveLayoutName)
            Button("Cancel", role: .cancel) { }
            Button("Save") {
                let name = LayoutPresetLogic.normalizedName(saveLayoutName)
                layouts.add(store.captureLayoutPreset(named: name))
            }
        } message: {
            Text("Name this pane arrangement so you can restore it later.")
        }
        .task { draft = store.focusedTab?.currentURL ?? "" }
        .onChange(of: scenePhase) { _, phase in
            if phase != .active {
                store.flushSave()
                history.flushSave()
                favicons.flushSave()
                layouts.flushSave()
            }
        }
        .onOpenURL { url in
            store.openExternalURL(url.absoluteString)
        }
    }

    @ViewBuilder
    private var mainContent: some View {
        if usesCompactLayout {
            mainPaneContent
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            HStack(spacing: 0) {
                mainPaneContent
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                if !store.parked.isEmpty && store.zoomedTabID == nil {
                    SplitHandle(
                        axis: .vertical,
                        onBegin:     {
                            dismissOmnibox()
                            store.beginSidebarDrag()
                        },
                        onTranslate: { t in store.updateSidebarDrag(translation: t) },
                        onEnd:       { store.endSidebarDrag() }
                    )
                    SidebarView(onInteraction: dismissOmnibox)
                        .frame(width: store.sidebarWidth)
                        .clipped()
                }
            }
        }
    }

    @ViewBuilder
    private var mainPaneContent: some View {
        if let zoomedID = store.zoomedTabID, store.tab(zoomedID) != nil {
            TileView(tabID: zoomedID, onOutsideURLBarInteraction: dismissOmnibox)
                .id(zoomedID)
        } else {
            BSPView(node: store.root, onOutsideURLBarInteraction: dismissOmnibox)
        }
    }

    private var usesCompactLayout: Bool {
        #if os(macOS)
        return false
        #else
        return horizontalSizeClass == .compact
        #endif
    }

    private func commit(_ value: String) {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }

        let targetID = tabIDForCommit()
        guard let targetID, let tab = store.tab(targetID) else { return }
        store.focus(targetID)
        tab.load(trimmed)
        draft = tab.currentURL
        omniboxOpen = false
        urlFocused = false
        urlEditingTabID = targetID
        selectedSuggestionIndex = nil
        tab.focusForBrowsing()
    }

    private func selectSuggestion(_ item: OmniboxItem) {
        switch OmniboxRoute.route(for: item) {
        case .focus(let id):
            guard let tab = store.tab(id) else { commit(item.url); return }
            store.focus(id)
            omniboxOpen = false
            urlFocused = false
            selectedSuggestionIndex = nil
            tab.focusForBrowsing()
        case .load(let url):
            commit(url)
        }
    }

    private func dismissOmnibox() {
        guard omniboxOpen || urlFocused || selectedSuggestionIndex != nil else { return }
        omniboxOpen = false
        urlFocused = false
        selectedSuggestionIndex = nil
        // Deliberately keep urlEditingTabID: selecting a suggestion can leak a
        // mouse-down to the pane behind the list, whose onInteraction calls this
        // dismiss AND refocuses that pane — before the row's mouse-up commit. If
        // we cleared the target here, commit would fall back to that wrongly
        // focused pane. The target only matters at commit and is re-captured on
        // the next omnibox open, so keeping a stale value here is harmless.
        draft = store.focusedTab?.currentURL ?? ""
    }

    private func tabIDForCommit() -> UUID? {
        if let id = urlEditingTabID, store.isMainPaneHost(id) { return id }
        if let id = store.focusedTabID, store.isMainPaneHost(id) { return id }
        return nil
    }

}

private struct ShortcutLayer: View {
    let store: BrowserStore
    let urlFocused: Bool
    let newWindow:   () -> Void
    let closeWindow: () -> Void

    var body: some View {
        ZStack {
            shortcut("New Window",       "n", action: newWindow)
            shortcut("Close Window",     "w", modifiers: [.command, .shift], action: closeWindow)

            shortcut("Park Tile",        "p", modifiers: [.command, .option], action: store.parkFocused)
            // Close Tile (Cmd-W) is handled by CloseTileKeyLayer's local key
            // monitor so it wins over the standard "Close Window" menu item.
            shortcut("Focus URL Bar",    "l", action: store.focusURLBar)

            shortcut("Reload",           "r", action: store.reloadFocused)
            shortcut("Force Reload",     "r", modifiers: [.command, .shift],
                     action: store.forceReloadFocused)
            shortcut("Find on Page",     "f", action: store.findInFocused)
            shortcut("Back",             "[", action: store.backFocused)
            shortcut("Forward",          "]", action: store.forwardFocused)

            // Per-tab page zoom. Plain Cmd-=/Cmd-+ zoom in, Cmd-- zoom out, Cmd-0
            // resets; the Equalize Group binding uses Cmd-Opt-Ctrl-= so these are
            // free.
            shortcut("Zoom In",          "=", action: store.zoomInFocused)
            shortcut("Zoom In (Plus)",   "+", action: store.zoomInFocused)
            shortcut("Zoom Out",         "-", action: store.zoomOutFocused)
            shortcut("Actual Size",      "0", action: store.resetZoomFocused)
            if !urlFocused {
                shortcut("Back Arrow",    .leftArrow, action: store.backFocused)
                shortcut("Forward Arrow", .rightArrow, action: store.forwardFocused)
            }

            Button("Toggle Zoom") { store.toggleZoom() }
                .keyboardShortcut("f", modifiers: [.command, .option, .control])
                .opacity(0)
                .frame(width: 0, height: 0)

            shortcut("Split Horizontal", "\\") {
                splitSelection(.horizontal)
            }
            shortcut("Split Vertical",   "\\", modifiers: [.command, .shift]) {
                splitSelection(.vertical)
            }
            shortcut("Select Parent Group", "p", modifiers: [.command, .option, .control],
                     action: store.selectParentGroup)
            shortcut("Equalize Group", "=", modifiers: [.command, .option, .control],
                     action: store.equalizeSelectedGroup)
            shortcut("Rotate Group", "r", modifiers: [.command, .option, .control],
                     action: store.rotateSelectedGroup)

            if !urlFocused {
                // Gate directional pane focus behind !urlFocused (like Back/Forward
                // arrows above) so arrow keys while editing the URL bar don't silently
                // move pane focus out from under the active edit.
                arrow("Focus Up",    .upArrow,    .up)
                arrow("Focus Down",  .downArrow,  .down)
                arrow("Focus Left",  .leftArrow,  .left)
                arrow("Focus Right", .rightArrow, .right)
            }
        }
        .frame(width: 0, height: 0)
        .accessibilityHidden(true)
    }

    private func shortcut(_ title: String, _ key: KeyEquivalent,
                          modifiers: EventModifiers = .command,
                          action: @escaping () -> Void) -> some View {
        Button(title, action: action)
            .keyboardShortcut(key, modifiers: modifiers)
            .opacity(0)
            .frame(width: 0, height: 0)
    }

    private func arrow(_ title: String, _ key: KeyEquivalent,
                       _ direction: Direction) -> some View {
        Button(title) { store.moveFocus(direction) }
            .keyboardShortcut(key, modifiers: [.command, .option])
            .opacity(0)
            .frame(width: 0, height: 0)
    }

    private func splitSelection(_ axis: BSPNode.Axis) {
        store.splitSelection(axis: axis)
    }
}

#if os(macOS)
private struct HistoryMouseButtonLayer: NSViewRepresentable {
    var onBack: () -> Bool
    var onForward: () -> Bool

    func makeNSView(context: Context) -> HistoryMouseButtonView {
        let view = HistoryMouseButtonView()
        view.onBack = onBack
        view.onForward = onForward
        return view
    }

    func updateNSView(_ view: HistoryMouseButtonView, context: Context) {
        view.onBack = onBack
        view.onForward = onForward
    }
}

private final class HistoryMouseButtonView: NSView {
    var onBack: (() -> Bool)?
    var onForward: (() -> Bool)?

    private var monitor: Any?
    private var handledButtons = Set<Int>()

    deinit {
        if let monitor {
            NSEvent.removeMonitor(monitor)
        }
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        installMonitorIfNeeded()
    }

    private func installMonitorIfNeeded() {
        guard monitor == nil else { return }
        monitor = NSEvent.addLocalMonitorForEvents(
            matching: [.otherMouseDown, .otherMouseUp]
        ) { [weak self] event in
            self?.handle(event) ?? event
        }
    }

    private func handle(_ event: NSEvent) -> NSEvent? {
        guard event.window === window else { return event }

        switch event.type {
        case .otherMouseDown:
            guard performHistoryAction(for: event.buttonNumber) else { return event }
            handledButtons.insert(event.buttonNumber)
            return nil
        case .otherMouseUp:
            guard handledButtons.remove(event.buttonNumber) != nil else { return event }
            return nil
        default:
            return event
        }
    }

    private func performHistoryAction(for buttonNumber: Int) -> Bool {
        switch buttonNumber {
        case 3:
            return onBack?() ?? false
        case 4:
            return onForward?() ?? false
        default:
            return false
        }
    }
}

private struct CloseTileKeyLayer: NSViewRepresentable {
    var onCloseTile: () -> Bool

    func makeNSView(context: Context) -> CloseTileKeyView {
        let view = CloseTileKeyView()
        view.onCloseTile = onCloseTile
        return view
    }

    func updateNSView(_ view: CloseTileKeyView, context: Context) {
        view.onCloseTile = onCloseTile
    }
}

private final class CloseTileKeyView: NSView {
    var onCloseTile: (() -> Bool)?

    private var monitor: Any?

    deinit {
        if let monitor {
            NSEvent.removeMonitor(monitor)
        }
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        installMonitorIfNeeded()
    }

    private func installMonitorIfNeeded() {
        guard monitor == nil else { return }
        monitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown]) { [weak self] event in
            self?.handle(event) ?? event
        }
    }

    private func handle(_ event: NSEvent) -> NSEvent? {
        guard event.window === window else { return event }
        // Plain Cmd-W only; let Cmd-Shift-W (Close Window) fall through.
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        guard flags == .command,
              event.charactersIgnoringModifiers?.lowercased() == "w" else { return event }
        guard onCloseTile?() ?? false else { return event }
        return nil
    }
}
#endif

extension View {
    func statusBarHiddenIfAvailable() -> some View {
        #if canImport(UIKit) && !os(macOS)
        return self.statusBarHidden(true)
        #else
        return self
        #endif
    }

    func ignoresTopSafeAreaIfAvailable() -> some View {
        #if canImport(UIKit) && !os(macOS)
        return self.ignoresSafeArea(.container, edges: .top)
        #else
        return self
        #endif
    }
}
