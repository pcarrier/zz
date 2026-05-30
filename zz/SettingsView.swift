import SwiftUI

struct SettingsView: View {
    @Environment(HistoryStore.self) private var history
    @Environment(\.dismiss) private var dismiss

    @AppStorage(SearchPreferences.engineKey)
    private var searchEngineRaw = SearchPreferences.defaultEngine.rawValue

    @AppStorage(SearchPreferences.customTemplateKey)
    private var customSearchTemplate = SearchPreferences.defaultCustomTemplate

    @AppStorage(BrowserPreferences.newWindowPolicyKey)
    private var newWindowPolicyRaw = BrowserPreferences.defaultNewWindowPolicy.rawValue

    @AppStorage(BrowserPreferences.recordHistoryKey)
    private var recordHistory = true

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
        .frame(minWidth: 420)
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
