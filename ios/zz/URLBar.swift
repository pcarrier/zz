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

private enum URLBarMetrics {
    static let controlSpacing: CGFloat = 6
    static let editableSpacing: CGFloat = 6
    static let findIconSize: CGFloat = 13
    static let searchIconSize: CGFloat = 12
    static let iconButtonSize: CGFloat = 24
    static let disabledOpacity: Double = 0.35

    static let horizontalPadding: CGFloat = 9
    static let verticalPadding: CGFloat = 4
    static let focusedBackgroundOpacity: Double = 0.14
    static let backgroundOpacity: Double = 0.10
    static let cornerRadius: CGFloat = 7
    static let focusedStrokeOpacity: Double = 0.48
    static let strokeOpacity: Double = 0.18
    static let strokeWidth: CGFloat = 0.75

    static let maxVisibleSuggestionRows = 5
    static let suggestionDividerOpacity: Double = 0.4
    static let suggestionBorderOpacity: Double = 0.4
    static let suggestionShadowOpacity: Double = 0.18
    static let suggestionShadowRadius: CGFloat = 18
    static let suggestionShadowYOffset: CGFloat = 8
    static let scrollAnimationDuration: TimeInterval = 0.12

    static let rowSpacing: CGFloat = 10
    static let rowIconWidth: CGFloat = 16
    static let rowTextSpacing: CGFloat = 3
    static let rowHorizontalPadding: CGFloat = 12
    static let rowVerticalPadding: CGFloat = 8
    static let selectedRowOpacity: Double = 0.18
    static let openTabBadgeHorizontalPadding: CGFloat = 6
    static let openTabBadgeVerticalPadding: CGFloat = 2
    static let openTabBadgeBackgroundOpacity: Double = 0.12
    static let tapGestureMinimumDistance: CGFloat = 0
    static let tapSlop: CGFloat = 8
}

struct URLBar: View {
    @Binding var text: String
    @FocusState.Binding var focused: Bool
    var placeholder: String = "Search or enter URL"
    var findEnabled: Bool = true
    var onFind: () -> Void = {}
    var onSubmit: () -> Void

    var body: some View {
        HStack(spacing: URLBarMetrics.controlSpacing) {
            editableArea
            Button(action: onFind) {
                Image(systemName: "text.magnifyingglass")
                    .font(.system(size: URLBarMetrics.findIconSize, weight: .medium))
                    .foregroundStyle(.secondary)
                    .frame(width: URLBarMetrics.iconButtonSize,
                           height: URLBarMetrics.iconButtonSize)
                    .contentShape(.rect)
            }
            .buttonStyle(.plain)
            .disabled(!findEnabled)
            .opacity(findEnabled ? 1 : URLBarMetrics.disabledOpacity)
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
        .padding(.horizontal, URLBarMetrics.horizontalPadding)
        .padding(.vertical, URLBarMetrics.verticalPadding)
        .background(Color.secondary.opacity(
            focused ? URLBarMetrics.focusedBackgroundOpacity : URLBarMetrics.backgroundOpacity
        ))
        .clipShape(.rect(cornerRadius: URLBarMetrics.cornerRadius, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: URLBarMetrics.cornerRadius, style: .continuous)
                .stroke(
                    focused
                        ? Color.accentColor.opacity(URLBarMetrics.focusedStrokeOpacity)
                        : Color.secondary.opacity(URLBarMetrics.strokeOpacity),
                    lineWidth: URLBarMetrics.strokeWidth
                )
        )
    }

    private var editableArea: some View {
        HStack(spacing: URLBarMetrics.editableSpacing) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: URLBarMetrics.searchIconSize, weight: .medium))
                .foregroundStyle(.secondary)
            field
                .onChange(of: focused) { _, isFocused in
                    if isFocused { selectAll() }
                }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentShape(.rect)
        .onTapGesture {
            if !focused { focused = true }
        }
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

    private static let maxVisibleRows = URLBarMetrics.maxVisibleSuggestionRows
    fileprivate static let coordinateSpace = "SuggestionListCoordinateSpace"

    @State private var rowFrames: [String: CGRect] = [:]

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                VStack(alignment: .leading, spacing: .zero) {
                    ForEach(Array(suggestions.enumerated()), id: \.element.id) { idx, item in
                        SuggestionRow(
                            item: item,
                            isSelected: idx == selectedIndex,
                            onSelect: onSelect
                        )
                        .id(item.id)
                        .background(SuggestionRowFrameReader(id: item.id))
                        if idx < suggestions.count - 1 {
                            Divider().opacity(URLBarMetrics.suggestionDividerOpacity)
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
            .preservesKeyboardOnScroll()
            .onChange(of: selectedSuggestionID) { _, _ in
                scrollSelectionIntoView(proxy)
            }
            .onChange(of: suggestions.map(\.id)) { _, _ in
                scrollSelectionIntoView(proxy)
            }
        }
        .background(.regularMaterial)
        .overlay(
            Rectangle().stroke(.separator.opacity(URLBarMetrics.suggestionBorderOpacity))
        )
        .shadow(color: .black.opacity(URLBarMetrics.suggestionShadowOpacity),
                radius: URLBarMetrics.suggestionShadowRadius,
                y: URLBarMetrics.suggestionShadowYOffset)
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
        withAnimation(.snappy(duration: URLBarMetrics.scrollAnimationDuration)) {
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
            HStack(spacing: URLBarMetrics.rowSpacing) {
                leadingIcon
                    .frame(width: URLBarMetrics.rowIconWidth)
                VStack(alignment: .leading, spacing: URLBarMetrics.rowTextSpacing) {
                    highlighted(displayTitle, ranges: titleRanges, base: .primary)
                        .font(.callout.weight(.medium))
                        .lineLimit(1)
                        .truncationMode(.tail)
                    highlighted(item.url, ranges: item.urlRanges, base: .secondaryLabelText)
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
                        .padding(.horizontal, URLBarMetrics.openTabBadgeHorizontalPadding)
                        .padding(.vertical, URLBarMetrics.openTabBadgeVerticalPadding)
                        .background(Color.secondary.opacity(URLBarMetrics.openTabBadgeBackgroundOpacity))
                        .clipShape(.capsule)
                }
            }
            .padding(.horizontal, URLBarMetrics.rowHorizontalPadding)
            .padding(.vertical, URLBarMetrics.rowVerticalPadding)
            .background(isSelected ? Color.accentColor.opacity(URLBarMetrics.selectedRowOpacity) : Color.clear)
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .simultaneousGesture(
            DragGesture(minimumDistance: URLBarMetrics.tapGestureMinimumDistance)
                .onEnded { value in
                    if value.translation.isTapSized {
                        selectOnce()
                    }
                }
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
        // Ranges from OmniboxRanker.classify are built against the RAW title
        // (`title ?? ""`). They are valid only when displayTitle renders that
        // same raw string; once we fall back to host, drop them.
        item.title?.isEmpty == false ? item.titleRanges : []
    }

    @ViewBuilder
    private func highlighted(_ string: String,
                             ranges: [Range<String.Index>],
                             base: Color) -> some View {
        Text(attributed(string, ranges: ranges, base: base))
    }

    private func attributed(_ string: String,
                            ranges: [Range<String.Index>],
                            base: Color) -> AttributedString {
        var attr = AttributedString(string)
        // Color EVERY run with a concrete base: runs left without an explicit
        // foregroundColor render transparent once any other run is colored, and a
        // semantic Color (.secondary) also renders transparent here -- both make
        // the non-highlighted parts of the URL disappear. `base` must be concrete.
        attr.foregroundColor = base
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
        // Must be the EXACT string titleRanges were computed against (the raw,
        // untrimmed `title ?? ""` from OmniboxRanker.classify) so highlight
        // String.Index offsets line up; fall back to host only when empty.
        let title = item.title ?? ""
        return title.isEmpty ? SiteVisual.host(for: item.url) : title
    }

    /// History/open-tab rows show the site favicon (with a globe fallback);
    /// search/open direct rows keep their SF Symbols.
    @ViewBuilder
    private var leadingIcon: some View {
        switch item.kind {
        case .history, .openTab:
            FaviconView(url: item.url, size: URLBarMetrics.rowIconWidth,
                        fallbackSymbol: item.kind == .openTab
                            ? "rectangle.on.rectangle" : "clock.arrow.circlepath")
        case .search, .open:
            Image(systemName: item.kind == .search ? "magnifyingglass" : "arrow.up.forward.app")
                .font(.system(size: URLBarMetrics.searchIconSize))
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

private extension View {
    @ViewBuilder
    func preservesKeyboardOnScroll() -> some View {
        #if os(iOS)
        scrollDismissesKeyboard(.never)
        #else
        self
        #endif
    }
}

private extension CGSize {
    var isTapSized: Bool {
        abs(width) <= URLBarMetrics.tapSlop && abs(height) <= URLBarMetrics.tapSlop
    }
}
