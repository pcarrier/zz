import SwiftUI
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
}

enum SiteVisual {
    static func host(for url: String) -> String {
        URL(string: url)?.host(percentEncoded: false)
        ?? URL(string: "https://" + url)?.host(percentEncoded: false)
        ?? url
    }
}

enum PaneSelectionVisual {
    static let strokeWidth: CGFloat = 2.0
}
