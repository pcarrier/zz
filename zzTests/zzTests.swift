import Foundation
import Testing
@testable import zz

@MainActor
struct BrowserUtilityTests {

    @Test func bareHostGetsHTTPS() {
        #expect(URLNormalizer.resolve("example.com")?.absoluteString == "https://example.com")
    }

    @Test func searchTermsUseDuckDuckGo() {
        #expect(URLNormalizer.resolve(
            "open ai",
            searchTemplate: SearchEngine.duckDuckGo.template!
        )?.absoluteString == "https://duckduckgo.com/?q=open%20ai")
    }

    @Test func searchTermsEscapeQueryDelimiters() {
        #expect(URLNormalizer.resolve(
            "a&b=c",
            searchTemplate: SearchEngine.duckDuckGo.template!
        )?.absoluteString == "https://duckduckgo.com/?q=a%26b%3Dc")
    }

    @Test func customSearchTemplateExpandsSearchTerms() {
        #expect(URLNormalizer.resolve(
            "open ai",
            searchTemplate: "https://example.com/search?s=%s"
        )?.absoluteString == "https://example.com/search?s=open%20ai")
    }

    @Test func droppedTextExtractsFirstLink() {
        #expect(DroppedURL.string(fromText: "Read https://example.com/path now") == "https://example.com/path")
    }

    @Test func fuzzyMatchRejectsMissingCharacters() {
        #expect(FuzzyMatch.score(needle: "zz", in: "browser") == nil)
        #expect(FuzzyMatch.score(needle: "zz", in: "Zebra Zone") != nil)
    }

    @Test func omniboxSuggestionsIncludeTypedURLFirst() {
        let history = [
            HistoryEntry(
                url: "https://example.com/docs",
                title: "Docs",
                lastVisited: .now
            )
        ]

        let suggestions = OmniboxSuggestions.entries(
            matching: "example.com",
            historyMatches: history,
            limit: 10
        )

        #expect(suggestions.map(\.url) == [
            "https://example.com",
            "https://example.com/docs",
        ])
        #expect(suggestions.first?.title == "Open")
    }

    @Test func omniboxSuggestionsIncludeTypedSearchFirst() {
        let suggestions = OmniboxSuggestions.entries(
            matching: "open ai",
            historyMatches: [],
            limit: 10,
            searchTemplate: SearchEngine.duckDuckGo.template!
        )

        #expect(suggestions.first?.url == "https://duckduckgo.com/?q=open%20ai")
        #expect(suggestions.first?.title == "Search")
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

    @Test func splittingGroupWrapsSelectedSubtree() {
        let outer = UUID(uuidString: "00000000-0000-0000-0000-000000000010")!
        let inner = UUID(uuidString: "00000000-0000-0000-0000-000000000011")!
        let left = UUID(uuidString: "00000000-0000-0000-0000-000000000001")!
        let topRight = UUID(uuidString: "00000000-0000-0000-0000-000000000002")!
        let bottomRight = UUID(uuidString: "00000000-0000-0000-0000-000000000003")!
        let fresh = UUID(uuidString: "00000000-0000-0000-0000-000000000004")!
        let root = BSPNode.split(
            id: outer, axis: .vertical, ratio: 0.5,
            first: .leaf(tabID: left),
            second: .split(
                id: inner, axis: .horizontal, ratio: 0.5,
                first: .leaf(tabID: topRight),
                second: .leaf(tabID: bottomRight)
            )
        )

        let result = root.splittingGroup(inner, axis: .vertical,
                                         newTabID: fresh, side: .after)

        guard case .split(_, .vertical, _, let first, let second) = result else {
            Issue.record("Expected the original outer split to remain vertical")
            return
        }
        #expect(first.tabIDs() == [left])

        guard case .split(_, .vertical, 0.5, let selectedGroup, let newPane) = second else {
            Issue.record("Expected the selected group to be wrapped in a new vertical split")
            return
        }
        #expect(selectedGroup.tabIDs() == [topRight, bottomRight])
        #expect(newPane.tabIDs() == [fresh])
    }

    @Test func parentSplitFindsNearestGroup() {
        let outer = UUID(uuidString: "00000000-0000-0000-0000-000000000010")!
        let inner = UUID(uuidString: "00000000-0000-0000-0000-000000000011")!
        let left = UUID(uuidString: "00000000-0000-0000-0000-000000000001")!
        let topRight = UUID(uuidString: "00000000-0000-0000-0000-000000000002")!
        let bottomRight = UUID(uuidString: "00000000-0000-0000-0000-000000000003")!
        let root = BSPNode.split(
            id: outer, axis: .vertical, ratio: 0.5,
            first: .leaf(tabID: left),
            second: .split(
                id: inner, axis: .horizontal, ratio: 0.5,
                first: .leaf(tabID: topRight),
                second: .leaf(tabID: bottomRight)
            )
        )

        #expect(root.parentSplitID(containingTab: bottomRight) == inner)
        #expect(root.parentSplitID(containingSplit: inner) == outer)
        #expect(root.parentSplitID(containingSplit: outer) == nil)
    }

    @Test func equalizingGroupResetsNestedRatios() {
        let outer = UUID(uuidString: "00000000-0000-0000-0000-000000000010")!
        let inner = UUID(uuidString: "00000000-0000-0000-0000-000000000011")!
        let left = UUID(uuidString: "00000000-0000-0000-0000-000000000001")!
        let topRight = UUID(uuidString: "00000000-0000-0000-0000-000000000002")!
        let bottomRight = UUID(uuidString: "00000000-0000-0000-0000-000000000003")!
        let root = BSPNode.split(
            id: outer, axis: .vertical, ratio: 0.25,
            first: .leaf(tabID: left),
            second: .split(
                id: inner, axis: .horizontal, ratio: 0.75,
                first: .leaf(tabID: topRight),
                second: .leaf(tabID: bottomRight)
            )
        )

        let result = root.equalizingRatios(in: outer)

        #expect(result.ratio(forSplit: outer) == 0.5)
        #expect(result.ratio(forSplit: inner) == 0.5)
    }

    @Test func rotatingGroupTogglesOnlySelectedSplitAxis() {
        let outer = UUID(uuidString: "00000000-0000-0000-0000-000000000010")!
        let inner = UUID(uuidString: "00000000-0000-0000-0000-000000000011")!
        let left = UUID(uuidString: "00000000-0000-0000-0000-000000000001")!
        let topRight = UUID(uuidString: "00000000-0000-0000-0000-000000000002")!
        let bottomRight = UUID(uuidString: "00000000-0000-0000-0000-000000000003")!
        let root = BSPNode.split(
            id: outer, axis: .vertical, ratio: 0.5,
            first: .leaf(tabID: left),
            second: .split(
                id: inner, axis: .horizontal, ratio: 0.5,
                first: .leaf(tabID: topRight),
                second: .leaf(tabID: bottomRight)
            )
        )

        let result = root.togglingAxis(for: inner)

        guard case .split(_, .vertical, _, _, let second) = result else {
            Issue.record("Expected the outer split axis to remain vertical")
            return
        }
        guard case .split(_, .vertical, _, _, _) = second else {
            Issue.record("Expected the selected inner split axis to become vertical")
            return
        }
    }
}
