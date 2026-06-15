//
//  VehicleWidgetView.swift
//  BetterBlueWidget
//
//  Created by Mark Schmidt on 8/29/25.
//

import AppIntents
import BetterBlueKit
import SwiftUI
import WidgetKit

struct VehicleWidgetEntryView: View {
    let entry: VehicleWidgetEntry

    var body: some View {
        if let vehicle = entry.vehicle {
            let gradient = entry.configuration.effectiveGradient(for: vehicle)
            VehicleControlsWidget(
                vehicle: vehicle,
                buttons: entry.configuration.slotButtons,
                gradient: gradient
            )
            .containerBackground(for: .widget) {
                LinearGradient(
                    gradient: Gradient(colors: gradient),
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                )
            }
        } else {
            VStack {
                Image(systemName: "car.fill")
                    .font(.largeTitle)
                    .foregroundColor(.secondary)
                Text("No Vehicle")
                    .font(.headline)
                Text("Add an account in the app")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
            .containerBackground(for: .widget) {
                Color(.systemBackground)
            }
        }
    }
}

struct VehicleControlsWidget: View {
    let vehicle: VehicleEntity
    let buttons: [ConfiguredWidgetButton]
    let gradient: [Color]
    @Environment(\.widgetFamily) private var family

    var body: some View {
        Link(destination: URL(string: "betterblue://vehicle/\(vehicle.vin)")!) {
            UnifiedVehicleWidget(
                vehicle: vehicle,
                buttons: buttons,
                gradient: gradient,
                isSmall: family == .systemSmall
            )
        }
    }
}

struct WidgetButtonStyle: ButtonStyle {
    let backgroundColor: Color

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .foregroundColor(.white)
            .padding(.vertical, 12)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(backgroundColor.opacity(0.6))
            .cornerRadius(12)
            .shadow(color: .black.opacity(0.2), radius: 1, x: 0, y: 1)
            .scaleEffect(configuration.isPressed ? 0.95 : 1.0)
            .animation(.easeInOut(duration: 0.1), value: configuration.isPressed)
    }
}

// Unified widget components
struct UnifiedVehicleWidget: View {
    let vehicle: VehicleEntity
    let buttons: [ConfiguredWidgetButton]
    let gradient: [Color]
    let isSmall: Bool

    var body: some View {
        VStack(spacing: isSmall ? 0 : 8) {
            // Vehicle header
            VehicleHeaderView(vehicle: vehicle, gradient: gradient, isSmall: isSmall)

            // Action buttons
            VehicleButtonsView(vehicle: vehicle, buttons: buttons, isSmall: isSmall)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(.horizontal, 16)
        .padding(.vertical, isSmall ? 0 : 16)
    }
}

struct VehicleHeaderView: View {
    let vehicle: VehicleEntity
    let gradient: [Color]
    let isSmall: Bool

    private var textColor: Color {
        guard let primaryColor = gradient.first else { return .primary }
        return isLightColor(primaryColor) ? .black : .white
    }

    private func isLightColor(_ color: Color) -> Bool {
        let uiColor = UIColor(color)
        var red: CGFloat = 0
        var green: CGFloat = 0
        var blue: CGFloat = 0
        var alpha: CGFloat = 0

        uiColor.getRed(&red, green: &green, blue: &blue, alpha: &alpha)

        // Calculate perceived brightness using standard luminance formula
        let brightness = (red * 0.299) + (green * 0.587) + (blue * 0.114)
        return brightness > 0.5
    }

    var body: some View {
        // Name + time on the left; all status (ranges, lock/climate
        // glyphs, percentage bars) on the right, vertically centered
        // against the title block.
        HStack(alignment: .center, spacing: 8) {
            VStack(alignment: .leading, spacing: 0) {
                Text(vehicle.displayName)
                    .font(isSmall ? .caption : .headline)
                    .fontWeight(.bold)
                    .foregroundColor(textColor)
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)

                subtitleLine
                    .font(.caption2)
                    .foregroundColor(textColor.opacity(0.7))
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
            }

            Spacer(minLength: 4)

            VehicleStatusColumn(vehicle: vehicle, textColor: textColor, isSmall: isSmall)
                .frame(maxWidth: isSmall ? 120 : 196, alignment: .trailing)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, isSmall ? 4 : 6)
        .cornerRadius(12)
        .padding(.bottom, isSmall ? 4 : 0)
    }

    /// The line under the title. Normally the absolute last-updated
    /// time (the lock/climate glyphs now live in the status column on
    /// the right). When the user has just tapped a widget button, it's
    /// replaced by "<command> requested at <time>" until a real status
    /// refresh lands. Absolute (not relative) time because a widget's
    /// text is frozen between timeline reloads — a relative "5m ago"
    /// would silently go stale.
    @ViewBuilder
    private var subtitleLine: some View {
        if let pending = pendingCommand {
            Text("\(pending.command) requested at \(absoluteTime(pending.date))")
        } else {
            Text(absoluteUpdated)
        }
    }

    /// The most recent widget-button command for this vehicle, but only
    /// while it's still "pending" — newer than the last status refresh
    /// and recent enough to be relevant (a real refresh that postdates
    /// it means the status now reflects reality, so we stop showing it).
    private var pendingCommand: (command: String, date: Date)? {
        guard let latest = WidgetCommandStatus.latest(vin: vehicle.vin) else { return nil }
        let lastUpdated = vehicle.lastUpdated ?? .distantPast
        guard latest.date > lastUpdated,
              Date().timeIntervalSince(latest.date) < 30 * 60 else { return nil }
        return latest
    }

    private var absoluteUpdated: String {
        let date = vehicle.timestamp
        if Calendar.current.isDateInToday(date) {
            return date.formatted(date: .omitted, time: .shortened)
        }
        return date.formatted(date: .abbreviated, time: .shortened)
    }

    private func absoluteTime(_ date: Date) -> String {
        date.formatted(date: .omitted, time: .shortened)
    }
}

/// Right side of the widget header: a single range + status line on
/// top (each fuel axis as a colored "icon range", then lock + climate
/// glyphs, dot-separated) with a color-coded percentage bar per fuel
/// axis beneath it.
///   • Gas  → orange "⛽ range", one orange bar.
///   • EV   → green "⚡ range", one green bar.
///   • PHEV → "⚡ range · ⛽ range", a green bar then an orange bar.
struct VehicleStatusColumn: View {
    let vehicle: VehicleEntity
    let textColor: Color
    let isSmall: Bool

    /// One fuel axis: its color, formatted range, and fill level. EV
    /// uses the charging color, gas uses the gas color.
    private struct Axis: Identifiable {
        let id: Int
        let color: Color
        let range: String
        let fraction: Double
    }

    private var axes: [Axis] {
        var result: [Axis] = []

        // EV first (matches the PHEV sketch: EV then gas).
        if vehicle.fuelType.hasElectricCapability, let evRange = vehicle.evRange {
            result.append(Axis(
                id: 0, color: vehicle.chargingColor,
                range: evRange, fraction: (vehicle.evBatteryPercentage ?? 0) / 100
            ))
        }
        if let gasRange = vehicle.gasRange {
            result.append(Axis(
                id: 1, color: vehicle.gasColor,
                range: gasRange, fraction: (vehicle.gasFuelPercentage ?? 0) / 100
            ))
        }

        // Fallback: a vehicle with no parsed per-axis data still shows
        // its legacy range + battery so the column isn't empty.
        if result.isEmpty, !vehicle.rangeText.isEmpty {
            let isEV = vehicle.fuelType.hasElectricCapability
            result.append(Axis(
                id: 2,
                color: isEV ? vehicle.chargingColor : vehicle.gasColor,
                range: vehicle.rangeText,
                fraction: (vehicle.batteryPercentage ?? 0) / 100
            ))
        }

        return result
    }

    /// The top line: each axis's range in its fuel color, a bolt + kW
    /// charging readout when charging, then smaller lock and climate
    /// glyphs in the default text color. The fuel icons are omitted —
    /// the bar color already conveys the axis. Laid out as an HStack
    /// (rather than concatenated Text, whose `+` is deprecated in
    /// iOS 26) so each run keeps its own color and glyph size.
    private var statusLineView: some View {
        HStack(spacing: 5) {
            ForEach(axes) { axis in
                Text(axis.range).foregroundColor(axis.color)
            }
            if vehicle.isCharging == true, let kw = vehicle.chargeSpeedKilowatts, kw > 0 {
                HStack(spacing: 1) {
                    Image(systemName: "bolt.fill").font(glyphFont)
                    Text("\(Int(kw.rounded()))")
                }
                .foregroundColor(vehicle.chargingColor)
            }
            if let locked = vehicle.isLocked {
                Image(systemName: locked ? "lock.fill" : "lock.open.fill")
                    .font(glyphFont)
                    .foregroundColor(textColor)
            }
            if let climateOn = vehicle.isClimateOn {
                Image(systemName: climateOn ? "fan.fill" : "fan.slash")
                    .font(glyphFont)
                    .foregroundColor(textColor)
            }
        }
        .font(isSmall ? .caption2 : .caption)
        .lineLimit(1)
        .minimumScaleFactor(0.7)
    }

    /// Lock/climate/charging glyphs render a step smaller than the range.
    private var glyphFont: Font { isSmall ? .system(size: 9) : .caption2 }

    // Width of the status line, measured so the bars are exactly as
    // wide as the text above them rather than spanning the whole column.
    @State private var lineWidth: CGFloat = 0

    var body: some View {
        VStack(alignment: .trailing, spacing: 3) {
            statusLineView
                .background(
                    GeometryReader { geo in
                        Color.clear.preference(key: StatusLineWidthKey.self, value: geo.size.width)
                    }
                )

            ForEach(axes) { axis in
                percentageBar(fraction: axis.fraction, color: axis.color)
            }
        }
        .onPreferenceChange(StatusLineWidthKey.self) { lineWidth = $0 }
    }

    private func percentageBar(fraction: Double, color: Color) -> some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Capsule().fill(textColor.opacity(0.22))
                Capsule()
                    .fill(color)
                    .frame(width: geo.size.width * min(max(fraction, 0), 1))
            }
        }
        .frame(width: lineWidth > 0 ? lineWidth : nil, height: 5)
    }
}

/// Reports the measured width of the status line so its percentage bars
/// can match it.
private struct StatusLineWidthKey: PreferenceKey {
    static let defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = max(value, nextValue())
    }
}

extension WidgetActionEntity {
    /// Maps a configured action onto its concrete control intent,
    /// targeting the widget's vehicle (or, for a preset-specific
    /// action, the preset's own vehicle). Lives here — not next to the
    /// entity — because the control intents are iOS-only while the
    /// entity is shared with the watch widget target.
    func makeIntent(for vehicle: VehicleEntity) -> (any AppIntent)? {
        switch kind {
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
            if let presetId, let presetVin {
                intent.preset = ClimatePresetEntity(
                    id: presetId,
                    vehicleVin: presetVin,
                    vehicleName: presetVehicleName ?? vehicle.displayName,
                    presetName: presetName ?? "Climate",
                    presetIcon: presetIcon ?? "fan",
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

    /// Icon to render on the button. A preset-specific start-climate
    /// action carries the preset's own icon; the generic "Start
    /// Climate" resolves to the vehicle's selected-preset icon so the
    /// button matches what it'll actually run.
    func displayIcon(for vehicle: VehicleEntity) -> String {
        if kind == .startClimate, presetId == nil {
            return vehicle.selectedPreset?.presetIcon ?? iconName
        }
        return iconName
    }
}

struct VehicleButtonsView: View {
    let vehicle: VehicleEntity
    let buttons: [ConfiguredWidgetButton]
    let isSmall: Bool

    var body: some View {
        if isSmall {
            // Small widget: 2-column grid, icons only
            LazyVGrid(columns: Array(repeating: GridItem(spacing: 4), count: 2), spacing: 4) {
                ForEach(Array(buttons.enumerated()), id: \.offset) { _, button in
                    actionButton(button)
                }
            }
            .labelStyle(.iconOnly)
            .font(.headline)
            .fontWeight(.medium)
        } else {
            // Medium widget: rows of two with full labels
            VStack(spacing: 8) {
                ForEach(Array(buttons.chunked(into: 2).enumerated()), id: \.offset) { _, row in
                    HStack(spacing: 6) {
                        ForEach(Array(row.enumerated()), id: \.offset) { _, button in
                            actionButton(button)
                        }
                    }
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .font(.caption)
            .fontWeight(.medium)
        }
    }

    @ViewBuilder
    private func actionButton(_ button: ConfiguredWidgetButton) -> some View {
        if let intent = button.action.makeIntent(for: vehicle) {
            Button(intent: intent) {
                Label(button.action.kind.defaultTitle, systemImage: button.action.displayIcon(for: vehicle))
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
            }
            .buttonStyle(WidgetButtonStyle(backgroundColor: button.color(for: vehicle)))
        }
    }
}

private extension Array {
    func chunked(into size: Int) -> [[Element]] {
        stride(from: 0, to: count, by: size).map {
            Array(self[$0 ..< Swift.min($0 + size, count)])
        }
    }
}

#Preview(as: .systemMedium) {
    BetterBlueWidget()
} timeline: {
    let placeholderVehicle = VehicleEntity(
        id: .init(),
        displayName: "Ioniq 5",
        vin: "test",
        fuelType: .electric,
        rangeText: "250 mi",
        batteryPercentage: 85.0,
        timestamp: Date(),
        backgroundColorName: "white",
    )

    VehicleWidgetEntry(date: .now, vehicle: placeholderVehicle, configuration: VehicleWidgetIntent())
}

#Preview(as: .systemSmall) {
    BetterBlueWidget()
} timeline: {
    let placeholderVehicle = VehicleEntity(
        id: .init(),
        displayName: "Genesis GV60",
        vin: "test",
        fuelType: .electric,
        rangeText: "250 mi",
        batteryPercentage: 85.0,
        timestamp: Date(),
        backgroundColorName: "white",
    )

    VehicleWidgetEntry(date: .now, vehicle: placeholderVehicle, configuration: VehicleWidgetIntent())
}

struct LockScreenVehicleWidgetView: View {
    let entry: VehicleWidgetEntry
    @Environment(\.widgetFamily) private var family

    var body: some View {
        if let vehicle = entry.vehicle {
            switch family {
            case .accessoryCircular:
                LockScreenRangeWidget(vehicle: vehicle)
                    .containerBackground(for: .widget) {
                        Color.clear
                    }
            case .accessoryRectangular:
                LockScreenWideRangeWidget(vehicle: vehicle)
                    .containerBackground(for: .widget) {
                        Color.clear
                    }
            default:
                LockScreenRangeWidget(vehicle: vehicle)
                    .containerBackground(for: .widget) {
                        Color.clear
                    }
            }
        } else {
            Image(systemName: "car.fill")
                .foregroundColor(.secondary)
                .font(.title2)
                .containerBackground(for: .widget) {
                    Color.clear
                }
        }
    }
}

struct LockScreenProgressIcon: View {
    let vehicle: VehicleEntity
    let lineWidth = 3.0

    private var rangePercentage: Double {
        guard let batteryPercentage = vehicle.batteryPercentage else { return 0.0 }
        return batteryPercentage / 100.0
    }

    var body: some View {
        ZStack {
            Circle()
                .stroke(Color.secondary.opacity(0.3), lineWidth: lineWidth)

            Circle()
                .trim(from: 0, to: rangePercentage)
                .stroke(Color.primary,
                        style: StrokeStyle(lineWidth: lineWidth, lineCap: .round))
                .rotationEffect(.degrees(-90))
                .animation(.easeInOut(duration: 1), value: rangePercentage)

            Image(systemName: vehicle.fuelType.hasElectricCapability ? "bolt.car.fill" : "car.fill")
        }
        .frame(width: 44, height: 44)
    }
}

struct LockScreenRangeWidget: View {
    let vehicle: VehicleEntity

    var body: some View {
        LockScreenProgressIcon(
            vehicle: vehicle,
        )
    }
}

struct LockScreenWideRangeWidget: View {
    let vehicle: VehicleEntity

    var body: some View {
        HStack(spacing: 8) {
            // Progress icon on the left
            LockScreenProgressIcon(
                vehicle: vehicle,
            )

            // Vehicle name and range text
            VStack(alignment: .leading, spacing: 1) {
                Text(vehicle.displayName)
                    .fontWeight(.medium)
                    .lineLimit(1)

                Text(vehicle.rangeText)
                    .foregroundColor(.secondary)
                    .lineLimit(1)
            }

            Spacer()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

#Preview(as: .accessoryCircular) {
    BetterBlueLockScreenWidget()
} timeline: {
    let placeholderVehicle = VehicleEntity(
        id: .init(),
        displayName: "Model Y",
        vin: "test",
        fuelType: .electric,
        rangeText: "280 mi",
        batteryPercentage: 75.0,
        timestamp: Date(),
        backgroundColorName: "white"
    )

    VehicleWidgetEntry(date: .now, vehicle: placeholderVehicle, configuration: VehicleWidgetIntent())
}

#Preview(as: .accessoryRectangular) {
    BetterBlueLockScreenWidget()
} timeline: {
    let placeholderVehicle = VehicleEntity(
        id: .init(),
        displayName: "Ioniq 5",
        vin: "test",
        fuelType: .electric,
        rangeText: "250 mi",
        batteryPercentage: 85.0,
        timestamp: Date(),
        backgroundColorName: "white"
    )

    VehicleWidgetEntry(date: .now, vehicle: placeholderVehicle, configuration: VehicleWidgetIntent())
}
