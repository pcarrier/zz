import Foundation
import SwiftUI
import UniformTypeIdentifiers
import Observation
#if canImport(UIKit)
import UIKit
#elseif canImport(AppKit)
import AppKit
#endif

private enum TileMetrics {
    static let progressLowerBound: Double = 0
    static let progressUpperBound: Double = 1
    static let progressBarHeight: CGFloat = 2

    static let mediaIndicatorOuterPadding: CGFloat = 8
    static let mediaIndicatorInnerPadding: CGFloat = 6
    static let mediaIndicatorBackgroundOpacity: Double = 0.55

    static let navigationErrorSpacing: CGFloat = 10
    static let navigationErrorURLLineLimit = 2
    static let navigationErrorCornerRadius: CGFloat = 8

    static let emptyTileOpacity: Double = 0.05

    static let dropZoneClearDelay: Duration = .milliseconds(900)
    static let dropEdgeThreshold: CGFloat = 0.15
    static let dropIndicatorFillOpacity: Double = 0.18
    static let dropIndicatorStrokeWidth: CGFloat = 2
    static let dropIndicatorCenterInset: CGFloat = 0.18
    static let dropIndicatorSplitFraction: CGFloat = 0.5
    static let fullFraction: CGFloat = 1
}

struct TileView: View {
    let tabID: UUID
    var onOutsideURLBarInteraction: () -> Void = {}

    @Environment(BrowserStore.self) private var store

    @State private var dropState = TileDropState()

    var body: some View {
        Group {
            if let tab = store.tab(tabID) {
                tile(for: tab)
            } else {
                Color.canvas
            }
        }
    }

    @ViewBuilder
    private func tile(for tab: Tab) -> some View {
        let active = store.focusedTabID == tabID && store.selectedGroupID == nil
        Group {
            if tab.isBlank {
                EmptyTileState {
                    store.focus(tabID)
                    store.focusURLBar()
                }
            } else {
                HostedWebView(webView: tab.webView,
                              onInteraction: {
                                  store.focus(tabID)
                                  onOutsideURLBarInteraction()
                              },
                              dropHandler: PaneDropHandler(
                                update: { location, size in
                                  dropState.update(location: location, size: size)
                                },
                                perform: { payload, location, size in
                                  dropState.size = size
                                  let zone = dropZone(at: location, in: size)
                                  performPaneDrop(payload, zone: zone)
                                  dropState.clear()
                                },
                                end: {
                                  dropState.clear()
                                }
                              ),
                              shouldHost: { store.isMainPaneHost(tabID) },
                              layoutRevision: store.paneLayoutRevision(for: tabID))
            }
        }
        .padding(PaneSelectionVisual.reservedInset)
        .background(Color.canvas)
        .clipped()
        .overlay(alignment: .top) {
            if tab.isLoading,
               tab.estimatedProgress > TileMetrics.progressLowerBound,
               tab.estimatedProgress < TileMetrics.progressUpperBound {
                GeometryReader { proxy in
                    Rectangle()
                        .fill(Color.accentColor)
                        .frame(width: proxy.size.width * tab.estimatedProgress,
                               height: TileMetrics.progressBarHeight)
                }
                .frame(height: TileMetrics.progressBarHeight)
                .allowsHitTesting(false)
            }
        }
        .overlay(alignment: .bottomTrailing) {
            if let symbol = mediaIndicatorSymbol(for: tab) {
                MediaIndicator(systemImage: symbol)
                    .padding(TileMetrics.mediaIndicatorOuterPadding)
                    .allowsHitTesting(false)
            }
        }
        .overlay {
            if let zone = dropState.zone {
                DropZoneIndicator(zone: zone)
                    .allowsHitTesting(false)
            }
        }
        .overlay {
            if let error = tab.navigationError {
                NavigationErrorView(error: error) {
                    tab.load(error.url)
                }
            }
        }
        .overlay {
            if active {
                ActivePaneOutline()
                    .allowsHitTesting(false)
            }
        }
        .contentShape(.rect)
        .onTapGesture { store.focus(tabID) }
        .background(
            GeometryReader { proxy in
                Color.clear
                    .onAppear { dropState.size = proxy.size }
                    .onChange(of: proxy.size) { _, new in dropState.size = new }
            }
        )
        .onDrop(of: TileDropDelegate.acceptedContentTypes, delegate: TileDropDelegate(
            store: store, tabID: tabID, state: dropState
        ))
        .onDisappear { dropState.clear() }
    }

    /// SF Symbol for the small media overlay, or nil when nothing should show.
    /// Reflects the user-controlled media-suspension state (no private playback
    /// SPI): a suspended pane shows a pause badge so it's clear which pane was
    /// silenced.
    private func mediaIndicatorSymbol(for tab: Tab) -> String? {
        tab.isMediaSuspended ? "pause.circle.fill" : nil
    }

    @MainActor
    private func performPaneDrop(_ payload: PaneDropPayload, zone: DropZone) {
        switch payload {
        case .url(let urlString):
            store.dropURL(urlString, on: tabID, zone: zone)
        case .parkedTab(let parkedTabID):
            store.dropParked(parkedTabID, on: tabID, zone: zone)
        }
    }
}

private struct NavigationErrorView: View {
    let error: NavigationError
    let retry: () -> Void

    var body: some View {
        VStack(spacing: TileMetrics.navigationErrorSpacing) {
            Image(systemName: "exclamationmark.triangle")
                .font(.title2)
                .foregroundStyle(.secondary)
            Text("Can't Open Page")
                .font(.headline)
            Text(error.url)
                .font(.caption.monospaced())
                .lineLimit(TileMetrics.navigationErrorURLLineLimit)
                .truncationMode(.middle)
                .foregroundStyle(.secondary)
            Text(error.message)
                .font(.caption)
                .multilineTextAlignment(.center)
                .foregroundStyle(.secondary)
            Button("Retry", action: retry)
        }
        .padding()
        .frame(maxWidth: .infinity)
        .background(.regularMaterial,
                    in: RoundedRectangle(cornerRadius: TileMetrics.navigationErrorCornerRadius,
                                         style: .continuous))
        .padding()
    }
}

private struct MediaIndicator: View {
    let systemImage: String

    var body: some View {
        Image(systemName: systemImage)
            .font(.caption.weight(.semibold))
            .foregroundStyle(.white)
            .padding(TileMetrics.mediaIndicatorInnerPadding)
            .background(.black.opacity(TileMetrics.mediaIndicatorBackgroundOpacity), in: Circle())
    }
}

private struct ActivePaneOutline: View {
    var body: some View {
        Rectangle()
            .strokeBorder(Color.textSelection,
                          lineWidth: PaneSelectionVisual.strokeWidth)
    }
}

// MARK: - Empty state

private struct EmptyTileState: View {
    var onTap: () -> Void

    var body: some View {
        Color.secondary.opacity(TileMetrics.emptyTileOpacity)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .contentShape(.rect)
            .onTapGesture(perform: onTap)
    }
}

// MARK: - Drop state

enum DropZone: Equatable { case top, bottom, left, right, center }

@MainActor
@Observable
final class TileDropState {
    var zone: DropZone?
    var size: CGSize = .zero

    @ObservationIgnored
    private var clearTask: Task<Void, Never>?

    func update(location: CGPoint, size: CGSize) {
        self.size = size
        zone = dropZone(at: location, in: size)
        scheduleClear()
    }

    func update(location: CGPoint) {
        zone = dropZone(at: location, in: size)
        scheduleClear()
    }

    func clear() {
        clearTask?.cancel()
        clearTask = nil
        zone = nil
    }

    private func scheduleClear() {
        clearTask?.cancel()
        clearTask = Task { @MainActor in
            try? await Task.sleep(for: TileMetrics.dropZoneClearDelay)
            guard !Task.isCancelled else { return }
            zone = nil
            clearTask = nil
        }
    }
}

private func dropZone(at location: CGPoint, in size: CGSize) -> DropZone {
    guard size.width > 0, size.height > 0 else { return .center }
    let xFrac = location.x / size.width
    let yFrac = location.y / size.height

    let dLeft = xFrac
    let dRight = TileMetrics.fullFraction - xFrac
    let dTop = yFrac
    let dBottom = TileMetrics.fullFraction - yFrac
    let minDist = min(dLeft, dRight, dTop, dBottom)

    if minDist > TileMetrics.dropEdgeThreshold { return .center }
    if minDist == dTop { return .top }
    if minDist == dBottom { return .bottom }
    if minDist == dLeft { return .left }
    return .right
}

private struct TileDropDelegate: DropDelegate {
    let store: BrowserStore
    let tabID: UUID
    let state: TileDropState

    static let acceptedContentTypes: [UTType] = [
        .url,
        .plainText,
        .utf8PlainText,
        .text,
        .json,
    ]

    private static let acceptedTypeIdentifiers = acceptedContentTypes.map(\.identifier)

    private static let urlTypes: [String] = [
        UTType.url.identifier,
        UTType.plainText.identifier,
        UTType.utf8PlainText.identifier,
        UTType.text.identifier,
    ]

    private static let tabTypes: [String] = [
        UTType.json.identifier,
    ]

    func validateDrop(info: DropInfo) -> Bool {
        store.isMainPaneHost(tabID) &&
            info.hasItemsConforming(to: Self.acceptedTypeIdentifiers)
    }

    func dropEntered(info: DropInfo) {
        state.update(location: info.location)
    }

    func dropExited(info: DropInfo) {
        state.clear()
    }

    func dropUpdated(info: DropInfo) -> DropProposal? {
        state.update(location: info.location)
        return DropProposal(operation: info.hasItemsConforming(to: Self.tabTypes) ? .move : .copy)
    }

    func performDrop(info: DropInfo) -> Bool {
        let target = zone(at: info.location)
        state.clear()
        guard store.isMainPaneHost(tabID) else { return false }

        if info.hasItemsConforming(to: Self.tabTypes),
           loadParkedTab(from: info, zone: target) {
            return true
        }
        if loadURL(from: info, zone: target) { return true }
        return false
    }

    private func zone(at location: CGPoint) -> DropZone {
        dropZone(at: location, in: state.size)
    }

    private func loadURL(from info: DropInfo, zone: DropZone) -> Bool {
        if let provider = info.itemProviders(for: [UTType.url.identifier]).first {
            if provider.canLoadObject(ofClass: URL.self) {
                _ = provider.loadObject(ofClass: URL.self) { url, _ in
                    guard let url else { return }
                    apply(.url(url.absoluteString), zone: zone)
                }
                return true
            }
            return loadText(from: provider, typeIdentifier: UTType.url.identifier, zone: zone)
        }

        for type in Self.urlTypes where type != UTType.url.identifier {
            if let provider = info.itemProviders(for: [type]).first {
                return loadText(from: provider, typeIdentifier: type, zone: zone)
            }
        }

        return false
    }

    private func loadParkedTab(from info: DropInfo, zone: DropZone) -> Bool {
        guard let provider = info.itemProviders(for: Self.tabTypes).first else { return false }
        // Capture URL providers synchronously: DropInfo is only valid during this
        // callback, but the NSItemProviders it returns can be retained for the
        // async decode below so we can fall back to a URL load if no parked tab
        // id can be extracted.
        let urlProviders = Self.urlTypes.compactMap { info.itemProviders(for: [$0]).first }
        provider.loadDataRepresentation(forTypeIdentifier: UTType.json.identifier) { data, _ in
            if let data {
                if let ref = try? JSONDecoder().decode(TabRef.self, from: data) {
                    apply(.parkedTab(ref.id), zone: zone)
                    return
                }
                if let string = String(data: data, encoding: .utf8),
                   let id = UUID(uuidString: string.trimmingCharacters(in: .whitespacesAndNewlines)) {
                    apply(.parkedTab(id), zone: zone)
                    return
                }
            }
            loadURL(fromProviders: urlProviders, zone: zone)
        }
        return true
    }

    private func loadURL(fromProviders providers: [NSItemProvider], zone: DropZone) {
        if let provider = providers.first(where: {
            $0.hasItemConformingToTypeIdentifier(UTType.url.identifier)
        }) {
            if provider.canLoadObject(ofClass: URL.self) {
                _ = provider.loadObject(ofClass: URL.self) { url, _ in
                    guard let url else { return }
                    apply(.url(url.absoluteString), zone: zone)
                }
                return
            }
            _ = loadText(from: provider, typeIdentifier: UTType.url.identifier, zone: zone)
            return
        }

        for type in Self.urlTypes where type != UTType.url.identifier {
            if let provider = providers.first(where: { $0.hasItemConformingToTypeIdentifier(type) }) {
                _ = loadText(from: provider, typeIdentifier: type, zone: zone)
                return
            }
        }
    }

    private func loadText(from provider: NSItemProvider,
                          typeIdentifier: String,
                          zone: DropZone) -> Bool {
        provider.loadItem(forTypeIdentifier: typeIdentifier, options: nil) { item, _ in
            guard let text = text(from: item) else { return }
            apply(.url(text), zone: zone)
        }
        return true
    }

    private func text(from item: NSSecureCoding?) -> String? {
        switch item {
        case let url as URL:
            return url.absoluteString
        case let data as Data:
            return String(data: data, encoding: .utf8)
        case let string as String:
            return string
        case let string as NSString:
            return string as String
        default:
            return nil
        }
    }

    private func apply(_ payload: PaneDropPayload, zone: DropZone) {
        let store = self.store
        let tabID = self.tabID
        Task { @MainActor in
            switch payload {
            case .url(let urlString):
                store.dropURL(urlString, on: tabID, zone: zone)
            case .parkedTab(let parkedTabID):
                store.dropParked(parkedTabID, on: tabID, zone: zone)
            }
        }
    }
}

private struct DropZoneIndicator: View {
    let zone: DropZone

    var body: some View {
        GeometryReader { proxy in
            let w = proxy.size.width
            let h = proxy.size.height
            let frame = targetFrame(width: w, height: h)
            Rectangle()
                .fill(Color.accentColor.opacity(TileMetrics.dropIndicatorFillOpacity))
                .overlay(Rectangle().strokeBorder(
                    Color.accentColor,
                    lineWidth: TileMetrics.dropIndicatorStrokeWidth
                ))
                .frame(width: frame.width, height: frame.height)
                .position(x: frame.midX, y: frame.midY)
        }
    }

    private func targetFrame(width w: CGFloat, height h: CGFloat) -> CGRect {
        switch zone {
        case .center:
            let inset = TileMetrics.dropIndicatorCenterInset
            return CGRect(x: w * inset, y: h * inset,
                          width: w * (TileMetrics.fullFraction - 2 * inset),
                          height: h * (TileMetrics.fullFraction - 2 * inset))
        case .top:
            return CGRect(x: 0, y: 0, width: w,
                          height: h * TileMetrics.dropIndicatorSplitFraction)
        case .bottom:
            return CGRect(x: 0, y: h * TileMetrics.dropIndicatorSplitFraction,
                          width: w, height: h * TileMetrics.dropIndicatorSplitFraction)
        case .left:
            return CGRect(x: 0, y: 0,
                          width: w * TileMetrics.dropIndicatorSplitFraction, height: h)
        case .right:
            return CGRect(x: w * TileMetrics.dropIndicatorSplitFraction, y: 0,
                          width: w * TileMetrics.dropIndicatorSplitFraction, height: h)
        }
    }
}
