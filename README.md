# zz

`zz` is a multi-pane SwiftUI browser for iPadOS and macOS.

## Build

Open `zz.xcodeproj` in Xcode, or build from the command line:

```sh
xcodebuild -project zz.xcodeproj -scheme zz -destination 'platform=macOS' build
xcodebuild -project zz.xcodeproj -scheme zz -destination 'platform=iOS Simulator,name=iPad Pro 13-inch (M5)' build
```

## Test

```sh
xcodebuild test -project zz.xcodeproj -scheme zz -destination 'platform=iOS Simulator,name=iPad Pro 13-inch (M5)'
```

## Release Build Checks

```sh
xcodebuild -project zz.xcodeproj -scheme zz -configuration Release -destination 'platform=macOS' build
xcodebuild -project zz.xcodeproj -scheme zz -configuration Release -destination 'generic/platform=iOS' build CODE_SIGNING_ALLOWED=NO
```

## Release Notes

- Confirm the bundle identifier, signing team, marketing version, and build number before archiving.
- The app target intentionally supports iPadOS and macOS. Add other Apple platforms only after validating the WebKit and drag/drop behavior there.
- Regenerate app icons after logo changes with:

```sh
swift tools/generate_app_icons.swift
```
