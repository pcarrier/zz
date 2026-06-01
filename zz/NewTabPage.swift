import Foundation
import SwiftUI
import Observation
import OSLog

nonisolated private let pinnedLogger = Logger(
    subsystem: Bundle.main.bundleIdentifier ?? "surf.zz",
    category: "PinnedShortcuts"
)

// MARK: - Pinned shortcut value type

/// A user-pinned New Tab shortcut. Persisted as JSON under zz/. Kept a plain
/// value type so the add/remove/encode logic is pure and unit-testable.
nonisolated struct PinnedShortcut: Codable, Identifiable, Hashable {
    var url: String
    var title: String?

    /// Stable identity + dedup key: the canonical form of the URL, so the same
    /// site pinned via slightly different URL spellings only appears once.
    var id: String { URLCanonicalizer.key(url) }

    enum CodingKeys: String, CodingKey { case url, title }

    init(url: String, title: String? = nil) {
        self.url = url
        self.title = title
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        url = try c.decode(String.self, forKey: .url)
        title = try c.decodeIfPresent(String.self, forKey: .title)
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(url, forKey: .url)
        try c.encodeIfPresent(title, forKey: .title)
    }
}

// MARK: - Pure New Tab logic (top sites + pinned add/remove)

/// Pure, testable New Tab page logic: top-site ranking/dedup and the pinned-list
/// add/remove transforms. Kept free of any store/UI state so it can be exercised
/// in isolation; `nonisolated` so it crosses the actor boundary for tests.
nonisolated enum NewTabLogic {
    /// Top sites derived from history frecency: dedup by canonical host (keeping
    /// the strongest entry per host), sort by frecency desc with deterministic
    /// tie-breaks, and cap at `limit`. Empty hosts are skipped.
    static func topSites(from history: [HistoryEntry],
                         now: Date = .now,
                         limit: Int) -> [HistoryEntry] {
        guard limit > 0 else { return [] }

        func frecency(_ entry: HistoryEntry) -> Int {
            OmniboxRanker.frecency(visitCount: entry.visitCount,
                                   lastVisited: entry.lastVisited, now: now)
        }

        // Keep the best entry per canonical host.
        var bestByHost: [String: HistoryEntry] = [:]
        for entry in history {
            let host = URLCanonicalizer.host(entry.url)
            guard !host.isEmpty else { continue }
            if let existing = bestByHost[host] {
                if isHigher(entry, existing, frecency: frecency) {
                    bestByHost[host] = entry
                }
            } else {
                bestByHost[host] = entry
            }
        }

        let ranked = bestByHost.values.sorted { isHigher($0, $1, frecency: frecency) }
        return Array(ranked.prefix(limit))
    }

    /// Deterministic ordering: frecency desc, visitCount desc, lastVisited desc,
    /// then canonical key asc so the result never depends on dictionary order.
    private static func isHigher(_ a: HistoryEntry, _ b: HistoryEntry,
                                 frecency: (HistoryEntry) -> Int) -> Bool {
        let fa = frecency(a), fb = frecency(b)
        if fa != fb { return fa > fb }
        if a.visitCount != b.visitCount { return a.visitCount > b.visitCount }
        if a.lastVisited != b.lastVisited { return a.lastVisited > b.lastVisited }
        return a.canonicalKey < b.canonicalKey
    }

    /// Add a shortcut, deduping by canonical id (keeping the existing position but
    /// refreshing the title), otherwise appending. Returns the new list. Empty or
    /// unresolvable URLs are rejected (returns the list unchanged).
    static func adding(_ shortcut: PinnedShortcut,
                       to list: [PinnedShortcut]) -> [PinnedShortcut] {
        let trimmed = shortcut.url.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, URLNormalizer.resolve(trimmed) != nil else { return list }
        let normalized = PinnedShortcut(url: trimmed, title: shortcut.title)
        var copy = list
        if let idx = copy.firstIndex(where: { $0.id == normalized.id }) {
            // Refresh title; keep position.
            if let title = normalized.title, !title.isEmpty {
                copy[idx].title = title
            }
            copy[idx].url = trimmed
            return copy
        }
        copy.append(normalized)
        return copy
    }

    /// Remove any shortcut whose canonical id matches `url`. Returns the new list.
    static func removing(url: String, from list: [PinnedShortcut]) -> [PinnedShortcut] {
        let key = URLCanonicalizer.key(url)
        return list.filter { $0.id != key }
    }

    /// True if `url` is already pinned (canonical match).
    static func isPinned(url: String, in list: [PinnedShortcut]) -> Bool {
        let key = URLCanonicalizer.key(url)
        return list.contains { $0.id == key }
    }
}

// MARK: - Pinned shortcut store

/// Persisted list of user-pinned New Tab shortcuts. Mirrors the other stores:
/// the mutating transforms are delegated to the pure NewTabLogic, encode happens
/// on the main actor (debounced), and the disk write is handed to a nonisolated
/// writer so the I/O runs off the main actor.
@MainActor
@Observable
final class PinnedShortcutStore {
    private(set) var shortcuts: [PinnedShortcut] = []

    @ObservationIgnored
    private var saveTask: Task<Void, Never>?

    init() {
        if let data = try? Data(contentsOf: Self.fileURL),
           let decoded = try? JSONDecoder().decode([PinnedShortcut].self, from: data) {
            shortcuts = decoded
        }
    }

    func pin(url: String, title: String?) {
        let updated = NewTabLogic.adding(PinnedShortcut(url: url, title: title), to: shortcuts)
        guard updated != shortcuts else { return }
        shortcuts = updated
        scheduleSave()
    }

    func unpin(url: String) {
        let updated = NewTabLogic.removing(url: url, from: shortcuts)
        guard updated != shortcuts else { return }
        shortcuts = updated
        scheduleSave()
    }

    func isPinned(url: String) -> Bool {
        NewTabLogic.isPinned(url: url, in: shortcuts)
    }

    private func scheduleSave() {
        saveTask?.cancel()
        let snapshot = shortcuts
        saveTask = Task {
            try? await Task.sleep(for: .milliseconds(300))
            guard !Task.isCancelled else { return }
            guard let data = try? JSONEncoder().encode(snapshot) else { return }
            await Self.writeDataOffMain(data)
        }
    }

    func flushSave() {
        saveTask?.cancel()
        guard let data = try? JSONEncoder().encode(shortcuts) else { return }
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
            pinnedLogger.error("PinnedShortcutStore save failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    nonisolated private static var fileURL: URL {
        URL.documentsDirectory
            .appending(path: "zz", directoryHint: .isDirectory)
            .appending(path: "pinned.json")
    }
}

// MARK: - History top-sites convenience

extension HistoryStore {
    /// Top sites for the New Tab page: deduped by host, ranked by frecency.
    func topSites(now: Date = .now, limit: Int = 12) -> [HistoryEntry] {
        NewTabLogic.topSites(from: entries, now: now, limit: limit)
    }
}

// MARK: - New Tab page view

/// The New Tab page shown in a blank tile in place of the old empty state. Shows
/// user-pinned shortcuts followed by frecency-derived top sites. A tap loads the
/// URL into this tile's tab; the surrounding tap-to-focus still works because the
/// tile installs its own focus tap underneath.
struct NewTabPageView: View {
    let onOpen: (String) -> Void
    let onFocus: () -> Void

    @Environment(HistoryStore.self) private var history
    @Environment(PinnedShortcutStore.self) private var pinned

    private let columns = [GridItem(.adaptive(minimum: 112, maximum: 160), spacing: 16)]

    var body: some View {
        let pinnedShortcuts = pinned.shortcuts
        let pinnedKeys = Set(pinnedShortcuts.map(\.id))
        let topSites = history.topSites(limit: 12)
            .filter { !pinnedKeys.contains(URLCanonicalizer.key($0.url)) }

        ScrollView {
            VStack(alignment: .leading, spacing: 28) {
                if !pinnedShortcuts.isEmpty {
                    section(title: "Pinned") {
                        ForEach(pinnedShortcuts) { shortcut in
                            NewTabTile(
                                url: shortcut.url,
                                title: shortcut.title,
                                onOpen: { onOpen(shortcut.url) },
                                onRemove: { pinned.unpin(url: shortcut.url) }
                            )
                        }
                    }
                }

                if !topSites.isEmpty {
                    section(title: "Top Sites") {
                        ForEach(topSites) { entry in
                            NewTabTile(
                                url: entry.url,
                                title: entry.title,
                                onOpen: { onOpen(entry.url) },
                                onRemove: nil
                            )
                        }
                    }
                }

                if pinnedShortcuts.isEmpty && topSites.isEmpty {
                    Text("Open a site to get started.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .center)
                        .padding(.top, 60)
                }
            }
            .padding(28)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color.canvas)
        .contentShape(.rect)
        .onTapGesture(perform: onFocus)
    }

    @ViewBuilder
    private func section<Content: View>(title: String,
                                        @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(title)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.secondary)
            LazyVGrid(columns: columns, alignment: .leading, spacing: 16) {
                content()
            }
        }
    }
}

private struct NewTabTile: View {
    let url: String
    let title: String?
    let onOpen: () -> Void
    let onRemove: (() -> Void)?

    @State private var hovering = false

    private var displayTitle: String {
        if let title, !title.isEmpty { return title }
        let host = URLCanonicalizer.host(url)
        return host.isEmpty ? url : host
    }

    var body: some View {
        Button(action: onOpen) {
            VStack(spacing: 8) {
                FaviconView(url: url, size: 32)
                    .frame(width: 56, height: 56)
                    .background(Color.canvasSecondary, in: .rect(cornerRadius: 14, style: .continuous))
                Text(displayTitle)
                    .font(.caption)
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .foregroundStyle(.primary)
                    .frame(maxWidth: .infinity)
            }
            .frame(maxWidth: .infinity)
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .overlay(alignment: .topTrailing) {
            if let onRemove, hovering {
                Button(action: onRemove) {
                    Image(systemName: "xmark.circle.fill")
                        .font(.body)
                        .foregroundStyle(.secondary)
                        .background(Color.canvas, in: Circle())
                }
                .buttonStyle(.plain)
                .help("Unpin")
            }
        }
        .onHover { hovering = $0 }
    }
}
