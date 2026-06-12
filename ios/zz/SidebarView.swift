import SwiftUI
import UniformTypeIdentifiers

private let sidebarReorderCoordinateSpace = "SidebarReorderCoordinateSpace"

private enum SidebarMetrics {
    static let rowSpacing: CGFloat = 10
    static let horizontalPadding: CGFloat = 8
    static let verticalPadding: CGFloat = 12
    static let insertionIndicatorOffset: CGFloat = 5

    static let previewMinWidth: Double = 80
    static let previewHorizontalInset: Double = 16
    static let dragPreviewOpacity: Double = 0.85

    static let swipeProgressMax: Double = 1
    static let swipeProgressMinDenominator: CGFloat = 1
    static let dismissIconSize: CGFloat = 18
    static let dismissIconFrameSize: CGFloat = 52
    static let dismissBackgroundBaseOpacity: Double = 0.25
    static let dismissBackgroundProgressOpacity: Double = 0.65
    static let visibleOpacity: Double = 1
    static let swipeGestureMinimumDistance: CGFloat = 14
    static let swipeDismissMinDistance: CGFloat = 72
    static let swipeDismissWidthRatio: CGFloat = 0.42
    static let swipePredictionMultiplier: CGFloat = 1.2
    static let horizontalSwipeDominance: CGFloat = 1.25

    static let insertionIndicatorSpacing: CGFloat = 6
    static let insertionDotSize: CGFloat = 6
    static let insertionLineHeight: CGFloat = 3

    static let previewContentSpacing: CGFloat = 6
    static let previewSeparatorOpacity: Double = 0.5
    static let previewSeparatorWidth: CGFloat = 0.5
    static let faviconSize: CGFloat = 14
    static let faviconTopPadding: CGFloat = 1
    static let titleSpacing: CGFloat = 1
    static let staticPreviewSpacing: CGFloat = 8
    static let staticPreviewFaviconSize: CGFloat = 32
}

struct SidebarView: View {
    var onSelect: (UUID) -> Void = { _ in }
    var onInteraction: () -> Void = {}

    @Environment(BrowserStore.self) private var store
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    @State private var reorderInsertionIndex: Int?
    @State private var rowFrames: [UUID: CGRect] = [:]

    var body: some View {
        previewList
            .background(Color.canvasSecondary)
    }

    private var previewList: some View {
        GeometryReader { proxy in
            let sidebarWidth = effectiveSidebarWidth(available: proxy.size.width)

            ScrollView {
                LazyVStack(spacing: SidebarMetrics.rowSpacing) {
                    ForEach(Array(store.parked.enumerated()), id: \.element) { idx, tabID in
                        if let tab = store.tab(tabID) {
                            SidebarParkedRow(
                                tab: tab,
                                tabID: tabID,
                                sidebarWidth: sidebarWidth,
                                index: idx,
                                reorderInsertionIndex: reorderInsertionIndex,
                                onSelect: onSelect,
                                onInteraction: onInteraction
                            )
                        }
                    }
                }
                .padding(.horizontal, SidebarMetrics.horizontalPadding)
                .padding(.vertical, SidebarMetrics.verticalPadding)
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

    private func effectiveSidebarWidth(available: CGFloat) -> Double {
        #if os(macOS)
        return store.sidebarWidth
        #else
        if horizontalSizeClass == .compact {
            return Double(available.clamped(to: AppMetrics.Sidebar.compactWidthRange))
        }
        return store.sidebarWidth
        #endif
    }
}

private struct SidebarParkedRow: View {
    @Environment(BrowserStore.self) private var store

    let tab: Tab
    let tabID: UUID
    let sidebarWidth: Double
    let index: Int
    let reorderInsertionIndex: Int?
    let onSelect: (UUID) -> Void
    let onInteraction: () -> Void

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
                    .offset(y: -SidebarMetrics.insertionIndicatorOffset)
            }
        }
        .overlay(alignment: .bottom) {
            if reorderInsertionIndex == store.parked.count,
               index == store.parked.count - 1 {
                SidebarInsertionIndicator()
                    .offset(y: SidebarMetrics.insertionIndicatorOffset)
            }
        }
    }

    private var rowContent: some View {
        SidebarTilePreview(tab: tab,
                           sidebarWidth: sidebarWidth,
                           shouldHostLiveView: {
                               store.isSidebarPreviewHost(tabID)
                           })
            .onTapGesture {
                onInteraction()
                store.swapParkedWithFocused(tabID)
                onSelect(tabID)
            }
            .contextMenu {
                Button(role: .destructive) {
                    onInteraction()
                    store.discardParked(tabID)
                } label: {
                    Label("Close", systemImage: "xmark")
                }
            }
            .draggable(TabRef(id: tabID)) {
                SidebarTilePreview(tab: tab,
                                   sidebarWidth: sidebarWidth,
                                   isLive: false)
                    .frame(width: max(SidebarMetrics.previewMinWidth,
                                      sidebarWidth - SidebarMetrics.previewHorizontalInset))
                    .opacity(SidebarMetrics.dragPreviewOpacity)
            }
    }

    private var dismissBackground: some View {
        let progress = min(
            SidebarMetrics.swipeProgressMax,
            Double(swipeOffset / max(SidebarMetrics.swipeProgressMinDenominator, CGFloat(sidebarWidth)))
        )

        return HStack {
            Image(systemName: "trash")
                .font(.system(size: SidebarMetrics.dismissIconSize, weight: .medium))
                .foregroundStyle(.white)
                .frame(width: SidebarMetrics.dismissIconFrameSize,
                       height: SidebarMetrics.dismissIconFrameSize)
            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color.red.opacity(
            SidebarMetrics.dismissBackgroundBaseOpacity
                + progress * SidebarMetrics.dismissBackgroundProgressOpacity
        ))
        .opacity(swipeOffset > 0 ? SidebarMetrics.visibleOpacity : AppMetrics.HiddenControl.opacity)
    }

    private var swipeToDismissGesture: some Gesture {
        DragGesture(minimumDistance: SidebarMetrics.swipeGestureMinimumDistance,
                    coordinateSpace: .local)
            .onChanged { value in
                guard isRightSwipe(value) else { return }
                onInteraction()
                swipeOffset = min(value.translation.width, CGFloat(sidebarWidth))
            }
            .onEnded { value in
                guard isRightSwipe(value) else {
                    swipeOffset = 0
                    return
                }
                let threshold = max(
                    SidebarMetrics.swipeDismissMinDistance,
                    CGFloat(sidebarWidth) * SidebarMetrics.swipeDismissWidthRatio
                )
                if value.translation.width > threshold ||
                    value.predictedEndTranslation.width > threshold * SidebarMetrics.swipePredictionMultiplier {
                    // Defer the discard to the next runloop tick. With a pointer
                    // (mouse/trackpad on macOS OR a mouse-enabled iPad) a drag also
                    // starts a .draggable session on the same gesture; discarding
                    // synchronously here deallocates the tab while that session is
                    // still unwinding on pointer-up -> crash. Letting the session
                    // finish first makes the swipe safe regardless of input device.
                    Task { @MainActor in store.discardParked(tabID) }
                } else {
                    swipeOffset = 0
                }
            }
    }

    private func isRightSwipe(_ value: DragGesture.Value) -> Bool {
        value.translation.width > 0 &&
            value.translation.width > abs(value.translation.height) * SidebarMetrics.horizontalSwipeDominance
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
        let dropLocation = info.location
        insertionIndex = nil

        guard let provider = info.itemProviders(for: [UTType.json.identifier]).first else {
            return false
        }

        provider.loadDataRepresentation(forTypeIdentifier: UTType.json.identifier) { data, _ in
            guard let data, let ref = Self.tabRef(from: data) else { return }
            Task { @MainActor in
                guard let source = store.parked.firstIndex(of: ref.id) else { return }
                // Resolve the destination against the live parked list at drop
                // time, since it may have changed since the delegate was built.
                let destination = candidateInsertionIndex(at: dropLocation, in: store.parked)
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

    private func candidateInsertionIndex(at location: CGPoint,
                                         in ids: [UUID]? = nil) -> Int {
        let ids = ids ?? parkedIDs
        for (idx, tabID) in ids.enumerated() {
            guard let frame = rowFrames[tabID] else { continue }
            if location.y < frame.midY { return idx }
        }
        return ids.count
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
        HStack(spacing: SidebarMetrics.insertionIndicatorSpacing) {
            Circle()
                .fill(Color.accentColor)
                .frame(width: SidebarMetrics.insertionDotSize,
                       height: SidebarMetrics.insertionDotSize)
            Capsule()
                .fill(Color.accentColor)
                .frame(height: SidebarMetrics.insertionLineHeight)
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
        let contentWidth = max(SidebarMetrics.previewMinWidth,
                               sidebarWidth - SidebarMetrics.previewHorizontalInset)

        VStack(alignment: .leading, spacing: SidebarMetrics.previewContentSpacing) {
            previewContent
            .frame(width: contentWidth, height: contentWidth)
            .clipShape(.rect)
            .overlay(
                Rectangle()
                    .stroke(.separator.opacity(SidebarMetrics.previewSeparatorOpacity),
                            lineWidth: SidebarMetrics.previewSeparatorWidth)
            )

            HStack(alignment: .top, spacing: SidebarMetrics.previewContentSpacing) {
                FaviconView(url: tab.currentURL, size: SidebarMetrics.faviconSize)
                    .padding(.top, SidebarMetrics.faviconTopPadding)
                VStack(alignment: .leading, spacing: SidebarMetrics.titleSpacing) {
                    Text(displayTitle)
                        .font(.caption.weight(.medium))
                        .lineLimit(1)
                    Text(displayHost)
                        .font(.system(.caption2, design: .monospaced))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
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
                    shouldHost: shouldHostLiveView,
                    reservesTopSafeArea: false
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
            VStack(spacing: SidebarMetrics.staticPreviewSpacing) {
                FaviconView(host: host, size: SidebarMetrics.staticPreviewFaviconSize)
                Text(host)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .padding(.horizontal, SidebarMetrics.horizontalPadding)
            }
        }
    }
}
