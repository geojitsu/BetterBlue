//
//  VehicleWidgetIntent.swift
//  BetterBlueWidget
//
//  Created by Mark Schmidt on 8/29/25.
//

import AppIntents
import BetterBlueKit
import SwiftData
import SwiftUI
import WidgetKit

struct VehicleWidgetIntent: WidgetConfigurationIntent {
    static var title: LocalizedStringResource =
        "Vehicle Widget Configuration"
    static var description = IntentDescription("Choose a vehicle for the widget")

    @Parameter(
        title: "Vehicle",
        description: "Select which vehicle this widget controls",
    )
    var vehicle: VehicleEntity?

    init(vehicle: VehicleEntity?) {
        self.vehicle = vehicle
    }

    init() {}
}

struct VehicleEntity: AppEntity {
    static var typeDisplayRepresentation: TypeDisplayRepresentation =
        "Vehicle"
    static var defaultQuery = VehicleQuery()

    var id: UUID
    var displayName: String
    var vin: String
    var fuelType: FuelType
    /// Formatted "primary" range — EV for vehicles with electric
    /// capability, gas otherwise. Kept as the default surface for
    /// simple "what's my range" shortcuts; use `evRange` / `gasRange`
    /// for PHEVs that need both axes independently.
    @Property(title: "Range")
    var rangeText: String
    /// "Primary" percentage — EV battery for EVs, gas tank for ICE.
    /// Same compatibility role as `rangeText`. For unambiguous reads,
    /// use `evBatteryPercentage` / `gasFuelPercentage`.
    @Property(title: "Battery Percentage")
    var batteryPercentage: Double?
    var backgroundColorName: String
    var primaryColorName: String?
    var chargingColorName: String?
    var lockColorName: String?
    var unlockColorName: String?
    var startClimateColorName: String?
    var stopColorName: String?
    var timestamp: Date
    var presets: [ClimatePresetEntity] = []

    // MARK: - Operational state (for Shortcuts conditionals)
    //
    // Each property is annotated with `@Property(title:)` so it shows
    // up with a localized label in the "Get Details of Vehicle"
    // picker in the Shortcuts editor. Without that annotation Apple
    // surfaces them with the raw camelCase name (or, on some OS
    // versions, hides them entirely under "Other Details").
    //
    // All operational state is optional because: the underlying
    // status may not have arrived yet for a new vehicle; or the
    // vehicle's fuel type doesn't support that signal (a pure ICE
    // car has no `pluggedIn`).

    @Property(title: "Is Locked")
    var isLocked: Bool?

    @Property(title: "Is Plugged In")
    var isPluggedIn: Bool?

    @Property(title: "Is Charging")
    var isCharging: Bool?

    @Property(title: "Charge Speed (kW)")
    var chargeSpeedKilowatts: Double?

    @Property(title: "Charge Time Remaining (minutes)")
    var chargeTimeRemainingMinutes: Int?

    @Property(title: "Target State of Charge")
    var targetStateOfCharge: Int?

    @Property(title: "Is Climate On")
    var isClimateOn: Bool?

    @Property(title: "Last Updated")
    var lastUpdated: Date?

    /// Vehicle's last reported latitude. Surfaced as a Number in
    /// Shortcuts so users can pipe it into Maps actions or do
    /// distance math against another coordinate.
    ///
    /// Originally tried to combine lat + lon into a single
    /// `CLPlacemark`-typed Location magic variable, but the only
    /// from-coords constructor (`MKPlacemark`) is deprecated in
    /// iOS / watchOS 26, and the App Intents framework's
    /// `_IntentValue` list doesn't include the replacement
    /// (`MKMapItem`) or even `CLLocation`. So separate Doubles
    /// it is until Apple updates App Intents.
    @Property(title: "Latitude")
    var latitude: Double?

    /// Vehicle's last reported longitude. See `latitude`.
    @Property(title: "Longitude")
    var longitude: Double?

    @Property(title: "Brand")
    var brand: String?

    // MARK: - Fuel-type-specific range + percentage
    //
    // The legacy `rangeText` / `batteryPercentage` pair has fuel-
    // type-dependent semantics (EV battery for EVs, gas tank for
    // ICE). The properties below are unambiguous: `evRange` only
    // populates for EV-capable vehicles, `gasRange` only for cars
    // with a gas tank. PHEVs populate BOTH, which is the only way
    // a Shortcut can read both readings off a single vehicle.

    /// Formatted EV range (e.g. "129 mi"). `nil` for ICE-only cars.
    @Property(title: "EV Range")
    var evRange: String?

    /// EV range as a raw number in the user's preferred distance
    /// unit — usable in Shortcuts math (e.g. "if EV Range Value
    /// is less than 50"). `nil` for ICE-only cars.
    @Property(title: "EV Range Value")
    var evRangeValue: Double?

    /// EV battery state of charge (0–100). `nil` for ICE-only cars.
    @Property(title: "EV Battery Percentage")
    var evBatteryPercentage: Double?

    /// Formatted gas range (e.g. "300 mi"). `nil` for pure EVs.
    @Property(title: "Gas Range")
    var gasRange: String?

    /// Gas range as a raw number in the user's preferred distance
    /// unit. `nil` for pure EVs.
    @Property(title: "Gas Range Value")
    var gasRangeValue: Double?

    /// Gas tank fill level (0–100). `nil` for pure EVs.
    @Property(title: "Gas Fuel Percentage")
    var gasFuelPercentage: Double?

    /// Whichever the legacy `Range` text uses — "mi" or "km" —
    /// reflecting the user's preferred distance unit at the moment
    /// this entity was built. Surfaced so a Shortcut can label a
    /// computed numeric range without guessing.
    @Property(title: "Range Unit")
    var rangeUnit: String?

    var primaryColor: Color { CustomColor.color(forName: primaryColorName, default: "blue") }
    var chargingColor: Color { CustomColor.color(forName: chargingColorName, default: "green") }
    var lockColor: Color { CustomColor.color(forName: lockColorName, default: "red") }
    var unlockColor: Color { CustomColor.color(forName: unlockColorName, default: "green") }
    var startClimateColor: Color { CustomColor.color(forName: startClimateColorName, default: "blue") }
    var stopColor: Color { CustomColor.color(forName: stopColorName, default: "red") }

    var selectedPreset: ClimatePresetEntity? {
        presets.first(where: \.isSelected)
    }

    var displayRepresentation: DisplayRepresentation {
        // Subtitle gives the Shortcuts magic-variable chip useful
        // at-a-glance info — range + battery for EVs, range alone
        // for ICE. Without a subtitle, the chip is just the name.
        var subtitleParts: [String] = []
        if !rangeText.isEmpty, rangeText != "--" {
            subtitleParts.append(rangeText)
        }
        if let battery = batteryPercentage {
            subtitleParts.append("\(Int(battery))%")
        }
        let subtitle = subtitleParts.isEmpty ? nil : subtitleParts.joined(separator: " · ")
        return DisplayRepresentation(
            title: "\(displayName)",
            subtitle: subtitle.map { LocalizedStringResource(stringLiteral: $0) }
        )
    }

    // Get the gradient colors for the selected background
    var backgroundGradient: [Color] {
        guard let background = BBVehicle.availableBackgrounds.first(where: {
            $0.name == backgroundColorName
        }) else {
            return BBVehicle.availableBackgrounds[0].gradient
        }
        return background.gradient
    }

    init(
        id: UUID,
        displayName: String,
        vin: String,
        fuelType: FuelType,
        rangeText: String,
        batteryPercentage: Double?,
        timestamp: Date,
        backgroundColorName: String = "default",
        primaryColorName: String? = nil,
        chargingColorName: String? = nil,
        lockColorName: String? = nil,
        unlockColorName: String? = nil,
        startClimateColorName: String? = nil,
        stopColorName: String? = nil,
        presets: [ClimatePresetEntity] = []
    ) {
        // Non-wrapped properties first — `@Property` setters (used
        // below for rangeText/batteryPercentage) require self to be
        // fully initialized.
        self.id = id
        self.displayName = displayName
        self.vin = vin
        self.fuelType = fuelType
        self.timestamp = timestamp
        self.backgroundColorName = backgroundColorName
        self.primaryColorName = primaryColorName
        self.chargingColorName = chargingColorName
        self.lockColorName = lockColorName
        self.unlockColorName = unlockColorName
        self.startClimateColorName = startClimateColorName
        self.stopColorName = stopColorName
        self.presets = presets

        // Wrapped properties — safe to set now that self is initialized.
        self.rangeText = rangeText
        self.batteryPercentage = batteryPercentage
    }

    init(from bbVehicle: BBVehicle, with unit: Distance.Units, allPresets: [ClimatePresetEntity]) {
        // STEP 1: assign every non-wrapped stored property. The
        // `@Property`-wrapped fields below have setters that go
        // through the wrapper, which requires `self` to be fully
        // initialized — so we have to finish the plain stored
        // properties before touching the wrapped ones.
        id = bbVehicle.id
        displayName = bbVehicle.displayName
        vin = bbVehicle.vin
        fuelType = bbVehicle.fuelType
        backgroundColorName = bbVehicle.backgroundColorName
        primaryColorName = bbVehicle.primaryColorName
        chargingColorName = bbVehicle.chargingColorName
        lockColorName = bbVehicle.lockColorName
        unlockColorName = bbVehicle.unlockColorName
        startClimateColorName = bbVehicle.startClimateColorName
        stopColorName = bbVehicle.stopColorName
        timestamp = bbVehicle.lastUpdated ?? Date()

        // Compute per-fuel-type range/percentage separately so PHEVs
        // (which have BOTH ev + gas data) populate both axes — and
        // so the unambiguous `evRange` / `gasRange` Shortcuts
        // properties always reflect their respective source. Each
        // tuple carries both the formatted text and the raw numeric
        // value (converted into the user's preferred unit) so
        // Shortcuts can branch on the number.
        let resolvedEV: (text: String?, value: Double?, percent: Double?) = {
            guard bbVehicle.fuelType.hasElectricCapability,
                  bbVehicle.modelContext != nil,
                  let ev = bbVehicle.evStatus,
                  ev.evRange.range.length > 0 else {
                return (nil, nil, nil)
            }
            let value = ev.evRange.range.units.convert(ev.evRange.range.length, to: unit)
            let text = ev.evRange.range.units.format(ev.evRange.range.length, to: unit)
            return (text, value, ev.evRange.percentage)
        }()
        let resolvedGas: (text: String?, value: Double?, percent: Double?) = {
            guard bbVehicle.modelContext != nil,
                  let gas = bbVehicle.gasRange,
                  gas.range.length > 0 else {
                return (nil, nil, nil)
            }
            let value = gas.range.units.convert(gas.range.length, to: unit)
            let text = gas.range.units.format(gas.range.length, to: unit)
            return (text, value, gas.percentage)
        }()

        // Legacy `rangeText` / `batteryPercentage` (kept for backward
        // compatibility): prefer EV for vehicles with electric
        // capability, fall back to gas. Empty-fallback text matches
        // the old behavior so existing user Shortcuts don't break.
        let legacyRangeText: String
        let legacyBatteryPercentage: Double?
        if bbVehicle.fuelType.hasElectricCapability {
            legacyRangeText = resolvedEV.text ?? "No EV data"
            legacyBatteryPercentage = resolvedEV.percent
        } else {
            legacyRangeText = resolvedGas.text ?? "No fuel data"
            legacyBatteryPercentage = resolvedGas.percent
        }
        // `presets` is plain (non-wrapped), set in step 1.
        // `rangeText` / `batteryPercentage` are @Property — defer
        // their assignment to step 2 below.
        presets = allPresets.filter { preset in preset.vehicleVin == vin }

        // STEP 2: now self is fully initialized — safe to assign
        // through `@Property` wrapped setters.
        rangeText = legacyRangeText
        batteryPercentage = legacyBatteryPercentage
        lastUpdated = bbVehicle.lastUpdated
        brand = bbVehicle.account?.brandEnum.displayName

        // Explicit per-fuel-type properties (computed above) —
        // formatted text + raw numeric value in the user's
        // preferred unit + percentage.
        evRange = resolvedEV.text
        evRangeValue = resolvedEV.value
        evBatteryPercentage = resolvedEV.percent
        gasRange = resolvedGas.text
        gasRangeValue = resolvedGas.value
        gasFuelPercentage = resolvedGas.percent
        rangeUnit = unit.abbreviation

        if bbVehicle.fuelType.hasElectricCapability,
           bbVehicle.modelContext != nil,
           let evStatus = bbVehicle.evStatus {
            // EV-only operational state. `chargeSpeed`, `chargeTime`,
            // and target SOC are only meaningful while plugged in /
            // charging, so leave them nil otherwise (rather than
            // zero) — that way Shortcuts conditionals like "if
            // chargeSpeed is set" do the right thing.
            isPluggedIn = evStatus.pluggedIn
            isCharging = evStatus.charging
            if evStatus.charging {
                chargeSpeedKilowatts = evStatus.chargeSpeed > 0 ? evStatus.chargeSpeed : nil
                let minutes = Int(evStatus.chargeTime.components.seconds / 60)
                chargeTimeRemainingMinutes = minutes > 0 ? minutes : nil
                if let target = evStatus.currentTargetSOC {
                    targetStateOfCharge = Int(target)
                }
            }
        }

        // Universal state (applies to all fuel types)
        if let lockStatus = bbVehicle.lockStatus {
            isLocked = lockStatus == .locked
        }
        if let climate = bbVehicle.climateStatus {
            isClimateOn = climate.airControlOn
        }
        if let loc = bbVehicle.location {
            latitude = loc.latitude
            longitude = loc.longitude
        }
    }
}

struct VehicleQuery: EntityQuery {
    func entities(
        for identifiers: [UUID],
    ) async throws -> [VehicleEntity] {
        let presets = try await ClimatePresetEntity.defaultQuery.suggestedEntities()
        return try await MainActor.run {
            let modelContainer = try createSharedModelContainer(enableCloudKit: false)
            let context = ModelContext(modelContainer)

            let vehicles = try context.fetch(FetchDescriptor<BBVehicle>())
            // Live UserDefaults read — see `AppSettings.liveDistanceUnit`.
            let unit = AppSettings.liveDistanceUnit()

            return vehicles
                .filter { identifiers.contains($0.id) }
                .map { VehicleEntity(from: $0, with: unit, allPresets: presets) }
        }
    }

    func suggestedEntities() async throws -> [VehicleEntity] {
        let presets = try await ClimatePresetEntity.defaultQuery.suggestedEntities()
        return try await MainActor.run {
            let modelContainer = try createSharedModelContainer(enableCloudKit: false)
            let context = ModelContext(modelContainer)

            let descriptor = FetchDescriptor<BBVehicle>(
                predicate: #Predicate { !$0.isHidden },
                sortBy: [SortDescriptor(\.sortOrder)],
            )

            let vehicles = try context.fetch(descriptor)
            let unit = AppSettings.liveDistanceUnit()

            return vehicles.map { VehicleEntity(from: $0, with: unit, allPresets: presets) }
        }
    }
}
