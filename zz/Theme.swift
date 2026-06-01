import SwiftUI
import Foundation
import Observation
import OSLog
#if canImport(UIKit)
import UIKit
#elseif canImport(AppKit)
import AppKit
#endif

extension Color {
    static var canvas: Color {
        #if canImport(UIKit)
        Color(.systemBackground)
        #else
        Color(.windowBackgroundColor)
        #endif
    }

    static var canvasSecondary: Color {
        #if canImport(UIKit)
        Color(.secondarySystemBackground)
        #else
        Color(.controlBackgroundColor)
        #endif
    }

    static var textSelection: Color {
        #if canImport(UIKit)
        Color(UIColor.systemBlue)
        #else
        Color(NSColor.selectedTextBackgroundColor)
        #endif
    }

    /// Concrete secondary-label color. Unlike the semantic `Color.secondary`,
    /// this resolves correctly as an AttributedString foreground color (the
    /// semantic one renders transparent there).
    static var secondaryLabelText: Color {
        #if canImport(UIKit)
        Color(UIColor.secondaryLabel)
        #else
        Color(NSColor.secondaryLabelColor)
        #endif
    }
}

nonisolated enum SiteVisual {
    static func host(for url: String) -> String {
        URL(string: url)?.host(percentEncoded: false)
        ?? URL(string: "https://" + url)?.host(percentEncoded: false)
        ?? url
    }
}

enum PaneSelectionVisual {
    static let strokeWidth: CGFloat = 1.0
    static let reservedInset: CGFloat = strokeWidth
}

// MARK: - Favicons

#if canImport(UIKit)
typealias PlatformImage = UIImage
#elseif canImport(AppKit)
typealias PlatformImage = NSImage
#endif

nonisolated private let faviconLogger = Logger(
    subsystem: Bundle.main.bundleIdentifier ?? "surf.zz",
    category: "Favicons"
)

/// Pure helpers for the favicon cache: candidate fetch URLs, the on-disk
/// filename for a host, decoding bytes to a platform image, and LRU eviction.
/// Kept free of any actor/state so they are unit-testable and Sendable-safe.
nonisolated enum FaviconLogic {
    /// Candidate URL(s) to try for a host: only the site's own favicon.ico, so
    /// no hostname is ever leaked to a third party. Returns empty for an empty host.
    static func candidateURLs(host: String) -> [URL] {
        let trimmed = host.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !trimmed.isEmpty,
              let direct = URL(string: "https://\(trimmed)/favicon.ico") else { return [] }
        return [direct]
    }

    /// Stable, filesystem-safe filename for a host's cached image. Hashing keeps
    /// it free of path-hostile characters (`:`, `/`, …) and bounded in length.
    static func fileName(for host: String) -> String {
        let normalized = host.lowercased()
        var hash: UInt64 = 1_469_598_103_934_665_603 // FNV-1a 64-bit offset basis
        for byte in normalized.utf8 {
            hash ^= UInt64(byte)
            hash = hash &* 1_099_511_628_211
        }
        return String(format: "%016llx", hash) + ".img"
    }

    /// Decode raw bytes into a platform image, returning nil on bad data. Never
    /// throws/crashes so the caller can simply fall back to an SF Symbol.
    static func decode(_ data: Data) -> PlatformImage? {
        guard !data.isEmpty else { return nil }
        #if canImport(UIKit)
        return UIImage(data: data)
        #elseif canImport(AppKit)
        return NSImage(data: data)
        #else
        return nil
        #endif
    }

    /// Given the current insertion-ordered keys and a cap, return the hosts that
    /// should be evicted (oldest first) to bring the count back within `cap`.
    static func hostsToEvict(order: [String], cap: Int) -> [String] {
        guard cap > 0, order.count > cap else { return [] }
        return Array(order.prefix(order.count - cap))
    }
}

/// Serializes all favicon image-file IO so writes and deletes for the same
/// deterministic filename cannot reorder. (Independent `Task.detached` blocks
/// could otherwise run a stale delete after a fresh write of the same path.)
actor FaviconDiskIO {
    static let shared = FaviconDiskIO()

    func write(_ data: Data, name: String, dir: URL) {
        do {
            try FileManager.default.createDirectory(
                at: dir, withIntermediateDirectories: true)
            try data.write(to: dir.appending(path: name), options: .atomic)
        } catch {
            faviconLogger.error("Favicon image write failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    func remove(name: String, dir: URL) {
        try? FileManager.default.removeItem(at: dir.appending(path: name))
    }
}

/// In-memory + on-disk favicon cache keyed by canonical host. Fetches happen
/// off the main actor; decoded images and the host->filename map live on the
/// main actor and drive `@Observable` updates so views refresh when an icon
/// arrives. Disk writes are debounced like the other stores.
@MainActor
@Observable
final class FaviconStore {
    /// Cap on the number of cached hosts kept in memory and on disk.
    static let maxEntries = 400

    /// Decoded images by canonical host. Mutating this republishes to observers.
    private var images: [String: PlatformImage] = [:]

    /// Insertion/most-recent-use order for LRU eviction (oldest first).
    @ObservationIgnored
    private var order: [String] = []

    /// Persisted host -> on-disk filename map.
    @ObservationIgnored
    private var fileNames: [String: String] = [:]

    /// Hosts with an in-flight or already-attempted fetch, to avoid duplicates.
    @ObservationIgnored
    private var inFlight: Set<String> = []

    /// Hosts whose fetch failed entirely; don't keep retrying within a session.
    @ObservationIgnored
    private var failed: Set<String> = []

    @ObservationIgnored
    private var saveTask: Task<Void, Never>?

    /// Serial tail for image-file IO. Each write/delete chains off the previous
    /// one so operations on the same deterministic filename run in enqueue order.
    @ObservationIgnored
    private var imageIOTail: Task<Void, Never> = Task {}

    init() {
        if let data = try? Data(contentsOf: Self.mapFileURL),
           let decoded = try? JSONDecoder().decode([String: String].self, from: data) {
            fileNames = decoded
            order = Array(decoded.keys)
        }
    }

    /// Returns a cached image for the URL/host if available, otherwise nil while
    /// it (lazily) kicks off an asynchronous fetch. Safe to call from view bodies.
    func image(forURL url: String) -> PlatformImage? {
        image(forHost: URLCanonicalizer.host(url))
    }

    func image(forHost rawHost: String) -> PlatformImage? {
        let host = rawHost.lowercased()
        guard !host.isEmpty else { return nil }

        if let img = images[host] {
            touch(host)
            return img
        }

        // Lazily hydrate from disk if we have a stored file for this host.
        // Return the decoded image immediately, but defer the @Observable write
        // to `images` to the next runloop tick: mutating tracked state inside the
        // current view-body evaluation is undefined behavior.
        if let name = fileNames[host],
           let data = try? Data(contentsOf: Self.imageDir.appending(path: name)),
           let img = FaviconLogic.decode(data) {
            Task { @MainActor in
                guard self.images[host] == nil else { return }
                self.store(image: img, for: host, persist: false)
            }
            return img
        }

        fetchIfNeeded(host: host)
        return nil
    }

    private func fetchIfNeeded(host: String) {
        guard !inFlight.contains(host), !failed.contains(host) else { return }
        inFlight.insert(host)
        let candidates = FaviconLogic.candidateURLs(host: host)
        guard !candidates.isEmpty else {
            inFlight.remove(host)
            return
        }
        Task { [weak self] in
            let data = await Self.fetch(candidates: candidates)
            await MainActor.run {
                guard let self else { return }
                self.inFlight.remove(host)
                if let data, let img = FaviconLogic.decode(data) {
                    self.store(image: img, for: host, persist: true, data: data)
                } else {
                    self.failed.insert(host)
                }
            }
        }
    }

    private func touch(_ host: String) {
        if let idx = order.firstIndex(of: host) { order.remove(at: idx) }
        order.append(host)
    }

    private func store(image: PlatformImage, for host: String,
                       persist: Bool, data: Data? = nil) {
        images[host] = image
        touch(host)
        if persist {
            let name = fileNames[host] ?? FaviconLogic.fileName(for: host)
            fileNames[host] = name
            if let data {
                writeImageOffMain(data, name: name)
            }
            scheduleSaveMap()
        }
        evictIfNeeded()
    }

    private func evictIfNeeded() {
        let victims = FaviconLogic.hostsToEvict(order: order, cap: Self.maxEntries)
        guard !victims.isEmpty else { return }
        for host in victims {
            images[host] = nil
            if let name = fileNames.removeValue(forKey: host) {
                removeImageOffMain(name: name)
            }
        }
        order.removeFirst(victims.count)
        scheduleSaveMap()
    }

    private func scheduleSaveMap() {
        saveTask?.cancel()
        let snapshot = fileNames
        saveTask = Task {
            try? await Task.sleep(for: .milliseconds(500))
            guard !Task.isCancelled else { return }
            guard let data = try? JSONEncoder().encode(snapshot) else { return }
            await Self.writeMapOffMain(data)
        }
    }

    func flushSave() {
        saveTask?.cancel()
        guard let data = try? JSONEncoder().encode(fileNames) else { return }
        Self.writeMap(data)
    }

    // MARK: Off-main IO (Sendable-safe: only Data/String cross the boundary)

    nonisolated private static func fetch(candidates: [URL]) async -> Data? {
        for url in candidates {
            do {
                var request = URLRequest(url: url)
                request.timeoutInterval = 8
                let (data, response) = try await URLSession.shared.data(for: request)
                if let http = response as? HTTPURLResponse,
                   !(200...299).contains(http.statusCode) {
                    continue
                }
                if FaviconLogic.decode(data) != nil { return data }
            } catch {
                continue
            }
        }
        return nil
    }

    private func writeImageOffMain(_ data: Data, name: String) {
        let dir = Self.imageDir
        let previous = imageIOTail
        imageIOTail = Task {
            await previous.value
            await FaviconDiskIO.shared.write(data, name: name, dir: dir)
        }
    }

    private func removeImageOffMain(name: String) {
        let dir = Self.imageDir
        let previous = imageIOTail
        imageIOTail = Task {
            await previous.value
            await FaviconDiskIO.shared.remove(name: name, dir: dir)
        }
    }

    nonisolated private static func writeMapOffMain(_ data: Data) async {
        writeMap(data)
    }

    nonisolated private static func writeMap(_ data: Data) {
        do {
            try FileManager.default.createDirectory(
                at: mapFileURL.deletingLastPathComponent(),
                withIntermediateDirectories: true)
            try data.write(to: mapFileURL, options: .atomic)
        } catch {
            faviconLogger.error("Favicon map save failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    nonisolated private static var imageDir: URL {
        URL.documentsDirectory
            .appending(path: "zz", directoryHint: .isDirectory)
            .appending(path: "favicons", directoryHint: .isDirectory)
    }

    nonisolated private static var mapFileURL: URL {
        imageDir.appending(path: "index.json")
    }
}

/// Shows the favicon for a url/host with a graceful SF Symbol fallback while
/// loading or on failure. Reads the store reactively so it refreshes when an
/// icon arrives.
struct FaviconView: View {
    @Environment(FaviconStore.self) private var favicons

    let host: String
    var size: CGFloat = 16
    var fallbackSymbol: String = "globe"

    init(url: String, size: CGFloat = 16, fallbackSymbol: String = "globe") {
        self.host = URLCanonicalizer.host(url)
        self.size = size
        self.fallbackSymbol = fallbackSymbol
    }

    init(host: String, size: CGFloat = 16, fallbackSymbol: String = "globe") {
        self.host = host
        self.size = size
        self.fallbackSymbol = fallbackSymbol
    }

    var body: some View {
        if let image = favicons.image(forHost: host) {
            #if canImport(UIKit)
            Image(uiImage: image)
                .resizable()
                .interpolation(.high)
                .aspectRatio(contentMode: .fit)
                .frame(width: size, height: size)
                .clipShape(.rect(cornerRadius: size * 0.18, style: .continuous))
            #elseif canImport(AppKit)
            Image(nsImage: image)
                .resizable()
                .interpolation(.high)
                .aspectRatio(contentMode: .fit)
                .frame(width: size, height: size)
                .clipShape(.rect(cornerRadius: size * 0.18, style: .continuous))
            #endif
        } else {
            Image(systemName: fallbackSymbol)
                .font(.system(size: size * 0.85, weight: .regular))
                .foregroundStyle(.secondary)
                .frame(width: size, height: size)
        }
    }
}
