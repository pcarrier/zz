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
}
