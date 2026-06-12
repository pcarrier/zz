import Foundation
import Testing
@testable import zz

@MainActor
struct BrowserUtilityTests {

    @Test func bareHostGetsHTTPS() {
        #expect(URLNormalizer.resolve("example.com")?.absoluteString == "https://example.com")
    }

    @Test func explicitHTTPIPWithPortStaysHTTP() {
        #expect(URLNormalizer.resolve("http://100.99.84.87:5173")?.absoluteString == "http://100.99.84.87:5173")
    }

    @Test func bareHostPortGetsHTTPForDevServers() {
        #expect(URLNormalizer.resolve("localhost:5173")?.absoluteString == "http://localhost:5173")
        #expect(URLNormalizer.resolve("shortname:5173")?.absoluteString == "http://shortname:5173")
        #expect(URLNormalizer.resolve("100.99.84.87:5173")?.absoluteString == "http://100.99.84.87:5173")
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

    // MARK: - Keyword bangs

    private static let bangEngines = [
        KeywordEngine(keyword: "gh", templateURL: "https://github.com/search?q=%s", title: "GitHub"),
        KeywordEngine(keyword: "w", templateURL: "https://en.wikipedia.org/wiki/Special:Search?search=%s", title: "Wikipedia"),
    ]

    @Test func keywordBangExpandsToEngineTemplate() {
        let url = KeywordBangs.expand("gh swift testing", engines: Self.bangEngines)
        #expect(url?.absoluteString == "https://github.com/search?q=swift%20testing")
    }

    @Test func keywordBangMatchIsCaseInsensitiveAndReportsRemainder() {
        let m = KeywordBangs.match("GH  multi   word", engines: Self.bangEngines)
        #expect(m?.engine.title == "GitHub")
        #expect(m?.query == "multi   word")
    }

    @Test func bareKeywordHasEmptyQueryAndDoesNotExpand() {
        let m = KeywordBangs.match("gh", engines: Self.bangEngines)
        #expect(m?.engine.title == "GitHub")
        #expect(m?.query == "")
        // expand() requires a non-empty query, so a bare keyword falls through.
        #expect(KeywordBangs.expand("gh", engines: Self.bangEngines) == nil)
    }

    @Test func nonKeywordInputIsUnaffectedByBangs() {
        #expect(KeywordBangs.match("github.com", engines: Self.bangEngines) == nil)
        #expect(KeywordBangs.expand("open ai", engines: Self.bangEngines) == nil)
    }

    @Test func resolveExpandsKeywordOverDefaultSearch() {
        // With a matching keyword + query, resolve uses the engine template,
        // not the default search template.
        #expect(URLNormalizer.resolve(
            "gh swift",
            searchTemplate: SearchEngine.duckDuckGo.template!,
            keywordEngines: Self.bangEngines
        )?.absoluteString == "https://github.com/search?q=swift")
    }

    @Test func resolveLeavesNonKeywordInputToDefaultSearch() {
        #expect(URLNormalizer.resolve(
            "swift testing",
            searchTemplate: SearchEngine.duckDuckGo.template!,
            keywordEngines: Self.bangEngines
        )?.absoluteString == "https://duckduckgo.com/?q=swift%20testing")
    }

    @Test func bareKeywordResolvesViaNormalHandling() {
        // "w" alone: no remaining query, no dot, no space -> default search.
        #expect(URLNormalizer.resolve(
            "w",
            searchTemplate: SearchEngine.duckDuckGo.template!,
            keywordEngines: Self.bangEngines
        )?.absoluteString == "https://duckduckgo.com/?q=w")
    }

    @Test func directItemLabelsMatchedEngine() {
        let item = OmniboxSuggestions.directItem(
            for: "gh swift",
            searchTemplate: SearchEngine.duckDuckGo.template!,
            keywordEngines: Self.bangEngines)
        #expect(item?.kind == .search)
        #expect(item?.title == "Search GitHub")
        #expect(item?.url == "https://github.com/search?q=swift")
    }

    @Test func directItemKeepsPlainSearchLabelForNonKeyword() {
        let item = OmniboxSuggestions.directItem(
            for: "open ai",
            searchTemplate: SearchEngine.duckDuckGo.template!,
            keywordEngines: Self.bangEngines)
        #expect(item?.title == "Search")
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
            history: history,
            openTabs: [],
            limit: 10
        )

        #expect(suggestions.map(\.url) == [
            "https://example.com",
            "https://example.com/docs",
        ])
        #expect(suggestions.first?.title == "Open")
        #expect(suggestions.first?.kind == .open)
    }

    @Test func omniboxSuggestionsIncludeTypedSearchFirst() {
        let suggestions = OmniboxSuggestions.entries(
            matching: "open ai",
            history: [],
            openTabs: [],
            limit: 10,
            searchTemplate: SearchEngine.duckDuckGo.template!
        )

        #expect(suggestions.first?.url == "https://duckduckgo.com/?q=open%20ai")
        #expect(suggestions.first?.title == "Search")
        #expect(suggestions.first?.kind == .search)
    }

    // MARK: - Omnibox ranker overhaul

    private static let pinnedNow = Date(timeIntervalSince1970: 1_700_000_000)

    private func entry(_ url: String, _ title: String? = nil,
                       count: Int = 1, ageSeconds: TimeInterval = 60) -> HistoryEntry {
        HistoryEntry(url: url, title: title,
                     lastVisited: Self.pinnedNow.addingTimeInterval(-ageSeconds),
                     visitCount: count)
    }

    private func suggest(_ query: String, _ history: [HistoryEntry],
                         openTabs: [(url: String, title: String?, tabID: UUID)] = [],
                         limit: Int = 20) -> [OmniboxItem] {
        OmniboxSuggestions.entries(
            matching: query, history: history, openTabs: openTabs,
            now: Self.pinnedNow, limit: limit,
            searchTemplate: SearchEngine.duckDuckGo.template!,
            keywordEngines: [])
    }

    @Test func hostPrefixBeatsScatter() {
        let history = [
            entry("https://login.target.com/account", "Target Login"),
            entry("https://github.com", "GitHub"),
        ]
        let out = suggest("git", history)
        let real = out.filter { $0.kind != .search && $0.kind != .open }
        #expect(real.first?.url == "https://github.com")
        if let target = real.firstIndex(where: { $0.url.contains("login.target.com") }),
           let gh = real.firstIndex(where: { $0.url == "https://github.com" }) {
            #expect(gh < target)
        }
    }

    @Test func rejectsPureScatter() {
        // "xyz" only appears as a scattered subsequence, never contiguous/boundary.
        let history = [entry("https://example.com/x-foo-y-bar-z-baz", "Example")]
        let out = suggest("xyz", history)
        #expect(out.allSatisfy { $0.kind == .open || $0.kind == .search })
    }

    @Test func contiguousSubstringBeatsFuzzy() {
        // github.com matches "hub" as a contiguous substring (Tier 2). The other
        // entry only matches as a scattered subsequence (Tier 1 fuzzy).
        let history = [
            entry("https://github.com", "GitHub"),
            entry("https://thunderbolt.example.com/x", "Thunderbolt"),
        ]
        let out = suggest("hub", history)
        let real = out.filter { $0.kind == .history || $0.kind == .openTab }
        #expect(real.first?.url == "https://github.com")
    }

    @Test func acronymMatchesWordStarts() {
        let gh = suggest("gh", [entry("https://github.com", "GitHub")])
            .filter { $0.kind == .history }
        #expect(gh.first?.url == "https://github.com")

        let so = suggest("so", [entry("https://stackoverflow.com", "Stack Overflow")])
            .filter { $0.kind == .history }
        #expect(so.first?.url == "https://stackoverflow.com")
    }

    @Test func frequencyOutranksRecencyWithinTier() {
        // A heavily-visited site slightly less recent still wins: its frequency
        // weight (200 visits) outweighs the one-bucket recency deficit.
        let history = [
            entry("https://gitlab.com", "GitLab", count: 1, ageSeconds: 60),
            entry("https://github.com", "GitHub", count: 200, ageSeconds: 4_000),
        ]
        let out = suggest("git", history).filter { $0.kind == .history }
        #expect(out.first?.url == "https://github.com")
    }

    @Test func recencyOutranksWithinTierWhenCountsEqual() {
        // Equal visitCount: the more recent (younger recency bucket) wins.
        let recent = [
            entry("https://gitb.com", "GitB", count: 5, ageSeconds: 200_000),
            entry("https://gita.com", "GitA", count: 5, ageSeconds: 4_000),
        ]
        let out = suggest("git", recent).filter { $0.kind == .history }
        #expect(out.first?.url == "https://gita.com")

        // Flips when the older one's visit count is high enough to overcome the
        // one-bucket recency deficit.
        let flipped = [
            entry("https://gitb.com", "GitB", count: 1000, ageSeconds: 200_000),
            entry("https://gita.com", "GitA", count: 5, ageSeconds: 4_000),
        ]
        let out2 = suggest("git", flipped).filter { $0.kind == .history }
        #expect(out2.first?.url == "https://gitb.com")
    }

    @Test func tierDominatesFrequency() {
        let history = [
            entry("https://example.com/git-archive-tool", "Git Archive", count: 500),
            entry("https://github.com", "GitHub", count: 1),
        ]
        let out = suggest("git", history).filter { $0.kind == .history }
        #expect(out.first?.url == "https://github.com")
    }

    @Test func frequencyWeightLog2Capped() {
        let w1 = OmniboxRanker.frequencyWeight(visitCount: 1)
        let w10 = OmniboxRanker.frequencyWeight(visitCount: 10)
        let w1000 = OmniboxRanker.frequencyWeight(visitCount: 1000)
        #expect(w1 < w10)
        #expect(w10 <= w1000)
        #expect(w1000 <= 400)
        #expect(w1 >= 0)
    }

    @Test func normalizedDedupCollapsesVariants() {
        let store = HistoryStore()
        store.clear()
        store.record(url: "https://x.com", title: "X")
        store.record(url: "https://x.com/", title: "X")
        store.record(url: "http://x.com", title: "X")
        store.record(url: "https://www.x.com", title: "X")
        #expect(store.entries.count == 1)
        #expect(store.entries.first?.visitCount == 4)
    }

    @Test func recordIncrementsVisitCount() {
        let store = HistoryStore()
        store.clear()
        store.record(url: "https://y.com/page", title: "Y")
        let firstVisit = store.entries.first?.lastVisited
        store.record(url: "https://y.com/page", title: "Y")
        #expect(store.entries.count == 1)
        #expect(store.entries.first?.visitCount == 2)
        if let firstVisit, let second = store.entries.first?.lastVisited {
            #expect(second >= firstVisit)
        }
    }

    @Test func legacyHistoryDecodesVisitCountDefaultsToOne() throws {
        let json = """
        [{"url":"https://legacy.com","title":"Legacy","lastVisited":0}]
        """.data(using: .utf8)!
        let decoded = try JSONDecoder().decode([HistoryEntry].self, from: json)
        #expect(decoded.count == 1)
        #expect(decoded.first?.visitCount == 1)
    }

    @Test func canonicalDedupeInSuggestions() {
        let history = [
            entry("https://x.com", "X"),
            entry("https://x.com/", "X"),
        ]
        let out = suggest("x.com", history).filter { $0.kind == .history }
        #expect(out.count == 1)
    }

    @Test func directEntrySuppressedWhenRealPrefixExists() {
        let history = [entry("https://github.com", "GitHub", count: 5)]
        let out = suggest("github.com", history)
        let ghRows = out.filter { URLCanonicalizer.key($0.url) == "https://github.com" }
        #expect(ghRows.count == 1)
        #expect(ghRows.first?.kind == .history)
    }

    @Test func directEntryKeptForNovelURL() {
        let out = suggest("newsite.com", [])
        #expect(out.first?.kind == .open)
        #expect(out.first?.url == "https://newsite.com")
    }

    @Test func openTabSuggestionFloatsAndDedups() {
        let tabID = UUID()
        let history = [entry("https://github.com", "GitHub", count: 3)]
        let out = suggest("git", history,
                          openTabs: [(url: "https://github.com", title: "GitHub", tabID: tabID)])
        let nonDirect = out.filter { $0.kind != .open && $0.kind != .search }
        #expect(nonDirect.first?.kind == .openTab)
        #expect(nonDirect.first?.tabID == tabID)
        // History row for the same key is suppressed.
        #expect(nonDirect.filter { URLCanonicalizer.key($0.url) == "https://github.com" }.count == 1)
    }

    @Test func openTabRoutesToFocusNotLoad() {
        let tabID = UUID()
        let openTab = OmniboxItem(id: "k", url: "https://github.com", title: "GitHub",
                                  kind: .openTab, tabID: tabID)
        #expect(OmniboxRoute.route(for: openTab) == .focus(tabID))

        let hist = OmniboxItem(id: "k2", url: "https://github.com", title: "GitHub", kind: .history)
        #expect(OmniboxRoute.route(for: hist) == .load("https://github.com"))

        let open = OmniboxItem(id: "k3", url: "https://new.com", title: "Open", kind: .open)
        #expect(OmniboxRoute.route(for: open) == .load("https://new.com"))
    }

    @Test func matchRangesReported() {
        let norm = OmniboxRanker.normalize("git")
        let cls = OmniboxRanker.classify(query: norm, host: "github.com",
                                         url: "https://github.com", title: "GitHub")
        #expect(cls != nil)
        if let cls {
            // url range covers leading "git" in the host portion of the url.
            #expect(cls.urlRanges.contains { range in
                "https://github.com"[range].lowercased() == "git"
            })
            #expect(cls.titleRanges.contains { range in
                "GitHub"[range].lowercased() == "git"
            })
        }
    }

    @Test func earlinessBonusOrdersSubstrings() {
        // Two Tier-2 substrings: earlier index ranks first.
        let history = [
            entry("https://example.com/a/b/zztarget", "deep target"),
            entry("https://example.com/zztarget/a/b", "shallow target"),
        ]
        let out = suggest("zztarget", history).filter { $0.kind == .history }
        #expect(out.first?.url == "https://example.com/zztarget/a/b")

        // Host-prefix docs.x.com beats substring x.com/docs for "doc".
        let docHistory = [
            entry("https://x.com/docs", "X Docs"),
            entry("https://docs.x.com", "Docs"),
        ]
        let docOut = suggest("doc", docHistory).filter { $0.kind == .history }
        #expect(docOut.first?.url == "https://docs.x.com")
    }

    @Test func shorterUrlWinsOnTie() {
        let history = [
            entry("https://x.com/a?utm=longlonglongtracking", "A"),
            entry("https://x.com/a", "A"),
        ]
        // Query the host (not "x.com/a"): a query that canonicalizes to one of
        // the entries' keys would be shown once as the typed/direct row and have
        // its history duplicate suppressed, hiding the tiebreak. "x.com" matches
        // both history rows but canonicalizes to neither, so both survive and the
        // shorter canonical URL must win on the length tiebreak.
        let out = suggest("x.com", history).filter { $0.kind == .history }
        #expect(out.first?.url == "https://x.com/a")
    }

    @Test func deterministicTotalOrder() {
        let history = [
            entry("https://a.com/git", "Git A", count: 5, ageSeconds: 60),
            entry("https://b.com/git", "Git B", count: 5, ageSeconds: 60),
            entry("https://c.com/git", "Git C", count: 5, ageSeconds: 60),
        ]
        let a = suggest("git", history).map(\.url)
        let b = suggest("git", history).map(\.url)
        #expect(a == b)
    }

    @Test func emptyQueryOrdersOpenTabsThenFrecency() {
        let tabID = UUID()
        let history = [
            entry("https://rare.com", "Rare", count: 1, ageSeconds: 2_000_000),
            entry("https://hot.com", "Hot", count: 100, ageSeconds: 60),
        ]
        let out = OmniboxSuggestions.entries(
            matching: "", history: history,
            openTabs: [(url: "https://opentab.com", title: "Open Tab", tabID: tabID)],
            now: Self.pinnedNow, limit: 20)
        #expect(out.first?.kind == .openTab)
        let hist = out.filter { $0.kind == .history }
        #expect(hist.first?.url == "https://hot.com")
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

@MainActor
struct BrowserLogicTests {

    @Test func candidateURLsUseOnlySiteFavicon() {
        let urls = FaviconLogic.candidateURLs(host: "example.com").map(\.absoluteString)
        // Only the site's own favicon.ico -- no third-party (e.g. Google s2) fallback
        // that would leak the visited hostname.
        #expect(urls == ["https://example.com/favicon.ico"])
    }

    @Test func candidateURLsEmptyHostYieldsNothing() {
        #expect(FaviconLogic.candidateURLs(host: "   ").isEmpty)
        #expect(FaviconLogic.candidateURLs(host: "").isEmpty)
    }

    @Test func candidateURLsLowercaseHost() {
        let urls = FaviconLogic.candidateURLs(host: "EXAMPLE.com").map(\.absoluteString)
        #expect(urls.first == "https://example.com/favicon.ico")
    }

    @Test func fileNameIsStableSafeAndCaseInsensitive() {
        let a = FaviconLogic.fileName(for: "example.com")
        let b = FaviconLogic.fileName(for: "example.com")
        let c = FaviconLogic.fileName(for: "EXAMPLE.COM")
        #expect(a == b)
        #expect(a == c)
        #expect(a.hasSuffix(".img"))
        #expect(!a.contains("/"))
        #expect(!a.contains(":"))
    }

    @Test func fileNamesDifferAcrossHosts() {
        #expect(FaviconLogic.fileName(for: "example.com") != FaviconLogic.fileName(for: "example.org"))
    }

    @Test func deleteRemovesMatchingEntry() {
        let store = HistoryStore()
        store.clear()
        store.record(url: "https://a.com/page", title: "A")
        store.record(url: "https://b.com/page", title: "B")
        #expect(store.entries.count == 2)
        store.delete(url: "https://a.com/page")
        #expect(store.entries.count == 1)
        #expect(store.entries.first?.url == "https://b.com/page")
    }

    @Test func deleteMatchesCanonicalVariants() {
        let store = HistoryStore()
        store.clear()
        store.record(url: "https://x.com/page", title: "X")
        // A different surface form that canonicalizes to the same key.
        store.delete(url: "http://www.x.com/page")
        #expect(store.entries.isEmpty)
    }

    @Test func deleteUnknownURLIsNoOp() {
        let store = HistoryStore()
        store.clear()
        store.record(url: "https://a.com", title: "A")
        store.delete(url: "https://missing.com")
        #expect(store.entries.count == 1)
    }

    @Test func deleteEntryRemovesByValue() {
        let store = HistoryStore()
        store.clear()
        store.record(url: "https://a.com", title: "A")
        store.record(url: "https://b.com", title: "B")
        guard let entry = store.entries.first(where: { $0.url == "https://a.com" }) else {
            Issue.record("expected recorded entry")
            return
        }
        store.delete(entry)
        #expect(store.entries.count == 1)
        #expect(store.entries.allSatisfy { $0.url != "https://a.com" })
    }

    @Test func historyGroupingBucketsByDayNewestFirst() {
        let now = Date(timeIntervalSince1970: 1_700_000_000) // fixed reference
        let cal = Calendar.current
        let today = now
        let yesterday = cal.date(byAdding: .day, value: -1, to: now)!
        let lastWeek = cal.date(byAdding: .day, value: -7, to: now)!
        let entries = [
            HistoryEntry(url: "https://old.com", title: "Old", lastVisited: lastWeek),
            HistoryEntry(url: "https://today.com", title: "Today", lastVisited: today),
            HistoryEntry(url: "https://yest.com", title: "Yest", lastVisited: yesterday),
        ]
        let groups = HistoryView.grouped(entries, now: now)
        #expect(groups.count == 3)
        #expect(groups.first?.title == "Today")
        #expect(groups[1].title == "Yesterday")
        #expect(groups.first?.entries.first?.url == "https://today.com")
    }

    @Test func decodeRejectsGarbageData() {
        #expect(FaviconLogic.decode(Data()) == nil)
        #expect(FaviconLogic.decode(Data([0x00, 0x01, 0x02, 0x03])) == nil)
    }

    @Test func evictionDropsOldestBeyondCap() {
        let order = ["a", "b", "c", "d", "e"]
        #expect(FaviconLogic.hostsToEvict(order: order, cap: 3) == ["a", "b"])
        #expect(FaviconLogic.hostsToEvict(order: order, cap: 5).isEmpty)
        #expect(FaviconLogic.hostsToEvict(order: order, cap: 10).isEmpty)
        #expect(FaviconLogic.hostsToEvict(order: order, cap: 0).isEmpty)
    }

    @Test func tileMenuBlankTileOnlyCloses() {
        let actions = TileMenuActions(isBlank: true)
        #expect(!actions.canDuplicate)
        #expect(!actions.canCopyURL)
        #expect(!actions.canReload)
        #expect(!actions.canPark)
    }

    @Test func tileMenuLoadedTileOffersAllActions() {
        let actions = TileMenuActions(isBlank: false)
        #expect(actions.canDuplicate)
        #expect(actions.canCopyURL)
        #expect(actions.canReload)
        #expect(actions.canPark)
    }

    // MARK: Page zoom

    @Test func pageZoomStepsByTenths() {
        #expect(PageZoom.zoomedIn(1.0) == 1.1)
        #expect(PageZoom.zoomedOut(1.0) == 0.9)
    }

    @Test func pageZoomClampsToBounds() {
        #expect(PageZoom.clamp(0.1) == PageZoom.minLevel)
        #expect(PageZoom.clamp(9.0) == PageZoom.maxLevel)
        #expect(PageZoom.clamp(1.25) == 1.25)
    }

    @Test func pageZoomStepsSaturateAtBounds() {
        // Zooming out from the floor / in from the ceiling never escapes the range.
        #expect(PageZoom.zoomedOut(PageZoom.minLevel) == PageZoom.minLevel)
        #expect(PageZoom.zoomedIn(PageZoom.maxLevel) == PageZoom.maxLevel)
    }

    @Test func tabRecordDecodesPageZoom() throws {
        let json = #"{"id":"\#(UUID().uuidString)","url":"https://a.com","scrollX":0,"scrollY":0,"pageZoom":1.5}"#
        let record = try JSONDecoder().decode(TabRecord.self, from: Data(json.utf8))
        #expect(record.pageZoom == 1.5)
    }

    @Test func legacyTabRecordDefaultsPageZoomToOne() throws {
        // Pre-zoom snapshots have no pageZoom key; decode must default to 1.0.
        let json = #"{"id":"\#(UUID().uuidString)","url":"https://a.com","scrollX":0,"scrollY":0}"#
        let record = try JSONDecoder().decode(TabRecord.self, from: Data(json.utf8))
        #expect(record.pageZoom == PageZoom.defaultLevel)
    }

    @Test func tabRecordPageZoomRoundTrips() throws {
        let original = TabRecord(id: UUID(), url: "https://a.com", title: "A", pageZoom: 1.3)
        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(TabRecord.self, from: data)
        #expect(decoded.pageZoom == 1.3)
    }

    // MARK: Desktop site content mode

    @Test func desktopUserAgentOnlyWhenRequested() {
        #expect(DesktopSiteMode.customUserAgent(requestsDesktop: false) == nil)
        let agent = DesktopSiteMode.customUserAgent(requestsDesktop: true)
        #expect(agent?.contains("Macintosh") == true)
        #expect(agent?.contains("Safari") == true)
    }

    @Test func tabRecordDecodesRequestsDesktopSite() throws {
        let json = #"{"id":"\#(UUID().uuidString)","url":"https://a.com","scrollX":0,"scrollY":0,"pageZoom":1.0,"requestsDesktopSite":true}"#
        let record = try JSONDecoder().decode(TabRecord.self, from: Data(json.utf8))
        #expect(record.requestsDesktopSite == true)
    }

    @Test func legacyTabRecordDefaultsRequestsDesktopSiteToFalse() throws {
        // Pre-DesktopSite snapshots have no requestsDesktopSite key.
        let json = #"{"id":"\#(UUID().uuidString)","url":"https://a.com","scrollX":0,"scrollY":0,"pageZoom":1.0}"#
        let record = try JSONDecoder().decode(TabRecord.self, from: Data(json.utf8))
        #expect(record.requestsDesktopSite == false)
    }

    @Test func tabRecordRequestsDesktopSiteRoundTrips() throws {
        let original = TabRecord(id: UUID(), url: "https://a.com", title: "A", requestsDesktopSite: true)
        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(TabRecord.self, from: data)
        #expect(decoded.requestsDesktopSite == true)
    }

    @Test func tileMenuAllowsDesktopSiteToggleWhenContentPresent() {
        #expect(TileMenuActions(isBlank: false).canRequestDesktopSite == true)
        #expect(TileMenuActions(isBlank: true).canRequestDesktopSite == false)
    }

    // MARK: Pane media suspension

    @Test func tileMenuAllowsSuspendMediaOnlyWhenContentPresent() {
        #expect(TileMenuActions(isBlank: false).canSuspendMedia == true)
        #expect(TileMenuActions(isBlank: true).canSuspendMedia == false)
    }

    @Test func tabRecordDecodesMediaSuspended() throws {
        let json = #"{"id":"\#(UUID().uuidString)","url":"https://a.com","scrollX":0,"scrollY":0,"pageZoom":1.0,"requestsDesktopSite":false,"mediaSuspended":true}"#
        let record = try JSONDecoder().decode(TabRecord.self, from: Data(json.utf8))
        #expect(record.mediaSuspended == true)
    }

    @Test func legacyIsMutedKeyMapsToMediaSuspended() throws {
        // Snapshots from the earlier SPI-mute build used the "isMuted" key; it must
        // still map onto mediaSuspended for a clean upgrade.
        let json = #"{"id":"\#(UUID().uuidString)","url":"https://a.com","scrollX":0,"scrollY":0,"pageZoom":1.0,"isMuted":true}"#
        let record = try JSONDecoder().decode(TabRecord.self, from: Data(json.utf8))
        #expect(record.mediaSuspended == true)
    }

    @Test func legacyTabRecordDefaultsMediaSuspendedToFalse() throws {
        // Older snapshots have neither key; decode must default to false.
        let json = #"{"id":"\#(UUID().uuidString)","url":"https://a.com","scrollX":0,"scrollY":0,"pageZoom":1.0}"#
        let record = try JSONDecoder().decode(TabRecord.self, from: Data(json.utf8))
        #expect(record.mediaSuspended == false)
    }

    @Test func tabRecordMediaSuspendedRoundTrips() throws {
        let original = TabRecord(id: UUID(), url: "https://a.com", title: "A", mediaSuspended: true)
        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(TabRecord.self, from: data)
        #expect(decoded.mediaSuspended == true)
    }

}

// MARK: - Layout presets

@MainActor
struct LayoutPresetTests {

    private func preset(_ name: String) -> LayoutPreset {
        let id = UUID()
        let node: BSPNode = .leaf(tabID: id)
        let records = [TabRecord(id: id, url: "https://a.com", title: "A")]
        return LayoutPreset(name: name, root: node,
                            focusedTabID: records.first?.id, tabs: records)
    }

    @Test func normalizedNameTrimsAndFallsBack() {
        #expect(LayoutPresetLogic.normalizedName("  Work  ") == "Work")
        #expect(LayoutPresetLogic.normalizedName("   ") == "Layout")
        #expect(LayoutPresetLogic.normalizedName("") == "Layout")
    }

    @Test func addAppendsPreset() {
        let p = preset("One")
        let list = LayoutPresetLogic.adding(p, to: [])
        #expect(list.map(\.name) == ["One"])
    }

    @Test func removeByIDDropsOnlyThatPreset() {
        let a = preset("A")
        let b = preset("B")
        let list = LayoutPresetLogic.removing(id: a.id, from: [a, b])
        #expect(list.map(\.id) == [b.id])
    }

    @Test func removeUnknownIDIsNoOp() {
        let a = preset("A")
        let list = LayoutPresetLogic.removing(id: UUID(), from: [a])
        #expect(list.map(\.id) == [a.id])
    }

    @Test func presetRoundTripsEncoding() throws {
        let id1 = UUID()
        let id2 = UUID()
        let root = BSPNode.split(
            id: UUID(), axis: .vertical, ratio: 0.4,
            first: .leaf(tabID: id1), second: .leaf(tabID: id2))
        let records = [
            TabRecord(id: id1, url: "https://a.com", title: "A", pageZoom: 1.2),
            TabRecord(id: id2, url: "https://b.com", title: nil),
        ]
        let original = LayoutPreset(name: "Split", root: root,
                                    focusedTabID: id2, tabs: records)
        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(LayoutPreset.self, from: data)
        #expect(decoded == original)
        #expect(decoded.root.tabIDs() == [id1, id2])
        #expect(decoded.focusedTabID == id2)
        #expect(decoded.tabs.first(where: { $0.id == id1 })?.pageZoom == 1.2)
    }

    @Test func decodeToleratesMissingOptionalFields() throws {
        // Old preset files may lack id/name/focusedTabID/tabs.
        let json = """
        {"root":{"leaf":{"tabID":"\(UUID().uuidString)"}}}
        """
        let decoded = try JSONDecoder().decode(
            LayoutPreset.self, from: Data(json.utf8))
        #expect(decoded.name == "Layout")
        #expect(decoded.tabs.isEmpty)
        #expect(decoded.focusedTabID == nil)
    }

    @Test func roundTripPreservesStructureWithDuplicateLeafIDs() {
        // A snapshot with a repeated leaf id: dedup rewrites the second leaf's id
        // but must preserve the tree shape (one split, two leaves).
        let dup = UUID()
        let root = BSPNode.split(
            id: UUID(), axis: .horizontal, ratio: 0.5,
            first: .leaf(tabID: dup), second: .leaf(tabID: dup))
        var seen = Set<UUID>()
        let deduped = root.deduplicatingLeafIDs(seen: &seen)
        let ids = deduped.tabIDs()
        #expect(ids.count == 2)
        #expect(Set(ids).count == 2)            // ids made unique
        #expect(ids.first == dup)               // first occurrence kept
        if case .split(_, let axis, let ratio, _, _) = deduped {
            #expect(axis == .horizontal)
            #expect(ratio == 0.5)
        } else {
            Issue.record("expected a split at the root")
        }
    }
}
