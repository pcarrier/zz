package surf.zz.ui

import androidx.compose.runtime.staticCompositionLocalOf
import surf.zz.favicon.FaviconStore
import surf.zz.store.BrowserStore
import surf.zz.store.HistoryStore
import surf.zz.store.LayoutPresetStore

/**
 * CompositionLocals replacing SwiftUI's `.environment(...)` injection.
 *
 * In the iOS app the stores are injected via `.environment(history)`,
 * `.environment(favicons)`, `.environment(layouts)` at the `zzApp`/`ContentView`
 * root and the per-window `BrowserStore` via `.environment(store)` further down
 * the view tree (see `zzApp.swift` and `ContentView.swift`). Composables read
 * them through `@Environment(HistoryStore.self)` etc.
 *
 * On Android (per ANDROID_ARCH.md §3) dependency injection is explicit
 * CompositionLocals — NOT Hilt. The app-global stores (`HistoryStore`,
 * `FaviconStore`, `LayoutPresetStore`) are created in `ZzApplication` and live
 * for the process lifetime; the per-window `BrowserStore` is created/`remember`ed
 * at the Activity composition root. All four are provided once at the `App()`
 * root via `CompositionLocalProvider`.
 *
 * `staticCompositionLocalOf` is used (rather than `compositionLocalOf`) because
 * the provided store *instances* never change for the lifetime of a given
 * composition subtree — only the snapshot state *inside* each store mutates, and
 * that is tracked field-by-field via Compose snapshot reads. A static local
 * avoids the recomposition-scope bookkeeping of a dynamic local. The default is
 * `error(...)` so reading any of these outside the provided tree fails loudly
 * rather than silently using a placeholder.
 */

val LocalBrowserStore = staticCompositionLocalOf<BrowserStore> {
    error("no BrowserStore provided; wrap in CompositionLocalProvider at the App() root")
}

val LocalHistoryStore = staticCompositionLocalOf<HistoryStore> {
    error("no HistoryStore provided; wrap in CompositionLocalProvider at the App() root")
}

val LocalFaviconStore = staticCompositionLocalOf<FaviconStore> {
    error("no FaviconStore provided; wrap in CompositionLocalProvider at the App() root")
}

val LocalLayoutPresetStore = staticCompositionLocalOf<LayoutPresetStore> {
    error("no LayoutPresetStore provided; wrap in CompositionLocalProvider at the App() root")
}
