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
    @FocusState private var urlFocused: Bool

    @Environment(HistoryStore.self) private var history
    @Environment(\.openWindow) private var openWindow
    @Environment(\.dismissWindow) private var dismissWindow
    @Environment(\.scenePhase) private var scenePhase

    init(windowID: WindowID, history: HistoryStore) {
        self.windowID = windowID
        _store = State(initialValue: BrowserStore(windowID: windowID, history: history))
    }

    private var matches: [HistoryEntry] {
        guard urlFocused else { return [] }
        return history.suggestions(matching: draft, limit: 8)
    }

    var body: some View {
        ZStack(alignment: .bottom) {
            Color.canvas.ignoresSafeArea()
            mainContent
                .environment(store)

            if !matches.isEmpty {
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
        }
        .safeAreaInset(edge: .bottom, spacing: 0) {
            BottomBar(
                draft: $draft,
                urlFocused: $urlFocused,
                selectedSuggestionIndex: $selectedSuggestionIndex,
                matches: matches,
                onCommit: commit
            )
            .environment(store)
        }
        .statusBarHiddenIfAvailable()
        .persistentSystemOverlaysHiddenIfAvailable()
        .onChange(of: store.focusedTabID) { _, _ in
            draft = store.focusedTab?.currentURL ?? ""
            if urlFocused { urlEditingTabID = store.focusedTabID }
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
                urlEditingTabID = store.focusedTabID
                draft = store.focusedTab?.currentURL ?? ""
            } else {
                selectedSuggestionIndex = nil
            }
        }
        .onChange(of: matches.count) { _, count in
            if let idx = selectedSuggestionIndex, idx >= count {
                selectedSuggestionIndex = nil
            }
        }
        .task { draft = store.focusedTab?.currentURL ?? "" }
        .onChange(of: scenePhase) { _, phase in
            if phase != .active {
                store.flushSave()
                history.flushSave()
            }
        }
        .onOpenURL { url in
            store.openExternalURL(url.absoluteString)
        }
    }

    @ViewBuilder
    private var mainContent: some View {
        HStack(spacing: 0) {
            Group {
                if let zoomedID = store.zoomedTabID, store.tab(zoomedID) != nil {
                    TileView(tabID: zoomedID).id(zoomedID)
                } else {
                    BSPView(node: store.root)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            if !store.parked.isEmpty && store.zoomedTabID == nil {
                SplitHandle(
                    axis: .vertical,
                    onBegin:     { store.beginSidebarDrag() },
                    onTranslate: { t in store.updateSidebarDrag(translation: t) },
                    onEnd:       { store.endSidebarDrag() }
                )
                SidebarView()
                    .frame(width: store.sidebarWidth)
                    .clipped()
            }
        }
    }

    private func commit(_ value: String) {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }

        let targetID = tabIDForCommit()
        guard let targetID, let tab = store.tab(targetID) else { return }
        store.focus(targetID)
        tab.load(trimmed)
        draft = tab.currentURL
        urlFocused = false
        urlEditingTabID = targetID
        selectedSuggestionIndex = nil
        tab.focusForBrowsing()
    }

    private func selectSuggestion(_ entry: HistoryEntry) {
        commit(entry.url)
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
            shortcut("New Window",       "n", modifiers: [.command, .shift], action: newWindow)
            shortcut("Close Window",     "w", modifiers: [.command, .shift], action: closeWindow)

            shortcut("Park Tile",        "n", action: store.parkFocused)
            shortcut("Close Tile",       "w", action: closeFocused)
            shortcut("Focus URL Bar",    "l", action: store.focusURLBar)

            shortcut("Reload",           "r", action: store.reloadFocused)
            shortcut("Force Reload",     "r", modifiers: [.command, .shift],
                     action: store.forceReloadFocused)
            #if !os(macOS)
            shortcut("Find on Page",     "f", action: store.findInFocused)
            #endif
            shortcut("Back",             "[", action: store.backFocused)
            shortcut("Forward",          "]", action: store.forwardFocused)
            if !urlFocused {
                shortcut("Back Arrow",    .leftArrow, action: store.backFocused)
                shortcut("Forward Arrow", .rightArrow, action: store.forwardFocused)
            }

            Button("Toggle Zoom") { store.toggleZoom() }
                .keyboardShortcut("f", modifiers: [.command, .control])
                .opacity(0)
                .frame(width: 0, height: 0)

            shortcut("Split Horizontal", "d") {
                splitFocused(.horizontal)
            }
            shortcut("Split Vertical",   "d", modifiers: [.command, .shift]) {
                splitFocused(.vertical)
            }

            arrow("Focus Up",    .upArrow,    .up)
            arrow("Focus Down",  .downArrow,  .down)
            arrow("Focus Left",  .leftArrow,  .left)
            arrow("Focus Right", .rightArrow, .right)
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

    private func splitFocused(_ axis: BSPNode.Axis) {
        guard let id = store.focusedTabID else { return }
        store.split(id, axis: axis)
    }

    private func closeFocused() {
        guard let id = store.focusedTabID else { return }
        store.close(id)
    }
}

extension View {
    func statusBarHiddenIfAvailable() -> some View {
        #if canImport(UIKit) && !os(macOS)
        return self.statusBarHidden(true)
        #else
        return self
        #endif
    }

    func persistentSystemOverlaysHiddenIfAvailable() -> some View {
        #if canImport(UIKit) && !os(macOS)
        return self.persistentSystemOverlays(.hidden)
        #else
        return self
        #endif
    }
}
