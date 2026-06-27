---
title: 'Build Guide'
description: 'How to set up the fork locally, resolve the submodule, configure Xcode signing, and get a build running on device.'
icon: 'i-heroicons-rocket-launch'
---

## Prerequisites

- **macOS** with **Xcode 15+** (required — iOS development cannot be done on Windows)
- An Apple Developer account for device signing (free tier works for personal-device sideloading)
- Git with submodule support
- A Hyundai BlueLink or Kia Connect account for live testing (or use the built-in Fake vehicle mode)

## Repository Setup

The fork lives at `https://github.com/geojitsu/BetterBlue`.

```bash
git clone https://github.com/geojitsu/BetterBlue
cd BetterBlue
git submodule update --init --recursive
```

The `BetterBlueKit/` directory is a git submodule pointing to the upstream
`schmidtwmark/BetterBlueKit` repo. It is referenced via `XCLocalSwiftPackageReference`
in the Xcode project so local changes can be made without pushing to GitHub first.

## Xcode Setup

1. Open `BetterBlue.xcodeproj` in Xcode.
2. Select the `BetterBlue` target and set your Team under **Signing & Capabilities**.
3. Change the Bundle Identifier if needed (e.g. `com.yourname.BetterBlue`).
4. Repeat for `BetterBlueWatch Watch App`, `Widget`, and `WidgetExtension` targets.
5. CloudKit sync uses iCloud container `iCloud.com.markschmidt.BetterBlue` — you will need
   your own container (`iCloud.com.yourname.BetterBlue`) and an App Group
   (`group.com.yourname.betterblue.shared`) for device builds.
6. Build the `BetterBlue` scheme for the iOS Simulator first to confirm package resolution works.

## Fake Vehicle Mode

The app includes a built-in Fake vehicle provider — no BlueLink credentials needed.
Use test credentials (see upstream CLAUDE.md) to activate `Brand.fake` mode during development.

## Simulator Build

```bash
xcodebuild -scheme BetterBlue \
  -destination 'platform=iOS Simulator,name=iPhone 15 Pro' \
  build
```

## Key Files Reference

| File | Purpose |
|---|---|
| `BetterBlue/Models/BBAccount.swift` | SwiftData account model; credentials, API client lifecycle |
| `BetterBlue/Models/BBVehicle.swift` | SwiftData vehicle model; status, presets, command methods |
| `BetterBlue/Models/ClimatePreset.swift` | Climate preset SwiftData model |
| `BetterBlue/Utility/SharedModelContainer.swift` | SwiftData container setup shared across targets |
| `BetterBlue/Views/VehicleCardView.swift` | Primary card: status + action buttons (primary target for new UI) |
| `BetterBlue/Views/Components/ClimateButton.swift` | Existing climate control UI — reference for preconditioning button pattern |
| `BetterBlue/Views/Components/EVChargingProgressView.swift` | Battery meter component (redesign target) |
| `Widget/VehicleAppIntents.swift` | App Intents for Siri / Control Center |
| `BetterBlueKit/` | API communication package (submodule) |
