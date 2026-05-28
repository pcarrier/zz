import SwiftUI
import WebKit

struct BottomBar: View {
    @Binding var draft: String
    @FocusState.Binding var urlFocused: Bool
    @Binding var selectedSuggestionIndex: Int?
    let matches: [HistoryEntry]
    let onCommit: (String) -> Void

    @Environment(BrowserStore.self) private var store
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        let tab = store.focusedTab
        HStack(spacing: 8) {
            navButtons(tab: tab)
            URLBar(text: $draft, focused: $urlFocused, onSubmit: submit)
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
                    // typing resets the selection so the user's text is what
                    // submit will commit until they explicitly arrow-pick again.
                    selectedSuggestionIndex = nil
                }
                .layoutPriority(1)
            actionButtons(tab: tab)
        }
        .padding(.horizontal, 12)
        .padding(.top, 12)
        .padding(.bottom, 0)
        .background(.bar)
        .overlay(alignment: .top) {
            Rectangle().fill(.separator.opacity(0.5)).frame(height: 0.5)
        }
    }

    // MARK: Sections

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
            BarIconButton(
                name: (tab?.isLoading == true) ? "xmark" : "arrow.clockwise",
                enabled: tab != nil,
                action: {
                    if tab?.isLoading == true { tab?.stop() } else { tab?.reload() }
                },
                help: tab?.isLoading == true ? "Stop" : "Reload (⌘R)"
            )
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
                            ? "Zoom focused tile (⌃⌘F)"
                            : "Restore layout (⌃⌘F)")
            BarIconButton(name: "tray.and.arrow.down",
                          enabled: !(tab?.isBlank ?? true),
                          action: { if let id = store.focusedTabID { store.park(id) } },
                          help: "Park to sidebar (⌘N)")
            BarIconButton(name: "rectangle.split.1x2", enabled: tab != nil,
                          action: { if let id = store.focusedTabID { store.split(id, axis: .horizontal) } },
                          help: "Split horizontal (⌘D)")
            BarIconButton(name: "rectangle.split.2x1", enabled: tab != nil,
                          action: { if let id = store.focusedTabID { store.split(id, axis: .vertical) } },
                          help: "Split vertical (⇧⌘D)")
            BarIconButton(name: "macwindow.badge.plus", enabled: true,
                          action: { openWindow(value: WindowID()) },
                          help: "New window (⇧⌘N)")
            BarIconButton(name: "xmark", enabled: tab != nil,
                          action: { if let id = store.focusedTabID { store.close(id) } },
                          help: "Close tile (⌘W)")
        }
    }

    // MARK: Actions

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
}

// MARK: - Back/Forward with long-press menu

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
            .frame(width: 32, height: 32)
            .contentShape(.rect)
    }

    private func label(for item: WKBackForwardListItem) -> String {
        if let title = item.title, !title.isEmpty { return title }
        return item.url.host(percentEncoded: false) ?? item.url.absoluteString
    }
}

// MARK: - Icon button

private struct BarIconButton: View {
    let name: String
    let enabled: Bool
    let action: () -> Void
    var help: String = ""

    var body: some View {
        Button(action: action) {
            Image(systemName: name)
                .font(.system(size: 14, weight: .medium))
                .frame(width: 32, height: 32)
                .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .disabled(!enabled)
        .opacity(enabled ? 1 : 0.35)
        .help(help)
    }
}
