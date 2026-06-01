import SwiftUI
import WebKit
#if canImport(UIKit)
import UIKit
#elseif canImport(AppKit)
import AppKit
#endif

struct BottomBar: View {
    @Binding var draft: String
    @FocusState.Binding var urlFocused: Bool
    @Binding var selectedSuggestionIndex: Int?
    let matches: [OmniboxItem]
    @Binding var sidebarPresented: Bool
    @Binding var settingsPresented: Bool
    @Binding var historyPresented: Bool
    let onSaveLayout: () -> Void
    let onApplyLayout: (LayoutPreset) -> Void
    let onDeleteLayout: (UUID) -> Void
    let onOutsideURLBarInteraction: () -> Void
    let onCommit: (String) -> Void
    let onSelect: (OmniboxItem) -> Void

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
                    settingsPresented: $settingsPresented,
                    historyPresented: $historyPresented,
                    onSaveLayout: onSaveLayout,
                    onApplyLayout: onApplyLayout,
                    onDeleteLayout: onDeleteLayout,
                    onOutsideURLBarInteraction: onOutsideURLBarInteraction
                )
                BarIconButton(name: "sidebar.right",
                              enabled: !store.parked.isEmpty,
                              action: { runOutsideURLBarInteraction { sidebarPresented = true } },
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
                enabled: tab?.canGoBack ?? false,
                onInteraction: onOutsideURLBarInteraction
            )
            HistoryMenu(
                tab: tab,
                items: Array(tab?.forwardList ?? []),
                icon: "chevron.forward",
                help: "Forward (⌘])",
                primaryAction: { tab?.goForward() },
                enabled: tab?.canGoForward ?? false,
                onInteraction: onOutsideURLBarInteraction
            )
            ReloadControl(tab: tab, onInteraction: onOutsideURLBarInteraction)
        }
    }

    @ViewBuilder
    private func actionButtons(tab: Tab?) -> some View {
        HStack(spacing: 2) {
            BarIconButton(name: store.zoomedTabID == nil
                            ? "arrow.up.left.and.arrow.down.right"
                            : "arrow.down.right.and.arrow.up.left",
                          enabled: tab != nil,
                          action: { runOutsideURLBarInteraction { store.toggleZoom() } },
                          help: store.zoomedTabID == nil
                            ? "Zoom focused tile (⌃⌥⌘F)"
                            : "Restore layout (⌃⌥⌘F)")
            BarIconButton(name: "tray.and.arrow.down",
                          enabled: !(tab?.isBlank ?? true),
                          action: {
                              runOutsideURLBarInteraction {
                                  if let id = store.focusedTabID { store.park(id) }
                              }
                          },
                          help: "Park (⌥⌘P)")
            BarIconButton(name: "rectangle.split.1x2", enabled: store.canSplitSelection,
                          action: {
                              runOutsideURLBarInteraction {
                                  store.splitSelection(axis: .horizontal)
                              }
                          },
                          help: "Horizontal Split (⌘\\)")
            BarIconButton(name: "rectangle.split.2x1", enabled: store.canSplitSelection,
                          action: {
                              runOutsideURLBarInteraction {
                                  store.splitSelection(axis: .vertical)
                              }
                          },
                          help: "Vertical Split (⇧⌘\\)")
            MoreMenu(
                tab: tab,
                isCompact: false,
                settingsPresented: $settingsPresented,
                historyPresented: $historyPresented,
                onSaveLayout: onSaveLayout,
                onApplyLayout: onApplyLayout,
                onDeleteLayout: onDeleteLayout,
                onOutsideURLBarInteraction: onOutsideURLBarInteraction
            )
            BarIconButton(name: "xmark", enabled: tab != nil,
                          action: {
                              runOutsideURLBarInteraction {
                                  if let id = store.focusedTabID { store.close(id) }
                              }
                          },
                          help: "Close tile (⌘W)")
        }
    }

    private func submit() {
        // Keyboard submit must route on kind exactly like click-select so an
        // open-tab row focuses rather than reloads.
        if let idx = selectedSuggestionIndex, idx >= 0, idx < matches.count {
            onSelect(matches[idx])
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

    private func runOutsideURLBarInteraction(_ action: () -> Void) {
        onOutsideURLBarInteraction()
        action()
    }
}

private struct MoreMenu: View {
    let tab: Tab?
    let isCompact: Bool
    @Binding var settingsPresented: Bool
    @Binding var historyPresented: Bool
    let onSaveLayout: () -> Void
    let onApplyLayout: (LayoutPreset) -> Void
    let onDeleteLayout: (UUID) -> Void
    let onOutsideURLBarInteraction: () -> Void

    @Environment(BrowserStore.self) private var store
    @Environment(HistoryStore.self) private var history
    @Environment(LayoutPresetStore.self) private var layouts
    @Environment(\.openWindow) private var openWindow
    @AppStorage(BrowserPreferences.recordHistoryKey) private var recordHistory = true

    var body: some View {
        Menu {
            Button {
                runOutsideURLBarInteraction {
                    openWindow(value: WindowID())
                }
            } label: {
                Label("New Window", systemImage: "macwindow.badge.plus")
            }

            if tab != nil {
                Divider()
                focusedPaneActions
                Divider()
            }

            layoutMenu
            layoutsMenu
            privacyHistoryMenu

            Divider()

            Button {
                runOutsideURLBarInteraction {
                    historyPresented = true
                }
            } label: {
                Label("History", systemImage: "clock.arrow.circlepath")
            }

            Button {
                runOutsideURLBarInteraction {
                    settingsPresented = true
                }
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
    private var focusedPaneActions: some View {
        if let tab, let tabID = store.focusedTabID {
            let actions = TileMenuActions(isBlank: tab.isBlank)

            if actions.canDuplicate {
                Button {
                    runOutsideURLBarInteraction {
                        store.split(tabID, axis: .vertical, side: .after,
                                    loadURL: tab.currentURL)
                    }
                } label: {
                    Label("Duplicate Tile", systemImage: "plus.rectangle.on.rectangle")
                }
            }

            if actions.canCopyURL {
                Button {
                    runOutsideURLBarInteraction {
                        copyURL(tab.currentURL)
                    }
                } label: {
                    Label("Copy URL", systemImage: "doc.on.doc")
                }
            }

            if actions.canReload {
                Button {
                    runOutsideURLBarInteraction {
                        tab.reload()
                    }
                } label: {
                    Label("Reload", systemImage: "arrow.clockwise")
                }
            }

            if actions.canRequestDesktopSite {
                Toggle(isOn: Binding(
                    get: { tab.requestsDesktopSite },
                    set: {
                        onOutsideURLBarInteraction()
                        tab.requestsDesktopSite = $0
                    }
                )) {
                    Label("Request Desktop Site", systemImage: "desktopcomputer")
                }
            }

            if actions.canSuspendMedia {
                Toggle(isOn: Binding(
                    get: { tab.isMediaSuspended },
                    set: {
                        onOutsideURLBarInteraction()
                        tab.isMediaSuspended = $0
                    }
                )) {
                    Label(tab.isMediaSuspended ? "Resume Media" : "Suspend Media",
                          systemImage: tab.isMediaSuspended ? "play.circle" : "pause.circle")
                }
            }

            if actions.canPark {
                Button {
                    runOutsideURLBarInteraction {
                        store.park(tabID)
                    }
                } label: {
                    Label("Park", systemImage: "tray.and.arrow.down")
                }
            }

            if actions.canPark || actions.canCopyURL {
                Divider()
            }

            Button(role: .destructive) {
                runOutsideURLBarInteraction {
                    store.close(tabID)
                }
            } label: {
                Label("Close", systemImage: "xmark")
            }
        }
    }

    @ViewBuilder
    private var layoutMenu: some View {
        Menu {
            Button {
                runOutsideURLBarInteraction {
                    store.selectParentGroup()
                }
            } label: {
                Label("Select Parent Group", systemImage: "square.stack.3d.up")
            }
            .disabled(!store.canSelectParentGroup)

            Button {
                runOutsideURLBarInteraction {
                    store.equalizeSelectedGroup()
                }
            } label: {
                Label("Equalize Group", systemImage: "rectangle.split.2x2")
            }
            .disabled(!store.canTransformSelectedGroup)

            Button {
                runOutsideURLBarInteraction {
                    store.rotateSelectedGroup()
                }
            } label: {
                Label("Rotate Group", systemImage: "rotate.right")
            }
            .disabled(!store.canTransformSelectedGroup)

            if isCompact {
                Divider()

                Button {
                    runOutsideURLBarInteraction {
                        store.splitSelection(axis: .horizontal)
                    }
                } label: {
                    Label("Horizontal Split", systemImage: "rectangle.split.1x2")
                }
                .disabled(!store.canSplitSelection)

                Button {
                    runOutsideURLBarInteraction {
                        store.splitSelection(axis: .vertical)
                    }
                } label: {
                    Label("Vertical Split", systemImage: "rectangle.split.2x1")
                }
                .disabled(!store.canSplitSelection)
            }
        } label: {
            Label("Layout", systemImage: "rectangle.3.group")
        }
    }

    @ViewBuilder
    private var layoutsMenu: some View {
        Menu {
            Button {
                runOutsideURLBarInteraction {
                    onSaveLayout()
                }
            } label: {
                Label("Save Current Layout…", systemImage: "square.and.arrow.down")
            }

            if !layouts.presets.isEmpty {
                Divider()

                ForEach(layouts.presets) { preset in
                    Menu {
                        Button {
                            runOutsideURLBarInteraction {
                                onApplyLayout(preset)
                            }
                        } label: {
                            Label("Apply", systemImage: "rectangle.on.rectangle")
                        }
                        Button(role: .destructive) {
                            runOutsideURLBarInteraction {
                                onDeleteLayout(preset.id)
                            }
                        } label: {
                            Label("Delete", systemImage: "trash")
                        }
                    } label: {
                        Text(preset.name)
                    }
                }
            }
        } label: {
            Label("Layouts", systemImage: "square.grid.2x2")
        }
    }

    @ViewBuilder
    private var privacyHistoryMenu: some View {
        Menu {
            Toggle("Record History", isOn: Binding(
                get: { recordHistory },
                set: {
                    onOutsideURLBarInteraction()
                    recordHistory = $0
                }
            ))

            Button(role: .destructive) {
                runOutsideURLBarInteraction {
                    history.clear()
                }
            } label: {
                Label("Clear History", systemImage: "trash")
            }
        } label: {
            Label("Privacy & History", systemImage: "hand.raised")
        }
    }

    private func copyURL(_ urlString: String) {
        #if canImport(UIKit)
        UIPasteboard.general.string = urlString
        #elseif canImport(AppKit)
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(urlString, forType: .string)
        #endif
    }

    private func runOutsideURLBarInteraction(_ action: () -> Void) {
        onOutsideURLBarInteraction()
        action()
    }
}

struct TileMenuActions: Equatable {
    let canDuplicate: Bool
    let canCopyURL: Bool
    let canReload: Bool
    let canPark: Bool
    let canRequestDesktopSite: Bool
    let canSuspendMedia: Bool

    init(isBlank: Bool) {
        let hasContent = !isBlank
        canDuplicate = hasContent
        canCopyURL = hasContent
        canReload = hasContent
        canPark = hasContent
        canRequestDesktopSite = hasContent
        canSuspendMedia = hasContent
    }
}

private struct ReloadControl: View {
    let tab: Tab?
    let onInteraction: () -> Void
    @State private var suppressNextTap = false
    @State private var suppressResetTask: Task<Void, Never>?

    var body: some View {
        if tab?.isLoading == true {
            BarIconButton(
                name: "xmark",
                enabled: tab != nil,
                action: {
                    onInteraction()
                    tab?.stop()
                },
                help: "Stop"
            )
        } else {
            Button {
                onInteraction()
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
                        onInteraction()
                        suppressNextTap = true
                        tab?.forceReload()
                        suppressResetTask?.cancel()
                        suppressResetTask = Task { @MainActor in
                            try? await Task.sleep(for: .milliseconds(700))
                            guard !Task.isCancelled else { return }
                            suppressNextTap = false
                        }
                    }
            )
            .help("Reload (⌘R), Force Reload (long-press or ⇧⌘R)")
            .onChange(of: tab?.isLoading) { _, _ in
                suppressResetTask?.cancel()
                suppressResetTask = nil
                suppressNextTap = false
            }
            .onChange(of: tab?.id) { _, _ in
                suppressResetTask?.cancel()
                suppressResetTask = nil
                suppressNextTap = false
            }
            .onDisappear {
                suppressResetTask?.cancel()
                suppressResetTask = nil
            }
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
    let onInteraction: () -> Void

    var body: some View {
        Group {
            if enabled && !items.isEmpty {
                Menu {
                    ForEach(items.prefix(25), id: \.self) { item in
                        Button {
                            onInteraction()
                            tab?.go(to: item)
                        } label: {
                            Text(label(for: item))
                        }
                    }
                } label: {
                    iconLabel
                } primaryAction: {
                    onInteraction()
                    primaryAction()
                }
                .menuStyle(.button)
                .buttonStyle(.plain)
                .menuIndicator(.hidden)
                .menuOrder(.fixed)
            } else {
                Button {
                    onInteraction()
                    primaryAction()
                } label: {
                    iconLabel
                }
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
