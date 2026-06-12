import SwiftUI

private enum SettingsMetrics {
    static let keywordRowSpacing: CGFloat = 4
    static let keywordFieldWidth: CGFloat = 90
    static let minWidth: CGFloat = 420
}

struct SettingsView: View {
    @Environment(HistoryStore.self) private var history
    @Environment(\.dismiss) private var dismiss

    @AppStorage(SearchPreferences.engineKey)
    private var searchEngineRaw = SearchPreferences.defaultEngine.rawValue

    @AppStorage(SearchPreferences.customTemplateKey)
    private var customSearchTemplate = SearchPreferences.defaultCustomTemplate

    @State private var keywordEngines: [KeywordEngine] = SearchPreferences.keywordEngines

    @AppStorage(BrowserPreferences.newWindowPolicyKey)
    private var newWindowPolicyRaw = BrowserPreferences.defaultNewWindowPolicy.rawValue

    @AppStorage(BrowserPreferences.recordHistoryKey)
    private var recordHistory = true

    @AppStorage(BrowserPreferences.requestDesktopSiteKey)
    private var requestsDesktopSite = BrowserPreferences.defaultRequestsDesktopSite

    var body: some View {
        Form {
            Section("Search") {
                Picker("Search Engine", selection: $searchEngineRaw) {
                    ForEach(SearchEngine.allCases) { engine in
                        Text(engine.displayName).tag(engine.rawValue)
                    }
                }
                if selectedSearchEngine == .custom {
                    TextField("Search URL Template", text: $customSearchTemplate)
                        .textFieldStyle(.roundedBorder)
                    Text("Use %s where the search terms should go.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            Section("Keyword Searches") {
                ForEach($keywordEngines) { $engine in
                    VStack(alignment: .leading, spacing: SettingsMetrics.keywordRowSpacing) {
                        HStack {
                            TextField("Keyword", text: $engine.keyword)
                                .textFieldStyle(.roundedBorder)
                                .frame(width: SettingsMetrics.keywordFieldWidth)
                            TextField("Title", text: $engine.title)
                                .textFieldStyle(.roundedBorder)
                            Button(role: .destructive) {
                                keywordEngines.removeAll { $0.id == engine.id }
                            } label: {
                                Image(systemName: "trash")
                            }
                            .buttonStyle(.borderless)
                        }
                        TextField("Search URL Template", text: $engine.templateURL)
                            .textFieldStyle(.roundedBorder)
                    }
                }
                Button {
                    keywordEngines.append(
                        KeywordEngine(keyword: "", templateURL: "https://example.com/search?q=%s", title: "")
                    )
                } label: {
                    Label("Add Keyword Search", systemImage: "plus")
                }
                Text("Type the keyword followed by your query, e.g. \"gh swift\". Use %s where the search terms should go.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .onChange(of: keywordEngines) { _, newValue in
                SearchPreferences.keywordEngines = newValue
            }

            Section("Content") {
                Toggle("Request Desktop Site", isOn: $requestsDesktopSite)
                Text("Default for new tabs. Toggle per tile from its context menu.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("Pop-ups") {
                Picker("Open New Windows", selection: $newWindowPolicyRaw) {
                    ForEach(NewWindowPolicy.allCases) { policy in
                        Text(policy.displayName).tag(policy.rawValue)
                    }
                }
            }

            Section("History") {
                Toggle("Record Browsing History", isOn: $recordHistory)
                Button(role: .destructive) {
                    history.clear()
                } label: {
                    Text("Clear History")
                }
            }
        }
        .formStyle(.grouped)
        .padding()
        .frame(minWidth: SettingsMetrics.minWidth)
        .toolbar {
            ToolbarItem(placement: .confirmationAction) {
                Button("Done") { dismiss() }
            }
        }
    }

    private var selectedSearchEngine: SearchEngine {
        SearchEngine(rawValue: searchEngineRaw) ?? SearchPreferences.defaultEngine
    }
}
