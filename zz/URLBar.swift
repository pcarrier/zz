import SwiftUI
#if canImport(UIKit)
import UIKit
#elseif canImport(AppKit)
import AppKit
#endif

/// Selects all text in whatever responder currently has the keyboard.
/// Called when the URL bar gains focus so a tap immediately selects the URL.
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
    var onSubmit: () -> Void

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(.secondary)
            TextField(placeholder, text: $text)
                .textFieldStyle(.plain)
                .font(.system(.callout, design: .rounded))
                .focused($focused)
                .submitLabel(.go)
                .autocorrectionDisabled()
                #if !os(macOS)
                .textInputAutocapitalization(.never)
                .keyboardType(.URL)
                #endif
                .onSubmit(onSubmit)
                .onChange(of: focused) { _, isFocused in
                    if isFocused { selectAll() }
                }
            if !text.isEmpty && focused {
                Button {
                    text = ""
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(.tertiary)
                }
                .buttonStyle(.plain)
                .transition(.opacity)
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(Color.secondary.opacity(0.12))
        .overlay(
            Rectangle().stroke(focused ? Color.accentColor.opacity(0.5) : .clear, lineWidth: 1)
        )
        .animation(.easeOut(duration: 0.12), value: focused)
    }
}

struct SuggestionList: View {
    let suggestions: [HistoryEntry]
    var selectedIndex: Int? = nil
    let onSelect: (HistoryEntry) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(Array(suggestions.enumerated()), id: \.element.id) { idx, entry in
                let isSelected = idx == selectedIndex
                Button {
                    onSelect(entry)
                } label: {
                    HStack(spacing: 10) {
                        Image(systemName: "clock.arrow.circlepath")
                            .font(.system(size: 12))
                            .foregroundStyle(.tertiary)
                            .frame(width: 16)
                        VStack(alignment: .leading, spacing: 1) {
                            if let title = entry.title, !title.isEmpty {
                                Text(title)
                                    .font(.callout)
                                    .lineLimit(1)
                            }
                            Text(entry.url)
                                .font(.system(.caption, design: .monospaced))
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                        }
                        Spacer(minLength: 0)
                    }
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
                    .background(isSelected ? Color.accentColor.opacity(0.18) : Color.clear)
                    .contentShape(.rect)
                }
                .buttonStyle(.plain)
                if idx < suggestions.count - 1 {
                    Divider().opacity(0.4)
                }
            }
        }
        .background(.regularMaterial)
        .overlay(
            Rectangle().stroke(.separator.opacity(0.4))
        )
        .shadow(color: .black.opacity(0.18), radius: 18, y: 8)
    }
}
