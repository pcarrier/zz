import SwiftUI

@main
struct zzApp: App {
    @State private var history = HistoryStore()
    @State private var favicons = FaviconStore()
    @State private var pinned = PinnedShortcutStore()
    @State private var layouts = LayoutPresetStore()
    @Environment(\.openWindow) private var openWindow

    var body: some Scene {
        WindowGroup(for: WindowID.self) { $windowID in
            ContentView(windowID: windowID)
                .environment(history)
                .environment(favicons)
                .environment(pinned)
                .environment(layouts)
        } defaultValue: {
            WindowID()
        }
        #if os(macOS)
        .windowResizability(.contentMinSize)
        .defaultSize(width: 1280, height: 860)
        #endif
        .commands {
            CommandGroup(replacing: .toolbar)        { }
            CommandGroup(replacing: .sidebar)        { }
            CommandGroup(replacing: .printItem)      { }
            CommandGroup(replacing: .saveItem)       { }
            CommandGroup(replacing: .textFormatting) { }
            CommandGroup(replacing: .help)           { }

            CommandGroup(replacing: .newItem) {
                Button("New Window") {
                    openWindow(value: WindowID())
                }
                .keyboardShortcut("n", modifiers: [.command])
            }
        }

        #if os(macOS)
        Settings {
            SettingsView()
                .environment(history)
                .environment(favicons)
        }
        #endif
    }
}
