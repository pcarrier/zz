import Foundation

nonisolated enum SearchEngine: String, CaseIterable, Identifiable {
    case duckDuckGo
    case google
    case custom

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .duckDuckGo: return "DuckDuckGo"
        case .google: return "Google"
        case .custom: return "Custom"
        }
    }

    var template: String? {
        switch self {
        case .duckDuckGo: return "https://duckduckgo.com/?q=%s"
        case .google: return "https://www.google.com/search?q=%s"
        case .custom: return nil
        }
    }
}

/// A user-defined keyword ("bang") search engine. The `keyword` is the first
/// whitespace-delimited token typed in the omnibox; the remaining query is
/// substituted into `templateURL` using the same `%s` machinery as the custom
/// search template. Pure value type so it can cross the actor boundary for
/// JSON encode/decode off the main actor and live in default-argument
/// expressions / sort comparators.
nonisolated struct KeywordEngine: Codable, Identifiable, Hashable {
    var id: UUID
    var keyword: String
    var templateURL: String
    var title: String

    init(id: UUID = UUID(), keyword: String, templateURL: String, title: String) {
        self.id = id
        self.keyword = keyword
        self.templateURL = templateURL
        self.title = title
    }

    enum CodingKeys: String, CodingKey {
        case id, keyword, templateURL, title
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        // Back-compat: tolerate records that predate any of these fields.
        id = try c.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        keyword = try c.decodeIfPresent(String.self, forKey: .keyword) ?? ""
        templateURL = try c.decodeIfPresent(String.self, forKey: .templateURL) ?? ""
        title = try c.decodeIfPresent(String.self, forKey: .title) ?? ""
    }
}

nonisolated enum SearchPreferences {
    static let engineKey = "searchEngine"
    static let customTemplateKey = "customSearchTemplate"
    static let keywordEnginesKey = "keywordEngines"
    static let defaultEngine = SearchEngine.duckDuckGo
    static let defaultCustomTemplate = SearchEngine.duckDuckGo.template!

    /// Seeded so users discover the feature; safe because they share no keyword
    /// with normal URLs/queries and only fire when a keyword + query is typed.
    static let defaultKeywordEngines: [KeywordEngine] = [
        KeywordEngine(keyword: "g", templateURL: "https://www.google.com/search?q=%s", title: "Google"),
        KeywordEngine(keyword: "gh", templateURL: "https://github.com/search?q=%s", title: "GitHub"),
        KeywordEngine(keyword: "w", templateURL: "https://en.wikipedia.org/wiki/Special:Search?search=%s", title: "Wikipedia"),
        KeywordEngine(keyword: "yt", templateURL: "https://www.youtube.com/results?search_query=%s", title: "YouTube"),
    ]

    private static let searchQueryAllowed: CharacterSet = {
        var allowed = CharacterSet.urlQueryAllowed
        allowed.remove(charactersIn: "&=?+#")
        return allowed
    }()

    static var selectedEngine: SearchEngine {
        get {
            let raw = UserDefaults.standard.string(forKey: engineKey)
            return raw.flatMap(SearchEngine.init(rawValue:)) ?? defaultEngine
        }
        set {
            UserDefaults.standard.set(newValue.rawValue, forKey: engineKey)
        }
    }

    static var customTemplate: String {
        get {
            UserDefaults.standard.string(forKey: customTemplateKey) ?? defaultCustomTemplate
        }
        set {
            UserDefaults.standard.set(newValue, forKey: customTemplateKey)
        }
    }

    /// User-defined keyword ("bang") engines. Persisted as JSON in UserDefaults.
    /// When the key is absent (fresh/old install) we seed sensible defaults; an
    /// explicitly-empty stored array (user removed all) decodes to `[]`.
    static var keywordEngines: [KeywordEngine] {
        get {
            guard let data = UserDefaults.standard.data(forKey: keywordEnginesKey) else {
                return defaultKeywordEngines
            }
            return (try? JSONDecoder().decode([KeywordEngine].self, from: data))
                ?? defaultKeywordEngines
        }
        set {
            if let data = try? JSONEncoder().encode(newValue) {
                UserDefaults.standard.set(data, forKey: keywordEnginesKey)
            }
        }
    }

    static var activeTemplate: String {
        switch selectedEngine {
        case .custom:
            return normalizedTemplate(customTemplate) ?? defaultCustomTemplate
        default:
            return selectedEngine.template ?? defaultCustomTemplate
        }
    }

    static func searchURL(for query: String,
                          template: String = activeTemplate) -> URL? {
        guard let normalized = normalizedTemplate(template) else { return nil }
        let encoded = query.addingPercentEncoding(withAllowedCharacters: searchQueryAllowed) ?? query
        return URL(string: normalized.replacingOccurrences(of: "%s", with: encoded))
    }

    static func normalizedTemplate(_ template: String) -> String? {
        let trimmed = template.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed.contains("%s") else { return nil }
        if URL(string: trimmed)?.scheme != nil { return trimmed }
        return "https://\(trimmed)"
    }
}

/// Pure, testable keyword-bang detection + expansion. Free of UI/UserDefaults
/// so the matching rules are unit-testable with an injected engine list.
nonisolated enum KeywordBangs {
    /// Result of matching the input's first token against a keyword engine.
    struct Match: Equatable {
        let engine: KeywordEngine
        /// The remaining query after the keyword (may be empty for a bare keyword).
        let query: String
    }

    /// Returns the matching engine + remaining query when the input's first
    /// whitespace-delimited token equals an engine keyword (case-insensitive).
    /// Returns nil when no keyword matches. A bare keyword (no remaining query)
    /// still matches, with an empty `query`, so callers can decide how to route.
    static func match(_ input: String, engines: [KeywordEngine]) -> Match? {
        let trimmed = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        // Split on the first run of whitespace into keyword + remainder.
        let parts = trimmed.split(maxSplits: 1, whereSeparator: { $0 == " " || $0 == "\t" })
        let token = String(parts.first ?? "").lowercased()
        guard !token.isEmpty else { return nil }
        guard let engine = engines.first(where: {
            !$0.keyword.isEmpty && $0.keyword.lowercased() == token
        }) else { return nil }
        let remainder = parts.count > 1
            ? String(parts[1]).trimmingCharacters(in: .whitespacesAndNewlines)
            : ""
        return Match(engine: engine, query: remainder)
    }

    /// Expands `input` against `engines`, returning a URL when a keyword matches
    /// AND there is a non-empty remaining query. A bare keyword returns nil here
    /// (callers fall through to normal handling / the engine's base host).
    static func expand(_ input: String, engines: [KeywordEngine]) -> URL? {
        guard let m = match(input, engines: engines), !m.query.isEmpty else { return nil }
        return SearchPreferences.searchURL(for: m.query, template: m.engine.templateURL)
    }
}

enum NewWindowPolicy: String, CaseIterable, Identifiable {
    case sidebar
    case splitRight
    case samePane
    case block

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .sidebar: return "Park"
        case .splitRight: return "Split Right"
        case .samePane: return "Same Pane"
        case .block: return "Block"
        }
    }
}

nonisolated enum BrowserPreferences {
    static let newWindowPolicyKey = "newWindowPolicy"
    static let recordHistoryKey = "recordHistory"
    static let defaultNewWindowPolicy = NewWindowPolicy.sidebar

    static var newWindowPolicy: NewWindowPolicy {
        get {
            let raw = UserDefaults.standard.string(forKey: newWindowPolicyKey)
            return raw.flatMap(NewWindowPolicy.init(rawValue:)) ?? defaultNewWindowPolicy
        }
        set {
            UserDefaults.standard.set(newValue.rawValue, forKey: newWindowPolicyKey)
        }
    }

    static var recordsHistory: Bool {
        get {
            guard UserDefaults.standard.object(forKey: recordHistoryKey) != nil else {
                return true
            }
            return UserDefaults.standard.bool(forKey: recordHistoryKey)
        }
        set {
            UserDefaults.standard.set(newValue, forKey: recordHistoryKey)
        }
    }

    static let requestDesktopSiteKey = "requestDesktopSite"
    static let defaultRequestsDesktopSite = false

    /// Initial "Request Desktop Site" content mode applied to newly created tabs.
    /// Restored tabs use their own persisted value instead (see TabRecord).
    static var requestsDesktopSite: Bool {
        get {
            guard UserDefaults.standard.object(forKey: requestDesktopSiteKey) != nil else {
                return defaultRequestsDesktopSite
            }
            return UserDefaults.standard.bool(forKey: requestDesktopSiteKey)
        }
        set {
            UserDefaults.standard.set(newValue, forKey: requestDesktopSiteKey)
        }
    }
}

/// Pure helper for the desktop content-mode behavior. Kept free of WebKit/UI
/// state so the macOS user-agent fallback string is unit-testable in isolation.
///
/// On iOS the content mode is driven by `WKWebpagePreferences.preferredContentMode`,
/// which has no macOS equivalent; there we fall back to spoofing a desktop Safari
/// user agent (a nil agent restores WebKit's platform default).
nonisolated enum DesktopSiteMode {
    /// A Safari-on-macOS user-agent override used on platforms (macOS) where
    /// `preferredContentMode` is unavailable. `nil` means "use the platform default".
    static func customUserAgent(requestsDesktop: Bool) -> String? {
        guard requestsDesktop else { return nil }
        return "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) "
            + "AppleWebKit/605.1.15 (KHTML, like Gecko) "
            + "Version/17.0 Safari/605.1.15"
    }
}
