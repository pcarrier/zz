import Foundation
import CoreGraphics
import Observation
import OSLog
import SwiftUI
import WebKit

private let persistenceLogger = Logger(
    subsystem: Bundle.main.bundleIdentifier ?? "surf.zz",
    category: "Persistence"
)

// MARK: - BSP tree (leaves carry a Tab id)

enum BSPNode: Codable, Identifiable, Hashable {
    enum Axis: String, Codable, Hashable { case horizontal, vertical }

    case leaf(tabID: UUID)
    indirect case split(id: UUID, axis: Axis, ratio: Double, first: BSPNode, second: BSPNode)

    var id: UUID {
        switch self {
        case .leaf(let id): return id
        case .split(let id, _, _, _, _): return id
        }
    }

    func tabIDs() -> [UUID] {
        switch self {
        case .leaf(let id): return [id]
        case .split(_, _, _, let a, let b): return a.tabIDs() + b.tabIDs()
        }
    }

    func contains(_ tabID: UUID) -> Bool {
        switch self {
        case .leaf(let id): return id == tabID
        case .split(_, _, _, let a, let b): return a.contains(tabID) || b.contains(tabID)
        }
    }

    func containsSplit(_ splitID: UUID) -> Bool {
        switch self {
        case .leaf:
            return false
        case .split(let id, _, _, let a, let b):
            return id == splitID || a.containsSplit(splitID) || b.containsSplit(splitID)
        }
    }

    func tabIDs(inSplit splitID: UUID) -> [UUID]? {
        switch self {
        case .leaf:
            return nil
        case .split(let id, _, _, let a, let b):
            if id == splitID { return tabIDs() }
            return a.tabIDs(inSplit: splitID) ?? b.tabIDs(inSplit: splitID)
        }
    }

    func parentSplitID(containingTab tabID: UUID) -> UUID? {
        switch self {
        case .leaf:
            return nil
        case .split(let id, _, _, let a, let b):
            if a.contains(tabID) {
                return a.parentSplitID(containingTab: tabID) ?? id
            }
            if b.contains(tabID) {
                return b.parentSplitID(containingTab: tabID) ?? id
            }
            return nil
        }
    }

    func parentSplitID(containingSplit splitID: UUID) -> UUID? {
        switch self {
        case .leaf:
            return nil
        case .split(let id, _, _, let a, let b):
            if a.id == splitID || b.id == splitID { return id }
            return a.parentSplitID(containingSplit: splitID) ??
                   b.parentSplitID(containingSplit: splitID)
        }
    }

    func replacingLeaf(_ tabID: UUID, with newTabID: UUID) -> BSPNode {
        switch self {
        case .leaf(let id):
            return id == tabID ? .leaf(tabID: newTabID) : self
        case .split(let id, let axis, let ratio, let a, let b):
            return .split(id: id, axis: axis, ratio: ratio,
                          first: a.replacingLeaf(tabID, with: newTabID),
                          second: b.replacingLeaf(tabID, with: newTabID))
        }
    }

    func splitting(_ tabID: UUID, axis newAxis: Axis,
                   newTabID: UUID, side: SplitSide = .after) -> BSPNode {
        switch self {
        case .leaf(let id):
            guard id == tabID else { return self }
            let existing = BSPNode.leaf(tabID: id)
            let fresh = BSPNode.leaf(tabID: newTabID)
            return .split(
                id: UUID(), axis: newAxis, ratio: 0.5,
                first:  side == .before ? fresh : existing,
                second: side == .before ? existing : fresh
            )
        case .split(let id, let axis, let ratio, let a, let b):
            return .split(id: id, axis: axis, ratio: ratio,
                          first: a.splitting(tabID, axis: newAxis,
                                             newTabID: newTabID, side: side),
                          second: b.splitting(tabID, axis: newAxis,
                                              newTabID: newTabID, side: side))
        }
    }

    func splittingGroup(_ splitID: UUID, axis newAxis: Axis,
                        newTabID: UUID, side: SplitSide = .after) -> BSPNode {
        switch self {
        case .leaf:
            return self
        case .split(let id, let axis, let ratio, let a, let b):
            if id == splitID {
                let existing = self
                let fresh = BSPNode.leaf(tabID: newTabID)
                return .split(
                    id: UUID(), axis: newAxis, ratio: 0.5,
                    first:  side == .before ? fresh : existing,
                    second: side == .before ? existing : fresh
                )
            }
            return .split(id: id, axis: axis, ratio: ratio,
                          first: a.splittingGroup(splitID, axis: newAxis,
                                                  newTabID: newTabID, side: side),
                          second: b.splittingGroup(splitID, axis: newAxis,
                                                   newTabID: newTabID, side: side))
        }
    }

    func removing(_ tabID: UUID) -> BSPNode? {
        switch self {
        case .leaf(let id):
            return id == tabID ? nil : self
        case .split(let id, let axis, let ratio, let a, let b):
            if a.contains(tabID) {
                guard let newA = a.removing(tabID) else { return b }
                return .split(id: id, axis: axis, ratio: ratio, first: newA, second: b)
            }
            if b.contains(tabID) {
                guard let newB = b.removing(tabID) else { return a }
                return .split(id: id, axis: axis, ratio: ratio, first: a, second: newB)
            }
            return self
        }
    }

    func tabIDsExpandedByRemoving(_ tabID: UUID) -> [UUID] {
        switch self {
        case .leaf:
            return []
        case .split(_, _, _, let a, let b):
            if a.contains(tabID) {
                if case .leaf = a { return b.tabIDs() }
                return a.tabIDsExpandedByRemoving(tabID)
            }
            if b.contains(tabID) {
                if case .leaf = b { return a.tabIDs() }
                return b.tabIDsExpandedByRemoving(tabID)
            }
            return []
        }
    }

    func tabIDToFocusAfterRemoving(_ tabID: UUID) -> UUID? {
        switch self {
        case .leaf:
            return nil
        case .split(_, let axis, _, let a, let b):
            if a.contains(tabID) {
                if case .leaf = a {
                    let direction: Direction = axis == .horizontal ? .down : .right
                    return b.edgeLeaf(opposite: direction)
                }
                return a.tabIDToFocusAfterRemoving(tabID)
            }
            if b.contains(tabID) {
                if case .leaf = b {
                    let direction: Direction = axis == .horizontal ? .up : .left
                    return a.edgeLeaf(opposite: direction)
                }
                return b.tabIDToFocusAfterRemoving(tabID)
            }
            return nil
        }
    }

    func settingRatio(_ ratio: Double, for splitID: UUID) -> BSPNode {
        switch self {
        case .leaf: return self
        case .split(let id, let axis, let r, let a, let b):
            if id == splitID {
                return .split(id: id, axis: axis, ratio: ratio.clamped(to: 0.05...0.95),
                              first: a, second: b)
            }
            return .split(id: id, axis: axis, ratio: r,
                          first: a.settingRatio(ratio, for: splitID),
                          second: b.settingRatio(ratio, for: splitID))
        }
    }

    func equalizingRatios(in splitID: UUID) -> BSPNode {
        switch self {
        case .leaf:
            return self
        case .split(let id, let axis, let ratio, let a, let b):
            if id == splitID { return equalizingAllRatios() }
            return .split(id: id, axis: axis, ratio: ratio,
                          first: a.equalizingRatios(in: splitID),
                          second: b.equalizingRatios(in: splitID))
        }
    }

    private func equalizingAllRatios() -> BSPNode {
        switch self {
        case .leaf:
            return self
        case .split(let id, let axis, _, let a, let b):
            return .split(id: id, axis: axis, ratio: 0.5,
                          first: a.equalizingAllRatios(),
                          second: b.equalizingAllRatios())
        }
    }

    func togglingAxis(for splitID: UUID) -> BSPNode {
        switch self {
        case .leaf:
            return self
        case .split(let id, let axis, let ratio, let a, let b):
            let nextAxis: Axis = axis == .horizontal ? .vertical : .horizontal
            return .split(id: id,
                          axis: id == splitID ? nextAxis : axis,
                          ratio: ratio,
                          first: a.togglingAxis(for: splitID),
                          second: b.togglingAxis(for: splitID))
        }
    }

    func ratio(forSplit splitID: UUID) -> Double? {
        switch self {
        case .leaf: return nil
        case .split(let id, _, let r, let a, let b):
            if id == splitID { return r }
            return a.ratio(forSplit: splitID) ?? b.ratio(forSplit: splitID)
        }
    }

    func neighbor(of tabID: UUID, direction: Direction) -> UUID? {
        var path: [(node: BSPNode, fromFirst: Bool)] = []
        guard pathTo(tabID, path: &path) else { return nil }
        for step in path.reversed() {
            if case .split(_, let axis, _, let a, let b) = step.node {
                let aligned = (axis == .horizontal && (direction == .up || direction == .down)) ||
                              (axis == .vertical && (direction == .left || direction == .right))
                guard aligned else { continue }
                let goSecond = (direction == .down || direction == .right)
                if step.fromFirst == goSecond {
                    let target = step.fromFirst ? b : a
                    return target.edgeLeaf(opposite: direction)
                }
            }
        }
        return nil
    }

    private func pathTo(_ tabID: UUID, path: inout [(node: BSPNode, fromFirst: Bool)]) -> Bool {
        switch self {
        case .leaf(let id):
            return id == tabID
        case .split(_, _, _, let a, let b):
            if a.pathTo(tabID, path: &path) {
                path.append((self, true))
                return true
            }
            if b.pathTo(tabID, path: &path) {
                path.append((self, false))
                return true
            }
            return false
        }
    }

    private func edgeLeaf(opposite direction: Direction) -> UUID {
        switch self {
        case .leaf(let id): return id
        case .split(_, let axis, _, let a, let b):
            let aligned = (axis == .horizontal && (direction == .up || direction == .down)) ||
                          (axis == .vertical && (direction == .left || direction == .right))
            if aligned {
                let pickFirst = (direction == .down || direction == .right)
                return (pickFirst ? a : b).edgeLeaf(opposite: direction)
            }
            return a.edgeLeaf(opposite: direction)
        }
    }
}

enum Direction { case up, down, left, right }

enum SplitSide { case before, after }

extension Comparable {
    func clamped(to range: ClosedRange<Self>) -> Self {
        min(max(self, range.lowerBound), range.upperBound)
    }
}

// MARK: - Window identity

struct WindowID: Hashable, Codable {
    let id: UUID
    init(_ id: UUID = UUID()) { self.id = id }
}

// MARK: - Persistence shape

private struct WindowSnapshot: Codable {
    var root: BSPNode
    var focusedTabID: UUID?
    var parked: [UUID]
    var tabs: [TabRecord]
    var sidebarWidth: Double

    enum CodingKeys: String, CodingKey {
        case root, focusedTabID, parked, tabs, sidebarWidth
    }

    init(root: BSPNode, focusedTabID: UUID?, parked: [UUID], tabs: [TabRecord], sidebarWidth: Double) {
        self.root = root
        self.focusedTabID = focusedTabID
        self.parked = parked
        self.tabs = tabs
        self.sidebarWidth = sidebarWidth
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        root = try c.decode(BSPNode.self, forKey: .root)
        focusedTabID = try c.decodeIfPresent(UUID.self, forKey: .focusedTabID)
        parked = try c.decodeIfPresent([UUID].self, forKey: .parked) ?? []
        tabs = try c.decodeIfPresent([TabRecord].self, forKey: .tabs) ?? []
        sidebarWidth = try c.decodeIfPresent(Double.self, forKey: .sidebarWidth) ?? 220
    }
}

// MARK: - Per-window store

@MainActor
@Observable
final class BrowserStore {
    let windowID: WindowID

    var root: BSPNode
    var focusedTabID: UUID?
    var selectedGroupID: UUID?
    var parked: [UUID] = []
    var sidebarWidth: Double = 220

    var tabs: [UUID: Tab] = [:]

    var focusURLBarTrigger: Int = 0
    var zoomedTabID: UUID?
    private var paneLayoutRevisions: [UUID: Int] = [:]

    @ObservationIgnored
    private weak var history: HistoryStore?

    @ObservationIgnored
    private var saveTask: Task<Void, Never>?

    init(windowID: WindowID, history: HistoryStore) {
        self.windowID = windowID
        self.history = history
        let url = Self.snapshotFile(for: windowID)
        if let data = try? Data(contentsOf: url),
           let snap = try? JSONDecoder().decode(WindowSnapshot.self, from: data) {
            var loadedTabs: [UUID: Tab] = [:]
            for record in snap.tabs {
                let tab = Tab(id: record.id, url: record.url,
                              title: record.title,
                              scrollOffset: CGPoint(x: record.scrollX, y: record.scrollY),
                              history: history)
                loadedTabs[tab.id] = tab
            }
            self.tabs = loadedTabs
            self.root = snap.root
            self.sidebarWidth = snap.sidebarWidth
            for tabID in root.tabIDs() where tabs[tabID] == nil {
                tabs[tabID] = Tab(id: tabID, history: history)
            }
            self.parked = Self.sanitizedParkedIDs(snap.parked, tabs: tabs, root: root)
            if let focused = snap.focusedTabID,
               root.contains(focused),
               tabs[focused] != nil {
                self.focusedTabID = focused
            } else {
                self.focusedTabID = root.tabIDs().first { tabs[$0] != nil }
            }
            let referenced = Set(root.tabIDs() + parked)
            for key in Array(tabs.keys) where !referenced.contains(key) {
                tabs[key] = nil
            }
        } else {
            let tab = Tab(history: history)
            self.tabs = [tab.id: tab]
            self.root = .leaf(tabID: tab.id)
            self.parked = []
            self.focusedTabID = tab.id
            self.sidebarWidth = 220
        }
        installTabCallbacks()
    }

    private func installTabCallbacks() {
        for tab in tabs.values {
            attachCallbacks(to: tab)
        }
    }

    private func attachCallbacks(to tab: Tab) {
        tab.onPersistenceChange = { [weak self] in
            self?.scheduleSave()
        }
        tab.onNewWindowRequest = { [weak self] configuration, navigationAction in
            self?.handleNewWindowRequest(
                from: tab.id,
                configuration: configuration,
                navigationAction: navigationAction
            )
        }
        tab.onCloseWindowRequest = { [weak self, weak tab] in
            guard let tab else { return }
            self?.closeOrDiscard(tab.id)
        }
    }

    private static func sanitizedParkedIDs(_ parked: [UUID], tabs: [UUID: Tab], root: BSPNode) -> [UUID] {
        var seen = Set<UUID>()
        return parked.filter { tabID in
            guard tabs[tabID] != nil,
                  !root.contains(tabID),
                  !seen.contains(tabID) else {
                return false
            }
            seen.insert(tabID)
            return true
        }
    }

    // MARK: Accessors

    func tab(_ id: UUID) -> Tab? { tabs[id] }

    func paneLayoutRevision(for tabID: UUID) -> Int {
        paneLayoutRevisions[tabID, default: 0]
    }

    func isMainPaneHost(_ tabID: UUID) -> Bool {
        tabs[tabID] != nil && root.contains(tabID) && !parked.contains(tabID)
    }

    func isSidebarPreviewHost(_ tabID: UUID) -> Bool {
        tabs[tabID] != nil && parked.contains(tabID) && !root.contains(tabID)
    }

    var focusedTab: Tab? {
        guard let id = focusedTabID else { return nil }
        return tabs[id]
    }

    var canSplitSelection: Bool {
        if let selectedGroupID, root.containsSplit(selectedGroupID) { return true }
        guard let focusedTabID else { return false }
        return tabs[focusedTabID] != nil && root.contains(focusedTabID)
    }

    var canSelectParentGroup: Bool {
        if let selectedGroupID, root.containsSplit(selectedGroupID) {
            return root.parentSplitID(containingSplit: selectedGroupID) != nil
        }
        guard let focusedTabID else { return false }
        return root.parentSplitID(containingTab: focusedTabID) != nil
    }

    var canTransformSelectedGroup: Bool {
        targetGroupID() != nil
    }

    // MARK: Tabs

    @discardableResult
    private func makeBlankTab(configuration: WKWebViewConfiguration? = nil) -> UUID {
        let tab = Tab(configuration: configuration, history: history)
        attachCallbacks(to: tab)
        tabs[tab.id] = tab
        return tab.id
    }

    func focus(_ tabID: UUID) {
        selectedGroupID = nil
        focusedTabID = tabID
        scheduleSave()
    }

    func selectGroup(_ splitID: UUID) {
        guard root.containsSplit(splitID) else { return }
        selectedGroupID = splitID
    }

    func selectParentGroup() {
        if let selectedGroupID, root.containsSplit(selectedGroupID) {
            guard let parentID = root.parentSplitID(containingSplit: selectedGroupID) else { return }
            self.selectedGroupID = parentID
            return
        }

        guard let focusedTabID,
              let parentID = root.parentSplitID(containingTab: focusedTabID) else {
            return
        }
        selectedGroupID = parentID
    }

    func equalizeSelectedGroup() {
        guard let splitID = targetGroupID(),
              let resizedTabIDs = root.tabIDs(inSplit: splitID) else { return }
        root = root.equalizingRatios(in: splitID)
        selectedGroupID = splitID
        markPaneLayoutsChanged(resizedTabIDs)
        scheduleSave()
    }

    func rotateSelectedGroup() {
        guard let splitID = targetGroupID(),
              let resizedTabIDs = root.tabIDs(inSplit: splitID) else { return }
        root = root.togglingAxis(for: splitID)
        selectedGroupID = splitID
        markPaneLayoutsChanged(resizedTabIDs)
        scheduleSave()
    }

    private func targetGroupID() -> UUID? {
        if let selectedGroupID, root.containsSplit(selectedGroupID) {
            return selectedGroupID
        }
        guard let focusedTabID else { return nil }
        return root.parentSplitID(containingTab: focusedTabID)
    }

    @discardableResult
    func splitSelection(axis: BSPNode.Axis,
                        side: SplitSide = .after,
                        loadURL: String? = nil) -> UUID? {
        if let selectedGroupID, root.containsSplit(selectedGroupID) {
            return splitGroup(selectedGroupID, axis: axis, side: side, loadURL: loadURL)
        }
        guard let focusedTabID else { return nil }
        return split(focusedTabID, axis: axis, side: side, loadURL: loadURL)
    }

    @discardableResult
    func split(_ tabID: UUID, axis: BSPNode.Axis,
               side: SplitSide = .after, loadURL: String? = nil) -> UUID? {
        guard tabs[tabID] != nil, root.contains(tabID) else { return nil }

        let newID = makeBlankTab()
        if let loadURL { tabs[newID]?.load(loadURL) }
        root = root.splitting(tabID, axis: axis, newTabID: newID, side: side)
        focusedTabID = newID
        selectedGroupID = nil
        if loadURL == nil { focusURLBarTrigger &+= 1 }
        markPaneLayoutsChanged([tabID])
        scheduleSave()
        return newID
    }

    @discardableResult
    func splitGroup(_ splitID: UUID, axis: BSPNode.Axis,
                    side: SplitSide = .after, loadURL: String? = nil) -> UUID? {
        guard root.containsSplit(splitID),
              let resizedTabIDs = root.tabIDs(inSplit: splitID) else {
            return nil
        }

        let newID = makeBlankTab()
        if let loadURL { tabs[newID]?.load(loadURL) }
        root = root.splittingGroup(splitID, axis: axis, newTabID: newID, side: side)
        focusedTabID = newID
        selectedGroupID = nil
        if loadURL == nil { focusURLBarTrigger &+= 1 }
        markPaneLayoutsChanged(resizedTabIDs)
        scheduleSave()
        return newID
    }

    @discardableResult
    func dropURL(_ urlString: String, on tabID: UUID, zone: DropZone) -> Bool {
        guard tabs[tabID] != nil,
              root.contains(tabID),
              let droppedURL = DroppedURL.string(fromText: urlString) else {
            return false
        }

        switch zone {
        case .center:
            tabs[tabID]?.load(droppedURL)
            focusedTabID = tabID
            selectedGroupID = nil
            scheduleSave()
            return true
        case .top:
            return split(tabID, axis: .horizontal, side: .before, loadURL: droppedURL) != nil
        case .bottom:
            return split(tabID, axis: .horizontal, side: .after, loadURL: droppedURL) != nil
        case .left:
            return split(tabID, axis: .vertical, side: .before, loadURL: droppedURL) != nil
        case .right:
            return split(tabID, axis: .vertical, side: .after, loadURL: droppedURL) != nil
        }
    }

    @discardableResult
    func dropParked(_ parkedTabID: UUID, on targetTabID: UUID, zone: DropZone) -> Bool {
        guard let parkedIdx = parked.firstIndex(of: parkedTabID),
              tabs[parkedTabID] != nil,
              tabs[targetTabID] != nil,
              root.contains(targetTabID),
              !root.contains(parkedTabID),
              parkedTabID != targetTabID else {
            return false
        }

        switch zone {
        case .center:
            let targetTab = tabs[targetTabID]
            root = root.replacingLeaf(targetTabID, with: parkedTabID)
            if targetTab?.isBlank ?? true {
                parked.remove(at: parkedIdx)
                tabs[targetTabID] = nil
            } else {
                parked[parkedIdx] = targetTabID
            }

        case .top:
            root = root.splitting(targetTabID, axis: .horizontal,
                                  newTabID: parkedTabID, side: .before)
            parked.remove(at: parkedIdx)
            markPaneLayoutsChanged([targetTabID])

        case .bottom:
            root = root.splitting(targetTabID, axis: .horizontal,
                                  newTabID: parkedTabID, side: .after)
            parked.remove(at: parkedIdx)
            markPaneLayoutsChanged([targetTabID])

        case .left:
            root = root.splitting(targetTabID, axis: .vertical,
                                  newTabID: parkedTabID, side: .before)
            parked.remove(at: parkedIdx)
            markPaneLayoutsChanged([targetTabID])

        case .right:
            root = root.splitting(targetTabID, axis: .vertical,
                                  newTabID: parkedTabID, side: .after)
            parked.remove(at: parkedIdx)
            markPaneLayoutsChanged([targetTabID])
        }

        focusedTabID = parkedTabID
        selectedGroupID = nil
        scheduleSave()
        return true
    }

    func close(_ tabID: UUID) {
        if zoomedTabID == tabID { zoomedTabID = nil }
        selectedGroupID = nil
        let expandedTabIDs = root.tabIDsExpandedByRemoving(tabID)
        let focusAfterClose = root.tabIDToFocusAfterRemoving(tabID)
        if let newRoot = root.removing(tabID) {
            root = newRoot
            tabs[tabID] = nil
            if focusedTabID == tabID {
                focusedTabID = focusAfterClose ?? newRoot.tabIDs().first
            }
        } else {
            tabs[tabID] = nil
            let newID = makeBlankTab()
            root = .leaf(tabID: newID)
            focusedTabID = newID
        }
        markPaneLayoutsChanged(expandedTabIDs)
        scheduleSave()
    }

    func setRatio(_ ratio: Double, for splitID: UUID) {
        root = root.settingRatio(ratio, for: splitID)
        scheduleSave()
    }

    @ObservationIgnored
    private var dragInitialRatios: [UUID: Double] = [:]

    func beginRatioDrag(_ splitID: UUID) {
        selectGroup(splitID)
        if dragInitialRatios[splitID] == nil {
            dragInitialRatios[splitID] = root.ratio(forSplit: splitID)
        }
    }

    func updateRatioDrag(_ splitID: UUID, usable: CGFloat, translation: CGFloat) {
        guard let initial = dragInitialRatios[splitID], usable > 0 else { return }
        let newSize = usable * initial + translation
        let newRatio = (newSize / usable).clamped(to: 0.05...0.95)
        root = root.settingRatio(newRatio, for: splitID)
    }

    func endRatioDrag(_ splitID: UUID) {
        dragInitialRatios[splitID] = nil
        scheduleSave()
    }

    func moveFocus(_ direction: Direction) {
        guard let current = focusedTabID,
              let next = root.neighbor(of: current, direction: direction) else { return }
        selectedGroupID = nil
        focusedTabID = next
        scheduleSave()
    }

    func setSidebarWidth(_ width: Double) {
        sidebarWidth = width.clamped(to: 0...520)
        scheduleSave()
    }

    @ObservationIgnored
    private var dragInitialSidebarWidth: Double?

    func beginSidebarDrag() {
        if dragInitialSidebarWidth == nil {
            dragInitialSidebarWidth = sidebarWidth
        }
    }

    func updateSidebarDrag(translation: CGFloat) {
        guard let initial = dragInitialSidebarWidth else { return }
        sidebarWidth = (initial - Double(translation)).clamped(to: 0...520)
    }

    func endSidebarDrag() {
        dragInitialSidebarWidth = nil
        scheduleSave()
    }

    func reloadFocused()      { focusedTab?.reload() }
    func forceReloadFocused() { focusedTab?.forceReload() }
    func backFocused()        { focusedTab?.goBack() }
    func forwardFocused()     { focusedTab?.goForward() }
    func findInFocused()      { focusedTab?.find() }
    func focusURLBar()        { focusURLBarTrigger &+= 1 }

    func toggleZoom() {
        if zoomedTabID != nil {
            zoomedTabID = nil
        } else if let id = focusedTabID {
            zoomedTabID = id
        }
        selectedGroupID = nil
        scheduleSave()
    }

    func openExternalURL(_ urlString: String) {
        guard let tab = focusedTab else { return }
        if tab.isBlank {
            tab.load(urlString)
        } else if let id = focusedTabID {
            split(id, axis: .vertical, side: .after, loadURL: urlString)
        }
    }

    func handleNewWindowRequest(
        from sourceTabID: UUID,
        configuration: WKWebViewConfiguration,
        navigationAction: WKNavigationAction
    ) -> WKWebView? {
        switch BrowserPreferences.newWindowPolicy {
        case .sidebar:
            return openNewWindowInSidebar(configuration: configuration)
        case .splitRight:
            return openNewWindowBeside(
                sourceTabID,
                configuration: configuration
            )
        case .samePane:
            if let url = navigationAction.request.url {
                tabs[sourceTabID]?.webView.load(URLRequest(url: url))
            }
            return nil
        case .block:
            return nil
        }
    }

    private func openNewWindowInSidebar(
        configuration: WKWebViewConfiguration
    ) -> WKWebView? {
        let newID = makeBlankTab(configuration: configuration)
        parked.insert(newID, at: 0)
        if zoomedTabID != nil { zoomedTabID = nil }
        scheduleSave()
        return tabs[newID]?.webView
    }

    private func openNewWindowBeside(
        _ sourceTabID: UUID,
        configuration: WKWebViewConfiguration
    ) -> WKWebView? {
        guard tabs[sourceTabID] != nil, root.contains(sourceTabID) else {
            return openNewWindowInSidebar(configuration: configuration)
        }

        let newID = makeBlankTab(configuration: configuration)
        root = root.splitting(sourceTabID, axis: .vertical,
                              newTabID: newID, side: .after)
        focusedTabID = newID
        selectedGroupID = nil
        if zoomedTabID != nil { zoomedTabID = nil }
        markPaneLayoutsChanged([sourceTabID])
        scheduleSave()
        return tabs[newID]?.webView
    }

    // MARK: Parking

    func parkFocused() {
        guard let id = focusedTabID else { return }
        park(id)
    }

    func park(_ tabID: UUID) {
        guard let tab = tabs[tabID], !tab.isBlank, root.contains(tabID) else { return }
        let newID = makeBlankTab()
        root = root.replacingLeaf(tabID, with: newID)
        parked.insert(tabID, at: 0)
        focusedTabID = newID
        selectedGroupID = nil
        focusURLBarTrigger &+= 1
        scheduleSave()
    }

    func swapParkedWithFocused(_ parkedTabID: UUID) {
        guard let focusedID = focusedTabID else { return }
        dropParked(parkedTabID, on: focusedID, zone: .center)
    }

    func discardParked(_ parkedTabID: UUID) {
        parked.removeAll { $0 == parkedTabID }
        tabs[parkedTabID] = nil
        scheduleSave()
    }

    private func closeOrDiscard(_ tabID: UUID) {
        if parked.contains(tabID) {
            discardParked(tabID)
        } else if root.contains(tabID) {
            close(tabID)
        }
    }

    func reorderParked(from source: IndexSet, to destination: Int) {
        parked.move(fromOffsets: source, toOffset: destination)
        scheduleSave()
    }

    // MARK: Persistence

    private func markPaneLayoutsChanged<S: Sequence>(_ tabIDs: S) where S.Element == UUID {
        for tabID in tabIDs where tabs[tabID] != nil && root.contains(tabID) && !parked.contains(tabID) {
            paneLayoutRevisions[tabID, default: 0] &+= 1
        }
    }

    private func currentSnapshot() -> WindowSnapshot {
        let visibleTabIDs = root.tabIDs()
        let validParked = Self.sanitizedParkedIDs(parked, tabs: tabs, root: root)
        let referenced = Set(visibleTabIDs + validParked)
        let validFocusedTabID: UUID?
        if let focusedTabID,
           root.contains(focusedTabID),
           tabs[focusedTabID] != nil {
            validFocusedTabID = focusedTabID
        } else {
            validFocusedTabID = visibleTabIDs.first { tabs[$0] != nil }
        }
        let tabRecords: [TabRecord] = referenced.compactMap { id in
            tabs[id].map(TabRecord.init)
        }
        return WindowSnapshot(
            root: root, focusedTabID: validFocusedTabID, parked: validParked,
            tabs: tabRecords, sidebarWidth: sidebarWidth)
    }

    private func scheduleSave() {
        saveTask?.cancel()
        let snapshot = currentSnapshot()
        let url = Self.snapshotFile(for: windowID)
        saveTask = Task {
            try? await Task.sleep(for: .milliseconds(250))
            guard !Task.isCancelled else { return }
            Self.write(snapshot, to: url)
        }
    }

    func flushSave() {
        saveTask?.cancel()
        Self.write(currentSnapshot(), to: Self.snapshotFile(for: windowID))
    }

    private static func write(_ snapshot: WindowSnapshot, to url: URL) {
        do {
            try FileManager.default.createDirectory(
                at: url.deletingLastPathComponent(),
                withIntermediateDirectories: true)
            let data = try JSONEncoder().encode(snapshot)
            try data.write(to: url, options: .atomic)
        } catch {
            persistenceLogger.error("BrowserStore save failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    private static func snapshotFile(for windowID: WindowID) -> URL {
        URL.documentsDirectory
            .appending(path: "zz/windows", directoryHint: .isDirectory)
            .appending(path: windowID.id.uuidString, directoryHint: .isDirectory)
            .appending(path: "state.json")
    }
}

// MARK: - Global history (LRU, fuzzy-searchable)

struct HistoryEntry: Codable, Identifiable, Hashable {
    var id: String { url }
    var url: String
    var title: String?
    var lastVisited: Date
}

enum OmniboxSuggestions {
    static func entries(matching query: String,
                        historyMatches: [HistoryEntry],
                        limit: Int,
                        searchTemplate: String = SearchPreferences.activeTemplate) -> [HistoryEntry] {
        var seen = Set<String>()
        var entries: [HistoryEntry] = []

        if let direct = directEntry(for: query, searchTemplate: searchTemplate),
           seen.insert(direct.url).inserted {
            entries.append(direct)
        }

        for entry in historyMatches where seen.insert(entry.url).inserted {
            entries.append(entry)
            if entries.count >= limit { break }
        }

        return entries
    }

    static func directEntry(for query: String,
                            searchTemplate: String = SearchPreferences.activeTemplate) -> HistoryEntry? {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty,
              let resolved = URLNormalizer.resolve(trimmed, searchTemplate: searchTemplate) else {
            return nil
        }

        return HistoryEntry(
            url: resolved.absoluteString,
            title: directTitle(for: trimmed),
            lastVisited: .now
        )
    }

    private static func directTitle(for query: String) -> String {
        if query.contains(" ") || !query.contains(".") {
            return "Search"
        }
        return "Open"
    }
}

@MainActor
@Observable
final class HistoryStore {
    private(set) var entries: [HistoryEntry] = []

    @ObservationIgnored
    private var saveTask: Task<Void, Never>?
    private let limit = 2000

    init() {
        if let data = try? Data(contentsOf: Self.fileURL),
           let decoded = try? JSONDecoder().decode([HistoryEntry].self, from: data) {
            entries = decoded
        }
    }

    func record(url: String, title: String?) {
        guard BrowserPreferences.recordsHistory else { return }
        let trimmed = url.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed.lowercased() != "about:blank" else { return }
        var copy = entries.filter { $0.url != trimmed }
        copy.insert(HistoryEntry(url: trimmed, title: title, lastVisited: .now), at: 0)
        if copy.count > limit { copy = Array(copy.prefix(limit)) }
        entries = copy
        scheduleSave()
    }

    func clear() {
        entries = []
        scheduleSave()
    }

    func suggestions(matching query: String, limit: Int = 8) -> [HistoryEntry] {
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !q.isEmpty else { return Array(entries.prefix(limit)) }
        let scored: [(HistoryEntry, Int)] = entries.compactMap { entry in
            let urlScore   = FuzzyMatch.score(needle: q, in: entry.url) ?? Int.min
            let titleScore = FuzzyMatch.score(needle: q, in: entry.title ?? "") ?? Int.min
            let best = max(urlScore, titleScore)
            return best > Int.min ? (entry, best) : nil
        }
        return scored
            .sorted { $0.1 == $1.1 ? $0.0.lastVisited > $1.0.lastVisited : $0.1 > $1.1 }
            .prefix(limit)
            .map { $0.0 }
    }

    func omniboxSuggestions(matching query: String, limit: Int = 8) -> [HistoryEntry] {
        OmniboxSuggestions.entries(
            matching: query,
            historyMatches: suggestions(matching: query, limit: limit),
            limit: limit
        )
    }

    private func scheduleSave() {
        saveTask?.cancel()
        let snapshot = entries
        saveTask = Task {
            try? await Task.sleep(for: .milliseconds(400))
            guard !Task.isCancelled else { return }
            Self.write(snapshot)
        }
    }

    func flushSave() {
        saveTask?.cancel()
        Self.write(entries)
    }

    private static func write(_ entries: [HistoryEntry]) {
        do {
            try FileManager.default.createDirectory(
                at: fileURL.deletingLastPathComponent(),
                withIntermediateDirectories: true)
            let data = try JSONEncoder().encode(entries)
            try data.write(to: fileURL, options: .atomic)
        } catch {
            persistenceLogger.error("HistoryStore save failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    private static var fileURL: URL {
        URL.documentsDirectory
            .appending(path: "zz", directoryHint: .isDirectory)
            .appending(path: "history.json")
    }
}

// MARK: - Fuzzy matching

enum FuzzyMatch {
    static func score(needle: String, in haystack: String) -> Int? {
        let n = Array(needle.lowercased())
        let h = Array(haystack.lowercased())
        guard !n.isEmpty else { return nil }
        guard n.count <= h.count else { return nil }

        var ni = 0
        var score = 0
        var prevMatch = -2
        var streak = 0
        for (i, c) in h.enumerated() where ni < n.count && c == n[ni] {
            let isBoundary = i == 0 || h[i - 1].isFuzzyBoundary
            score += 1
            if isBoundary { score += 8 }
            if i == prevMatch + 1 {
                streak += 1
                score += 4 + streak
            } else {
                streak = 0
            }
            prevMatch = i
            ni += 1
        }
        guard ni == n.count else { return nil }
        score -= h.count / 32
        return score
    }
}

private extension Character {
    var isFuzzyBoundary: Bool {
        self == " " || self == "/" || self == "." || self == "-" ||
        self == "_" || self == ":" || self == "?" || self == "&" ||
        self == "=" || self == "#"
    }
}

// MARK: - URL normalization

enum URLNormalizer {
    static func resolve(_ input: String,
                        searchTemplate: String = SearchPreferences.activeTemplate) -> URL? {
        let trimmed = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        if let url = URL(string: trimmed), let scheme = url.scheme,
           scheme == "http" || scheme == "https" || scheme == "about" || scheme == "file" {
            return url
        }
        if trimmed.contains(" ") || !trimmed.contains(".") {
            return SearchPreferences.searchURL(for: trimmed, template: searchTemplate)
        }
        return URL(string: "https://" + trimmed)
    }
}

enum DroppedURL {
    static func string(fromText input: String) -> String? {
        let trimmed = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }

        if let detected = firstLink(in: trimmed) {
            return detected.absoluteString
        }

        guard URLNormalizer.resolve(trimmed) != nil else { return nil }
        return trimmed
    }

    private static func firstLink(in text: String) -> URL? {
        guard let detector = try? NSDataDetector(
            types: NSTextCheckingResult.CheckingType.link.rawValue
        ) else { return nil }

        let range = NSRange(text.startIndex..<text.endIndex, in: text)
        return detector.firstMatch(in: text, options: [], range: range)?.url
    }
}
