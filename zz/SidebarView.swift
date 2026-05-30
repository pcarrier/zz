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
                        SidebarParkedRow(
                            tab: tab,
                            tabID: tabID,
                            index: idx,
                            reorderInsertionIndex: reorderInsertionIndex
                        )
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

private struct SidebarParkedRow: View {
    @Environment(BrowserStore.self) private var store

    let tab: Tab
    let tabID: UUID
    let index: Int
    let reorderInsertionIndex: Int?

    @State private var swipeOffset: CGFloat = 0

    var body: some View {
        ZStack(alignment: .leading) {
            dismissBackground
            rowContent
                .offset(x: swipeOffset)
        }
        .clipped()
        .contentShape(.rect)
        .simultaneousGesture(swipeToDismissGesture)
        .background(SidebarRowFrameReader(tabID: tabID))
        .overlay(alignment: .top) {
            if reorderInsertionIndex == index {
                SidebarInsertionIndicator()
                    .offset(y: -5)
            }
        }
        .overlay(alignment: .bottom) {
            if reorderInsertionIndex == store.parked.count,
               index == store.parked.count - 1 {
                SidebarInsertionIndicator()
                    .offset(y: 5)
            }
        }
    }

    private var rowContent: some View {
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
    }

    private var dismissBackground: some View {
        let progress = min(1, Double(swipeOffset / max(1, CGFloat(store.sidebarWidth))))

        return HStack {
            Image(systemName: "trash")
                .font(.system(size: 18, weight: .medium))
                .foregroundStyle(.white)
                .frame(width: 52, height: 52)
            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color.red.opacity(0.25 + progress * 0.65))
        .opacity(swipeOffset > 0 ? 1 : 0)
    }

    private var swipeToDismissGesture: some Gesture {
        DragGesture(minimumDistance: 14, coordinateSpace: .local)
            .onChanged { value in
                guard isRightSwipe(value) else { return }
                swipeOffset = min(value.translation.width, CGFloat(store.sidebarWidth))
            }
            .onEnded { value in
                guard isRightSwipe(value) else {
                    swipeOffset = 0
                    return
                }
                let threshold = max(72, CGFloat(store.sidebarWidth) * 0.42)
                if value.translation.width > threshold ||
                    value.predictedEndTranslation.width > threshold * 1.2 {
                    store.discardParked(tabID)
                } else {
                    swipeOffset = 0
                }
            }
    }

    private func isRightSwipe(_ value: DragGesture.Value) -> Bool {
        value.translation.width > 0 &&
            value.translation.width > abs(value.translation.height) * 1.25
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
