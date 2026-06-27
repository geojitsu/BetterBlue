---
title: 'Better Blue Too'
description: 'A personal-use fork of BetterBlue adding cabin preconditioning shortcut, Find My Car, and an improved battery meter for Hyundai/Kia vehicles.'
icon: 'i-heroicons-fire'
---

## What This Fork Does

Better Blue Too is a fork of [schmidtwmark/BetterBlue](https://github.com/schmidtwmark/BetterBlue),
a free open-source iOS app that replaces the official Hyundai BlueLink app. The fork adds
three targeted features to the upstream app:

1. **Cabin preconditioning shortcut** — a single-tap button on the vehicle card to start
   HVAC preconditioning, with a confirmation dialog, bypassing the three-tap preset flow.
2. **Find My Car** — reads the vehicle's last-known GPS coordinates from BlueLink and opens
   a walking route in Google Maps or Apple Maps.
3. **Battery meter redesign** — replaces the minimal progress-bar battery indicator with a
   richer, more expressive component that reads well in both charging and non-charging states.

No backend changes are required. All three features operate entirely within the existing
BetterBlue + BetterBlueKit architecture. Monthly cost: $0.

## Repository

- **This fork**: [geojitsu/BetterBlue](https://github.com/geojitsu/BetterBlue)

## Upstream

- Main app: [schmidtwmark/BetterBlue](https://github.com/schmidtwmark/BetterBlue)
- API package (submodule): [schmidtwmark/BetterBlueKit](https://github.com/schmidtwmark/BetterBlueKit)

## Platform

iOS 17+ / Swift 5.9+ / SwiftUI / SwiftData. Building requires macOS with Xcode 15+.

## Important Conventions

All new code in this fork must follow these rules (enforced from the security audit):

- All polling loops must have a hard **60-second timeout ceiling** — no unbounded `waitForStatusChange` calls.
- All new view code must use the `safeLocation` / `PersistentModelGuard` patterns.
- UI copy must say **"cabin preconditioning"** not "battery preconditioning" (BlueLink only controls HVAC, not battery thermal conditioning).
- Keychain migration (password, pin, token fields off SwiftData) must be complete before any distribution beyond the developer's own device.
