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
                .ignoresSafeArea(.keyboard, edges: .bottom)

            if !matches.isEmpty {
                SuggestionList(
                    suggestions: matches,
                    selectedIndex: selectedSuggestionIndex,
                    onSelect: { commit($0.url) }
                )
                .frame(maxWidth: 720)
                .padding(.horizontal, 16)
                .padding(.bottom, 6)
                .transition(.opacity)
                .allowsHitTesting(urlFocused)
            }

            ShortcutLayer(
                store: store,
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
        .animation(.easeOut(duration: 0.1), value: matches.isEmpty)
        .statusBarHiddenIfAvailable()
        .persistentSystemOverlaysHiddenIfAvailable()
        .onChange(of: store.focusedTabID) { _, _ in
            draft = store.focusedTab?.currentURL ?? ""
            urlFocused = false
            selectedSuggestionIndex = nil
        }
        .onChange(of: store.focusedTab?.currentURL ?? "") { _, new in
            if !urlFocused { draft = new }
        }
        .onChange(of: store.focusURLBarTrigger) { _, _ in
            urlFocused = true
        }
        .onChange(of: urlFocused) { _, focused in
            if focused {
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
    }

    @ViewBuilder
    private var mainContent: some View {
        HStack(spacing: 0) {
            BSPView(node: store.root)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            if !store.parked.isEmpty {
                SplitHandle(axis: .vertical) { delta in
                    store.setSidebarWidth(store.sidebarWidth - delta)
                }
                .transition(.opacity)
                SidebarView()
                    .frame(width: store.sidebarWidth)
                    .clipped()
                    .transition(.move(edge: .trailing).combined(with: .opacity))
            }
        }
        .animation(.easeInOut(duration: 0.22), value: store.parked.isEmpty)
    }

    private func commit(_ value: String) {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, let tab = store.focusedTab else { return }
        tab.load(trimmed)
        draft = tab.currentURL
        urlFocused = false
        selectedSuggestionIndex = nil
    }
}

// MARK: - Shortcut layer (invisible buttons)

private struct ShortcutLayer: View {
    let store: BrowserStore
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
            shortcut("Back",             "[", action: store.backFocused)
            shortcut("Forward",          "]", action: store.forwardFocused)

            shortcut("Split Horizontal", "h", modifiers: [.command, .option]) {
                splitFocused(.horizontal)
            }
            shortcut("Split Vertical",   "v", modifiers: [.command, .option]) {
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
