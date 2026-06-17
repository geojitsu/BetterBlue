//
//  VehicleStatusSection.swift
//  BetterBlue
//
//  The widget's status section (range line + per-axis percentage bars +
//  the app-style EV charging bar). Decoupled from the widget's
//  `VehicleEntity` via `StatusSectionData` so it can be shared with the
//  main app — which lets the interactive debug screen
//  (`WidgetStatusDebugView`) render the real view and preview reliably
//  under the app scheme. Compiled into both the app and WidgetExtension
//  targets.
//

import SwiftUI

/// Plain inputs the status section renders. The widget builds this from
/// its `VehicleEntity`; the debug screen builds it from sliders.
struct StatusSectionData {
    var hasElectricCapability: Bool
    var evRange: String?
    var evBatteryPercentage: Double?
    var gasRange: String?
    var gasFuelPercentage: Double?
    var rangeText: String
    var batteryPercentage: Double?
    var isCharging: Bool
    var chargeSpeedKilowatts: Double?
    var chargeTimeRemainingMinutes: Int?
    var targetStateOfCharge: Int?
    var isLocked: Bool?
    var isClimateOn: Bool?
    var chargingColor: Color
    var gasColor: Color
}

/// Range + status line on top, a color-coded percentage bar per fuel
/// axis beneath. The EV axis becomes the app-style charging bar while
/// plugged in (on the larger / non-`isSmall` layout).
///   • Gas  → one orange bar.
///   • EV   → one green bar.
///   • PHEV → a green bar then an orange bar.
struct VehicleStatusColumn: View {
    let data: StatusSectionData
    let textColor: Color
    let isSmall: Bool
    /// When set (small widget), the status line leads with this text —
    /// the last-updated time, which has no room of its own there.
    var leadingTime: String?

    /// One fuel axis: its color, formatted range, and fill level. EV
    /// uses the charging color, gas uses the gas color. The EV axis gets
    /// the richer charging bar when plugged in.
    private struct Axis: Identifiable {
        let id: Int
        let color: Color
        let range: String
        let fraction: Double
        let isEV: Bool
    }

    private var axes: [Axis] {
        var result: [Axis] = []

        // EV first (matches the PHEV sketch: EV then gas).
        if data.hasElectricCapability, let evRange = data.evRange {
            result.append(Axis(
                id: 0, color: data.chargingColor,
                range: evRange, fraction: (data.evBatteryPercentage ?? 0) / 100, isEV: true
            ))
        }
        if let gasRange = data.gasRange {
            result.append(Axis(
                id: 1, color: data.gasColor,
                range: gasRange, fraction: (data.gasFuelPercentage ?? 0) / 100, isEV: false
            ))
        }

        // Fallback: a vehicle with no parsed per-axis data still shows
        // its legacy range + battery so the column isn't empty.
        if result.isEmpty, !data.rangeText.isEmpty {
            let isEV = data.hasElectricCapability
            result.append(Axis(
                id: 2,
                color: isEV ? data.chargingColor : data.gasColor,
                range: data.rangeText,
                fraction: (data.batteryPercentage ?? 0) / 100,
                isEV: isEV
            ))
        }

        return result
    }

    /// The top line: each axis's range in its fuel color, then smaller
    /// lock and climate glyphs in the default text color. Laid out as an
    /// HStack (rather than concatenated Text, whose `+` is deprecated in
    /// iOS 26) so each run keeps its own color and glyph size.
    private var statusLineView: some View {
        HStack(spacing: 5) {
            if let leadingTime {
                Text(leadingTime).foregroundColor(textColor.opacity(0.7))
            }
            ForEach(axes) { axis in
                Text(axis.range).foregroundColor(axis.color)
            }
            // Charge speed isn't shown here — it lives inside the charging
            // bar (right-aligned) so a PHEV's two-range line isn't cut off.
            if let locked = data.isLocked {
                Image(systemName: locked ? "lock.fill" : "lock.open.fill")
                    .font(glyphFont)
                    .foregroundColor(textColor)
            }
            if let climateOn = data.isClimateOn {
                Image(systemName: climateOn ? "fan.fill" : "fan.slash")
                    .font(glyphFont)
                    .foregroundColor(textColor)
            }
        }
        .font(isSmall ? .caption2 : .footnote)
        .lineLimit(1)
        .minimumScaleFactor(0.7)
    }

    /// Lock/climate glyphs render a step smaller than the range.
    private var glyphFont: Font { isSmall ? .system(size: 9) : .caption2 }

    // Width of the status line, measured so the bars are exactly as wide
    // as the text above them rather than spanning the whole column.
    @State private var lineWidth: CGFloat = 0

    var body: some View {
        VStack(alignment: isSmall ? .center : .trailing, spacing: 3) {
            statusLineView
                .background(
                    GeometryReader { geo in
                        Color.clear.preference(key: StatusLineWidthKey.self, value: geo.size.width)
                    }
                )

            ForEach(axes) { axis in
                // While charging, the EV axis gets the app-style bar
                // (time-remaining text + dashed target marker) on the
                // larger layout; everything else is the thin capsule.
                if axis.isEV, !isSmall, data.isCharging {
                    chargingBar(axis)
                } else {
                    percentageBar(fraction: axis.fraction, color: axis.color)
                }
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

    /// App-style charging bar: a taller filled track with the time
    /// remaining and charge speed inside it and a dashed vertical marker
    /// at the target charge level — mirroring the main sheet's EV bar.
    /// Text positions are fill-aware so they sit over the green fill or
    /// the gray remainder rather than straddling the boundary/outline.
    private func chargingBar(_ axis: Axis) -> some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                RoundedRectangle(cornerRadius: 5).fill(textColor.opacity(0.22))
                RoundedRectangle(cornerRadius: 5)
                    .fill(axis.color)
                    .frame(width: fillWidth(axis, geo.size.width))

                // Target marker: a "v" pinching down from the top edge and
                // a "^" pinching up from the bottom edge at the target SOC.
                // Clipped to the bar so it doesn't spill past the rounded
                // edge near 99%; absent entirely at 100%.
                if let target = data.targetStateOfCharge, target < 100 {
                    ChargeTargetMarker(centerX: geo.size.width * (Double(target) / 100.0))
                        .stroke(
                            Color.white.opacity(0.9),
                            style: StrokeStyle(lineWidth: 2, lineCap: .round, lineJoin: .round)
                        )
                        .clipShape(RoundedRectangle(cornerRadius: 5))
                }

                // Time remaining (left): over the green fill when there's
                // room for it (>25%), otherwise shifted to the start of
                // the gray remainder so it's not cramped on a thin fill.
                if let minutes = data.chargeTimeRemainingMinutes, minutes > 0 {
                    Text(timeRemainingString(minutes))
                        .font(.system(size: 9, weight: .semibold))
                        .foregroundColor(.white)
                        .shadow(color: .black.opacity(0.5), radius: 1, x: 0, y: 1)
                        .padding(.leading, 5)
                        .offset(x: axis.fraction > 0.25 ? 0 : fillWidth(axis, geo.size.width))
                }

                // Charge speed (right): right-aligned over the gray when
                // the fill is small (<80%); once the fill is large the gray
                // is too thin, so right-align to the green fill edge so it
                // stays clear of the rounded outline.
                if let kw = data.chargeSpeedKilowatts, kw > 0 {
                    Text("\(Int(kw.rounded()))kw")
                        .font(.system(size: 9, weight: .semibold))
                        .foregroundColor(.white)
                        .shadow(color: .black.opacity(0.5), radius: 1, x: 0, y: 1)
                        .padding(.trailing, 6)
                        .frame(
                            width: axis.fraction < 0.8 ? geo.size.width : fillWidth(axis, geo.size.width),
                            alignment: .trailing
                        )
                }
            }
        }
        .frame(width: lineWidth > 0 ? lineWidth : nil, height: 18)
    }

    /// Pixel width of the filled portion for an axis's fraction.
    private func fillWidth(_ axis: Axis, _ width: CGFloat) -> CGFloat {
        width * min(max(axis.fraction, 0), 1)
    }

    private func timeRemainingString(_ minutes: Int) -> String {
        minutes >= 60 ? "\(minutes / 60)h \(minutes % 60)m" : "\(minutes)m"
    }
}

/// Charge-limit target marker: a "v" pinching down from the top edge and
/// a "^" pinching up from the bottom edge, both centered on `centerX`.
/// The legs are quadratic curves (rather than straight triangles) so they
/// read as soft chevrons matching the bar's rounded corners. Shared by
/// the widget status bar and the main sheet's `EVChargingProgressView`;
/// `halfWidth` / `reach` scale it to each bar's height + corner radius.
struct ChargeTargetMarker: Shape {
    /// Target x within the rect (absolute, not a fraction).
    var centerX: CGFloat
    /// Half the marker's width at the bar edge.
    var halfWidth: CGFloat = 4.5
    /// How far each chevron's point reaches in from its edge.
    var reach: CGFloat = 5

    func path(in rect: CGRect) -> Path {
        var path = Path()
        let cx = centerX

        // Top "v" — base on the top edge, point reaching down into the bar.
        path.move(to: CGPoint(x: cx - halfWidth, y: rect.minY))
        path.addQuadCurve(
            to: CGPoint(x: cx, y: rect.minY + reach),
            control: CGPoint(x: cx - halfWidth * 0.35, y: rect.minY + reach * 0.7)
        )
        path.addQuadCurve(
            to: CGPoint(x: cx + halfWidth, y: rect.minY),
            control: CGPoint(x: cx + halfWidth * 0.35, y: rect.minY + reach * 0.7)
        )

        // Bottom "^" — base on the bottom edge, point reaching up.
        path.move(to: CGPoint(x: cx - halfWidth, y: rect.maxY))
        path.addQuadCurve(
            to: CGPoint(x: cx, y: rect.maxY - reach),
            control: CGPoint(x: cx - halfWidth * 0.35, y: rect.maxY - reach * 0.7)
        )
        path.addQuadCurve(
            to: CGPoint(x: cx + halfWidth, y: rect.maxY),
            control: CGPoint(x: cx + halfWidth * 0.35, y: rect.maxY - reach * 0.7)
        )
        return path
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
