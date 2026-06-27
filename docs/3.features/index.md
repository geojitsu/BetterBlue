---
title: 'Features'
description: 'The three features added by this fork: cabin preconditioning shortcut, Find My Car, and battery meter redesign.'
icon: 'i-heroicons-bolt'
---

## Planned Features (In Implementation Order)

| # | Feature | Status | Key File |
|---|---|---|---|
| 1 | [Cabin Preconditioning Shortcut](/better-blue-too/features/cabin-preconditioning) | Planned | `PreconditioningButton.swift` (new) |
| 2 | [Find My Car](/better-blue-too/features/find-my-car) | Planned | `FindMyCarButton.swift` (new) |
| 3 | [Battery Meter Redesign](/better-blue-too/features/battery-meter) | Planned | `BatteryMeterView.swift` (new) |

## Prerequisites for All Features

The Keychain migration (`BBAccount` password/pin/token off SwiftData) must be completed
before any feature work is distributed beyond the developer's personal device. The migration
is tracked separately as the first build task.

## Implementation Dependency

All three features are independent of each other. They share only the vehicle card layout
(`VehicleCardView.swift`) as a common integration point. The preconditioning shortcut should
be implemented first (it is the simplest and establishes the button component pattern used
by Find My Car).
