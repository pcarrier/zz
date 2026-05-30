import SwiftUI
import WebKit

struct BottomBar: View {
    @Binding var draft: String
    @FocusState.Binding var urlFocused: Bool
    @Binding var selectedSuggestionIndex: Int?
    let matches: [HistoryEntry]
    @Binding var sidebarPresented: Bool
    @Binding var settingsPresented: Bool
    let onCommit: (String) -> Void

    @Environment(BrowserStore.self) private var store
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass

    var body: some View {
        let tab = store.focusedTab
        HStack(spacing: 6) {
            navButtons(tab: tab)
            URLBar(
                text: $draft,
                focused: $urlFocused,
                findEnabled: tab != nil && !(tab?.isBlank ?? true),
                onFind: { store.findInFocused() },
                onSubmit: submit
            )
                .onKeyPress(.downArrow) { moveSelection(+1) }
                .onKeyPress(.upArrow)   { moveSelection(-1) }
                .onKeyPress(.escape) {
                    if selectedSuggestionIndex != nil {
                        selectedSuggestionIndex = nil
                        return .handled
                    }
                    if urlFocused {
                        urlFocused = false
                        return .handled
                    }
                    return .ignored
                }
                .onChange(of: draft) { _, _ in
                    selectedSuggestionIndex = nil
                }
                .layoutPriority(1)
            if isCompact {
                MoreMenu(
                    tab: tab,
                    isCompact: isCompact,
                    settingsPresented: $settingsPresented
                )
                BarIconButton(name: "sidebar.right",
                              enabled: !store.parked.isEmpty,
                              action: { sidebarPresented = true },
                              help: "Sidebar")
            } else {
                actionButtons(tab: tab)
            }
        }
        .padding(.horizontal, 10)
        .padding(.top, 6)
        .padding(.bottom, 2)
        .background(.bar, ignoresSafeAreaEdges: .bottom)
        .overlay(alignment: .top) {
            Rectangle().fill(.separator.opacity(0.28)).frame(height: 0.5)
        }
    }

    @ViewBuilder
    private func navButtons(tab: Tab?) -> some View {
        HStack(spacing: 2) {
            HistoryMenu(
                tab: tab,
                items: (tab?.backList ?? []).reversed(),
                icon: "chevron.backward",
                help: "Back (⌘[)",
                primaryAction: { tab?.goBack() },
                enabled: tab?.canGoBack ?? false
            )
            HistoryMenu(
                tab: tab,
                items: Array(tab?.forwardList ?? []),
                icon: "chevron.forward",
                help: "Forward (⌘])",
                primaryAction: { tab?.goForward() },
                enabled: tab?.canGoForward ?? false
            )
            ReloadControl(tab: tab)
        }
    }

    @ViewBuilder
    private func actionButtons(tab: Tab?) -> some View {
        HStack(spacing: 2) {
            BarIconButton(name: store.zoomedTabID == nil
                            ? "arrow.up.left.and.arrow.down.right"
                            : "arrow.down.right.and.arrow.up.left",
                          enabled: tab != nil,
                          action: { store.toggleZoom() },
                          help: store.zoomedTabID == nil
                            ? "Zoom focused tile (⌃⌥⌘F)"
                            : "Restore layout (⌃⌥⌘F)")
            BarIconButton(name: "tray.and.arrow.down",
                          enabled: !(tab?.isBlank ?? true),
                          action: { if let id = store.focusedTabID { store.park(id) } },
                          help: "Park (⌥⌘P)")
            BarIconButton(name: "rectangle.split.1x2", enabled: store.canSplitSelection,
                          action: { store.splitSelection(axis: .horizontal) },
                          help: "Horizontal Split (⌘\\)")
            BarIconButton(name: "rectangle.split.2x1", enabled: store.canSplitSelection,
                          action: { store.splitSelection(axis: .vertical) },
                          help: "Vertical Split (⇧⌘\\)")
            MoreMenu(
                tab: tab,
                isCompact: false,
                settingsPresented: $settingsPresented
            )
            BarIconButton(name: "xmark", enabled: tab != nil,
                          action: { if let id = store.focusedTabID { store.close(id) } },
                          help: "Close tile (⌘W)")
        }
    }

    private func submit() {
        if let idx = selectedSuggestionIndex, idx >= 0, idx < matches.count {
            onCommit(matches[idx].url)
        } else {
            onCommit(draft)
        }
    }

    private func moveSelection(_ delta: Int) -> KeyPress.Result {
        guard !matches.isEmpty else { return .ignored }
        let current = selectedSuggestionIndex ?? -1
        let next = current + delta
        let clamped = max(0, min(matches.count - 1, next))
        selectedSuggestionIndex = clamped
        return .handled
    }

    private var isCompact: Bool {
        #if os(macOS)
        return false
        #else
        return horizontalSizeClass == .compact
        #endif
    }
}

private struct MoreMenu: View {
    let tab: Tab?
    let isCompact: Bool
    @Binding var settingsPresented: Bool

    @Environment(BrowserStore.self) private var store
    @Environment(HistoryStore.self) private var history
    @Environment(\.openWindow) private var openWindow
    @AppStorage(BrowserPreferences.recordHistoryKey) private var recordHistory = true

    var body: some View {
        Menu {
            Button {
                openWindow(value: WindowID())
            } label: {
                Label("New Window", systemImage: "macwindow.badge.plus")
            }

            layoutMenu
            privacyHistoryMenu

            Divider()

            Button {
                settingsPresented = true
            } label: {
                Label("Settings", systemImage: "gearshape")
            }
        } label: {
            Image(systemName: "ellipsis")
                .font(.system(size: 14, weight: .medium))
                .frame(width: 30, height: 30)
                .contentShape(.rect)
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .menuIndicator(.hidden)
        .menuOrder(.fixed)
        .help("More")
    }

    @ViewBuilder
    private var layoutMenu: some View {
        Menu {
            Button {
                store.selectParentGroup()
            } label: {
                Label("Select Parent Group", systemImage: "square.stack.3d.up")
            }
            .disabled(!store.canSelectParentGroup)

            Button {
                store.equalizeSelectedGroup()
            } label: {
                Label("Equalize Group", systemImage: "rectangle.split.2x2")
            }
            .disabled(!store.canTransformSelectedGroup)

            Button {
                store.rotateSelectedGroup()
            } label: {
                Label("Rotate Group", systemImage: "rotate.right")
            }
            .disabled(!store.canTransformSelectedGroup)

            if isCompact {
                Divider()

                Button {
                    if let id = store.focusedTabID { store.park(id) }
                } label: {
                    Label("Park", systemImage: "tray.and.arrow.down")
                }
                .disabled(tab?.isBlank ?? true)

                Button {
                    store.splitSelection(axis: .horizontal)
                } label: {
                    Label("Horizontal Split", systemImage: "rectangle.split.1x2")
                }
                .disabled(!store.canSplitSelection)

                Button {
                    store.splitSelection(axis: .vertical)
                } label: {
                    Label("Vertical Split", systemImage: "rectangle.split.2x1")
                }
                .disabled(!store.canSplitSelection)
                Button(role: .destructive) {
                    if let id = store.focusedTabID { store.close(id) }
                } label: {
                    Label("Close Pane", systemImage: "xmark")
                }
                .disabled(tab == nil)
            }
        } label: {
            Label("Layout", systemImage: "rectangle.3.group")
        }
    }

    @ViewBuilder
    private var privacyHistoryMenu: some View {
        Menu {
            Toggle("Record History", isOn: $recordHistory)

            Button(role: .destructive) {
                history.clear()
            } label: {
                Label("Clear History", systemImage: "trash")
            }
        } label: {
            Label("Privacy & History", systemImage: "hand.raised")
        }
    }
}

private struct ReloadControl: View {
    let tab: Tab?
    @State private var suppressNextTap = false

    var body: some View {
        if tab?.isLoading == true {
            BarIconButton(
                name: "xmark",
                enabled: tab != nil,
                action: { tab?.stop() },
                help: "Stop"
            )
        } else {
            Button {
                if suppressNextTap {
                    suppressNextTap = false
                } else {
                    tab?.reload()
                }
            } label: {
                iconLabel
            }
            .buttonStyle(.plain)
            .disabled(tab == nil)
            .opacity(tab == nil ? 0.35 : 1)
            .simultaneousGesture(
                LongPressGesture(minimumDuration: 0.45)
                    .onEnded { _ in
                        guard tab != nil else { return }
                        suppressNextTap = true
                        tab?.forceReload()
                        Task { @MainActor in
                            try? await Task.sleep(for: .milliseconds(700))
                            suppressNextTap = false
                        }
                    }
            )
            .help("Reload (⌘R), Force Reload (long-press or ⇧⌘R)")
        }
    }

    private var iconLabel: some View {
        Image(systemName: "arrow.clockwise")
            .font(.system(size: 14, weight: .medium))
            .frame(width: 30, height: 30)
            .contentShape(.rect)
    }
}

private struct HistoryMenu: View {
    let tab: Tab?
    let items: [WKBackForwardListItem]
    let icon: String
    let help: String
    let primaryAction: () -> Void
    let enabled: Bool

    var body: some View {
        Group {
            if enabled && !items.isEmpty {
                Menu {
                    ForEach(items.prefix(25), id: \.self) { item in
                        Button {
                            tab?.go(to: item)
                        } label: {
                            Text(label(for: item))
                        }
                    }
                } label: {
                    iconLabel
                } primaryAction: {
                    primaryAction()
                }
                .menuStyle(.button)
                .buttonStyle(.plain)
                .menuIndicator(.hidden)
                .menuOrder(.fixed)
            } else {
                Button(action: primaryAction) { iconLabel }
                    .buttonStyle(.plain)
                    .disabled(!enabled)
            }
        }
        .opacity(enabled ? 1 : 0.35)
        .help(help)
    }

    private var iconLabel: some View {
        Image(systemName: icon)
            .font(.system(size: 14, weight: .medium))
            .frame(width: 30, height: 30)
            .contentShape(.rect)
    }

    private func label(for item: WKBackForwardListItem) -> String {
        if let title = item.title, !title.isEmpty { return title }
        return item.url.host(percentEncoded: false) ?? item.url.absoluteString
    }
}

private struct BarIconButton: View {
    let name: String
    let enabled: Bool
    let action: () -> Void
    var help: String = ""

    var body: some View {
        Button(action: action) {
            Image(systemName: name)
                .font(.system(size: 14, weight: .medium))
                .frame(width: 30, height: 30)
                .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .disabled(!enabled)
        .opacity(enabled ? 1 : 0.35)
        .help(help)
    }
}
