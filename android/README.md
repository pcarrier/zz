# zz — Android

Android (Kotlin + Jetpack Compose) port of the **zz** SwiftUI browser
(`/src/zz/ios/zz/*.swift`).

The architecture, type names, package layout, and porting conventions are defined
in **[ANDROID_ARCH.md](ANDROID_ARCH.md)** — read it before adding code. All port
agents must follow its contracts so independently ported files compile together.

## Project identity

| Property | Value |
|---|---|
| Application / namespace | `surf.zz` |
| Module | single `:app` |
| Language | Kotlin 2.0.21 (K2), JVM target 17 |
| UI | Jetpack Compose (Material3) |
| minSdk | 26 (Android 8.0) |
| targetSdk / compileSdk | 35 (Android 15) |
| Gradle | 8.9 (wrapper) |
| AGP | 8.7.3 |

## Requirements

- JDK 17 (the Gradle build targets JVM 17).
- Android SDK with platform 35 and build-tools installed. Point the build at it
  via either:
  - a `local.properties` file at this directory's root containing
    `sdk.dir=/path/to/Android/sdk`, or
  - the `ANDROID_HOME` / `ANDROID_SDK_ROOT` environment variable.

`local.properties` is intentionally git-ignored.

## Build

For a reproducible JDK/Android SDK environment, run this once from `/src/zz`:

```sh
nix develop
```

From `/src/zz/android`:

```sh
# Assemble the debug APK.
./gradlew :app:assembleDebug

# Install onto a connected device / running emulator.
./gradlew :app:installDebug

# Unit tests (JVM — pure-logic ports: ranker, fuzzy match, canonicalizer, etc.).
./gradlew :app:testDebugUnitTest

# Full check.
./gradlew check
```

The debug APK is written to `app/build/outputs/apk/debug/`.

On Windows use `gradlew.bat` instead of `./gradlew`.

## Layout

`app/src/main/java/surf/zz/` follows the canonical package tree in
[ANDROID_ARCH.md §12](ANDROID_ARCH.md). Entry points:

- `ZzApplication.kt` — process-lifetime singleton stores (history, favicons,
  layout presets); flushes them on background.
- `MainActivity.kt` — single Activity, edge-to-edge; creates/restores the
  `WindowID`, remembers the per-window `BrowserStore`, hosts the top-level
  `App(...)` composable, forwards `http`/`https` deep links to
  `store.openExternalURL`, and maps the system Back gesture to
  `store.backFocused`.

The top-level Compose entry point is `surf.zz.ui.App` (the port of
`ContentView.swift`).

## v1 scope notes

Single Activity, single browser window. Multi-window, desktop-only features
(menu bar, pane drag-and-drop reorg, find-bar) are deferred or stubbed. See
ANDROID_ARCH.md §9–§10 for the documented deviations.
