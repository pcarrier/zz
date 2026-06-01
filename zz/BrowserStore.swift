import Foundation
import CoreGraphics
import Observation
import OSLog
import SwiftUI
import WebKit

nonisolated private let persistenceLogger = Logger(
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

    /// Returns a copy of the tree in which any leaf whose tab id has already
    /// appeared earlier in a pre-order traversal is rewritten with a fresh UUID,
    /// guaranteeing every leaf carries a unique id.
    func deduplicatingLeafIDs(seen: inout Set<UUID>) -> BSPNode {
        switch self {
        case .leaf(let id):
            if seen.insert(id).inserted {
                return self
            }
            return .leaf(tabID: UUID())
        case .split(let id, let axis, let ratio, let a, let b):
            // Dedup split ids in the same pre-order walk: a snapshot with a repeated
            // split UUID makes split-id-keyed ops (ratio/axis/equalize/selectGroup/
            // divider drag) short-circuit on the first match and target the wrong node.
            let newID = seen.insert(id).inserted ? id : UUID()
            return .split(id: newID, axis: axis, ratio: ratio,
                          first: a.deduplicatingLeafIDs(seen: &seen),
                          second: b.deduplicatingLeafIDs(seen: &seen))
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
        for step in path {
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
            var seenLeafIDs = Set<UUID>()
            self.root = snap.root.deduplicatingLeafIDs(seen: &seenLeafIDs)
            self.sidebarWidth = snap.sidebarWidth.clamped(to: 0...520)
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
        tab.onNewWindowRequest = { [weak self, weak tab] configuration, navigationAction in
            guard let self, let tab else { return nil }
            return self.handleNewWindowRequest(
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

    /// Open-tab candidates for the omnibox: every tab in the layout + parked,
    /// excluding the focused main-pane tab and blank/about:blank tabs.
    func openTabSuggestions() -> [(url: String, title: String?, tabID: UUID)] {
        let focused = focusedTabID
        var seen = Set<UUID>()
        var result: [(url: String, title: String?, tabID: UUID)] = []
        for id in root.tabIDs() + parked {
            guard seen.insert(id).inserted else { continue }
            if id == focused, isMainPaneHost(id) { continue }
            guard let tab = tabs[id] else { continue }
            let url = tab.currentURL.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !url.isEmpty, url.lowercased() != "about:blank" else { continue }
            result.append((url: url, title: tab.title, tabID: id))
        }
        return result
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
        if zoomedTabID != nil { zoomedTabID = nil }
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
        if zoomedTabID != nil { zoomedTabID = nil }
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
                if zoomedTabID == targetTabID { zoomedTabID = nil }
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
        // Re-capture the baseline at the start of every gesture. The gesture's
        // translation is cumulative-from-start, so each new drag needs the
        // divider's current ratio as its baseline. Capturing only when nil
        // would reuse a stale ratio if a prior drag was cancelled without
        // endRatioDrag firing.
        dragInitialRatios[splitID] = root.ratio(forSplit: splitID)
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
        if zoomedTabID != nil { zoomedTabID = nil }
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
        if zoomedTabID == tabID { zoomedTabID = nil }
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
        if zoomedTabID == parkedTabID { zoomedTabID = nil }
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
            // Encode on the main actor (WindowSnapshot's Codable conformance is
            // main-actor-isolated, and the encode is cheap + coalesced by the
            // debounce), then hand the bytes to a nonisolated writer so the
            // unbounded atomic disk write runs OFF the main actor.
            guard let data = try? JSONEncoder().encode(snapshot) else { return }
            await Self.writeDataOffMain(data, to: url)
        }
    }

    func flushSave() {
        saveTask?.cancel()
        // Synchronous on purpose: flushSave runs at scenePhase background/terminate
        // and must finish before the process is suspended, so it cannot hand off to
        // a task that may never get scheduled.
        guard let data = try? JSONEncoder().encode(currentSnapshot()) else { return }
        Self.writeData(data, to: Self.snapshotFile(for: windowID))
    }

    nonisolated private static func writeDataOffMain(_ data: Data, to url: URL) async {
        writeData(data, to: url)
    }

    nonisolated private static func writeData(_ data: Data, to url: URL) {
        do {
            try FileManager.default.createDirectory(
                at: url.deletingLastPathComponent(),
                withIntermediateDirectories: true)
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
    var visitCount: Int = 1

    /// NOT stored/coded; derived dedup + match key.
    var canonicalKey: String { URLCanonicalizer.key(url) }

    enum CodingKeys: String, CodingKey { case url, title, lastVisited, visitCount }

    init(url: String, title: String?, lastVisited: Date, visitCount: Int = 1) {
        self.url = url
        self.title = title
        self.lastVisited = lastVisited
        self.visitCount = visitCount
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        url = try c.decode(String.self, forKey: .url)
        title = try c.decodeIfPresent(String.self, forKey: .title)
        lastVisited = try c.decode(Date.self, forKey: .lastVisited)
        visitCount = try c.decodeIfPresent(Int.self, forKey: .visitCount) ?? 1
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(url, forKey: .url)
        try c.encodeIfPresent(title, forKey: .title)
        try c.encode(lastVisited, forKey: .lastVisited)
        try c.encode(visitCount, forKey: .visitCount)
    }
}

// MARK: - URL canonicalization (single source of truth)

/// The ONLY canonicalizer. record(), suggestion dedup, and the open-tab map all
/// call it so the dedup/match key never drifts between call sites.
enum URLCanonicalizer {
    /// Produces the dedup/match key. Collapses http/https + www, drops default
    /// ports, drops a single empty trailing slash, keeps the query, drops the
    /// fragment.
    static func key(_ url: String) -> String {
        let trimmed = url.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return "" }

        var comps = URLComponents(string: trimmed)
        if comps?.host == nil {
            comps = URLComponents(string: "https://" + trimmed)
        }
        guard var c = comps, let rawHost = c.host else {
            return trimmed.lowercased()
        }

        // Collapse http/https into https; keep other schemes (file/about) as-is.
        let scheme = (c.scheme ?? "https").lowercased()
        let normScheme = (scheme == "http" || scheme == "https") ? "https" : scheme

        var host = rawHost.lowercased()
        if host.hasPrefix("www.") { host.removeFirst(4) }

        // Drop default ports.
        if let port = c.port, (port == 80 || port == 443) {
            c.port = nil
        }
        let portSuffix = c.port.map { ":\($0)" } ?? ""

        var path = c.percentEncodedPath
        if path == "/" { path = "" }

        var result = "\(normScheme)://\(host)\(portSuffix)\(path)"
        if let query = c.percentEncodedQuery, !query.isEmpty {
            result += "?\(query)"
        }
        return result
    }

    /// Lowercased, www-stripped host for tier matching. Reuses SiteVisual.host
    /// semantics (which prefixes https:// for bare hosts).
    static func host(_ url: String) -> String {
        var host = SiteVisual.host(for: url).lowercased()
        if host.hasPrefix("www.") { host.removeFirst(4) }
        return host
    }
}

// MARK: - Omnibox value types

enum SuggestionKind { case search, open, openTab, history }

/// Selection routing decision, shared by click-select and keyboard-submit so an
/// open-tab row never reloads. Pure + testable.
enum OmniboxRoute: Equatable {
    case focus(UUID)
    case load(String)

    static func route(for item: OmniboxItem) -> OmniboxRoute {
        if item.kind == .openTab, let id = item.tabID {
            return .focus(id)
        }
        return .load(item.url)
    }
}

struct OmniboxItem: Identifiable, Hashable {
    var id: String
    var url: String
    var title: String?
    var kind: SuggestionKind
    var tabID: UUID?
    var titleRanges: [Range<String.Index>]
    var urlRanges: [Range<String.Index>]

    init(id: String,
         url: String,
         title: String?,
         kind: SuggestionKind,
         tabID: UUID? = nil,
         titleRanges: [Range<String.Index>] = [],
         urlRanges: [Range<String.Index>] = []) {
        self.id = id
        self.url = url
        self.title = title
        self.kind = kind
        self.tabID = tabID
        self.titleRanges = titleRanges
        self.urlRanges = urlRanges
    }
}

// MARK: - Omnibox ranker

/// Deterministic, tiered "frecency" ranker. Pure over in-memory data plus
/// injected open-tab values and an injected `now`. Never imports BrowserStore.
enum OmniboxRanker {
    // Tier bases. Gap = 2000 so any higher tier always beats any lower tier
    // regardless of frecency/earliness (bounded < 2000 by construction).
    static let tierOpenTab = 12000   // 0
    static let tierHostPrefix = 10000 // 5
    static let tierPrefix = 8000      // 4
    static let tierWordStart = 6000   // 3
    static let tierSubstring = 4000   // 2
    static let tierFuzzy = 1000       // 1

    struct Normalized {
        let q: String       // trimmed, lowercased
        let qHost: String   // scheme + www stripped (for host comparisons)
        let qRaw: String    // trimmed, lowercased, scheme/www intact
    }

    static func normalize(_ query: String) -> Normalized {
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        var qHost = q
        for scheme in ["https://", "http://"] where qHost.hasPrefix(scheme) {
            qHost.removeFirst(scheme.count)
            break
        }
        if qHost.hasPrefix("www.") { qHost.removeFirst(4) }
        return Normalized(q: q, qHost: qHost, qRaw: q)
    }

    /// A classification result: the winning tier plus matched ranges against the
    /// ORIGINAL (non-lowercased) displayed strings.
    struct Classification {
        var tier: Int
        var titleRanges: [Range<String.Index>]
        var urlRanges: [Range<String.Index>]
        var matchStart: Int   // for earliness
    }

    static func classify(query norm: Normalized,
                         host: String,
                         url: String,
                         title: String?) -> Classification? {
        let q = norm.q
        guard !q.isEmpty else { return nil }
        let displayTitle = title ?? ""
        let canonical = URLCanonicalizer.key(url)
        let lowerTitle = displayTitle.lowercased()
        let lowerHost = host.lowercased()
        let lowerCanonical = canonical.lowercased()

        // Tier 5 — host prefix.
        if !norm.qHost.isEmpty, lowerHost.hasPrefix(norm.qHost) {
            var titleRanges: [Range<String.Index>] = []
            var urlRanges: [Range<String.Index>] = []
            // Mirror the host prefix onto the displayed URL where the host sits.
            if let r = rangeOfHostPrefix(in: url, host: host, length: norm.qHost.count) {
                urlRanges = [r]
            }
            if lowerTitle.hasPrefix(q), let r = prefixRange(in: displayTitle, length: q.count) {
                titleRanges = [r]
            }
            return Classification(tier: tierHostPrefix, titleRanges: titleRanges,
                                  urlRanges: urlRanges, matchStart: 0)
        }

        // Tier 4 — URL/title prefix.
        if lowerCanonical.hasPrefix(norm.qRaw) || lowerTitle.hasPrefix(q) {
            var titleRanges: [Range<String.Index>] = []
            var urlRanges: [Range<String.Index>] = []
            if lowerCanonical.hasPrefix(norm.qRaw),
               let r = rangeOfSubstring(norm.qRaw, in: url, from: 0) {
                urlRanges = [r]
            }
            if lowerTitle.hasPrefix(q), let r = prefixRange(in: displayTitle, length: q.count) {
                titleRanges = [r]
            }
            return Classification(tier: tierPrefix, titleRanges: titleRanges,
                                  urlRanges: urlRanges, matchStart: 0)
        }

        // Tier 3 — word-start / boundary contiguous match, plus acronym match.
        if let ws = wordStartMatch(q, host: host, url: url, title: displayTitle) {
            return ws
        }

        // Tier 2 — contiguous substring anywhere in canonical url or title.
        do {
            var titleRanges: [Range<String.Index>] = []
            var urlRanges: [Range<String.Index>] = []
            var start = Int.max
            if let idx = lowerCanonical.range(of: q) {
                let off = lowerCanonical.distance(from: lowerCanonical.startIndex, to: idx.lowerBound)
                start = min(start, off)
                if let r = rangeOfSubstring(q, in: url, from: 0) { urlRanges = [r] }
            }
            if let idx = lowerTitle.range(of: q) {
                let off = lowerTitle.distance(from: lowerTitle.startIndex, to: idx.lowerBound)
                start = min(start, off)
                if let r = rangeOfSubstring(q, in: displayTitle, from: 0) { titleRanges = [r] }
            }
            if !titleRanges.isEmpty || !urlRanges.isEmpty {
                return Classification(tier: tierSubstring, titleRanges: titleRanges,
                                      urlRanges: urlRanges, matchStart: start == .max ? 0 : start)
            }
        }

        // Tier 1 — gated fuzzy fallback (only reached if nothing above matched).
        if let fuzzy = gatedFuzzy(q, url: url, title: displayTitle) {
            return fuzzy
        }

        return nil
    }

    // MARK: Tier helpers

    private static func wordStartMatch(_ q: String,
                                       host: String,
                                       url: String,
                                       title: String) -> Classification? {
        // Contiguous boundary-start match in host, path, or title.
        let canonical = URLCanonicalizer.key(url)
        for field in [host, canonical, title] {
            if let r = boundaryContiguous(q, in: field) {
                let offset = field.distance(from: field.startIndex, to: r.lowerBound)
                if field == title {
                    return Classification(tier: tierWordStart, titleRanges: [r],
                                          urlRanges: [], matchStart: offset)
                } else {
                    // Map onto displayed url when the field is host/canonical.
                    let matched = String(field[r])
                    if let ur = rangeOfSubstring(matched.lowercased(), in: url, from: 0) {
                        return Classification(tier: tierWordStart, titleRanges: [],
                                              urlRanges: [ur], matchStart: offset)
                    }
                    return Classification(tier: tierWordStart, titleRanges: [],
                                          urlRanges: [], matchStart: offset)
                }
            }
        }

        // Acronym: chars of q match first letters of consecutive boundary-delimited
        // segments of host or title.
        if let r = acronymRanges(q, in: title) {
            return Classification(tier: tierWordStart, titleRanges: r, urlRanges: [], matchStart: 0)
        }
        if let r = acronymRanges(q, in: host) {
            // Map per-letter ranges onto the displayed url.
            let urlRanges = r.compactMap { seg -> Range<String.Index>? in
                let ch = String(host[seg]).lowercased()
                return rangeOfSubstring(ch, in: url, from: 0)
            }
            return Classification(tier: tierWordStart, titleRanges: [], urlRanges: urlRanges, matchStart: 0)
        }
        return nil
    }

    /// Matches `q` contiguously starting at a boundary char (or string start).
    private static func boundaryContiguous(_ q: String, in field: String) -> Range<String.Index>? {
        guard !q.isEmpty, !field.isEmpty else { return nil }
        let lower = field.lowercased()
        let lowerChars = Array(lower)
        let qLen = q.count
        var i = 0
        while i + qLen <= lowerChars.count {
            let isBoundary = i == 0 || lowerChars[i - 1].isFuzzyBoundary
            if isBoundary {
                var matched = true
                for (j, qc) in q.enumerated() where lowerChars[i + j] != qc {
                    matched = false
                    break
                }
                if matched {
                    let startIdx = field.index(field.startIndex, offsetBy: i)
                    let endIdx = field.index(startIdx, offsetBy: qLen)
                    return startIdx..<endIdx
                }
            }
            i += 1
        }
        return nil
    }

    /// Acronym match: q's chars are the first letters of consecutive segments.
    private static func acronymRanges(_ q: String, in field: String) -> [Range<String.Index>]? {
        guard q.count >= 2, !field.isEmpty else { return nil }
        let chars = Array(field)
        // Collect segment-start indices (string start or after a boundary).
        var starts: [Int] = []
        for i in 0..<chars.count {
            if i == 0 || chars[i - 1].isFuzzyBoundary {
                if !chars[i].isFuzzyBoundary { starts.append(i) }
            }
        }
        let qChars = Array(q.lowercased())
        guard starts.count >= qChars.count else { return nil }
        // Match q against consecutive segment starts.
        outer: for offset in 0...(starts.count - qChars.count) {
            var ranges: [Range<String.Index>] = []
            for k in 0..<qChars.count {
                let pos = starts[offset + k]
                if Character(String(chars[pos]).lowercased()) != qChars[k] { continue outer }
                let s = field.index(field.startIndex, offsetBy: pos)
                let e = field.index(after: s)
                ranges.append(s..<e)
            }
            return ranges
        }
        return nil
    }

    private static func gatedFuzzy(_ q: String, url: String, title: String) -> Classification? {
        let candidates = [url, title]
        var best: (positions: [Int], field: String)? = nil
        var bestScore = Int.min
        for field in candidates {
            guard let positions = FuzzyMatch.matchPositions(needle: q, in: field) else { continue }
            // Quality floor.
            let lowerChars = Array(field.lowercased())
            let boundaryHits = positions.filter { p in
                p == 0 || (p - 1 >= 0 && lowerChars[p - 1].isFuzzyBoundary)
            }.count
            let needBoundary = Int(ceil(Double(q.count) / 2.0))
            guard boundaryHits >= needBoundary else { continue }
            guard let first = positions.first, let last = positions.last else { continue }
            let span = last - first + 1
            guard span <= 3 * q.count else { continue }
            let score = FuzzyMatch.score(needle: q, in: field) ?? Int.min
            if score > bestScore {
                bestScore = score
                best = (positions, field)
            }
        }
        guard let best else { return nil }
        let ranges = best.positions.compactMap { p -> Range<String.Index>? in
            guard p < best.field.count else { return nil }
            let s = best.field.index(best.field.startIndex, offsetBy: p)
            let e = best.field.index(after: s)
            return s..<e
        }
        if best.field == title {
            return Classification(tier: tierFuzzy, titleRanges: ranges, urlRanges: [], matchStart: 0)
        }
        return Classification(tier: tierFuzzy, titleRanges: [], urlRanges: ranges, matchStart: 0)
    }

    // MARK: Range mapping helpers (against ORIGINAL displayed strings)

    private static func prefixRange(in s: String, length: Int) -> Range<String.Index>? {
        guard length > 0, s.count >= length else { return nil }
        let end = s.index(s.startIndex, offsetBy: length)
        return s.startIndex..<end
    }

    private static func rangeOfSubstring(_ needleLower: String, in s: String,
                                         from: Int) -> Range<String.Index>? {
        guard !needleLower.isEmpty else { return nil }
        return s.range(of: needleLower, options: [.caseInsensitive])
    }

    /// Locate the leading `length` chars of the host within the displayed url.
    private static func rangeOfHostPrefix(in url: String, host: String,
                                          length: Int) -> Range<String.Index>? {
        guard length > 0, host.count >= length else { return nil }
        let prefix = String(host.prefix(length))
        return url.range(of: prefix, options: [.caseInsensitive])
    }

    // MARK: Scoring

    static func recencyWeight(lastVisited: Date, now: Date) -> Int {
        let age = now.timeIntervalSince(lastVisited)
        if age < 3600 { return 600 }
        if age < 86_400 { return 400 }
        if age < 604_800 { return 250 }
        if age < 2_592_000 { return 120 }
        return 40
    }

    static func frequencyWeight(visitCount: Int) -> Int {
        let v = max(0, visitCount)
        let raw = 40.0 * log2(1.0 + Double(v))
        return min(Int(raw.rounded()), 400)
    }

    static func earliness(matchStart: Int) -> Int {
        max(0, 200 - matchStart * 8)
    }

    static func frecency(visitCount: Int, lastVisited: Date, now: Date) -> Int {
        recencyWeight(lastVisited: lastVisited, now: now)
            + frequencyWeight(visitCount: visitCount)
    }

    static func finalScore(tier: Int,
                           visitCount: Int,
                           lastVisited: Date,
                           now: Date,
                           matchStart: Int,
                           canonicalLength: Int,
                           includeEarliness: Bool) -> Int {
        let frec = frecency(visitCount: visitCount, lastVisited: lastVisited, now: now)
        let early = includeEarliness ? earliness(matchStart: matchStart) : 0
        let lengthPenalty = min(canonicalLength, 120)
        return tier + frec + early - lengthPenalty
    }
}

enum OmniboxSuggestions {
    /// A scored, ranked candidate prior to total-order sorting.
    private struct Scored {
        var item: OmniboxItem
        var canonicalKey: String
        var tier: Int
        var score: Int
        var visitCount: Int
        var lastVisited: Date
        var canonicalLength: Int
    }

    static func entries(matching query: String,
                        history: [HistoryEntry],
                        openTabs: [(url: String, title: String?, tabID: UUID)] = [],
                        now: Date = .now,
                        limit: Int,
                        searchTemplate: String = SearchPreferences.activeTemplate) -> [OmniboxItem] {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)

        // Empty query: skip tiering, return open tabs then history by frecency.
        if trimmed.isEmpty {
            return emptyQueryEntries(history: history, openTabs: openTabs, now: now, limit: limit)
        }

        let norm = OmniboxRanker.normalize(query)

        // 1. Direct entry (typed URL/search), always candidate index 0.
        let direct = directItem(for: trimmed, searchTemplate: searchTemplate)
        let directKey = direct.map { URLCanonicalizer.key($0.url) }

        // 2. Open tabs -> Tier-0 candidates.
        var scored: [Scored] = []
        var openTabKeys = Set<String>()
        for tab in openTabs {
            let host = URLCanonicalizer.host(tab.url)
            let titleMatches = (tab.title?.lowercased().contains(norm.q)) ?? false
            let hostMatches = !norm.qHost.isEmpty && host.hasPrefix(norm.qHost)
            guard hostMatches || titleMatches else { continue }
            let key = URLCanonicalizer.key(tab.url)
            openTabKeys.insert(key)

            // Borrow frecency from a coinciding history entry if present.
            let coincide = history.first { $0.canonicalKey == key }
            let visitCount = coincide?.visitCount ?? 1
            let lastVisited = coincide?.lastVisited ?? now

            var titleRanges: [Range<String.Index>] = []
            var urlRanges: [Range<String.Index>] = []
            if let cls = OmniboxRanker.classify(query: norm, host: host, url: tab.url, title: tab.title) {
                titleRanges = cls.titleRanges
                urlRanges = cls.urlRanges
            } else if titleMatches, let t = tab.title,
                      let r = t.range(of: norm.q, options: [.caseInsensitive]) {
                titleRanges = [r]
            }

            let item = OmniboxItem(id: key, url: tab.url, title: tab.title,
                                   kind: .openTab, tabID: tab.tabID,
                                   titleRanges: titleRanges, urlRanges: urlRanges)
            let canonicalLength = URLCanonicalizer.key(tab.url).count
            let s = OmniboxRanker.finalScore(
                tier: OmniboxRanker.tierOpenTab, visitCount: visitCount,
                lastVisited: lastVisited, now: now, matchStart: 0,
                canonicalLength: canonicalLength, includeEarliness: false)
            scored.append(Scored(item: item, canonicalKey: key,
                                 tier: OmniboxRanker.tierOpenTab, score: s,
                                 visitCount: visitCount, lastVisited: lastVisited,
                                 canonicalLength: canonicalLength))
        }

        // 3. History -> gated-tier candidates.
        for entry in history {
            let host = URLCanonicalizer.host(entry.url)
            guard let cls = OmniboxRanker.classify(query: norm, host: host,
                                                   url: entry.url, title: entry.title) else {
                continue
            }
            let key = entry.canonicalKey
            let canonicalLength = key.count
            let includeEarliness = cls.tier == OmniboxRanker.tierHostPrefix
                || cls.tier == OmniboxRanker.tierPrefix
                || cls.tier == OmniboxRanker.tierWordStart
                || cls.tier == OmniboxRanker.tierSubstring
            let s = OmniboxRanker.finalScore(
                tier: cls.tier, visitCount: entry.visitCount,
                lastVisited: entry.lastVisited, now: now, matchStart: cls.matchStart,
                canonicalLength: canonicalLength, includeEarliness: includeEarliness)
            let item = OmniboxItem(id: key, url: entry.url, title: entry.title,
                                   kind: .history,
                                   titleRanges: cls.titleRanges, urlRanges: cls.urlRanges)
            scored.append(Scored(item: item, canonicalKey: key, tier: cls.tier,
                                 score: s, visitCount: entry.visitCount,
                                 lastVisited: entry.lastVisited,
                                 canonicalLength: canonicalLength))
        }

        // 4. Dedup by canonicalKey, keeping the highest-ranked; open-tab wins ties.
        var bestByKey: [String: Scored] = [:]
        for cand in scored {
            if let existing = bestByKey[cand.canonicalKey] {
                if isHigher(cand, existing) { bestByKey[cand.canonicalKey] = cand }
            } else {
                bestByKey[cand.canonicalKey] = cand
            }
        }
        var ranked = Array(bestByKey.values)

        // 5. Sort by deterministic total order.
        ranked.sort(by: isHigher)

        // 6. directEntry suppression: drop synthetic direct only if top real
        // candidate is a Tier 4/5 match with the same canonicalKey.
        var keepDirect = direct != nil
        if let directKey, let top = ranked.first,
           top.canonicalKey == directKey,
           (top.tier == OmniboxRanker.tierHostPrefix || top.tier == OmniboxRanker.tierPrefix) {
            keepDirect = false
        }

        var result: [OmniboxItem] = []
        if keepDirect, let direct { result.append(direct) }
        for cand in ranked {
            if keepDirect == false, let directKey, cand.canonicalKey == directKey,
               result.contains(where: { $0.id == cand.item.id }) { continue }
            result.append(cand.item)
            if result.count >= limit { break }
        }
        return Array(result.prefix(limit))
    }

    private static func emptyQueryEntries(history: [HistoryEntry],
                                          openTabs: [(url: String, title: String?, tabID: UUID)],
                                          now: Date,
                                          limit: Int) -> [OmniboxItem] {
        var result: [OmniboxItem] = []
        var seen = Set<String>()
        for tab in openTabs {
            let key = URLCanonicalizer.key(tab.url)
            guard seen.insert(key).inserted else { continue }
            result.append(OmniboxItem(id: key, url: tab.url, title: tab.title,
                                      kind: .openTab, tabID: tab.tabID))
        }
        let sortedHistory = history.sorted { a, b in
            let fa = OmniboxRanker.frecency(visitCount: a.visitCount, lastVisited: a.lastVisited, now: now)
            let fb = OmniboxRanker.frecency(visitCount: b.visitCount, lastVisited: b.lastVisited, now: now)
            if fa != fb { return fa > fb }
            if a.visitCount != b.visitCount { return a.visitCount > b.visitCount }
            if a.lastVisited != b.lastVisited { return a.lastVisited > b.lastVisited }
            return a.canonicalKey < b.canonicalKey
        }
        for entry in sortedHistory {
            let key = entry.canonicalKey
            guard seen.insert(key).inserted else { continue }
            result.append(OmniboxItem(id: key, url: entry.url, title: entry.title, kind: .history))
            if result.count >= limit { break }
        }
        return Array(result.prefix(limit))
    }

    /// Fully deterministic comparison-key chain (never floats alone):
    /// score desc, visitCount desc, lastVisited desc, canonicalLength asc, key asc.
    nonisolated private static func isHigher(_ a: Scored, _ b: Scored) -> Bool {
        if a.score != b.score { return a.score > b.score }
        if a.visitCount != b.visitCount { return a.visitCount > b.visitCount }
        if a.lastVisited != b.lastVisited { return a.lastVisited > b.lastVisited }
        if a.canonicalLength != b.canonicalLength { return a.canonicalLength < b.canonicalLength }
        return a.canonicalKey < b.canonicalKey
    }

    static func directItem(for query: String,
                           searchTemplate: String = SearchPreferences.activeTemplate) -> OmniboxItem? {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty,
              let resolved = URLNormalizer.resolve(trimmed, searchTemplate: searchTemplate) else {
            return nil
        }
        let url = resolved.absoluteString
        let isSearch = directIsSearch(for: trimmed, resolved: resolved, searchTemplate: searchTemplate)
        return OmniboxItem(
            id: url,
            url: url,
            title: isSearch ? "Search" : "Open",
            kind: isSearch ? .search : .open
        )
    }

    private static func directIsSearch(for query: String,
                                       resolved: URL,
                                       searchTemplate: String) -> Bool {
        if let searchURL = SearchPreferences.searchURL(for: query, template: searchTemplate),
           searchURL == resolved {
            return true
        }
        return false
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
        let key = URLCanonicalizer.key(trimmed)

        var copy = entries
        if let idx = copy.firstIndex(where: { $0.canonicalKey == key }) {
            var existing = copy.remove(at: idx)
            existing.visitCount += 1
            existing.lastVisited = .now
            if let title, !title.isEmpty { existing.title = title }
            // Prefer a more specific (longer) display URL form.
            if trimmed.count > existing.url.count { existing.url = trimmed }
            copy.insert(existing, at: 0)
        } else {
            copy.insert(HistoryEntry(url: trimmed, title: title, lastVisited: .now, visitCount: 1), at: 0)
        }
        if copy.count > limit { copy = Array(copy.prefix(limit)) }
        entries = copy
        scheduleSave()
    }

    func clear() {
        entries = []
        scheduleSave()
    }

    func omniboxSuggestions(matching query: String,
                            openTabs: [(url: String, title: String?, tabID: UUID)] = [],
                            now: Date = .now,
                            limit: Int = 8) -> [OmniboxItem] {
        OmniboxSuggestions.entries(
            matching: query,
            history: entries,
            openTabs: openTabs,
            now: now,
            limit: limit
        )
    }

    private func scheduleSave() {
        saveTask?.cancel()
        let snapshot = entries
        saveTask = Task {
            try? await Task.sleep(for: .milliseconds(400))
            guard !Task.isCancelled else { return }
            // Encode on main (debounce coalesces it), write off main.
            guard let data = try? JSONEncoder().encode(snapshot) else { return }
            await Self.writeDataOffMain(data)
        }
    }

    func flushSave() {
        saveTask?.cancel()
        guard let data = try? JSONEncoder().encode(entries) else { return }
        Self.writeData(data)
    }

    nonisolated private static func writeDataOffMain(_ data: Data) async {
        writeData(data)
    }

    nonisolated private static func writeData(_ data: Data) {
        do {
            try FileManager.default.createDirectory(
                at: fileURL.deletingLastPathComponent(),
                withIntermediateDirectories: true)
            try data.write(to: fileURL, options: .atomic)
        } catch {
            persistenceLogger.error("HistoryStore save failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    nonisolated private static var fileURL: URL {
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

    /// Greedy left-to-right subsequence match positions (indices into the
    /// lowercased haystack), or nil if the needle isn't a subsequence. Used by
    /// the gated Tier-1 fallback for its quality floor + highlight ranges.
    static func matchPositions(needle: String, in haystack: String) -> [Int]? {
        let n = Array(needle.lowercased())
        let h = Array(haystack.lowercased())
        guard !n.isEmpty, n.count <= h.count else { return nil }
        var ni = 0
        var positions: [Int] = []
        for (i, c) in h.enumerated() where ni < n.count && c == n[ni] {
            positions.append(i)
            ni += 1
        }
        return ni == n.count ? positions : nil
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
        // Foundation does NOT lowercase URL.scheme, so compare case-insensitively.
        if let url = URL(string: trimmed), let scheme = url.scheme?.lowercased() {
            if scheme == "http" || scheme == "https" || scheme == "about" || scheme == "file" {
                return url
            }
            // The input carries an explicit, non-web scheme (mailto:, tel:, ftp:,
            // sms:, data:, javascript:, localhost:8080's bogus "localhost"…).
            // Never prepend https:// to it — that produces corrupt URLs. Detect a
            // host:port authority and treat it as web; otherwise reject so the
            // caller can hand off / search rather than navigate to garbage.
            if isHostPort(trimmed) {
                return URL(string: "https://" + trimmed)
            }
            return nil
        }
        if trimmed.contains(" ") || !trimmed.contains(".") {
            return SearchPreferences.searchURL(for: trimmed, template: searchTemplate)
        }
        return URL(string: "https://" + trimmed)
    }

    /// Matches a bare "host:port" (optionally with a "/path"), e.g. "localhost:8080",
    /// "myhost:3000/path". These have no dot so the dot/space heuristic misroutes
    /// them to search, and URL() parses them with a bogus scheme equal to the host.
    private static func isHostPort(_ s: String) -> Bool {
        guard let range = s.range(of: #"^[A-Za-z0-9][A-Za-z0-9.-]*:[0-9]+(/.*)?$"#,
                                  options: .regularExpression) else { return false }
        return range == s.startIndex..<s.endIndex
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
