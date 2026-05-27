import SwiftUI

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
}

enum SiteVisual {
    static func host(for url: String) -> String {
        URL(string: url)?.host(percentEncoded: false)
        ?? URL(string: "https://" + url)?.host(percentEncoded: false)
        ?? url
    }
}
