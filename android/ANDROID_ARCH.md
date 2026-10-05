# zz Android — Architecture & Port Conventions

This document is the single source of truth for porting the **zz** SwiftUI browser
(`/src/zz/ios/zz/*.swift`) to Android (Kotlin + Jetpack Compose). Every port agent
MUST follow the type names, package layout, and patterns below so the independently
ported files compile together without renegotiation.

---

## 1. Project identity

| Property | Value |
|---|---|
| Application / package id | `surf.zz` |
| Source root | `/src/zz/android/app/src/main/java/surf/zz/...` |
| Module | single `:app` module |
| Language | Kotlin 2.0.x (K2), JVM target 17 |
| UI | Jetpack Compose (Material3) |
| minSdk | **26** (Android 8.0 — required for `java.time`, WebView features, adaptive icons, `Files.move` ATOMIC_MOVE on internal storage) |
| targetSdk / compileSdk | **35** (Android 15) |
| Gradle | 8.9, AGP 8.7.x, Gradle wrapper (Kotlin DSL) |

`v1 scope` is a **single Activity, single browser window** (see §9). Multi-window is
explicitly deferred. Desktop-only features (macOS menu bar, NSEvent monitors, pane
drag-and-drop reorg, find-bar) are dropped or stubbed in v1; see per-unit notes.

---

## 2. Gradle dependencies (canonical list)

Pin via the Compose BOM. Versions below are the agreed baseline.

```
// Kotlin / Compose plugins (in build.gradle.kts plugins {})
org.jetbrains.kotlin.android            2.0.21
org.jetbrains.kotlin.plugin.serialization 2.0.21
org.jetbrains.kotlin.plugin.compose      2.0.21   // Compose compiler (K2)
com.android.application                  8.7.3

// Compose
androidx.compose:compose-bom:2024.12.01
androidx.compose.ui:ui
androidx.compose.ui:ui-graphics
androidx.compose.ui:ui-tooling-preview
androidx.compose.foundation:foundation        // drag-and-drop, gestures
androidx.compose.material3:material3
androidx.compose.material:material-icons-extended
androidx.compose.material3:material3-window-size-class

// Lifecycle / Activity
androidx.activity:activity-compose:1.9.3
androidx.lifecycle:lifecycle-runtime-ktx:2.8.7
androidx.lifecycle:lifecycle-runtime-compose:2.8.7   // collectAsStateWithLifecycle, LocalLifecycleOwner
androidx.lifecycle:lifecycle-process:2.8.7           // ProcessLifecycleOwner for flushSave

// Serialization
org.jetbrains.kotlinx:kotlinx-serialization-json:1.7.3

// Coroutines
org.jetbrains.kotlinx:kotlinx-coroutines-android:1.9.0

// DataStore (scalar prefs only — NOT the big window snapshots)
androidx.datastore:datastore-preferences:1.1.1

// Images (favicons)
io.coil-kt:coil-compose:2.7.0

// Test
junit:junit:4.13.2
org.jetbrains.kotlinx:kotlinx-coroutines-test:1.9.0
```

WebView is from the platform (`android.webkit.WebView`); no AndroidX webkit dependency
required for v1.

---

## 3. State management: how `@Observable` / `@MainActor` map

**Decision: mirror `@Observable`, do NOT do a heavyweight MVVM rewrite.**

Swift's `@Observable final class` stores (`BrowserStore`, `HistoryStore`,
`LayoutPresetStore`, `FaviconStore`, `Tab`) become **plain Kotlin classes** whose
observable fields are **Compose snapshot state**:

- `var x: T` (observed)  → `var x by mutableStateOf(initial)`
- `var d: [K: V]` (observed) → `val d = mutableStateMapOf<K, V>()`
- `var a: [T]` (observed) → `val a = mutableStateListOf<T>()`
- `@ObservationIgnored var y` → plain `private var y` (no snapshot state)
- `focusURLBarTrigger &+= 1` (one-shot trigger) → `var focusUrlBarTrigger by mutableStateOf(0)`; bump with `focusUrlBarTrigger++`, observed via `LaunchedEffect`.

These classes are **`@MainActor`** in Swift → on Android **all mutation happens on the
main thread**. Disk I/O is dispatched off-main with `withContext(Dispatchers.IO)` and
results are applied back on `Dispatchers.Main`.

**Scoping / lifetime** (replaces SwiftUI `@State` ownership + `.environment(...)`):

- App-global stores (`HistoryStore`, `FaviconStore`, `LayoutPresetStore`) are created
  in `ZzApplication` and held as `lateinit`/`val` singletons for the process lifetime.
- The per-window `BrowserStore` is created/`remember`ed at the Activity composition
  root and survives recomposition. (It does not survive config changes by default;
  v1 sets `android:configChanges` so the Activity is not recreated — see §13.)
- Dependency injection is **explicit CompositionLocals**, not Hilt. Define them in
  `surf/zz/ui/Locals.kt`:

```kotlin
val LocalBrowserStore = staticCompositionLocalOf<BrowserStore> { error("no BrowserStore") }
val LocalHistoryStore = staticCompositionLocalOf<HistoryStore> { error("no HistoryStore") }
val LocalFaviconStore = staticCompositionLocalOf<FaviconStore> { error("no FaviconStore") }
val LocalLayoutPresetStore = staticCompositionLocalOf<LayoutPresetStore> { error("no LayoutPresetStore") }
```

Composables read `LocalBrowserStore.current`. Because the store fields are snapshot
state, reading them inside composition tracks them exactly like SwiftUI `@Observable`.

There is **no ViewModel** for the browser core; the only `ViewModel` is the small
`SettingsViewModel` (DataStore-backed), because Settings is a self-contained screen.

---

## 4. WebView mapping

`WKWebView` → `android.webkit.WebView`. **The WebView is owned by the `Tab` model, not
by Compose**, so it survives pane moves / recomposition (mirrors the Swift "externally
owned, reparented" design in `WebView.swift`).

- `Tab` is constructed with a `Context` (application context is fine for creation) and
  builds its `WebView` eagerly, configuring `settings` (JS on, DOM storage, media
  playback without gesture, wide viewport for desktop mode).
- Hosting in Compose: `HostedWebView` is an `@Composable` using
  `AndroidView(factory = { WebViewContainer(it) }, update = { ... })`. The factory
  creates a `WebViewContainer` (a `FrameLayout` subclass); `update` re-parents the
  `Tab`'s `WebView` into the container (`(webView.parent as? ViewGroup)?.removeView(webView)`
  then `container.addView(webView)`), keyed by `layoutRevision`.
- KVO observation → `WebViewClient` (`onPageStarted`/`onPageFinished`/`doUpdateVisitedHistory`/
  `onReceivedError`/`onReceivedHttpAuthRequest`/`onRenderProcessGone`) and
  `WebChromeClient` (`onProgressChanged`/`onReceivedTitle`/`onCreateWindow`/`onCloseWindow`/
  `onShowCustomView`/`onHideCustomView`). These callbacks write the `Tab`'s snapshot
  state on the main thread. `canGoBack`/`canGoForward` are polled from the WebView in
  those callbacks.
- Zoom: `webView.evaluateJavascript("document.documentElement.style.zoom='$level'", null)`,
  re-applied in `onPageFinished` (matches the iOS CSS-zoom path).
- Desktop mode: swap `settings.userAgentString` (see `DesktopSiteMode`) + `useWideViewPort`/
  `loadWithOverviewMode`, then reload.
- Media suspension: `webView.onPause()`/`onResume()` plus a JS pause-all-media injection
  (documented as an imperfect mapping).
- Downloads: `webView.setDownloadListener { ... }` → `DownloadManager`.

---

## 5. Serialization (Codable → kotlinx.serialization)

Single shared `Json` instance in `surf/zz/persistence/Json.kt`:

```kotlin
val ZzJson = Json {
    ignoreUnknownKeys = true     // == decodeIfPresent forward-compat
    encodeDefaults = true
    explicitNulls = false        // == encodeIfPresent (omit nulls)
    classDiscriminator = "type"  // for BspNode sealed hierarchy
}
```

### UUID
No built-in serializer. Provide `surf/zz/persistence/UuidSerializer.kt`:
`object UuidSerializer : KSerializer<UUID>` encoding to/from `uuid.toString()`. Use
`@Serializable(with = UuidSerializer::class)` on every `UUID` field so JSON stays
compatible with Swift's `UUID` (lowercase-with-dashes string).

### Date / Instant
`HistoryEntry.lastVisited: Date` is encoded by Swift's `JSONEncoder` as a
**`Double` seconds since 2001-01-01 (Apple reference date)** by default. To stay
byte-compatible with existing on-device data we DO NOT need cross-platform parity
(fresh install on Android), so store as **epoch milliseconds `Long`** via a
`InstantEpochMillisSerializer` / store `lastVisitedMillis: Long`. Document: Android
history files are independent from iOS; no shared format requirement.

### BSPNode → sealed interface
Swift encodes `enum BSPNode { case leaf(tabID:); indirect case split(...) }` with the
default Codable strategy (an object keyed by the case name). On Android use a
**`@Serializable sealed interface BspNode`** with `@SerialName`:

```kotlin
@Serializable
sealed interface BspNode {
    @Serializable @SerialName("leaf")
    data class Leaf(@Serializable(UuidSerializer::class) val tabId: UUID) : BspNode
    @Serializable @SerialName("split")
    data class Split(
        @Serializable(UuidSerializer::class) val id: UUID,
        val axis: Axis,
        val ratio: Double,
        val first: BspNode,
        val second: BspNode,
    ) : BspNode
    enum class Axis { @SerialName("horizontal") HORIZONTAL, @SerialName("vertical") VERTICAL }
}
```

Note: this is a **fresh JSON shape** (`{"type":"leaf",...}`); it is NOT byte-identical
to Swift's encoding, which is acceptable because Android starts with no saved state.
Keep `classDiscriminator = "type"`.

### Snapshot DTOs
`@Serializable data class` with nullable + default fields (== `decodeIfPresent ?? x`):
- `WindowSnapshot(root, focusedTabId?, parked=[], tabs=[], sidebarWidth=220.0)`
- `TabRecord(id, url, title?, scrollX, scrollY, pageZoom, requestsDesktopSite=false, mediaSuspended=false)` — legacy `isMuted` handled by reading both keys; since Android has no legacy data, a single `mediaSuspended` field with default `false` suffices (document the dropped legacy fallback).

### String highlight ranges
Swift `[Range<String.Index>]` → Kotlin **`List<IntRange>`** (UTF-16/char offsets).
`OmniboxRanker` must emit `IntRange` offsets directly so Compose `AnnotatedString`
`addStyle(start, end)` lines up. Do the Index→Int conversion at the ranker/data layer.

---

## 6. Persistence: debounced atomic writes

JSON snapshots are **plain files under `context.filesDir`**, NOT DataStore (payloads are
large structured blobs). DataStore is used only for scalar prefs (search engine, toggles).

Paths (resolved from `Context.filesDir`):
- Per-window state: `filesDir/zz/windows/<windowUuid>/state.json`
- Layout presets: `filesDir/zz/layouts.json`
- History: `filesDir/zz/history.json`
- Favicon index: `filesDir/zz/favicons/index.json` + per-host `*.img` files

**Atomic write helper** (`surf/zz/persistence/AtomicFile.kt`): write to `path.tmp` then
`Files.move(tmp, dest, ATOMIC_MOVE)` (fallback `renameTo`). `mkdirs()` parents.

**Debounce pattern** (replaces `Task { sleep; cancel }`): each store owns a
`CoroutineScope(Dispatchers.Main + SupervisorJob())` and a `var saveJob: Job?`:

```kotlin
private fun scheduleSave() {
    saveJob?.cancel()
    saveJob = scope.launch {
        delay(250)                               // 250/300/400/500 per store
        val payload = buildSnapshot()            // on Main (reads snapshot state)
        withContext(Dispatchers.IO) { AtomicFile.write(file, ZzJson.encodeToString(payload)) }
    }
}
```

Debounce intervals (match Swift): BrowserStore **250ms**, LayoutPresetStore **300ms**,
HistoryStore **400ms**, FaviconStore **500ms**.

**`flushSave()`** (synchronous before process suspend): a `fun flushSave()` that cancels
the debounce, builds the payload on Main, and writes with `runBlocking(Dispatchers.IO)`.
Invoked from a `LifecycleEventObserver` on `ON_STOP` (and `ProcessLifecycleOwner` for
app-global stores) — the Android analog of `scenePhase != .active`.

**`PersistenceWriteOrderer`** (`surf/zz/persistence/PersistenceWriteOrderer.kt`):
`object` with a `Mutex` (or `synchronized`) over `MutableMap<String, Long>` keyed by file
path, holding a monotonic generation. Ports the Swift guard verbatim: drop a write if a
committed generation `>=` this write's generation. `FaviconMapWriteOrderer` reuses this.

---

## 7. Coroutines & threading conventions

- Stores own a `MainScope()`-style scope (`CoroutineScope(Dispatchers.Main.immediate + SupervisorJob())`); `Tab` owns its own scope, cancelled in `close()`.
- All snapshot-state mutation on `Dispatchers.Main`. I/O on `Dispatchers.IO`.
- Per-file serial I/O (favicon images) → `Dispatchers.IO.limitedParallelism(1)` or a `Mutex`.
- No deterministic `deinit`: every store/`Tab` exposes `fun close()` / `dispose()` that
  cancels its scope, drains pending auth completions, and destroys the WebView. Owners
  call it when removing the pane.

---

## 8. Drag & drop

v1 mobile target: **pane-reorg drag-and-drop is deferred**. The Swift contract types are
still ported as plain data so signatures compile:

- `PaneDropPayload` → `sealed interface PaneDropPayload { data class Url(val url: String); data class ParkedTab(val id: UUID) }`
- `PaneDropHandler` → `class PaneDropHandler(val update, val perform, val end)` (lambdas).
- `DropZone` → `enum class DropZone { TOP, BOTTOM, LEFT, RIGHT, CENTER }`; pure geometry
  (`dropZone(at: Offset, in: Size)`) ports verbatim.
- Sidebar reorder + tile drop use `androidx.compose.foundation` drag-and-drop
  (`Modifier.dragAndDropSource` / `Modifier.dragAndDropTarget`) when implemented; in v1
  the targets may be wired but reorder/drop can be a follow-up. `TabRef` is the
  `@Serializable` payload carried as a `text/x-zz-tabref` ClipData item.

---

## 9. Multi-window (DEVIATION — documented)

SwiftUI `WindowGroup(for: WindowID.self)` (auto-restored multi-window) has **no v1 Android
equivalent**. v1 is **single Activity, single window**:

- `WindowID` is still a real type (`data class WindowID(val id: UUID = UUID.randomUUID())`)
  used to key the snapshot file. `MainActivity` creates one fixed `WindowID` (persisted in
  DataStore so the same window restores on relaunch).
- "New Window" (Cmd+N / menu) maps to a no-op or a toast in v1 (documented). A future
  version can use `documentLaunchMode` + Intent extras (`WindowID` as a string extra).

---

## 10. Keyboard shortcuts

`ShortcutLayer` (invisible buttons with `.keyboardShortcut`) and macOS NSEvent monitors →
a single `KeyboardShortcuts` handler attached via `Modifier.onPreviewKeyEvent` on the
focusable root composable. Match `KeyEvent.key` + `isCtrlPressed`/`isMetaPressed`/
`isShiftPressed`/`isAltPressed` (Cmd→Ctrl-or-Meta) and return `true` to consume. Mouse
back/forward and the macOS Cmd-W interceptor are dropped; the system Back gesture maps to
`store.backFocused()` via `BackHandler`.

---

## 11. Theming & colors

`Color` extension semantic colors → Compose `MaterialTheme.colorScheme` + a small
`ZzColors` object / extension props on `ColorScheme`:

| Swift | Compose |
|---|---|
| `Color.canvas` | `colorScheme.background` |
| `Color.canvasSecondary` | `colorScheme.surfaceVariant` |
| `Color.textSelection` | `colorScheme.primary` (also `LocalTextSelectionColors`) |
| `Color.secondaryLabelText` | `colorScheme.onSurfaceVariant` |
| `Color.accentColor` | `colorScheme.primary` |

SF Symbols → `androidx.compose.material.icons` (extended). `Dp` for all geometry; SF
`CGFloat` constants (`PaneSelectionVisual.strokeWidth = 1`, `reservedInset`) become `Dp`.

---

## 12. Package layout (canonical tree)

```
surf.zz
├─ ZzApplication.kt
├─ MainActivity.kt
├─ model/            WindowID.kt, TabRef.kt
├─ persistence/      Json.kt, UuidSerializer.kt, InstantEpochMillisSerializer.kt,
│                    AtomicFile.kt, PersistenceWriteOrderer.kt
├─ layout/           BspNode.kt
├─ store/            BrowserStore.kt, HistoryStore.kt, LayoutPresetStore.kt
├─ omnibox/          OmniboxModels.kt, OmniboxRanker.kt, OmniboxSuggestions.kt, FuzzyMatch.kt
├─ url/              UrlCanonicalizer.kt, UrlNormalizer.kt, DroppedUrl.kt
├─ search/           SearchEngine.kt, KeywordEngine.kt, SearchPreferences.kt, KeywordBangs.kt
├─ prefs/            BrowserPreferences.kt, AppPreferences.kt (DataStore)
├─ browser/
│  ├─ tab/           Tab.kt, PageZoom.kt, TabRecord.kt, TabWebViewClient.kt, TabWebChromeClient.kt, TabDownloadListener.kt
│  ├─ auth/          HttpAuthKey.kt, HttpAuthPendingCompletions.kt, HttpAuthCredentialStore.kt
│  └─ web/           HostedWebView.kt, WebViewContainer.kt, PaneDrop.kt, DesktopSiteMode.kt
├─ favicon/          FaviconLogic.kt, FaviconStore.kt, FaviconDiskIO.kt, FaviconView.kt
└─ ui/
   ├─ App.kt, BrowserScreen.kt, MainContent.kt, KeyboardShortcuts.kt, Locals.kt
   ├─ theme/         Theme.kt, ThemeColors.kt
   ├─ PaneSelectionVisual.kt
   ├─ util/          SiteVisual.kt
   ├─ bsp/           BspView.kt, SplitHandle.kt
   ├─ tile/          TileView.kt, TileDropState.kt, DropZone.kt, TileDropTarget.kt, DropZoneIndicator.kt
   ├─ sidebar/       SidebarView.kt, SidebarTilePreview.kt
   ├─ omnibox/       UrlBar.kt, SuggestionList.kt
   ├─ bottombar/     BottomBar.kt, MoreMenu.kt, NavControls.kt, BarIcon.kt, TileMenuActions.kt
   ├─ history/       HistoryScreen.kt, HistoryGrouping.kt
   └─ settings/      SettingsScreen.kt, SettingsViewModel.kt
```

> Note: specs proposed mixed package roots (`com.zz`, `surf.zz`). **`surf.zz` is
> canonical everywhere**; ignore `com.zz` paths in the per-file specs.

---

## 13. AndroidManifest essentials

- `<uses-permission android:name="android.permission.INTERNET"/>`
- `<application android:name=".ZzApplication" ... >`
- `MainActivity`: `android:configChanges="orientation|screenSize|keyboard|keyboardHidden|smallestScreenSize|screenLayout|uiMode"` so config changes don't recreate the Activity (keeps the in-memory `BrowserStore`/WebViews alive in v1), `android:launchMode="singleTask"`.
- Intent filters: `ACTION_MAIN`/`LAUNCHER` plus a `VIEW` filter for `http`/`https` deep
  links forwarded to `store.openExternalURL`.
- `WindowCompat.setDecorFitsSystemWindows(window, false)` in `onCreate` for edge-to-edge
  (maps the iOS top-safe-area handling).

---

## 14. Translation parity checklist (apply per unit)

- Pure logic (omnibox ranker, fuzzy match, canonicalizer, normalizer, keyword bangs,
  page-zoom math, BSP tree ops, history grouping, favicon logic) → port **verbatim** as
  Kotlin `object`/top-level funcs and **unit-test** them. Highest value, lowest risk.
- `clamped(to:)` → `coerceIn(min, max)`.
- `&+=` overflow add → ordinary `++`.
- `inout Set` → `MutableSet` param.
- `URLComponents` → `android.net.Uri` / `java.net.URI` (VERIFY host/port/query/percent
  normalization differs — canonicalizer must be unit-tested against the Swift behavior).
- Percent-encoding for search queries → `Uri.encode(query, allowed)` (NOT `URLEncoder`,
  which form-encodes spaces as `+`).
- `String.Index` ranges → `IntRange` (char offsets) at the data layer.
- `Logger`/OSLog → `android.util.Log`.
- `NSDataDetector` → `android.util.Patterns.WEB_URL`.
