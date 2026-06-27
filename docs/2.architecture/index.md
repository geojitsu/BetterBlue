---
title: 'Architecture'
description: 'As-built architecture of the fork: data flow, key layers, SwiftData models, and how the fork extends the upstream design.'
icon: 'i-heroicons-cpu-chip'
---

## Overview

This fork makes no changes to the upstream architecture. The three planned features are
pure additions at the SwiftUI view layer and do not require modifications to BetterBlueKit,
the SwiftData models (beyond the Keychain migration), or the App Group container setup.

The upstream architecture is documented in depth in the repository's `CLAUDE.md`.

## Data Flow (Unchanged from Upstream)

```
SwiftUI Views (BetterBlue app)
  | @Query / SwiftData
  v
BBAccount / BBVehicle (SwiftData models)
  | account.sendCommand() / account.refreshStatus()
  v
CachedAPIClient -> APIClientFactory -> regional APIClient
  | URLSession HTTPS
  v
Hyundai / Kia BlueLink cloud API
  | JSON response
  v
SwiftData persistence -> WidgetKit / ActivityKit refresh
```

## Key Patterns Used by This Fork

### Adding a new command (preconditioning shortcut)

Per the upstream CLAUDE.md convention:
1. `VehicleCommand.startClimate(ClimateOptions)` already exists in BetterBlueKit — no new API work.
2. Add a `BBAccount` convenience method if needed (see `lockVehicle()`, `startClimate()` as references).
3. Create new SwiftUI view component (`PreconditioningButton.swift`).
4. Wire into `VehicleCardView.swift`.
5. Status-wait must use a **60-second hard timeout** (not unbounded).

### Location access (Find My Car)

`BBVehicle.location` (`VehicleStatus.Location?`) already provides GPS coordinates from the
last status refresh. Always access via `safeLocation` guard; never force-unwrap.

### Credential security (Keychain migration)

`BBAccount` currently stores `password`, `pin`, and `serializedAuthToken` as plain SwiftData
fields. These must be migrated to the iOS Keychain before any distribution. The migration
is the first task in the build sequence.

## Targets

| Target | Description |
|---|---|
| `BetterBlue` | Main iOS app — primary target for all fork changes |
| `BetterBlueWatch Watch App` | watchOS companion — out of scope for initial milestone |
| `Widget` | WidgetKit / ActivityKit extensions — battery meter changes may affect this |
| `BetterBlueKit` (submodule) | API package — no changes planned for initial milestone |
