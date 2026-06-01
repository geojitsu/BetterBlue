//
//  CustomizableControlsWidget.swift
//  BetterBlueWidget
//
//  A second-generation, fully customizable controls widget. Unlike the
//  original `BetterBlueWidget`, the action buttons here are circular and
//  user-configurable: each slot can be assigned any vehicle command (or a
//  specific climate preset) and reordered via the widget's Edit screen.
//
//  Two gallery tiles share all of this code:
//    • `CustomControls2x2Widget`  — systemSmall, 2 buttons
//        default: Lock, Start Climate
//    • `CustomControls4x2Widget`  — systemMedium, 4 buttons
//        default: Lock, Unlock, Start Climate, Stop Climate
//
//  WidgetKit can't give one tile per-size defaults, so they're two
//  separate widgets with their own configuration intents (and thus their
//  own size-appropriate default action sets + edit UIs).
//

import AppIntents
import BetterBlueKit
import SwiftData
import SwiftUI
import WidgetKit

// MARK: - Action model

/// The command a single configurable button performs. `startClimate`
/// covers both the generic "selected preset" case (presetId == nil) and a
/// specific preset (presetId set) — see `WidgetActionEntity`.
enum WidgetActionKind: String, Sendable {
    case lock
    case unlock
    case startClimate
    case stopClimate
    case startCharge
    case stopCharge
    case none

    var defaultTitle: String {
        switch self {
        case .lock: "Lock"
        case .unlock: "Unlock"
        case .startClimate: "Start Climate"
        case .stopClimate: "Stop Climate"
        case .startCharge: "Start Charge"
        case .stopCharge: "Stop Charge"
        case .none: "None"
        }
    }

    var icon: String {
        switch self {
        case .lock: "lock.fill"
        case .unlock: "lock.open.fill"
        case .startClimate: "fan.fill"
        case .stopClimate: "fan.slash.fill"
        case .startCharge: "bolt.fill"
        case .stopCharge: "bolt.slash.fill"
        case .none: "circle.dashed"
        }
    }

    /// Resolves the per-vehicle custom color this action should use.
    func color(for vehicle: VehicleEntity) -> Color {
        switch self {
        case .lock: vehicle.lockColor
        case .unlock: vehicle.unlockColor
        case .startClimate: vehicle.startClimateColor
        case .stopClimate: vehicle.stopColor
        case .startCharge: vehicle.chargingColor
        case .stopCharge: vehicle.stopColor
        case .none: Color.gray
        }
    }
}

/// One selectable option in a button slot. Modeled as an `AppEntity`
/// (rather than a static `AppEnum`) so the picker can offer dynamic
/// options — specifically, one "Start Climate – <Preset>" entry per
/// climate preset the user has created.
struct WidgetActionEntity: AppEntity, Identifiable, Sendable {
    /// Stable identifier. Fixed actions use their kind raw value
    /// ("lock", "startClimate", …); preset-specific start-climate
    /// actions use "preset:<presetId>".
    var id: String
    var kindRaw: String
    var title: String
    var iconName: String

    // Populated only for a preset-specific start-climate action.
    var presetId: UUID?
    var presetVin: String?
    var presetVehicleName: String?
    var presetName: String?
    var presetIcon: String?

    var kind: WidgetActionKind { WidgetActionKind(rawValue: kindRaw) ?? .none }

    static let typeDisplayRepresentation: TypeDisplayRepresentation = "Vehicle Action"
    static let defaultQuery = WidgetActionQuery()

    var displayRepresentation: DisplayRepresentation {
        if let presetVehicleName, presetId != nil {
            return DisplayRepresentation(
                title: "\(title)",
                subtitle: LocalizedStringResource(stringLiteral: presetVehicleName),
                image: .init(systemName: iconName)
            )
        }
        return DisplayRepresentation(title: "\(title)", image: .init(systemName: iconName))
    }

    // MARK: Fixed-action factories

    static func fixed(_ kind: WidgetActionKind) -> WidgetActionEntity {
        WidgetActionEntity(
            id: kind.rawValue,
            kindRaw: kind.rawValue,
            title: kind.defaultTitle,
            iconName: kind.icon
        )
    }

    static var lock: WidgetActionEntity { fixed(.lock) }
    static var unlock: WidgetActionEntity { fixed(.unlock) }
    static var startClimate: WidgetActionEntity { fixed(.startClimate) }
    static var stopClimate: WidgetActionEntity { fixed(.stopClimate) }
    static var none: WidgetActionEntity { fixed(.none) }

    /// Builds the full option list: the fixed commands plus one
    /// start-climate entry per known preset.
    static func allOptions(presets: [ClimatePresetEntity]) -> [WidgetActionEntity] {
        var options: [WidgetActionEntity] = [
            .lock,
            .unlock,
            .startClimate,
            .stopClimate,
            .fixed(.startCharge),
            .fixed(.stopCharge)
        ]
        for preset in presets {
            options.append(WidgetActionEntity(
                id: "preset:\(preset.id.uuidString)",
                kindRaw: WidgetActionKind.startClimate.rawValue,
                title: "Start Climate – \(preset.presetName)",
                iconName: preset.presetIcon,
                presetId: preset.id,
                presetVin: preset.vehicleVin,
                presetVehicleName: preset.vehicleName,
                presetName: preset.presetName,
                presetIcon: preset.presetIcon
            ))
        }
        options.append(.none)
        return options
    }
}

struct WidgetActionQuery: EntityQuery {
    func entities(for identifiers: [WidgetActionEntity.ID]) async throws -> [WidgetActionEntity] {
        let presets = (try? await ClimatePresetEntity.defaultQuery.suggestedEntities()) ?? []
        let all = WidgetActionEntity.allOptions(presets: presets)
        // Preserve the caller's requested ordering.
        return identifiers.compactMap { id in all.first { $0.id == id } }
    }

    func suggestedEntities() async throws -> [WidgetActionEntity] {
        let presets = (try? await ClimatePresetEntity.defaultQuery.suggestedEntities()) ?? []
        return WidgetActionEntity.allOptions(presets: presets)
    }
}

// MARK: - Configuration intents

/// Shared surface the timeline provider + views read, so a single
/// generic provider drives both the 2x2 and 4x2 widgets.
protocol ControlsConfigIntent: WidgetConfigurationIntent {
    var vehicle: VehicleEntity? { get }
    /// Resolved button actions in slot order. `nil` slots collapse to
    /// `.none` so the array length always equals the widget's slot count.
    var slotActions: [WidgetActionEntity] { get }
}

struct CustomControls2x2ConfigIntent: WidgetConfigurationIntent, ControlsConfigIntent {
    static let title: LocalizedStringResource = "Vehicle Controls (2×2)"
    static let description = IntentDescription("A small widget with two configurable buttons.")

    @Parameter(title: "Vehicle")
    var vehicle: VehicleEntity?

    @Parameter(title: "Button 1")
    var action1: WidgetActionEntity?

    @Parameter(title: "Button 2")
    var action2: WidgetActionEntity?

    init() {
        action1 = .lock
        action2 = .startClimate
    }

    var slotActions: [WidgetActionEntity] {
        [action1 ?? .none, action2 ?? .none]
    }
}

struct CustomControls4x2ConfigIntent: WidgetConfigurationIntent, ControlsConfigIntent {
    static let title: LocalizedStringResource = "Vehicle Controls (4×2)"
    static let description = IntentDescription("A medium widget with four configurable buttons.")

    @Parameter(title: "Vehicle")
    var vehicle: VehicleEntity?

    @Parameter(title: "Button 1")
    var action1: WidgetActionEntity?

    @Parameter(title: "Button 2")
    var action2: WidgetActionEntity?

    @Parameter(title: "Button 3")
    var action3: WidgetActionEntity?

    @Parameter(title: "Button 4")
    var action4: WidgetActionEntity?

    init() {
        action1 = .lock
        action2 = .unlock
        action3 = .startClimate
        action4 = .stopClimate
    }

    var slotActions: [WidgetActionEntity] {
        [action1 ?? .none, action2 ?? .none, action3 ?? .none, action4 ?? .none]
    }
}

// MARK: - Timeline

struct ControlsWidgetEntry: TimelineEntry {
    let date: Date
    let vehicle: VehicleEntity?
    let actions: [WidgetActionEntity]
}

struct ControlsTimelineProvider<Intent: ControlsConfigIntent>: AppIntentTimelineProvider {
    typealias Entry = ControlsWidgetEntry

    func placeholder(in _: Context) -> ControlsWidgetEntry {
        ControlsWidgetEntry(date: Date(), vehicle: nil, actions: [])
    }

    func snapshot(for configuration: Intent, in _: Context) async -> ControlsWidgetEntry {
        let vehicle = await loadControlsVehicleEntity(configuredVin: configuration.vehicle?.vin)
        return ControlsWidgetEntry(date: Date(), vehicle: vehicle, actions: configuration.slotActions)
    }

    func timeline(for configuration: Intent, in _: Context) async -> Timeline<ControlsWidgetEntry> {
        let currentDate = Date()
        let refreshInterval = await MainActor.run {
            AppSettings.shared.widgetRefreshInterval.timeInterval
        }
        let vehicle = await loadControlsVehicleEntity(configuredVin: configuration.vehicle?.vin)
        let actions = configuration.slotActions

        let entries = [
            ControlsWidgetEntry(date: currentDate, vehicle: vehicle, actions: actions),
            ControlsWidgetEntry(
                date: currentDate.addingTimeInterval(refreshInterval),
                vehicle: vehicle,
                actions: actions
            )
        ]
        return Timeline(entries: entries, policy: .atEnd)
    }
}

/// Compact vehicle load + conditional refresh, mirroring
/// `VehicleTimelineProvider`'s tight-scope pattern: open a fresh
/// container, refresh only when the cached status is older than 30
/// minutes, and let the context drop as soon as we've built the entity.
@MainActor
private func loadControlsVehicleEntity(configuredVin: String?) async -> VehicleEntity? {
    let unit = AppSettings.liveDistanceUnit()
    let allPresets = (try? await ClimatePresetEntity.defaultQuery.suggestedEntities()) ?? []
    do {
        let container = try createSharedModelContainer(enableCloudKit: false)
        HTTPLogSinkManager.shared.configure(with: container, deviceType: .widget)
        let context = ModelContext(container)

        let target: BBVehicle?
        if let configuredVin {
            target = try context.fetch(FetchDescriptor<BBVehicle>()).first { $0.vin == configuredVin }
        } else {
            let descriptor = FetchDescriptor<BBVehicle>(
                predicate: #Predicate { !$0.isHidden },
                sortBy: [SortDescriptor(\.sortOrder)]
            )
            target = try context.fetch(descriptor).first
        }

        guard let bbVehicle = target else { return nil }

        if let account = bbVehicle.account {
            let lastUpdated = bbVehicle.lastUpdated ?? .distantPast
            if Date().timeIntervalSince(lastUpdated) >= 30 * 60 {
                try? await account.fetchAndUpdateVehicleStatus(for: bbVehicle, modelContext: context)
                try? context.save()
            }
        }

        return VehicleEntity(from: bbVehicle, with: unit, allPresets: allPresets)
    } catch {
        BBLogger.error(.app, "ControlsWidget: failed to load vehicle: \(error)")
        return nil
    }
}

// MARK: - Widgets

struct CustomControls2x2Widget: Widget {
    let kind = "CustomControls2x2Widget"

    var body: some WidgetConfiguration {
        AppIntentConfiguration(
            kind: kind,
            intent: CustomControls2x2ConfigIntent.self,
            provider: ControlsTimelineProvider<CustomControls2x2ConfigIntent>()
        ) { entry in
            ControlsWidgetView(entry: entry)
                .containerBackground(for: .widget) { ControlsWidgetBackground(vehicle: entry.vehicle) }
        }
        .contentMarginsDisabled()
        .configurationDisplayName("Vehicle Controls (2×2)")
        .description("Vehicle status with two customizable buttons.")
        .supportedFamilies([.systemSmall])
    }
}

struct CustomControls4x2Widget: Widget {
    let kind = "CustomControls4x2Widget"

    var body: some WidgetConfiguration {
        AppIntentConfiguration(
            kind: kind,
            intent: CustomControls4x2ConfigIntent.self,
            provider: ControlsTimelineProvider<CustomControls4x2ConfigIntent>()
        ) { entry in
            ControlsWidgetView(entry: entry)
                .containerBackground(for: .widget) { ControlsWidgetBackground(vehicle: entry.vehicle) }
        }
        .contentMarginsDisabled()
        .configurationDisplayName("Vehicle Controls (4×2)")
        .description("Vehicle status with four customizable buttons.")
        .supportedFamilies([.systemMedium])
    }
}

// MARK: - Views

private struct ControlsWidgetBackground: View {
    let vehicle: VehicleEntity?

    var body: some View {
        if let vehicle {
            LinearGradient(
                gradient: Gradient(colors: vehicle.backgroundGradient),
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
        } else {
            Color.gray.opacity(0.1)
        }
    }
}

struct ControlsWidgetView: View {
    let entry: ControlsWidgetEntry
    @Environment(\.widgetFamily) private var family

    private var isSmall: Bool { family == .systemSmall }

    var body: some View {
        if let vehicle = entry.vehicle {
            VStack(alignment: .leading, spacing: isSmall ? 6 : 10) {
                ControlsHeaderView(vehicle: vehicle, isSmall: isSmall)
                ControlsButtonRow(vehicle: vehicle, actions: entry.actions)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            .padding(.horizontal, isSmall ? 12 : 16)
            .padding(.vertical, isSmall ? 12 : 14)
        } else {
            VStack(spacing: 4) {
                Image(systemName: "car.fill")
                    .font(.title2)
                    .foregroundColor(.secondary)
                Text("No Vehicle")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
        }
    }
}

private struct ControlsHeaderView: View {
    let vehicle: VehicleEntity
    let isSmall: Bool

    private var textColor: Color {
        ControlsColorUtil.contrastingText(for: vehicle.backgroundGradient.first)
    }

    private var chargingText: String? {
        guard vehicle.isCharging == true else { return nil }
        if let kw = vehicle.chargeSpeedKilowatts, kw > 0 {
            return String(format: "%.1f kW", kw)
        }
        return "Charging"
    }

    private var rangeText: String {
        var text = vehicle.rangeText
        if let percentage = vehicle.batteryPercentage {
            text += " · \(Int(percentage))%"
        }
        return text
    }

    var body: some View {
        if isSmall {
            smallHeader
        } else {
            mediumHeader
        }
    }

    // 2×2: one datum per row, compact title — nothing competes for
    // horizontal space so nothing truncates.
    private var smallHeader: some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(vehicle.displayName)
                .font(.subheadline)
                .fontWeight(.semibold)
                .foregroundColor(textColor)
                .lineLimit(1)
                .minimumScaleFactor(0.7)

            Text(updatedText)
                .font(.caption2)
                .foregroundColor(textColor.opacity(0.7))

            HStack(spacing: 4) {
                Image(systemName: vehicle.fuelType.hasElectricCapability ? "bolt.fill" : "fuelpump.fill")
                    .font(.caption2)
                    .foregroundColor(vehicle.fuelType.hasElectricCapability ? vehicle.chargingColor : .orange)
                Text(rangeText)
                    .font(.caption)
                    .foregroundColor(textColor)
                    .lineLimit(1)
            }

            if let chargingText {
                Text(chargingText)
                    .font(.caption2)
                    .foregroundColor(vehicle.chargingColor)
                    .lineLimit(1)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    // 4×2: title + updated on one row, range/charging on the next.
    private var mediumHeader: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(alignment: .firstTextBaseline) {
                Text(vehicle.displayName)
                    .font(.headline)
                    .fontWeight(.bold)
                    .foregroundColor(textColor)
                    .lineLimit(1)
                Spacer()
                Text(updatedText)
                    .font(.caption2)
                    .foregroundColor(textColor.opacity(0.7))
                    .lineLimit(1)
            }

            HStack(spacing: 6) {
                Image(systemName: vehicle.fuelType.hasElectricCapability ? "bolt.fill" : "fuelpump.fill")
                    .font(.caption2)
                    .foregroundColor(vehicle.fuelType.hasElectricCapability ? vehicle.chargingColor : .orange)
                Text(rangeText)
                    .font(.caption)
                    .foregroundColor(textColor)
                    .lineLimit(1)
                if let chargingText {
                    Spacer(minLength: 4)
                    HStack(spacing: 2) {
                        Image(systemName: "bolt.fill")
                            .font(.caption2)
                        Text(chargingText)
                            .font(.caption2)
                            .lineLimit(1)
                    }
                    .foregroundColor(vehicle.chargingColor)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var updatedText: String {
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .abbreviated
        return formatter.localizedString(for: vehicle.timestamp, relativeTo: Date())
    }
}

private struct ControlsButtonRow: View {
    let vehicle: VehicleEntity
    let actions: [WidgetActionEntity]

    private let spacing: CGFloat = 10

    var body: some View {
        GeometryReader { geo in
            let count = max(actions.count, 1)
            let slotWidth = (geo.size.width - spacing * CGFloat(count - 1)) / CGFloat(count)
            // Largest square that fits both the per-slot width and the
            // row's height — so the buttons grow to fill the space left
            // under the header rather than sitting tiny in a gap.
            let diameter = max(36, min(slotWidth, geo.size.height))
            HStack(spacing: spacing) {
                ForEach(Array(actions.enumerated()), id: \.offset) { _, action in
                    ControlsCircleButton(vehicle: vehicle, action: action, diameter: diameter)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
        }
    }
}

private struct ControlsCircleButton: View {
    let vehicle: VehicleEntity
    let action: WidgetActionEntity
    let diameter: CGFloat

    private var iconSize: CGFloat { diameter * 0.42 }

    /// The icon to draw. A preset-specific start-climate action carries
    /// the preset's own icon; the generic "Start Climate" resolves to
    /// the vehicle's selected-preset icon so it matches what it'll run.
    private var displayIcon: String {
        if action.kind == .startClimate, action.presetId == nil {
            return vehicle.selectedPreset?.presetIcon ?? action.iconName
        }
        return action.iconName
    }

    var body: some View {
        if action.kind == .none {
            // Empty slot: render nothing, but reserve the space so the
            // remaining buttons keep their positions.
            Color.clear
                .frame(width: diameter, height: diameter)
        } else if let intent = makeIntent() {
            Button(intent: intent) {
                buttonLabel
            }
            .buttonStyle(.plain)
        }
    }

    /// A solid tinted circle with a white glyph. The in-app quick-action
    /// style (faint tint circle + colored icon) only reads on a neutral
    /// sheet; the widget sits on the vehicle's color gradient, so it
    /// needs an opaque fill to stay legible on any background.
    private var buttonLabel: some View {
        let tint = action.kind.color(for: vehicle)
        return ZStack {
            Circle().fill(tint)
            Image(systemName: displayIcon)
                .font(.system(size: iconSize, weight: .semibold))
                .foregroundStyle(.white)
        }
        .frame(width: diameter, height: diameter)
        .overlay(Circle().stroke(Color.white.opacity(0.25), lineWidth: 0.5))
    }

    /// Maps the configured action onto its concrete control intent,
    /// targeting the widget's configured vehicle (or, for a preset
    /// action, the preset's own vehicle).
    private func makeIntent() -> (any AppIntent)? {
        switch action.kind {
        case .lock:
            let intent = LockVehicleControlIntent()
            intent.vehicle = vehicle
            return intent
        case .unlock:
            let intent = UnlockVehicleControlIntent()
            intent.vehicle = vehicle
            return intent
        case .stopClimate:
            let intent = StopClimateControlIntent()
            intent.vehicle = vehicle
            return intent
        case .startCharge:
            let intent = StartChargeControlIntent()
            intent.vehicle = vehicle
            return intent
        case .stopCharge:
            let intent = StopChargeControlIntent()
            intent.vehicle = vehicle
            return intent
        case .startClimate:
            let intent = StartClimateControlIntent()
            if let presetId = action.presetId, let presetVin = action.presetVin {
                intent.preset = ClimatePresetEntity(
                    id: presetId,
                    vehicleVin: presetVin,
                    vehicleName: action.presetVehicleName ?? vehicle.displayName,
                    presetName: action.presetName ?? "Climate",
                    presetIcon: action.presetIcon ?? "fan",
                    isSelected: false
                )
            } else {
                intent.preset = vehicle.selectedPreset
            }
            return intent
        case .none:
            return nil
        }
    }
}

// MARK: - Color helpers

enum ControlsColorUtil {
    /// Picks black or white text for legibility against the widget's
    /// gradient top color — same luminance heuristic the original
    /// widget uses.
    static func contrastingText(for color: Color?) -> Color {
        guard let color else { return .white }
        let uiColor = UIColor(color)
        var red: CGFloat = 0
        var green: CGFloat = 0
        var blue: CGFloat = 0
        var alpha: CGFloat = 0
        uiColor.getRed(&red, green: &green, blue: &blue, alpha: &alpha)
        let brightness = (red * 0.299) + (green * 0.587) + (blue * 0.114)
        return brightness > 0.5 ? .black : .white
    }
}
