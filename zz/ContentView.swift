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
    @FocusState private var urlFocused: Bool

    @Environment(HistoryStore.self) private var history
    @Environment(\.openWindow) private var openWindow
    @Environment(\.dismissWindow) private var dismissWindow
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    @Environment(\.scenePhase) private var scenePhase

    init(windowID: WindowID, history: HistoryStore) {
        self.windowID = windowID
        _store = State(initialValue: BrowserStore(windowID: windowID, history: history))
    }

    private var matches: [OmniboxItem] {
        guard urlFocused else { return [] }
        // Fetch up to 100; the suggestion list caps the visible rows and
        // makes the rest scrollable.
        return history.omniboxSuggestions(
            matching: draft,
            openTabs: store.openTabSuggestions(),
            now: .now,
            limit: 100
        )
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
                onCommit: commit,
                onSelect: selectSuggestion
            )
            .environment(store)
        }
        .statusBarHiddenIfAvailable()
        .onChange(of: store.focusedTabID) { _, _ in
            if !urlFocused { draft = store.focusedTab?.currentURL ?? "" }
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
        .onChange(of: store.parked.count) { oldCount, newCount in
            if usesCompactLayout && newCount > oldCount {
                sidebarPresented = true
            }
        }
        .sheet(isPresented: $sidebarPresented) {
            SidebarView { _ in sidebarPresented = false }
                .environment(store)
        }
        .sheet(isPresented: $settingsPresented) {
            SettingsView()
                .environment(history)
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
    }

    @ViewBuilder
    private var mainPaneContent: some View {
        if let zoomedID = store.zoomedTabID, store.tab(zoomedID) != nil {
            TileView(tabID: zoomedID).id(zoomedID)
        } else {
            BSPView(node: store.root)
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
            urlFocused = false
            selectedSuggestionIndex = nil
            tab.focusForBrowsing()
        case .load(let url):
            commit(url)
        }
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

    private func splitSelection(_ axis: BSPNode.Axis) {
        store.splitSelection(axis: axis)
    }

    private func closeFocused() {
        guard let id = store.focusedTabID else { return }
        store.close(id)
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
