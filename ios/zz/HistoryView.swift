import SwiftUI

private enum HistoryViewMetrics {
    static let minWidth: CGFloat = 420
    static let minHeight: CGFloat = 480
    static let rowSpacing: CGFloat = 10
    static let faviconSize: CGFloat = 18
    static let rowTextSpacing: CGFloat = 2
    static let searchResultLimit = 200
    static let yesterdayOffset = -1
}

/// A searchable browser of the global HistoryStore, grouped by day. Reachable
/// from the More menu as a sheet (mirrors the Settings sheet pattern). Tapping a
/// row opens its URL via the same load path the omnibox uses and dismisses.
struct HistoryView: View {
    /// Opens the chosen URL in the focused pane and dismisses the sheet. Wired in
    /// ContentView to the same commit path the omnibox uses on selection.
    let onOpen: (String) -> Void

    @Environment(HistoryStore.self) private var history
    @Environment(\.dismiss) private var dismiss

    @State private var query: String = ""

    var body: some View {
        NavigationStack {
            content
                .navigationTitle("History")
                #if !os(macOS)
                .navigationBarTitleDisplayMode(.inline)
                #endif
                .toolbar {
                    ToolbarItem(placement: .confirmationAction) {
                        Button("Done") { dismiss() }
                    }
                    ToolbarItem(placement: .destructiveAction) {
                        Button(role: .destructive) {
                            history.clear()
                        } label: {
                            Label("Clear All", systemImage: "trash")
                        }
                        .disabled(history.entries.isEmpty)
                    }
                }
        }
        .frame(minWidth: HistoryViewMetrics.minWidth,
               minHeight: HistoryViewMetrics.minHeight)
        .searchable(text: $query, prompt: "Search History")
    }

    @ViewBuilder
    private var content: some View {
        let groups = Self.grouped(filteredEntries, now: .now)
        if groups.isEmpty {
            ContentUnavailableView(
                query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                    ? "No History" : "No Results",
                systemImage: "clock.arrow.circlepath"
            )
        } else {
            List {
                ForEach(groups, id: \.title) { group in
                    Section(group.title) {
                        ForEach(group.entries) { entry in
                            row(entry)
                        }
                        #if !os(macOS)
                        .onDelete { offsets in
                            for index in offsets {
                                history.delete(group.entries[index])
                            }
                        }
                        #endif
                    }
                }
            }
        }
    }

    @ViewBuilder
    private func row(_ entry: HistoryEntry) -> some View {
        Button {
            onOpen(entry.url)
            dismiss()
        } label: {
            HStack(spacing: HistoryViewMetrics.rowSpacing) {
                FaviconView(url: entry.url,
                            size: HistoryViewMetrics.faviconSize,
                            fallbackSymbol: "clock.arrow.circlepath")
                VStack(alignment: .leading, spacing: HistoryViewMetrics.rowTextSpacing) {
                    Text(displayTitle(entry))
                        .font(.callout.weight(.medium))
                        .lineLimit(1)
                        .truncationMode(.tail)
                    Text(entry.url)
                        .font(.system(.caption, design: .monospaced))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                Spacer(minLength: 0)
            }
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .contextMenu {
            Button(role: .destructive) {
                history.delete(entry)
            } label: {
                Label("Delete", systemImage: "trash")
            }
        }
    }

    private func displayTitle(_ entry: HistoryEntry) -> String {
        let title = entry.title?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return title.isEmpty ? SiteVisual.host(for: entry.url) : title
    }

    /// Live filter: reuse the omnibox ranker when there's a query (so results
    /// match the URL bar), otherwise show all entries newest-first.
    private var filteredEntries: [HistoryEntry] {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return history.entries }
        let items = history.omniboxSuggestions(matching: trimmed,
                                               limit: HistoryViewMetrics.searchResultLimit)
        let matchedKeys = Set(items.filter { $0.kind == .history }.map { URLCanonicalizer.key($0.url) })
        return history.entries.filter { matchedKeys.contains($0.canonicalKey) }
    }

    // MARK: - Day grouping

    struct DayGroup {
        var title: String
        var entries: [HistoryEntry]
    }

    /// Groups entries (assumed newest-first or arbitrary) into day buckets ordered
    /// newest day first, each bucket sorted newest-visit first. Pure + testable.
    static func grouped(_ entries: [HistoryEntry], now: Date) -> [DayGroup] {
        let calendar = Calendar.current
        let sorted = entries.sorted { $0.lastVisited > $1.lastVisited }
        var order: [Date] = []
        var byDay: [Date: [HistoryEntry]] = [:]
        for entry in sorted {
            let day = calendar.startOfDay(for: entry.lastVisited)
            if byDay[day] == nil {
                byDay[day] = []
                order.append(day)
            }
            byDay[day]?.append(entry)
        }
        return order.map { day in
            DayGroup(title: title(for: day, now: now, calendar: calendar),
                     entries: byDay[day] ?? [])
        }
    }

    static func title(for day: Date, now: Date, calendar: Calendar) -> String {
        let today = calendar.startOfDay(for: now)
        if calendar.isDate(day, inSameDayAs: today) { return "Today" }
        if let yesterday = calendar.date(byAdding: .day,
                                         value: HistoryViewMetrics.yesterdayOffset,
                                         to: today),
           calendar.isDate(day, inSameDayAs: yesterday) {
            return "Yesterday"
        }
        let formatter = DateFormatter()
        if calendar.isDate(day, equalTo: now, toGranularity: .year) {
            formatter.dateFormat = "EEEE, MMMM d"
        } else {
            formatter.dateStyle = .long
            formatter.timeStyle = .none
        }
        return formatter.string(from: day)
    }
}
