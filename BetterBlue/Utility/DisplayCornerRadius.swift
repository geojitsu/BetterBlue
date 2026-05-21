//
//  DisplayCornerRadius.swift
//  BetterBlue
//
//  Reads the device's hardware display corner radius so views that
//  hug the screen edges (the Apple-Maps-style persistent sheet) can
//  use a *concentric* corner radius — i.e. inner radius = outer
//  radius − inset, which makes the inner shape's curve visually
//  parallel to the screen's curve instead of looking off-center.
//
//  Apple doesn't expose this publicly, so we go through the same
//  private KVC key that Apple Maps and a handful of other system
//  apps use. Falls back to a reasonable default (47pt — most
//  notched/Dynamic-Island iPhones) when the key is unavailable
//  (older devices, iPad).
//

import UIKit

@MainActor
enum DisplayCornerRadius {
    /// Hardware corner radius of the current main display in points.
    /// Cached after first access; the value is fixed per device.
    /// Main-actor isolated because UIKit screen / scene APIs are.
    static let value: CGFloat = {
        let key = "_displayCornerRadius"
        // `UIScreen.main` is deprecated since iOS 16 — resolve the
        // active screen through a connected window scene instead.
        let screen: UIScreen? = UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .first?
            .screen
        let radius = screen?.value(forKey: key) as? CGFloat
        return radius ?? 47.0
    }()

    /// Computes the corner radius an inset child needs to look
    /// concentric with the display corners. Never goes below 8pt so
    /// it still reads as rounded on devices without curved screens.
    static func concentric(insetBy inset: CGFloat) -> CGFloat {
        max(8, value - inset)
    }
}
