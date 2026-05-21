//
//  VehicleSheetView.swift
//  BetterBlue
//
//  Apple-Maps-style bottom sheet that hosts the existing
//  `VehicleCardView` for the currently-selected vehicle. Designed to
//  be presented from `MainView`'s `.sheet(isPresented:)` once and
//  remain visible while the user pans around the map underneath.
//
//  Detents: `.medium` (basic controls visible above the fold) and
//  `.large` (everything in the card + room to scroll). The sheet
//  itself can't be dismissed by the user — it's always present when
//  there's a vehicle to display.
//

import BetterBlueKit
import SwiftUI

struct VehicleSheetView: View {
    let bbVehicle: BBVehicle
    let bbVehicles: [BBVehicle]
    let accounts: [BBAccount]
    let onVehicleSelected: (BBVehicle) -> Void
    let onSuccessfulRefresh: (() -> Void)?
    var transition: Namespace.ID?

    var body: some View {
        // ScrollView so the user can drag content within the sheet at
        // the .large detent. `presentationContentInteraction(.scrolls)`
        // below tells SwiftUI to route drags inside the scroll view
        // before they're interpreted as sheet-detent changes — without
        // that, swiping any of the inner buttons starts collapsing
        // the sheet.
        ScrollView {
            VehicleCardView(
                bbVehicle: bbVehicle,
                bbVehicles: bbVehicles,
                accounts: accounts,
                onVehicleSelected: onVehicleSelected,
                onSuccessfulRefresh: onSuccessfulRefresh,
                transition: transition,
                topAligned: true
            )
            .padding(.top, 8)
            .padding(.bottom, 24)
        }
        // Map under the sheet stays tappable at every detent (this is
        // what re-enables the map-marker affordance the old overlay
        // covered).
        .presentationBackgroundInteraction(.enabled(upThrough: .large))
        // Two-stop sheet: half-screen for at-a-glance controls,
        // full-screen for everything.
        .presentationDetents([.medium, .large])
        .presentationDragIndicator(.visible)
        // Drags on scrollable content should scroll first, then resize
        // the sheet only at the edges.
        .presentationContentInteraction(.scrolls)
        // Sheet is the primary surface — never dismiss.
        .interactiveDismissDisabled()
    }
}
