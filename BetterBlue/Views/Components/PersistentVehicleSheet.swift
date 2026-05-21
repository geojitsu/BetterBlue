//
//  PersistentVehicleSheet.swift
//  BetterBlue
//
//  Apple-Maps-style persistent bottom panel. Unlike a real
//  `.sheet(isPresented:)` it:
//    - Lives inside the tab-content ZStack, so it sits *above* the
//      system tab bar instead of overlaying it.
//    - Doesn't compete with other `.sheet` modifiers — opening
//      Settings (a real sheet) no longer animates this panel away.
//    - Is continuously presented (no dismiss affordance, no
//      `interactiveDismissDisabled` needed — there's no SwiftUI
//      sheet machinery in the loop at all).
//
//  Section order mirrors the legacy VehicleCardView so muscle memory
//  carries over: header (name + refresh) → EV range → charging →
//  gas range → lock → climate → divider → below-the-fold details.
//

import BetterBlueKit
import CoreLocation
import SwiftData
import SwiftUI
import WidgetKit

/// Detent for the persistent vehicle sheet. Two snap heights —
/// shared by both `PersistentVehicleSheet` (which uses it to size
/// its chrome) and `VehicleSheetPager` (which owns the @State so
/// all cards animate together as the user pages between vehicles).
enum SheetDetent { case collapsed, expanded }

/// One self-contained vehicle card. Owns its own glass chrome,
/// drag handle, asymmetric concentric corners, and the actions it
/// hosts. The parent `VehicleSheetPager` just lays a row of these
/// in a paging ScrollView — each card is a complete visual unit,
/// so swiping between them slides whole cards rather than swapping
/// content inside a shared frame.
struct PersistentVehicleSheet: View {
    let bbVehicle: BBVehicle
    let bbVehicles: [BBVehicle]
    /// Index of the currently-visible vehicle in the pager. Used by
    /// the drag handle to render a page-indicator (filled capsule
    /// for selected, small dots for the others) when there's more
    /// than one vehicle. All cards render the same indicator
    /// because they all see the same `selectedIndex`.
    let selectedIndex: Int
    @Binding var detent: SheetDetent
    /// Height of the glass chrome — computed by the parent
    /// `VehicleSheetPager` (so all cards share the same height) and
    /// passed down. The card has no GeometryReader of its own; the
    /// pager handles sizing so it can constrain its outer ScrollView
    /// frame and let map taps pass through above the card.
    let cardHeight: CGFloat
    let onSuccessfulRefresh: (() -> Void)?

    @Environment(\.modelContext) private var modelContext
    @State private var appSettings = AppSettings.shared
    @Query private var allClimatePresets: [ClimatePreset]

    // Refresh state
    @State private var isRefreshing = false
    @State private var showRefreshSuccess = false

    // Per-action in-progress flags so each circular button can spin
    // independently of the others (locking the vehicle shouldn't stall
    // the climate button's UI).
    @State private var isLockBusy = false
    @State private var isClimateBusy = false
    @State private var isChargingBusy = false
    // Live status text from each in-flight action — replaces the
    // section's idle subtitle so the user sees real progress (e.g.
    // "Locking...", "Waiting for vehicle...", "Charge started").
    // Same mechanism the legacy VehicleButtons used via the
    // statusMessageUpdater closure.
    @State private var lockStatusText: String?
    @State private var chargingStatusText: String?
    @State private var climateStatusText: String?

    // Error state — single banner above the sections, taps to
    // ErrorDetailsSheet for the structured view.
    @State private var errorMessage: AttributedString?
    @State private var lastActionError: ActionError?
    @State private var showingErrorDetails = false

    // Per-action info sheets (lifted from the old button files so the
    // circular replacements can still surface them).
    @State private var showingVehicleInfo = false
    @State private var showingAccountInfo = false
    @State private var showingHTTPLogs = false
    @State private var showingVehicleConfiguration = false
    @State private var showingTripDetails = false
    @State private var showingClimateSettings = false
    @State private var showingChargeLimitSettings = false

    /// Outer padding on all four sides — the card "floats" inside
    /// this gap. Bottom matches sides so the spacing is uniform.
    private let outerInset: CGFloat = 8
    /// Corner radius for the card's top corners. Picked to be
    /// large enough that the inline refresh button at the trailing
    /// edge of the headerRow visually sits in the corner curve.
    private let cornerRadius: CGFloat = 40
    /// Total vertical space the drag handle occupies inside the
    /// card (8pt top pad + 5pt capsule + 4pt bottom pad). Used to
    /// size the contentArea's bounded frame.
    private let dragHandleHeight: CGFloat = 17

    var body: some View {
        // Page: optional error card above + main card. Both share
        // the same glass-with-ZStack-mask treatment so they look
        // like sibling cards. Error overhead is measured on the
        // error card itself (in `errorCardView`) so the page
        // height doesn't cascade with `cardHeight` during drags.
        VStack(spacing: 8) {
            if let errorMessage {
                errorCardView(errorMessage)
            }
            mainCardBody
        }
        // No card-wide DragGesture — the *vertical* swipe-anywhere
        // behavior is delegated to the inner vertical ScrollView in
        // `contentArea`, which doesn't conflict with the parent
        // horizontal pager because the gestures are perpendicular.
        // We watch its scroll offset and snap the detent when the
        // user scrolls up while collapsed, or overscrolls down past
        // the top while expanded.
        .animation(.spring(response: 0.35, dampingFraction: 0.85), value: detent)
        .ignoresSafeArea(.keyboard)
        .task(id: bbVehicle.vin) { await refreshStatus() }
        .sheet(isPresented: $showingErrorDetails) {
            if let lastActionError {
                ErrorDetailsSheet(error: lastActionError) {
                    showingErrorDetails = false
                }
                .presentationDetents([.medium, .large])
            }
        }
        .sheet(isPresented: $showingVehicleInfo) {
            NavigationView {
                VehicleInfoView(bbVehicle: bbVehicle)
                    .toolbar {
                        ToolbarItem(placement: .navigationBarLeading) {
                            Button("Done") { showingVehicleInfo = false }
                        }
                    }
            }
        }
        .sheet(isPresented: $showingAccountInfo) {
            if let account = bbVehicle.account {
                NavigationView {
                    AccountInfoView(account: account)
                        .toolbar {
                            ToolbarItem(placement: .navigationBarLeading) {
                                Button("Done") { showingAccountInfo = false }
                            }
                        }
                }
            }
        }
        .sheet(isPresented: $showingHTTPLogs) {
            if let account = bbVehicle.account {
                NavigationView {
                    HTTPLogView(accountId: account.id, transition: nil)
                        .toolbar {
                            ToolbarItem(placement: .navigationBarLeading) {
                                Button("Done") { showingHTTPLogs = false }
                            }
                        }
                }
            }
        }
        .sheet(isPresented: $showingVehicleConfiguration) {
            if bbVehicle.account?.brandEnum == .fake {
                NavigationView {
                    FakeVehicleDetailView(vehicle: bbVehicle)
                        .navigationTitle("Configure Vehicle")
                        .navigationBarTitleDisplayMode(.inline)
                        .toolbar {
                            ToolbarItem(placement: .navigationBarLeading) {
                                Button("Done") { showingVehicleConfiguration = false }
                            }
                        }
                }
            }
        }
        .sheet(isPresented: $showingTripDetails) {
            NavigationView {
                TripDetailsView(bbVehicle: bbVehicle)
                    .toolbar {
                        ToolbarItem(placement: .navigationBarLeading) {
                            Button("Done") { showingTripDetails = false }
                        }
                    }
            }
        }
        .sheet(isPresented: $showingClimateSettings) {
            ClimateSettingsSheet(vehicle: bbVehicle)
        }
        .sheet(isPresented: $showingChargeLimitSettings) {
            ChargeLimitSettingsSheet(vehicle: bbVehicle)
        }
    }

    /// Main glass card body (header + sections + detail rows).
    /// Sized to `cardHeight`; the page may render an error card
    /// above it as a sibling in the body's VStack.
    @ViewBuilder
    private var mainCardBody: some View {
        let bottomCornerRadius = max(8, DisplayCornerRadius.value - outerInset)
        let shape = UnevenRoundedRectangle(
            topLeadingRadius: cornerRadius,
            bottomLeadingRadius: bottomCornerRadius,
            bottomTrailingRadius: bottomCornerRadius,
            topTrailingRadius: cornerRadius,
            style: .continuous
        )
        ZStack(alignment: .top) {
            Color.clear
                .glassEffect(.regular, in: shape)
            VStack(spacing: 0) {
                dragHandle
                // No `.frame(height: cardHeight - dragHandleHeight)`
                // on contentArea. Constraining it would make its
                // internal GeometryReader measurement depend on
                // `cardHeight` — which during a drag changes every
                // frame, triggering a measurement → preference →
                // `naturalHeights` → `cardHeight` cascade that
                // judders. Letting contentArea use its intrinsic
                // height keeps the measurement stable; the outer
                // `.mask(shape)` clips overflow at the corners.
                contentArea
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .frame(height: cardHeight, alignment: .top)
        .mask(shape)
        .padding(.horizontal, outerInset)
        .padding(.bottom, outerInset)
    }

    /// Error notification card rendered above the main card when
    /// an action fails. Tapping it surfaces the structured error
    /// details sheet (when one exists). Visually styled like a
    /// sibling glass card to the main sheet.
    @ViewBuilder
    private func errorCardView(_ message: AttributedString) -> some View {
        let shape = RoundedRectangle(cornerRadius: 20, style: .continuous)
        Button {
            if lastActionError != nil {
                showingErrorDetails = true
            }
        } label: {
            HStack(spacing: 12) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundStyle(.red)
                    .font(.title3)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Connection Error")
                        .font(.subheadline)
                        .fontWeight(.semibold)
                        .foregroundStyle(.primary)
                    Text(message)
                        .font(.caption)
                        .foregroundColor(.secondary)
                        .tint(.blue)
                }
                Spacer()
                if lastActionError != nil {
                    Image(systemName: "chevron.right")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .buttonStyle(.plain)
        .background(
            ZStack {
                Color.clear.glassEffect(.regular, in: shape)
            }
            .mask(shape)
        )
        .padding(.horizontal, outerInset)
        .padding(.top, outerInset)
        // Report only the error card's own outer height + the
        // VStack spacing — stable measurement that doesn't change
        // with `cardHeight`. Pager adds this to its ScrollView
        // frame so the error card fits above the main card.
        .background(
            GeometryReader { proxy in
                Color.clear.preference(
                    key: ErrorOverheadPreferenceKey.self,
                    value: proxy.size.height + 8
                )
            }
        )
    }

    // MARK: - Chrome (drag handle + content area)

    /// Drag handle that doubles as a pagination indicator. With a
    /// single vehicle it's the familiar 36×5pt capsule. With
    /// multiple vehicles it becomes a row of small dots — one per
    /// vehicle — with the currently-selected dot stretched to a
    /// capsule (e.g. `. _ . .` when on the second of four). All
    /// cards render the same indicator since they all see the
    /// same `selectedIndex` from the pager.
    @ViewBuilder
    private var dragHandle: some View {
        HStack(spacing: 6) {
            if bbVehicles.count <= 1 {
                Capsule()
                    .fill(.tertiary)
                    .frame(width: 36, height: 5)
            } else {
                ForEach(0 ..< bbVehicles.count, id: \.self) { index in
                    Capsule()
                        .fill(.tertiary)
                        .frame(
                            width: index == selectedIndex ? 20 : 5,
                            height: 5
                        )
                }
            }
        }
        .animation(.spring(response: 0.3, dampingFraction: 0.85), value: selectedIndex)
        .padding(.top, 8)
        .padding(.bottom, 4)
        .frame(maxWidth: .infinity)
        .contentShape(Rectangle())
        .onTapGesture {
            detent = detent == .collapsed ? .expanded : .collapsed
        }
        // No local drag gesture — vertical swipe-anywhere is
        // handled by the pager's `verticalCardDragGesture`
        // (attached as a `simultaneousGesture` on the pager's
        // ScrollView) so it works from anywhere on the card.
    }

    @ViewBuilder
    private var contentArea: some View {
        // Plain VStack — no inner scroll. Vertical resize is driven
        // by the parent pager's `simultaneousGesture` on the
        // ScrollView, which gives finger-follow live updates.
        contentStack
            .padding(.horizontal, 20)
            .padding(.top, 5)
            .padding(.bottom, 16)
            .frame(maxWidth: .infinity, alignment: .topLeading)
            .background(
                GeometryReader { proxy in
                    Color.clear.preference(
                        key: ContentHeightPreferenceKey.self,
                        // +17 = drag handle vertical space
                        // (8 top pad + 5 handle + 4 bottom pad).
                        value: proxy.size.height + 17
                    )
                }
            )
    }


    // MARK: - Content stack (sections)

    @ViewBuilder
    private var contentStack: some View {
        VStack(alignment: .leading, spacing: 16) {
            // Error display moved to a separate `errorCardView`
            // rendered above the main card in `body`'s VStack.
            headerRow
            // Compact fuel rows for all vehicle types — gas first,
            // then EV (PHEVs get both; pure EV and pure ICE get
            // just the relevant one). EV row's bar upgrades to the
            // thick EVChargingProgressView charging bar when plugged
            // in + charging.
            if let gas = safeGasRange {
                gasRangeRow(gas)
            }
            if let ev = safeEvStatus {
                evRangeRow(ev)
                chargingSection(ev)
            }
            lockSection
            climateSection
            Divider().padding(.top, 4)
            detailRows
        }
    }

    // MARK: - Header (name as menu + inline refresh button)

    @ViewBuilder
    private var headerRow: some View {
        // Title Menu + Spacer + refresh button — inline so the row
        // lays out naturally and the refresh button is guaranteed
        // visible (overlays inside the GlassEffectContainer were
        // disappearing). Menu is in an HStack with a Spacer (not
        // `.frame(maxWidth: .infinity)`) so its hit area stays
        // bound to the label and doesn't eat horizontal swipes.
        HStack(alignment: .center, spacing: 8) {
            Menu {
                vehicleMenuContent
            } label: {
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 4) {
                        Text(bbVehicle.displayName)
                            .font(.title2)
                            .fontWeight(.bold)
                            .foregroundColor(.primary)
                        Image(systemName: "chevron.down")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                    if let lastUpdated = bbVehicle.lastUpdated {
                        Text("Updated \(compactLastUpdated(lastUpdated))")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                }
            }
            .buttonStyle(.plain)
            Spacer(minLength: 0)
            CircularIconButton(
                systemName: showRefreshSuccess ? "checkmark" : "arrow.clockwise",
                tint: showRefreshSuccess ? .green : bbVehicle.primaryColor,
                isBusy: isRefreshing
            ) {
                Task { await refreshStatus(forceCacheBypass: true) }
            }
            .disabled(isRefreshing)
        }
    }

    // MARK: - Sections

    /// Compact EV range row. Used for all vehicles with an EV
    /// drivetrain (pure EV + PHEV). Aligns with the SectionRow icon
    /// column (32pt), range left, percentage right, and an
    /// EVChargingProgressView-driven bar — thin capsule when not
    /// charging, thick 32pt charging bar with kW + time + dotted
    /// target SOC line when plugged in and charging.
    @ViewBuilder
    private func evRangeRow(_ ev: VehicleStatus.EVStatus) -> some View {
        let formattedRange: String = {
            guard ev.evRange.range.length > 0 else { return "--" }
            return ev.evRange.range.units.format(
                ev.evRange.range.length,
                to: appSettings.preferredDistanceUnit
            )
        }()
        let chargeSpeed: String? = (ev.charging && ev.chargeSpeed > 0)
            ? String(format: "%.1f kW", ev.chargeSpeed)
            : nil
        let timeRemaining: String? = {
            guard ev.charging, ev.chargeTime > .seconds(0) else { return nil }
            let formatted = ev.chargeTime.formatted(
                .units(allowed: [.hours, .minutes], width: .abbreviated)
            )
            if let target = ev.currentTargetSOC {
                return "\(formatted) to \(Int(target))%"
            }
            return formatted
        }()
        // EV indicator color: chargingColor (default green) for both
        // states — user-customizable via Vehicle → Customization →
        // Charging Color.
        let tint = bbVehicle.chargingColor

        HStack(alignment: .center, spacing: 12) {
            Image(systemName: "bolt.fill")
                .font(.title3)
                .foregroundStyle(tint)
                .frame(width: 32, height: 32)
            VStack(alignment: .leading, spacing: 6) {
                HStack(alignment: .firstTextBaseline) {
                    Text(formattedRange)
                        .font(.subheadline)
                        .fontWeight(.semibold)
                    Spacer()
                    Text("\(Int(ev.evRange.percentage))%")
                        .font(.subheadline)
                        .foregroundColor(.secondary)
                }
                if ev.charging {
                    // Thick 32pt charging bar with kW + time +
                    // dotted target SOC line. Same visual as the
                    // legacy EV charging view.
                    EVChargingProgressView(
                        formattedRange: "",
                        batteryPercentage: Int(ev.evRange.percentage),
                        isCharging: true,
                        chargeSpeed: chargeSpeed,
                        chargeTimeRemaining: timeRemaining,
                        targetSOC: ev.currentTargetSOC,
                        showHeader: false,
                        chargingColor: bbVehicle.chargingColor
                    )
                } else {
                    // Slim 6pt bar in the EV tint (green default).
                    // Matches the gas row's bar style for visual
                    // consistency across the PHEV section.
                    slimProgressBar(
                        percentage: ev.evRange.percentage,
                        tint: tint
                    )
                }
            }
        }
    }

    /// Compact gas range row — same layout as `evRangeRow` but
    /// with a fuelpump icon and a plain slim capsule progress bar.
    /// Used for all vehicles with a gas tank (pure ICE + PHEV).
    @ViewBuilder
    private func gasRangeRow(_ gas: VehicleStatus.FuelRange) -> some View {
        let formattedRange: String = {
            guard gas.range.length > 0 else { return "--" }
            return gas.range.units.format(
                gas.range.length,
                to: appSettings.preferredDistanceUnit
            )
        }()
        // Gas indicator color: gasColor (default orange) —
        // user-customizable via Vehicle → Customization →
        // Gas Color.
        let tint = bbVehicle.gasColor
        HStack(alignment: .center, spacing: 12) {
            Image(systemName: "fuelpump.fill")
                .font(.title3)
                .foregroundStyle(tint)
                .frame(width: 32, height: 32)
            VStack(alignment: .leading, spacing: 6) {
                HStack(alignment: .firstTextBaseline) {
                    Text(formattedRange)
                        .font(.subheadline)
                        .fontWeight(.semibold)
                    Spacer()
                    Text("\(Int(gas.percentage))%")
                        .font(.subheadline)
                        .foregroundColor(.secondary)
                }
                slimProgressBar(percentage: gas.percentage, tint: tint)
            }
        }
    }

    /// 6pt capsule progress bar used by both the gas row and the
    /// EV row's not-charging state. Gray background with a tinted
    /// fill. Matches EVChargingProgressView's not-charging bar
    /// thickness exactly.
    @ViewBuilder
    private func slimProgressBar(percentage: Double, tint: Color) -> some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Capsule()
                    .fill(Color.gray.opacity(0.3))
                    .frame(height: 6)
                Capsule()
                    .fill(tint.opacity(0.7))
                    .frame(
                        width: geo.size.width * max(0, min(1, percentage / 100.0)),
                        height: 6
                    )
            }
        }
        .frame(height: 6)
    }

    @ViewBuilder
    private func chargingSection(_ ev: VehicleStatus.EVStatus) -> some View {
        let chargingColor = bbVehicle.chargingColor
        let isCharging = ev.charging
        let isPluggedIn = ev.pluggedIn
        let icon = isCharging ? "bolt.slash.fill" : "bolt.fill"
        let stateText: String = {
            if isCharging { return "Charging" }
            if isPluggedIn { return "Ready to Charge" }
            return "Unplugged"
        }()
        SectionRow(
            icon: bbVehicle.plugIcon(for: ev.plugType),
            iconColor: isPluggedIn ? chargingColor : .secondary,
            // Pulse the status icon (left side) while charging is
            // active — matches the legacy ChargingButton cue. The
            // trailing quick-action button stays static.
            iconAnimation: isCharging ? .pulse : .none,
            title: "Charging",
            // While an action is in-flight, show its live status
            // text (e.g. "Starting Charge", "Waiting for vehicle").
            // Falls back to the steady-state stateText when idle.
            subtitle: chargingStatusText ?? stateText
        ) {
            // Menu(primaryAction:): tap → toggle, long-press → menu
            // (charge limit settings). Confines the long-press
            // recognizer to the small button area so it doesn't
            // block horizontal swipes on the rest of the row.
            Menu {
                chargingMenuContent(isCharging: isCharging)
            } label: {
                CircularIconLabel(
                    systemName: icon,
                    tint: isCharging ? .secondary : (isPluggedIn ? chargingColor : .secondary.opacity(0.5)),
                    isBusy: isChargingBusy
                )
            } primaryAction: {
                Task { await toggleCharging(start: !isCharging) }
            }
            .disabled(isChargingBusy || (!isCharging && !isPluggedIn))
        }
    }

    @ViewBuilder
    private var lockSection: some View {
        let isLocked = (bbVehicle.lockStatus == .locked)
        SectionRow(
            icon: Image(systemName: isLocked ? "lock.fill" : "lock.open.fill"),
            iconColor: isLocked ? bbVehicle.lockColor : bbVehicle.unlockColor,
            title: "Doors",
            subtitle: lockStatusText ?? (isLocked ? "Locked" : "Unlocked")
        ) {
            CircularIconButton(
                systemName: isLocked ? "lock.open.fill" : "lock.fill",
                tint: isLocked ? bbVehicle.unlockColor : bbVehicle.lockColor,
                isBusy: isLockBusy
            ) {
                Task { await toggleLock(targetLocked: !isLocked) }
            }
            .disabled(isLockBusy)
        }
    }

    @ViewBuilder
    private var climateSection: some View {
        let isClimateOn = bbVehicle.climateStatus?.airControlOn ?? false
        let climateColor = bbVehicle.startClimateColor
        SectionRow(
            icon: Image(systemName: isClimateOn ? "fan" : "fan.slash"),
            iconColor: isClimateOn ? climateColor : .secondary,
            // Spin the fan icon (left side) while climate is running.
            iconAnimation: isClimateOn ? .rotate : .none,
            title: "Climate",
            subtitle: climateStatusText ?? climateSubtitle
        ) {
            // Tap → toggle, long-press → preset shortcuts +
            // Climate Settings.
            Menu {
                climateMenuContent(isClimateOn: isClimateOn)
            } label: {
                CircularIconLabel(
                    systemName: isClimateOn ? "fan.slash" : "fan",
                    tint: isClimateOn ? .secondary : climateColor,
                    isBusy: isClimateBusy
                )
            } primaryAction: {
                Task { await toggleClimate(start: !isClimateOn) }
            }
            .disabled(isClimateBusy)
        }
    }

    private var climateSubtitle: String {
        let isClimateOn = bbVehicle.climateStatus?.airControlOn ?? false
        if isClimateOn, let status = bbVehicle.climateStatus {
            let temp = status.temperature
            if temp.isPlausibleForDisplay {
                let formatted = temp.units.format(temp.value, to: appSettings.preferredTemperatureUnit)
                return "Running at \(formatted)"
            }
            return "Running"
        }
        return "Off"
    }

    // MARK: - Below-the-fold detail rows

    @ViewBuilder
    private var detailRows: some View {
        VStack(alignment: .leading, spacing: 12) {
            if let lastUpdated = bbVehicle.lastUpdated {
                DetailRow(
                    icon: "arrow.clockwise",
                    label: "Server Timestamp",
                    value: formatLastUpdated(lastUpdated)
                )
            }
            if let syncDate = bbVehicle.syncDate {
                DetailRow(
                    icon: "car",
                    label: "Car Timestamp",
                    value: formatLastUpdated(syncDate)
                )
            }
            DetailRow(
                icon: "speedometer",
                label: "Odometer",
                value: bbVehicle.odometer.units.format(
                    bbVehicle.odometer.length,
                    to: appSettings.preferredDistanceUnit
                )
            )
            if let battery12V = bbVehicle.battery12V {
                DetailRow(
                    icon: "batteryblock",
                    label: "12V Battery",
                    value: "\(battery12V)%",
                    valueColor: battery12V < 30 ? .red : (battery12V < 50 ? .orange : .primary)
                )
            }
            if let doorOpen = bbVehicle.doorOpen {
                let doorStatus = doorStatusText(doorOpen: doorOpen)
                DetailRow(
                    icon: doorOpen.anyOpen ? "exclamationmark.triangle" : "lock",
                    label: "Doors",
                    value: doorStatus.text,
                    valueColor: doorStatus.isOpen ? .orange : .green
                )
            }
            let hood = bbVehicle.hoodOpen ?? false
            let trunk = bbVehicle.trunkOpen ?? false
            DetailRow(
                icon: hood || trunk ? "exclamationmark.triangle" : "car.side",
                label: "Hood / Trunk",
                value: hoodTrunkText(hood: hood, trunk: trunk),
                valueColor: (hood || trunk) ? .orange : .green
            )
            if let tirePressure = bbVehicle.tirePressureWarning {
                DetailRow(
                    icon: tirePressure.hasWarning ? "exclamationmark.tirepressure" : "tirepressure",
                    label: "Tire Pressure",
                    value: tirePressureText(tirePressure),
                    valueColor: tirePressure.hasWarning ? .orange : .green
                )
            }
        }
    }

    // MARK: - Error banner

    @ViewBuilder
    private func errorBanner(_ message: AttributedString) -> some View {
        Button {
            if lastActionError != nil {
                showingErrorDetails = true
            }
        } label: {
            HStack(spacing: 8) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundColor(.red)
                Text(message)
                    .font(.caption)
                    .foregroundColor(.red)
                    .tint(.blue)
                Spacer()
                if lastActionError != nil {
                    Image(systemName: "chevron.right")
                        .font(.caption)
                        .foregroundColor(.red.opacity(0.7))
                }
            }
        }
        .buttonStyle(.plain)
    }

    // MARK: - Vehicle name menu content

    @ViewBuilder
    private var vehicleMenuContent: some View {
        if let location = safeLocation {
            let availableApps = NavigationHelper.availableMapApps
            let coordinate = CLLocationCoordinate2D(
                latitude: location.latitude,
                longitude: location.longitude
            )
            let destinationName = bbVehicle.displayName
            if availableApps.count == 1 {
                Button {
                    NavigationHelper.navigate(
                        using: availableApps[0],
                        to: coordinate,
                        destinationName: destinationName
                    )
                } label: {
                    Label("Navigate to Vehicle", systemImage: "location")
                }
            } else {
                Menu {
                    NavigationMenuContent(
                        coordinate: coordinate,
                        destinationName: destinationName
                    )
                } label: {
                    Label("Navigate to Vehicle", systemImage: "location")
                }
            }
        }

        if bbVehicle.fuelType.hasElectricCapability,
           bbVehicle.account?.supportsEVTripDetails == true {
            Button {
                showingTripDetails = true
            } label: {
                Label("Trip History", systemImage: "chart.line.uptrend.xyaxis")
            }
        }

        Button {
            showingVehicleInfo = true
        } label: {
            Label("Vehicle Info", systemImage: "car.fill")
        }

        Button {
            showingAccountInfo = true
        } label: {
            Label("Account Info", systemImage: "person.circle")
        }

        if AppSettings.shared.debugModeEnabled {
            Button {
                showingHTTPLogs = true
            } label: {
                Label("HTTP Logs", systemImage: "network")
            }
        }

        if bbVehicle.account?.brandEnum == .fake {
            Button {
                showingVehicleConfiguration = true
            } label: {
                Label("Configure Vehicle", systemImage: "gearshape.fill")
            }
        }
    }

    // MARK: - Action menus (long-press on section circular button)

    @ViewBuilder
    private func chargingMenuContent(isCharging: Bool) -> some View {
        Button {
            Task { await toggleCharging(start: !isCharging) }
        } label: {
            Label(
                isCharging ? "Stop Charge" : "Start Charge",
                systemImage: isCharging ? "bolt.slash" : "bolt.fill"
            )
        }
        Button {
            showingChargeLimitSettings = true
        } label: {
            Label("Charge Limits", systemImage: "battery.100percent")
        }
    }

    @ViewBuilder
    private func climateMenuContent(isClimateOn: Bool) -> some View {
        Button {
            Task { await toggleClimate(start: !isClimateOn) }
        } label: {
            Label(
                isClimateOn ? "Stop Climate" : "Start Climate",
                systemImage: isClimateOn ? "fan.slash" : "fan"
            )
        }
        // Preset shortcuts (only the non-selected ones — selected is the
        // default behavior of the main tap).
        ForEach(filteredClimatePresets.filter { !$0.isSelected }, id: \.id) { preset in
            let options = preset.climateOptions
            Button {
                Task { await toggleClimate(start: true, options: options) }
            } label: {
                Label("Start \(preset.name)", systemImage: preset.iconName)
            }
        }
        Button {
            showingClimateSettings = true
        } label: {
            Label("Climate Settings", systemImage: "gearshape.fill")
        }
    }

    private var filteredClimatePresets: [ClimatePreset] {
        allClimatePresets.filter { $0.vehicle?.id == bbVehicle.id }
    }

    private var selectedClimatePreset: ClimatePreset? {
        filteredClimatePresets.first { $0.isSelected }
            ?? filteredClimatePresets.first
    }

    // MARK: - Safe accessors

    private var safeEvStatus: VehicleStatus.EVStatus? {
        guard bbVehicle.modelContext != nil else { return nil }
        return bbVehicle.evStatus
    }

    private var safeGasRange: VehicleStatus.FuelRange? {
        guard bbVehicle.modelContext != nil else { return nil }
        return bbVehicle.gasRange
    }

    private var safeLocation: VehicleStatus.Location? {
        guard bbVehicle.modelContext != nil else { return nil }
        return bbVehicle.location
    }

    // MARK: - Refresh action

    private func refreshStatus(forceCacheBypass: Bool = false) async {
        await MainActor.run {
            isRefreshing = true
            showRefreshSuccess = false
            errorMessage = nil
            lastActionError = nil
        }
        do {
            guard let account = bbVehicle.account else {
                throw APIError(message: "Account not found for vehicle")
            }
            try await account.fetchAndUpdateVehicleStatus(
                for: bbVehicle,
                modelContext: modelContext,
                cached: !forceCacheBypass,
                forceVehicleListRefresh: forceCacheBypass
            )
            await MainActor.run {
                isRefreshing = false
                showRefreshSuccess = true
                WidgetCenter.shared.reloadAllTimelines()
                onSuccessfulRefresh?()
                Task {
                    try? await Task.sleep(nanoseconds: 2_000_000_000)
                    await MainActor.run { showRefreshSuccess = false }
                }
            }
        } catch {
            await MainActor.run {
                isRefreshing = false
                showRefreshSuccess = false
                guard !(error is CancellationError) else { return }
                handleError(error, action: "Refresh \(bbVehicle.displayName)")
            }
        }
    }

    // MARK: - Lock / unlock action

    @MainActor
    private func toggleLock(targetLocked: Bool) async {
        guard let account = bbVehicle.account else { return }
        isLockBusy = true
        lockStatusText = targetLocked ? "Locking" : "Unlocking"
        defer {
            isLockBusy = false
            lockStatusText = nil
        }
        let context = modelContext
        do {
            if targetLocked {
                try await account.lockVehicle(bbVehicle, modelContext: context)
            } else {
                try await account.unlockVehicle(bbVehicle, modelContext: context)
            }
            let target: VehicleStatus.LockStatus = targetLocked ? .locked : .unlocked
            try await bbVehicle.waitForStatusChange(
                modelContext: context,
                condition: { $0.lockStatus == target },
                statusMessageUpdater: { msg in
                    Task { @MainActor in lockStatusText = msg }
                }
            )
        } catch {
            handleError(error, action: targetLocked ? "Lock \(bbVehicle.displayName)" : "Unlock \(bbVehicle.displayName)")
        }
    }

    // MARK: - Charging start / stop action

    @MainActor
    private func toggleCharging(start: Bool) async {
        guard let account = bbVehicle.account else { return }
        isChargingBusy = true
        chargingStatusText = start ? "Starting Charge" : "Stopping Charge"
        defer {
            isChargingBusy = false
            chargingStatusText = nil
        }
        let context = modelContext
        do {
            if start {
                try await account.startCharge(bbVehicle, modelContext: context)
            } else {
                try await account.stopCharge(bbVehicle, modelContext: context)
                // Mirror legacy ChargingButton: poke status immediately
                // so Live Activity ends even if the wait below times out.
                try? await account.fetchAndUpdateVehicleStatus(
                    for: bbVehicle, modelContext: context, cached: false
                )
            }
            try await bbVehicle.waitForStatusChange(
                modelContext: context,
                condition: { $0.evStatus?.charging == start },
                statusMessageUpdater: { msg in
                    Task { @MainActor in chargingStatusText = msg }
                }
            )
        } catch {
            handleError(error, action: start ? "Start Charging \(bbVehicle.displayName)" : "Stop Charging \(bbVehicle.displayName)")
        }
    }

    // MARK: - Climate start / stop action

    @MainActor
    private func toggleClimate(start: Bool, options: ClimateOptions? = nil) async {
        guard let account = bbVehicle.account else { return }
        isClimateBusy = true
        climateStatusText = start ? "Starting Climate" : "Stopping Climate"
        defer {
            isClimateBusy = false
            climateStatusText = nil
        }
        let context = modelContext
        let preset = selectedClimatePreset
        do {
            if start {
                let climateOptions = options ?? preset?.climateOptions ?? ClimateOptions()
                try await account.startClimate(
                    bbVehicle,
                    options: climateOptions,
                    modelContext: context,
                    presetName: preset?.name,
                    presetIcon: preset?.iconName
                )
            } else {
                try await account.stopClimate(bbVehicle, modelContext: context)
                try? await account.fetchAndUpdateVehicleStatus(
                    for: bbVehicle, modelContext: context, cached: false
                )
            }
            try await bbVehicle.waitForStatusChange(
                modelContext: context,
                condition: { $0.climateStatus.airControlOn == start },
                statusMessageUpdater: { msg in
                    Task { @MainActor in climateStatusText = msg }
                }
            )
        } catch {
            handleError(error, action: start ? "Start Climate \(bbVehicle.displayName)" : "Stop Climate \(bbVehicle.displayName)")
        }
    }

    // MARK: - Error wiring

    private func handleError(_ error: Error, action: String) {
        let message: String
        if let apiError = error as? APIError {
            message = apiError.message
        } else {
            message = "\(action) failed: \(error.localizedDescription)"
        }
        if let attributed = try? AttributedString(markdown: message) {
            errorMessage = attributed
        } else {
            errorMessage = AttributedString(message)
        }
        lastActionError = ActionError(
            action: action,
            error: error,
            accountId: bbVehicle.account?.id
        )
    }

    // MARK: - Formatters

    private func formatRange(_ range: VehicleStatus.FuelRange) -> String {
        range.range.units.format(range.range.length, to: appSettings.preferredDistanceUnit)
    }

    private func chargingDetailText(_ ev: VehicleStatus.EVStatus) -> String? {
        var bits: [String] = []
        if ev.chargeSpeed > 0 {
            bits.append(String(format: "%.1f kW", ev.chargeSpeed))
        }
        let duration = ev.chargeTime
        if duration > .seconds(0) {
            let formatted = duration.formatted(.units(allowed: [.hours, .minutes], width: .abbreviated))
            if let target = ev.currentTargetSOC {
                bits.append("\(formatted) to \(Int(target))%")
            } else {
                bits.append(formatted)
            }
        }
        return bits.isEmpty ? nil : bits.joined(separator: " · ")
    }

    private func doorStatusText(doorOpen: VehicleStatus.DoorStatus) -> (text: String, isOpen: Bool) {
        let entries: [(String, Bool)] = [
            ("Front Left", doorOpen.frontLeft),
            ("Front Right", doorOpen.frontRight),
            ("Rear Left", doorOpen.backLeft),
            ("Rear Right", doorOpen.backRight)
        ]
        let openCount = entries.filter { $0.1 }.count
        if openCount == 0 { return ("Closed", false) }
        if openCount == 1, let open = entries.first(where: { $0.1 }) {
            return ("\(open.0) open", true)
        }
        return ("\(openCount) open", true)
    }

    private func hoodTrunkText(hood: Bool, trunk: Bool) -> String {
        switch (hood, trunk) {
        case (true, true): return "Hood & Trunk open"
        case (true, false): return "Hood open"
        case (false, true): return "Trunk open"
        case (false, false): return "Closed"
        }
    }

    private func tirePressureText(_ pressure: VehicleStatus.TirePressureWarning) -> String {
        if !pressure.hasWarning { return "OK" }
        if pressure.all { return "All tires low" }
        let entries: [(String, Bool)] = [
            ("Front Left", pressure.frontLeft),
            ("Front Right", pressure.frontRight),
            ("Rear Left", pressure.rearLeft),
            ("Rear Right", pressure.rearRight)
        ]
        let lowCount = entries.filter { $0.1 }.count
        if lowCount == 1, let low = entries.first(where: { $0.1 }) {
            return "\(low.0) low"
        }
        return "\(lowCount) tires low"
    }
}

// MARK: - Section row helper

/// Single horizontal row used by lock / climate / charging sections.
/// Left: status icon + title above subtitle. Right: caller-supplied
/// trailing content (the circular action button). The status icon can
/// pulse (charging) or rotate (climate fan) via `iconAnimation`.
///
/// Intentionally has NO row-level contextMenu — that registers a
/// long-press recognizer that competes with the parent ScrollView's
/// horizontal pan, blocking swipe-to-page on most of the card. Any
/// long-press menus live on the trailing button itself (via
/// `Menu(primaryAction:)`), keeping the recognizer confined to a
/// small 40pt-square area.
private struct SectionRow<Trailing: View>: View {
    let icon: Image
    let iconColor: Color
    var iconAnimation: AnimatedStatusIcon.Animation = .none
    let title: String
    let subtitle: String
    @ViewBuilder var trailing: () -> Trailing

    var body: some View {
        HStack(alignment: .center, spacing: 12) {
            AnimatedStatusIcon(
                icon: icon,
                color: iconColor,
                animation: iconAnimation
            )
            .frame(width: 32, height: 32)
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.subheadline)
                    .fontWeight(.semibold)
                Text(subtitle)
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
            Spacer()
            trailing()
        }
    }
}

// MARK: - Animated status icon

/// Renders an Image with an optional continuous pulse (scale) or
/// rotate (360° spin) animation. Used by `SectionRow` to communicate
/// "this thing is currently active" — pulse while charging, rotate
/// while the climate fan is running.
struct AnimatedStatusIcon: View {
    enum Animation { case none, pulse, rotate }

    let icon: Image
    let color: Color
    var animation: Animation = .none

    @State private var phase: Double = 0

    var body: some View {
        let base = icon
            .font(.title3)
            .foregroundStyle(color)
        Group {
            switch animation {
            case .none:
                base
            case .pulse:
                base.scaleEffect(1.0 + 0.18 * phase)
            case .rotate:
                base.rotationEffect(.degrees(360 * phase))
            }
        }
        .onAppear { startAnimation() }
        .onChange(of: animation) { _, _ in startAnimation() }
    }

    private func startAnimation() {
        phase = 0
        switch animation {
        case .none:
            return
        case .pulse:
            withAnimation(
                SwiftUI.Animation.easeInOut(duration: 0.9)
                    .repeatForever(autoreverses: true)
            ) {
                phase = 1
            }
        case .rotate:
            withAnimation(
                SwiftUI.Animation.linear(duration: 2.0)
                    .repeatForever(autoreverses: false)
            ) {
                phase = 1
            }
        }
    }
}

// MARK: - Detail row (below-the-fold)

private struct DetailRow: View {
    let icon: String
    let label: String
    let value: String
    var valueColor: Color = .primary

    var body: some View {
        HStack {
            Image(systemName: icon)
                .font(.caption)
                .foregroundColor(.secondary)
                .frame(width: 20)
            Text(label)
                .font(.caption)
                .foregroundColor(.secondary)
            Spacer()
            Text(value)
                .font(.caption)
                .fontWeight(.medium)
                .foregroundColor(valueColor)
        }
    }
}

// MARK: - Circular icon button

/// Just the visual — circle background, optional spinner or icon.
/// Used as the label for both `Button` (refresh / lock) and
/// `Menu(primaryAction:)` (charging / climate, where long-press
/// surfaces extras like presets and charge limits).
struct CircularIconLabel: View {
    let systemName: String
    let tint: Color
    var isBusy: Bool = false
    var diameter: CGFloat = 40

    var body: some View {
        ZStack {
            Circle()
                .fill(tint.opacity(0.18))
            Group {
                if isBusy {
                    ProgressView()
                        .scaleEffect(0.7)
                } else {
                    Image(systemName: systemName)
                        .font(.system(size: diameter * 0.42, weight: .semibold))
                        .foregroundStyle(tint)
                }
            }
        }
        .frame(width: diameter, height: diameter)
    }
}

/// Convenience Button wrapper around `CircularIconLabel` for cases
/// without a long-press menu (refresh, lock).
struct CircularIconButton: View {
    let systemName: String
    let tint: Color
    var isBusy: Bool = false
    var diameter: CGFloat = 40
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            CircularIconLabel(
                systemName: systemName,
                tint: tint,
                isBusy: isBusy,
                diameter: diameter
            )
        }
        .buttonStyle(.plain)
    }
}

// MARK: - Content-height preference key

/// PreferenceKey used by each `PersistentVehicleSheet` to report its
/// natural (unconstrained) MAIN-card content height back up to its
/// parent `VehicleSheetPager`. Drives the main card's `cardHeight`
/// detent calc — independent of the error card overhead.
private struct ContentHeightPreferenceKey: PreferenceKey {
    static let defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = max(value, nextValue())
    }
}

/// PreferenceKey reporting the height contribution of the optional
/// error card above the main card (its outer height + the VStack
/// spacing). The pager adds the max across all cards to its
/// `scrollViewHeight` so the error card fits without being clipped.
/// Reports 0 when no error is present.
///
/// Crucially, this measures ONLY the error card itself — NOT the
/// total page including the main card. The main card's height
/// changes every frame during a drag, so measuring the whole page
/// would cascade `cardHeight` → measurement → `scrollViewHeight` →
/// re-layout per drag tick, producing visible judder. Measuring
/// just the (drag-independent) error overhead breaks that loop.
private struct ErrorOverheadPreferenceKey: PreferenceKey {
    static let defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = max(value, nextValue())
    }
}

// MARK: - Vehicle sheet pager

/// Horizontal paging container for one `PersistentVehicleSheet` per
/// vehicle. Owns the shared detent + drag-translation state so all
/// cards animate to the same height together, and computes the
/// card height from the largest natural content height reported by
/// any card.
///
/// The pager bounds its ScrollView's frame to the current card
/// height and bottom-anchors it inside an outer VStack — so the
/// ScrollView only intercepts touches in the actual card area and
/// touches above pass through to the map underneath.
struct VehicleSheetPager: View {
    let bbVehicles: [BBVehicle]
    @Binding var selectedVehicleIndex: Int
    let onSuccessfulRefresh: (() -> Void)?

    @State private var detent: SheetDetent = .collapsed
    /// Live vertical drag offset from the pager's swipe gesture.
    /// Positive = finger dragged down (shrink), negative = up (grow).
    @State private var dragTranslation: CGFloat = 0
    /// Captures the `translation.height` at the moment the gesture
    /// commits to vertical. Subsequent updates use the delta from
    /// this offset, so `dragTranslation` starts at 0 (no jump from
    /// the gesture's `minimumDistance` deadzone).
    @State private var dragActivationOffset: CGFloat?
    /// Per-VIN natural content height. Pager uses `max` across all
    /// reported values so cards render at a consistent height,
    /// preventing height jumps during paging.
    @State private var naturalHeights: [String: CGFloat] = [:]
    /// Per-VIN error-card overhead (errorCardView outer height + 8pt
    /// VStack spacing). Stable measurement — doesn't change with
    /// `cardHeight` during drags. Pager adds the max across cards
    /// to `scrollViewHeight` so the error card fits above the main
    /// card without clipping.
    @State private var errorOverheads: [String: CGFloat] = [:]

    private let collapsedHeight: CGFloat = 380
    private let expandedTopInset: CGFloat = 80
    private let snapThreshold: CGFloat = 60
    /// Extra space the main card adds on top of `cardHeight` for
    /// its outer chrome — 8pt bottom padding only; no top padding.
    private let chromeOuterInset: CGFloat = 8

    var body: some View {
        GeometryReader { geo in
            let cardHeight = computeCardHeight(geo: geo)
            // ScrollView frame = main card height + chrome + the
            // stable error-card overhead. Stable overhead means
            // the only thing changing during a drag is `cardHeight`
            // itself — no cascading preference updates.
            let scrollViewHeight = cardHeight + chromeOuterInset + maxErrorOverhead
            // VStack with Spacer pushes the bounded ScrollView to the
            // bottom. Spacer takes the empty area above without
            // intercepting touches, so map taps reach the map.
            VStack(spacing: 0) {
                Spacer(minLength: 0)
                pagerScrollView(cardHeight: cardHeight)
                    .frame(height: scrollViewHeight)
                    // Vertical swipe-anywhere — attached as a
                    // `simultaneousGesture` on the pager's ScrollView.
                    // Direction-dominance check in the gesture keeps
                    // it from firing on horizontal pans so the
                    // pager's paging snap stays clean.
                    .simultaneousGesture(verticalCardDragGesture)
                    .animation(.spring(response: 0.35, dampingFraction: 0.85), value: detent)
                    .animation(.spring(response: 0.4, dampingFraction: 0.85), value: maxNaturalHeight)
                    // Explicitly suppress any implicit animation
                    // context for dragTranslation changes — guarantees
                    // the live drag updates are applied immediately
                    // (no spring, no interpolation) regardless of
                    // any inherited animation transaction.
                    .animation(nil, value: dragTranslation)
            }
        }
        // Extend the geometry through the bottom safe area so the
        // card's outer inset (8pt) lands 8pt above the actual screen
        // edge, not 8pt above the home indicator safe area.
        .ignoresSafeArea(edges: .bottom)
    }

    private var maxNaturalHeight: CGFloat {
        naturalHeights.values.max() ?? 0
    }

    private var maxErrorOverhead: CGFloat {
        errorOverheads.values.max() ?? 0
    }

    private func computeCardHeight(geo: GeometryProxy) -> CGFloat {
        let screenMax = geo.size.height - expandedTopInset
        let natural = maxNaturalHeight
        let expanded: CGFloat = natural > 0 ? min(natural, screenMax) : screenMax
        let base = detent == .collapsed ? min(collapsedHeight, expanded) : expanded
        // dragTranslation < 0 grows the card, > 0 shrinks it.
        // Round to integer points so the card frame snaps to pixel
        // boundaries — fractional cardHeight values cause SwiftUI
        // to re-snap mid-drag, producing visible 1pt judder.
        let raw = clamp(base - dragTranslation, min: 80, max: expanded)
        return raw.rounded()
    }

    /// Vertical swipe-anywhere gesture. Attached via
    /// `simultaneousGesture` to the pager's ScrollView so it
    /// recognizes alongside the horizontal pan.
    ///
    /// Lower `minimumDistance` (8pt) for responsiveness; the
    /// vertical-dominance check filters horizontal pans so the
    /// pager's paging snap stays clean. The activation offset
    /// captures `translation.height` at the moment we commit to
    /// vertical and subtracts it from subsequent updates, so the
    /// card's `dragTranslation` starts at 0 — no jump from the
    /// gesture's deadzone.
    private var verticalCardDragGesture: some Gesture {
        // CRITICAL: `coordinateSpace: .global` — translation reads
        // from the fixed window space, not the ScrollView's local
        // space. The ScrollView's frame moves as `cardHeight`
        // grows/shrinks during the drag (because the Spacer above
        // it adjusts), so a `.local` translation creates a
        // feedback loop: each grow moves the ScrollView's origin,
        // which makes the next gesture tick report less movement
        // than the finger actually did, which shrinks the card,
        // which moves the origin back, etc. The result is the
        // visible "few pixels up, then reset, repeat" judder
        // even though the finger is moving smoothly.
        DragGesture(minimumDistance: 8, coordinateSpace: .global)
            .onChanged { value in
                let dy = value.translation.height
                let dx = value.translation.width
                if dragActivationOffset == nil {
                    guard abs(dy) > abs(dx) else { return }
                    dragActivationOffset = dy
                }
                let adjusted = dy - (dragActivationOffset ?? 0)
                // Apply via a non-animating transaction so the live
                // drag update is delivered without inheriting any
                // implicit animation from a parent transaction.
                var t = Transaction()
                t.disablesAnimations = true
                withTransaction(t) {
                    switch (detent, adjusted < 0) {
                    case (.collapsed, true), (.expanded, false):
                        dragTranslation = adjusted
                    default:
                        break
                    }
                }
            }
            .onEnded { value in
                if dragActivationOffset != nil {
                    let predicted = value.predictedEndTranslation.height
                        - (dragActivationOffset ?? 0)
                    switch detent {
                    case .collapsed:
                        if predicted < -snapThreshold { detent = .expanded }
                    case .expanded:
                        if predicted > snapThreshold { detent = .collapsed }
                    }
                }
                dragTranslation = 0
                dragActivationOffset = nil
            }
    }

    @ViewBuilder
    private func pagerScrollView(cardHeight: CGFloat) -> some View {
        // ScrollViewReader (+ `.onScrollPhaseChange` for sync)
        // instead of `.scrollPosition(id:)`. The latter's
        // bidirectional binding was interacting badly with our
        // vertical `.simultaneousGesture`, causing pages to
        // commit between snap targets. Decoupling read (phase
        // change → index) from write (selection change →
        // scrollTo) breaks that loop.
        ScrollViewReader { proxy in
            ScrollView(.horizontal, showsIndicators: false) {
                // Bottom-align cards in the HStack. Default HStack
                // alignment is vertical center, which means when one
                // card has an error overhead and another doesn't, the
                // shorter card's bottom shifts up by half the
                // difference — and during a vertical drag (when
                // `cardHeight` and the HStack's max child height
                // change), that center can micro-shift, producing
                // the 1–2pt up/down judder. Bottom alignment pins
                // each card's bottom to the HStack's bottom, so
                // resize only moves the top edge.
                HStack(alignment: .bottom, spacing: 0) {
                    ForEach(Array(bbVehicles.enumerated()), id: \.element.id) { index, vehicle in
                        PersistentVehicleSheet(
                            bbVehicle: vehicle,
                            bbVehicles: bbVehicles,
                            selectedIndex: selectedVehicleIndex,
                            detent: $detent,
                            cardHeight: cardHeight,
                            onSuccessfulRefresh: onSuccessfulRefresh
                        )
                        .containerRelativeFrame(.horizontal)
                        .onPreferenceChange(ContentHeightPreferenceKey.self) { value in
                            let rounded = (value * 2).rounded() / 2
                            let vin = vehicle.vin
                            if abs((naturalHeights[vin] ?? 0) - rounded) > 0.5 {
                                naturalHeights[vin] = rounded
                            }
                        }
                        .onPreferenceChange(ErrorOverheadPreferenceKey.self) { value in
                            let rounded = (value * 2).rounded() / 2
                            let vin = vehicle.vin
                            if abs((errorOverheads[vin] ?? 0) - rounded) > 0.5 {
                                errorOverheads[vin] = rounded
                            }
                        }
                        .id(index)
                    }
                }
                .scrollTargetLayout()
            }
            .scrollTargetBehavior(.paging)
            .scrollDisabled(bbVehicles.count <= 1)
            .onScrollPhaseChange { _, new, context in
                // Only commit a selection change when the scroll
                // has fully settled — avoids the mid-drag thrash
                // that the `.scrollPosition` binding caused.
                guard new == .idle else { return }
                let width = context.geometry.containerSize.width
                guard width > 0 else { return }
                let index = Int(
                    (context.geometry.contentOffset.x / width).rounded()
                )
                let clamped = max(0, min(bbVehicles.count - 1, index))
                if clamped != selectedVehicleIndex {
                    selectedVehicleIndex = clamped
                }
            }
            .onChange(of: selectedVehicleIndex) { _, new in
                withAnimation {
                    proxy.scrollTo(new, anchor: .leading)
                }
            }
            .onAppear {
                proxy.scrollTo(selectedVehicleIndex, anchor: .leading)
            }
        }
    }
}

// MARK: - Misc

private func clamp<T: Comparable>(_ value: T, min lower: T, max upper: T) -> T {
    Swift.max(lower, Swift.min(upper, value))
}
