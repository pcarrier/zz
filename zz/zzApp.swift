import SwiftUI

@main
struct zzApp: App {
    @State private var history = HistoryStore()
    @Environment(\.openWindow) private var openWindow

    var body: some Scene {
        WindowGroup(for: WindowID.self) { $windowID in
            ContentView(windowID: windowID)
                .environment(history)
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
                .keyboardShortcut("n", modifiers: [.command, .shift])
            }
        }
    }
}
