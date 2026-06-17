//
//  EVChargingProgressView.swift
//  BetterBlue
//
//  Shared view for EV charging progress display
//  Used by both EVRangeChargingCard and Live Activity
//

import SwiftUI

/// Shared view for displaying EV charging progress
/// Used by EVRangeChargingCard in the main app and VehicleActivityWidget for Live Activities
struct EVChargingProgressView: View {
    let icon: Image?
    let formattedRange: String
    let batteryPercentage: Int
    let isCharging: Bool
    let chargeSpeed: String?
    let chargeTimeRemaining: String?
    let targetSOC: Double?
    let showHeader: Bool
    /// Tint used for the actively-charging progress fill and the pulsing
    /// header icon. Callers pass the vehicle's customizable
    /// `chargingColor` so the bar matches the rest of the app's accents.
    let chargingColor: Color

    init(
        icon: Image? = nil,
        formattedRange: String = "",
        batteryPercentage: Int,
        isCharging: Bool,
        chargeSpeed: String?,
        chargeTimeRemaining: String?,
        targetSOC: Double?,
        showHeader: Bool = true,
        chargingColor: Color = .green
    ) {
        self.icon = icon
        self.formattedRange = formattedRange
        self.batteryPercentage = batteryPercentage
        self.isCharging = isCharging
        self.chargeSpeed = chargeSpeed
        self.chargeTimeRemaining = chargeTimeRemaining
        self.targetSOC = targetSOC
        self.showHeader = showHeader
        self.chargingColor = chargingColor
    }

    var body: some View {
        VStack(spacing: 12) {
            if showHeader {
                // Top row: Icon (optional), Range, and Battery percentage
                HStack(spacing: 12) {
                    if let icon {
                        icon
                            .font(.title2)
                            .foregroundColor(isCharging ? chargingColor : .primary)
                            .symbolEffect(.pulse, isActive: isCharging)
                            .frame(width: 28)
                    }

                    VStack(alignment: .leading, spacing: 4) {
                        Text("EV Range")
                            .font(.caption)
                        Text(formattedRange)
                            .font(.title3)
                            .fontWeight(.semibold)
                    }

                    Spacer()

                    VStack(alignment: .trailing, spacing: 4) {
                        Text("Battery")
                            .font(.caption)
                        Text("\(batteryPercentage)%")
                            .font(.title3)
                            .fontWeight(.semibold)
                    }
                }
                .foregroundColor(.primary)
            }

            // Progress bar
            if isCharging {
                chargingProgressBar
            } else {
                notChargingProgressBar
            }
        }
    }

    private var chargingProgressBar: some View {
        GeometryReader { geometry in
            ZStack(alignment: .leading) {
                // Background
                RoundedRectangle(cornerRadius: 8)
                    .fill(Color.gray.opacity(0.2))
                    .frame(height: 32)

                // Foreground progress
                RoundedRectangle(cornerRadius: 8)
                    .fill(chargingColor)
                    .frame(
                        width: geometry.size.width * (Double(batteryPercentage) / 100.0),
                        height: 32
                    )

                // Target SOC indicator — a curved "v" from the top edge
                // and "^" from the bottom edge pointing at the limit,
                // clipped to the bar so it doesn't spill past the rounded
                // edge near 99%. Hidden at 100%.
                if let targetSOC, targetSOC < 100 {
                    ChargeTargetMarker(
                        centerX: geometry.size.width * (targetSOC / 100.0),
                        halfWidth: 7,
                        reach: 8
                    )
                    .stroke(
                        Color.white.opacity(0.85),
                        style: StrokeStyle(lineWidth: 2.5, lineCap: .round, lineJoin: .round)
                    )
                    .frame(height: 32)
                    .clipShape(RoundedRectangle(cornerRadius: 8))
                }

                // Charge speed on the left (when provided).
                HStack {
                    if let speed = chargeSpeed {
                        Text(speed)
                            .font(.caption)
                            .fontWeight(.semibold)
                            .foregroundColor(.white)
                            .shadow(color: .black.opacity(0.5), radius: 2, x: 0, y: 1)
                            .padding(.leading, 12)
                    }
                    Spacer()
                }
                .frame(height: 32)

                // Time remaining. When the caller passed a charge
                // speed, time goes on the right within the target-SOC
                // area (Live Activity layout). When speed is hidden
                // (main sheet's EV row — the speed already shows on
                // the charging label), time moves to the LEFT so the
                // bar isn't entirely empty on that side.
                if let timeRemaining = chargeTimeRemaining {
                    if chargeSpeed != nil {
                        HStack {
                            Spacer()
                            Text(timeRemaining)
                                .font(.caption)
                                .fontWeight(.semibold)
                                .foregroundColor(.white)
                                .shadow(color: .black.opacity(0.5), radius: 2, x: 0, y: 1)
                                .padding(.trailing, 12)
                        }
                        .frame(
                            width: targetSOC != nil
                                ? geometry.size.width * ((targetSOC ?? 100) / 100.0)
                                : geometry.size.width,
                            height: 32
                        )
                    } else {
                        HStack {
                            Text(timeRemaining)
                                .font(.caption)
                                .fontWeight(.semibold)
                                .foregroundColor(.white)
                                .shadow(color: .black.opacity(0.5), radius: 2, x: 0, y: 1)
                                .padding(.leading, 12)
                            Spacer()
                        }
                        .frame(height: 32)
                    }
                }
            }
        }
        .frame(height: 32)
    }

    private var notChargingProgressBar: some View {
        GeometryReader { geometry in
            ZStack(alignment: .leading) {
                // Background
                Capsule()
                    .fill(Color.gray.opacity(0.3))
                    .frame(height: 6)

                // Foreground
                Capsule()
                    .fill(Color.gray.opacity(0.5))
                    .frame(
                        width: geometry.size.width * (Double(batteryPercentage) / 100.0),
                        height: 6
                    )
            }
        }
        .frame(height: 6)
    }
}
