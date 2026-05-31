//
//  BetterBlueWidgetBundle.swift
//  BetterBlueWidget
//
//  Created by Mark Schmidt on 8/29/25.
//

import AppIntents
import SwiftUI
import WidgetKit

@main
struct BetterBlueWidgetBundle: WidgetBundle {
    var body: some Widget {
        // Listed first so they lead the widget gallery and are the
        // default content when converting an app icon into a widget.
        CustomControls2x2Widget()
        CustomControls4x2Widget()
        BetterBlueWidget()
        BetterBlueLockScreenWidget()
        VehicleLockControlWidget()
        VehicleUnlockControlWidget()
        ClimateStartControlWidget()
        ClimateStopControlWidget()
        StartChargeControlWidget()
        StopChargeControlWidget()
        VehicleActivityWidget()
    }
}
