import Foundation

enum SearchEngine: String, CaseIterable, Identifiable {
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

enum SearchPreferences {
    static let engineKey = "searchEngine"
    static let customTemplateKey = "customSearchTemplate"
    static let defaultEngine = SearchEngine.duckDuckGo
    static let defaultCustomTemplate = SearchEngine.duckDuckGo.template!

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

enum BrowserPreferences {
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
}
