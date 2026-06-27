---
title: 'Troubleshooting'
description: 'Known pitfalls, gotchas, and solutions encountered during development of this fork.'
icon: 'i-heroicons-wrench-screwdriver'
---

## Known Pitfalls

These pitfalls were identified during the pre-build security and code audit. Any new code
that touches these areas must address them before commit.

### Pitfall 1: Unbounded polling loop

`BBVehicle.waitForStatusChange()` polls until the vehicle state changes or the view
disappears — there is no hard timeout in the upstream implementation. If the BlueLink API
returns stale data indefinitely (stuck command, network issue), the loop will run until
the user leaves the view.

**Rule:** All new command implementations in this fork must apply a **60-second hard
timeout ceiling** on `waitForStatusChange` calls. Do not use the raw `waitForStatusChange`
without a wrapping timeout.

### Pitfall 2: SwiftData location access crashes

`BBVehicle.location` is `VehicleStatus.Location?` (optional), but the struct itself is
non-optional in BetterBlueKit. All views and code paths that read location must use
the `safeLocation` guard pattern. Force-unwrapping `vehicle.location` will crash when
no status has been fetched yet (first launch, offline, fresh account).

**Rule:** Always use `guard let location = vehicle.safeLocation else { ... }` for any
location access in new view code. Never force-unwrap.

### Pitfall 3: "Battery preconditioning" vs. "cabin preconditioning"

The BlueLink API `startClimate` command (`POST ac/v2/evc/fatc/start`) controls the HVAC
cabin climate system only. It does NOT trigger battery thermal preconditioning
(heating the battery pack for faster DC charging). Battery thermal preconditioning is
triggered only by navigating to a charger via the in-car nav system.

**Rule:** All UI copy in this fork must use "cabin preconditioning" not "battery
preconditioning" to avoid misleading users.

### Pitfall 4: Keychain migration timing — RESOLVED in TASK-001

**Previously:** `BBAccount` stored `password`, `pin`, and `serializedAuthToken` in
SwiftData (unencrypted, CloudKit-synced). These three fields are now Keychain-backed.

**What was done (TASK-001):**
- SwiftData backing fields renamed `_password`, `_pin`, `_serializedAuthToken` with
  `@Attribute(originalName:)` so existing column data is preserved across the schema
  rename (lightweight migration, no explicit migration plan required).
- Computed properties `password`, `pin`, `serializedAuthToken` now read/write the iOS
  Keychain via `KeychainService` (`BetterBlue/Utility/KeychainService.swift`).
- `migrateAccountCredentials(container:)` runs once at startup (guarded by
  `UserDefaults` key `keychain_migration_v1_complete`) and sweeps all accounts.
- `BBAccount.removeAccount` now deletes the three Keychain items before removing the
  SwiftData record.
- Schema version bumped to `1.0.10`.

**Remaining caveat — CloudKit multi-device:** Once the primary device migrates and
CloudKit syncs the now-empty SwiftData fields to a secondary device, the secondary
device has no way to self-migrate (the plaintext is gone from SwiftData). Users with
multiple devices will need to re-enter credentials on secondary devices after first
launch following the update. Acceptable for a personal-use fork.

**Temporary-account Keychain orphans:** `AccountInfoView.checkNewAccountData` creates
a throwaway `BBAccount` to test new credentials. Its `init` writes to Keychain
(under its random UUID). These entries are never explicitly deleted because the test
object is never inserted into SwiftData. Each credential-update test leaves ~2 tiny
orphan Keychain items. Acceptable for personal use; a future cleanup could add an
explicit `cleanupKeychain()` call to that flow.

### Pitfall 5: Simulator vs. device SwiftData paths

`SharedModelContainer.swift` uses `/tmp/BetterBlue_Shared` on Simulator and an iCloud
App Group container on device. If you change the App Group identifier in Signing &
Capabilities, the device path changes and existing data will not migrate automatically.
Keep the bundle identifier and App Group consistent throughout development.

## Build Troubleshooting

### Submodule shows empty directory after clone

Run `git submodule update --init --recursive` from the repo root. The `BetterBlueKit/`
directory is a git submodule and will be empty after a plain clone.

### SwiftLint plugin conflicts

SwiftLint has been removed from the project to avoid plugin conflicts with the local
BetterBlueKit submodule. If you add SwiftLint back, the plugin in
`BetterBlueKit/Package.swift` must be commented out first.

### iCloud sync issues on device

Check Diagnostics view (Settings > About in the app) and verify the App Group container
is accessible. See upstream CLAUDE.md for details.
