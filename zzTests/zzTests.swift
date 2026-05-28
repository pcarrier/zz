import Foundation
import Testing
@testable import zz

@MainActor
struct BrowserUtilityTests {

    @Test func bareHostGetsHTTPS() {
        #expect(URLNormalizer.resolve("example.com")?.absoluteString == "https://example.com")
    }

    @Test func searchTermsUseDuckDuckGo() {
        #expect(URLNormalizer.resolve("open ai")?.absoluteString == "https://duckduckgo.com/?q=open%20ai")
    }

    @Test func searchTermsEscapeQueryDelimiters() {
        #expect(URLNormalizer.resolve("a&b=c")?.absoluteString == "https://duckduckgo.com/?q=a%26b%3Dc")
    }

    @Test func droppedTextExtractsFirstLink() {
        #expect(DroppedURL.string(fromText: "Read https://example.com/path now") == "https://example.com/path")
    }

    @Test func fuzzyMatchRejectsMissingCharacters() {
        #expect(FuzzyMatch.score(needle: "zz", in: "browser") == nil)
        #expect(FuzzyMatch.score(needle: "zz", in: "Zebra Zone") != nil)
    }

    @Test func removingLeafFocusesDirectSibling() {
        let a = UUID(uuidString: "00000000-0000-0000-0000-000000000001")!
        let b = UUID(uuidString: "00000000-0000-0000-0000-000000000002")!
        let root = BSPNode.split(
            id: UUID(), axis: .vertical, ratio: 0.5,
            first: .leaf(tabID: a),
            second: .leaf(tabID: b)
        )

        #expect(root.tabIDToFocusAfterRemoving(a) == b)
        #expect(root.tabIDToFocusAfterRemoving(b) == a)
    }

    @Test func removingLeafFocusesNearestSiblingEdge() {
        let top = UUID(uuidString: "00000000-0000-0000-0000-000000000001")!
        let bottomLeft = UUID(uuidString: "00000000-0000-0000-0000-000000000002")!
        let bottomRight = UUID(uuidString: "00000000-0000-0000-0000-000000000003")!
        let root = BSPNode.split(
            id: UUID(), axis: .horizontal, ratio: 0.5,
            first: .leaf(tabID: top),
            second: .split(
                id: UUID(), axis: .vertical, ratio: 0.5,
                first: .leaf(tabID: bottomLeft),
                second: .leaf(tabID: bottomRight)
            )
        )

        #expect(root.tabIDToFocusAfterRemoving(top) == bottomLeft)
    }
}
