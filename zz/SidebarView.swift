import SwiftUI
import UniformTypeIdentifiers

private let sidebarReorderCoordinateSpace = "SidebarReorderCoordinateSpace"

struct SidebarView: View {
    @Environment(BrowserStore.self) private var store
    @State private var reorderInsertionIndex: Int?
    @State private var rowFrames: [UUID: CGRect] = [:]

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
                            .background(SidebarRowFrameReader(tabID: tabID))
                            .overlay(alignment: .top) {
                                if reorderInsertionIndex == idx {
                                    SidebarInsertionIndicator()
                                        .offset(y: -5)
                                }
                            }
                            .overlay(alignment: .bottom) {
                                if reorderInsertionIndex == store.parked.count,
                                   idx == store.parked.count - 1 {
                                    SidebarInsertionIndicator()
                                        .offset(y: 5)
                                }
                            }
                    }
                }
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 12)
            .coordinateSpace(name: sidebarReorderCoordinateSpace)
            .onPreferenceChange(SidebarRowFramePreferenceKey.self) { frames in
                rowFrames = frames
            }
            .onDrop(of: [UTType.json.identifier],
                    delegate: SidebarReorderDropDelegate(
                        store: store,
                        parkedIDs: store.parked,
                        rowFrames: rowFrames,
                        insertionIndex: $reorderInsertionIndex
                    ))
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

// MARK: - Reorder preview

private struct SidebarReorderDropDelegate: DropDelegate {
    let store: BrowserStore
    let parkedIDs: [UUID]
    let rowFrames: [UUID: CGRect]
    @Binding var insertionIndex: Int?

    func validateDrop(info: DropInfo) -> Bool {
        info.hasItemsConforming(to: [UTType.json.identifier])
    }

    func dropEntered(info: DropInfo) {
        updateInsertionIndex(info)
    }

    func dropUpdated(info: DropInfo) -> DropProposal? {
        updateInsertionIndex(info)
        return DropProposal(operation: .move)
    }

    func dropExited(info: DropInfo) {
        insertionIndex = nil
    }

    func performDrop(info: DropInfo) -> Bool {
        let destination = candidateInsertionIndex(at: info.location)
        insertionIndex = nil

        guard let provider = info.itemProviders(for: [UTType.json.identifier]).first else {
            return false
        }

        provider.loadDataRepresentation(forTypeIdentifier: UTType.json.identifier) { data, _ in
            guard let data, let ref = Self.tabRef(from: data) else { return }
            Task { @MainActor in
                guard let source = store.parked.firstIndex(of: ref.id) else { return }
                let clampedDestination = destination.clamped(to: 0...store.parked.count)
                store.reorderParked(from: IndexSet(integer: source),
                                    to: clampedDestination)
            }
        }
        return true
    }

    private func updateInsertionIndex(_ info: DropInfo) {
        insertionIndex = candidateInsertionIndex(at: info.location)
    }

    private func candidateInsertionIndex(at location: CGPoint) -> Int {
        for (idx, tabID) in parkedIDs.enumerated() {
            guard let frame = rowFrames[tabID] else { continue }
            if location.y < frame.midY { return idx }
        }
        return parkedIDs.count
    }

    private static func tabRef(from data: Data) -> TabRef? {
        if let ref = try? JSONDecoder().decode(TabRef.self, from: data) {
            return ref
        }
        if let string = String(data: data, encoding: .utf8),
           let id = UUID(uuidString: string.trimmingCharacters(in: .whitespacesAndNewlines)) {
            return TabRef(id: id)
        }
        return nil
    }
}

private struct SidebarInsertionIndicator: View {
    var body: some View {
        HStack(spacing: 6) {
            Circle()
                .fill(Color.accentColor)
                .frame(width: 6, height: 6)
            Capsule()
                .fill(Color.accentColor)
                .frame(height: 3)
        }
        .allowsHitTesting(false)
    }
}

private struct SidebarRowFrameReader: View {
    let tabID: UUID

    var body: some View {
        GeometryReader { proxy in
            Color.clear.preference(
                key: SidebarRowFramePreferenceKey.self,
                value: [tabID: proxy.frame(in: .named(sidebarReorderCoordinateSpace))]
            )
        }
    }
}

private struct SidebarRowFramePreferenceKey: PreferenceKey {
    static var defaultValue: [UUID: CGRect] = [:]

    static func reduce(value: inout [UUID: CGRect],
                       nextValue: () -> [UUID: CGRect]) {
        value.merge(nextValue(), uniquingKeysWith: { _, new in new })
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
