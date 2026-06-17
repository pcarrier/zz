package surf.zz.ui

import androidx.compose.runtime.Composable
import androidx.compose.runtime.CompositionLocalProvider
import surf.zz.favicon.FaviconStore
import surf.zz.model.WindowID
import surf.zz.store.HistoryStore
import surf.zz.store.LayoutPresetStore

/**
 * Top-level Compose composition root: provides the app-global store
 * CompositionLocals and renders the single window's [BrowserScreen].
 *
 * ## What it ports
 *
 * Derived from `zzApp.swift`'s `WindowGroup(for:)` content closure plus
 * `ContentView.swift`'s entry point. In SwiftUI the body is:
 *
 * ```swift
 * WindowGroup(for: WindowID.self) { $windowID in
 *     ContentView(windowID: windowID)
 *         .environment(history)
 *         .environment(favicons)
 *         .environment(layouts)
 * }
 * ```
 *
 * and `ContentView` immediately delegates to `BrowserScene(windowID:history:)`.
 * Here that collapses to: provide the three app-global stores as
 * CompositionLocals (the Android analog of the `.environment(...)` injections —
 * ANDROID_ARCH.md §3) and hand the [windowId] to [BrowserScreen], which owns the
 * per-window state and view tree (the port of `BrowserScene`).
 *
 * ## Where the stores come from
 *
 * The app-global stores ([HistoryStore], [FaviconStore], [LayoutPresetStore]) are
 * created once in `ZzApplication` for the process lifetime and passed in here by
 * `MainActivity`, mirroring `zzApp`'s `@State private var history/favicons/layouts`
 * that live for the scene's lifetime. They are re-provided here at the App root so
 * that `App` is a self-contained composition root regardless of who calls it; the
 * per-window `BrowserStore` is created and provided (`LocalBrowserStore`) by
 * `MainActivity` around this composable, matching the SwiftUI design where
 * `.environment(store)` is injected further down the tree (inside `BrowserScene`).
 *
 * ## Deviation (ANDROID_ARCH.md §9)
 *
 * SwiftUI's `WindowGroup(for: WindowID.self)` provides auto-restored multi-window;
 * v1 Android is single Activity / single window. The [windowId] is still a real
 * value (minted/persisted by `MainActivity`) used to key the on-disk snapshot, but
 * there is exactly one of them and "New Window" is a no-op. The macOS-only
 * `.commands { ... }` menu replacements and the `Settings { ... }` scene have no
 * Android equivalent and are dropped here (Settings is reached in-app from the
 * bottom bar / more menu, presented by `BrowserScreen`).
 */
@Composable
fun App(
    windowId: WindowID,
    history: HistoryStore,
    favicons: FaviconStore,
    layouts: LayoutPresetStore,
) {
    CompositionLocalProvider(
        LocalHistoryStore provides history,
        LocalFaviconStore provides favicons,
        LocalLayoutPresetStore provides layouts,
    ) {
        BrowserScreen(
            windowId = windowId,
            history = history,
            favicons = favicons,
            layouts = layouts,
        )
    }
}
