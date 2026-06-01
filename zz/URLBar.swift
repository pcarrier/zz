import SwiftUI
#if canImport(UIKit)
import UIKit
#elseif canImport(AppKit)
import AppKit
#endif

@MainActor
private func selectAll() {
    #if canImport(UIKit)
    DispatchQueue.main.async {
        UIApplication.shared.sendAction(
            #selector(UIResponder.selectAll(_:)),
            to: nil, from: nil, for: nil)
    }
    #elseif canImport(AppKit)
    DispatchQueue.main.async {
        NSApplication.shared.sendAction(
            #selector(NSResponder.selectAll(_:)),
            to: nil, from: nil)
    }
    #endif
}

struct URLBar: View {
    @Binding var text: String
    @FocusState.Binding var focused: Bool
    var placeholder: String = "Search or enter URL"
    var findEnabled: Bool = true
    var onFind: () -> Void = {}
    var onSubmit: () -> Void

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(.secondary)
            field
                .onChange(of: focused) { _, isFocused in
                    if isFocused { selectAll() }
                }
            Button(action: onFind) {
                Image(systemName: "text.magnifyingglass")
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(.secondary)
                    .frame(width: 24, height: 24)
                    .contentShape(.rect)
            }
            .buttonStyle(.plain)
            .disabled(!findEnabled)
            .opacity(findEnabled ? 1 : 0.35)
            .help("Find on Page (⌘F)")
            if !text.isEmpty && focused {
                Button {
                    text = ""
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(.tertiary)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 9)
        .padding(.vertical, 4)
        .background(Color.secondary.opacity(focused ? 0.14 : 0.10))
        .clipShape(.rect(cornerRadius: 7, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 7, style: .continuous)
                .stroke(focused ? Color.accentColor.opacity(0.48) : Color.secondary.opacity(0.18),
                        lineWidth: 0.75)
        )
    }

    @ViewBuilder
    private var field: some View {
        TextField(placeholder, text: $text)
            .textFieldStyle(.plain)
            .font(.system(.callout, design: .rounded))
            .focused($focused)
            .submitLabel(.go)
            .autocorrectionDisabled()
            #if !os(macOS)
            .textInputAutocapitalization(.never)
            .keyboardType(.webSearch)
            #endif
            .onSubmit(onSubmit)
    }
}

struct SuggestionList: View {
    let suggestions: [OmniboxItem]
    var selectedIndex: Int? = nil
    let onSelect: (OmniboxItem) -> Void

    private static let maxVisibleRows = 5
    fileprivate static let coordinateSpace = "SuggestionListCoordinateSpace"

    @State private var rowFrames: [String: CGRect] = [:]

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(Array(suggestions.enumerated()), id: \.element.id) { idx, item in
                        SuggestionRow(
                            item: item,
                            isSelected: idx == selectedIndex,
                            onSelect: onSelect
                        )
                        .id(item.id)
                        .background(SuggestionRowFrameReader(id: item.id))
                        if idx < suggestions.count - 1 {
                            Divider().opacity(0.4)
                        }
                    }
                }
                .coordinateSpace(name: Self.coordinateSpace)
                .onPreferenceChange(SuggestionRowFramePreferenceKey.self) { frames in
                    rowFrames = frames
                }
            }
            .frame(maxHeight: maxVisibleHeight)
            .scrollIndicators(.automatic)
            .onChange(of: selectedSuggestionID) { _, _ in
                scrollSelectionIntoView(proxy)
            }
            .onChange(of: suggestions.map(\.id)) { _, _ in
                scrollSelectionIntoView(proxy)
            }
        }
        .background(.regularMaterial)
        .overlay(
            Rectangle().stroke(.separator.opacity(0.4))
        )
        .shadow(color: .black.opacity(0.18), radius: 18, y: 8)
    }

    private var selectedSuggestionID: String? {
        guard let selectedIndex,
              selectedIndex >= 0,
              selectedIndex < suggestions.count else {
            return nil
        }
        return suggestions[selectedIndex].id
    }

    private func scrollSelectionIntoView(_ proxy: ScrollViewProxy) {
        guard let selectedSuggestionID else { return }
        withAnimation(.snappy(duration: 0.12)) {
            proxy.scrollTo(selectedSuggestionID, anchor: .center)
        }
    }

    private var maxVisibleHeight: CGFloat? {
        let visibleCount = min(suggestions.count, Self.maxVisibleRows)
        guard visibleCount > 0 else { return nil }
        let lastVisibleID = suggestions[visibleCount - 1].id
        guard let frame = rowFrames[lastVisibleID],
              frame.maxY > .zero else { return nil }
        return frame.maxY
    }
}

private struct SuggestionRow: View {
    let item: OmniboxItem
    let isSelected: Bool
    let onSelect: (OmniboxItem) -> Void

    @State private var didSelect = false

    var body: some View {
        Button {
            selectOnce()
        } label: {
            HStack(spacing: 10) {
                leadingIcon
                    .frame(width: 16)
                VStack(alignment: .leading, spacing: 3) {
                    highlighted(displayTitle, ranges: titleRanges, base: .primary)
                        .font(.callout.weight(.medium))
                        .lineLimit(1)
                        .truncationMode(.tail)
                    highlighted(item.url, ranges: item.urlRanges, base: .secondary)
                        .font(.system(.callout, design: .monospaced))
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                Spacer(minLength: 0)
                if item.kind == .openTab {
                    Text("Switch to Tab")
                        .font(.caption2.weight(.medium))
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(Color.secondary.opacity(0.12))
                        .clipShape(.capsule)
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(isSelected ? Color.accentColor.opacity(0.18) : Color.clear)
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .simultaneousGesture(
            DragGesture(minimumDistance: 0)
                .onChanged { _ in selectOnce() }
        )
    }

    private func selectOnce() {
        guard !didSelect else { return }
        didSelect = true
        onSelect(item)
    }

    /// Title ranges target the title string when present; otherwise we display
    /// the host and have no title ranges to apply.
    private var titleRanges: [Range<String.Index>] {
        let raw = item.title?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return raw.isEmpty ? [] : item.titleRanges
    }

    @ViewBuilder
    private func highlighted(_ string: String,
                             ranges: [Range<String.Index>],
                             base: Color) -> some View {
        // Apply the base color via .foregroundStyle on the Text, NOT inside the
        // AttributedString: a semantic Color like .secondary set as
        // AttributedString.foregroundColor renders transparent (invisible URLs).
        // Spans we explicitly color (the matches) override; the rest inherit base.
        Text(attributed(string, ranges: ranges)).foregroundStyle(base)
    }

    private func attributed(_ string: String,
                            ranges: [Range<String.Index>]) -> AttributedString {
        var attr = AttributedString(string)
        for r in ranges {
            // Clamp against the live string; ranges were built on the same
            // displayed value but guard against drift / combining chars.
            guard r.lowerBound >= string.startIndex,
                  r.upperBound <= string.endIndex,
                  r.lowerBound < r.upperBound,
                  let lo = AttributedString.Index(r.lowerBound, within: attr),
                  let hi = AttributedString.Index(r.upperBound, within: attr) else { continue }
            attr[lo..<hi].foregroundColor = .accentColor
            attr[lo..<hi].inlinePresentationIntent = .stronglyEmphasized
        }
        return attr
    }

    private var displayTitle: String {
        let title = item.title?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return title.isEmpty ? SiteVisual.host(for: item.url) : title
    }

    /// History/open-tab rows show the site favicon (with a globe fallback);
    /// search/open direct rows keep their SF Symbols.
    @ViewBuilder
    private var leadingIcon: some View {
        switch item.kind {
        case .history, .openTab:
            FaviconView(url: item.url, size: 16,
                        fallbackSymbol: item.kind == .openTab
                            ? "rectangle.on.rectangle" : "clock.arrow.circlepath")
        case .search, .open:
            Image(systemName: item.kind == .search ? "magnifyingglass" : "arrow.up.forward.app")
                .font(.system(size: 12))
                .foregroundStyle(.tertiary)
        }
    }
}

private struct SuggestionRowFrameReader: View {
    let id: String

    var body: some View {
        GeometryReader { proxy in
            Color.clear.preference(
                key: SuggestionRowFramePreferenceKey.self,
                value: [id: proxy.frame(in: .named(SuggestionList.coordinateSpace))]
            )
        }
    }
}

private struct SuggestionRowFramePreferenceKey: PreferenceKey {
    static var defaultValue: [String: CGRect] = [:]

    static func reduce(value: inout [String: CGRect],
                       nextValue: () -> [String: CGRect]) {
        value.merge(nextValue(), uniquingKeysWith: { _, new in new })
    }
}
