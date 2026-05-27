import SwiftUI
import UniformTypeIdentifiers

struct SidebarView: View {
    @Environment(BrowserStore.self) private var store

    var body: some View {
        previewList
            .background(Color.canvasSecondary)
    }

    private var previewList: some View {
        ScrollView {
            LazyVStack(spacing: 10) {
                ForEach(Array(store.parked.enumerated()), id: \.element) { idx, tabID in
                    if let tab = store.tab(tabID) {
                        SidebarTilePreview(tab: tab,
                                           sidebarWidth: store.sidebarWidth,
                                           shouldHostLiveView: {
                                               store.isSidebarPreviewHost(tabID)
                                           })
                            .onTapGesture {
                                store.swapParkedWithFocused(tabID)
                            }
                            .contextMenu {
                                Button(role: .destructive) {
                                    store.discardParked(tabID)
                                } label: {
                                    Label("Close", systemImage: "xmark")
                                }
                            }
                            .draggable(TabRef(id: tabID)) {
                                SidebarTilePreview(tab: tab,
                                                   sidebarWidth: store.sidebarWidth,
                                                   isLive: false)
                                    .frame(width: store.sidebarWidth - 16)
                                    .opacity(0.85)
                            }
                            .dropDestination(for: TabRef.self) { items, _ in
                                guard let ref = items.first,
                                      let source = store.parked.firstIndex(of: ref.id) else {
                                    return false
                                }
                                let destination = idx + (source < idx ? 1 : 0)
                                store.reorderParked(from: IndexSet(integer: source),
                                                    to: destination)
                                return true
                            }
                    }
                }
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 12)
        }
        .scrollIndicators(.never)
    }
}

// MARK: - Drag payload

struct TabRef: Codable, Transferable {
    let id: UUID

    static var transferRepresentation: some TransferRepresentation {
        CodableRepresentation(contentType: .json)
    }
}

// MARK: - Preview cell

struct SidebarTilePreview: View {
    let tab: Tab
    let sidebarWidth: Double
    var isLive: Bool = true
    var shouldHostLiveView: () -> Bool = { true }

    var body: some View {
        let contentWidth = max(80, sidebarWidth - 16)

        VStack(alignment: .leading, spacing: 6) {
            previewContent
            .frame(width: contentWidth, height: contentWidth)
            .clipShape(.rect)
            .overlay(
                Rectangle()
                    .stroke(.separator.opacity(0.5), lineWidth: 0.5)
            )

            VStack(alignment: .leading, spacing: 1) {
                Text(displayTitle)
                    .font(.caption.weight(.medium))
                    .lineLimit(1)
                Text(displayHost)
                    .font(.system(.caption2, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            .frame(maxWidth: contentWidth, alignment: .leading)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentShape(.rect)
    }

    @ViewBuilder
    private var previewContent: some View {
        if isLive {
            ZStack {
                Color.canvas
                HostedWebView(
                    webView: tab.webView,
                    shouldHost: shouldHostLiveView
                )
                    .allowsHitTesting(false)
            }
        } else {
            StaticSidebarPreview(host: displayHost)
        }
    }

    private var displayTitle: String {
        if let title = tab.title, !title.isEmpty { return title }
        return SiteVisual.host(for: tab.currentURL)
    }

    private var displayHost: String {
        SiteVisual.host(for: tab.currentURL)
    }
}

private struct StaticSidebarPreview: View {
    let host: String

    var body: some View {
        ZStack {
            Color.canvasSecondary
            VStack(spacing: 8) {
                Image(systemName: "globe")
                    .font(.system(size: 28, weight: .regular))
                    .foregroundStyle(.secondary)
                Text(host)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .padding(.horizontal, 8)
            }
        }
    }
}
