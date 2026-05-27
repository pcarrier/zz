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
            // Empty placeholders SwiftUI adds by default.
            CommandGroup(replacing: .toolbar)        { }
            CommandGroup(replacing: .sidebar)        { }
            CommandGroup(replacing: .printItem)      { }
            CommandGroup(replacing: .saveItem)       { }
            CommandGroup(replacing: .textFormatting) { }
            CommandGroup(replacing: .help)           { }

            // File > New Window — replaces the default Cmd+N entry (we use ⌘N
            // for "park focused tile" inside a window, so new-window lives on ⇧⌘N).
            CommandGroup(replacing: .newItem) {
                Button("New Window") {
                    openWindow(value: WindowID())
                }
                .keyboardShortcut("n", modifiers: [.command, .shift])
            }
        }
    }
}
