//
//  DiagnosticInfo.swift
//  BetterBlue
//
//  Created by Claude on 9/17/25.
//

import BetterBlueKit
import CloudKit
import SwiftData
import SwiftUI

struct DiagnosticInfo {
    let timestamp: Date
    let deviceType: String
    let containerURL: String?
    let accountCount: Int
    let vehicleCount: Int
    let hiddenVehicleCount: Int
    let accounts: [AccountDiagnostic]
    let vehicles: [VehicleDiagnostic]
    let cloudKitStatus: CloudKitDiagnostic?

    struct AccountDiagnostic {
        let id: UUID
        let username: String
        let brand: String
        let vehicleCount: Int
    }

    struct VehicleDiagnostic {
        let id: UUID
        let vin: String
        let displayName: String
        let accountId: UUID
        let isHidden: Bool
        let sortOrder: Int
        let lastUpdated: Date?
        let hasEvStatus: Bool
        let hasGasRange: Bool
        let hasLockStatus: Bool
        let hasClimateStatus: Bool
        let hasLocation: Bool
    }

    struct CloudKitDiagnostic {
        let accountStatus: String
        let isSignedIn: Bool
        let isAvailable: Bool
        let containerIdentifier: String?
        let databaseScope: String
        let lastSyncAttempt: Date?
        let syncError: String?
        /// `aps-environment` value embedded in the running binary's
        /// signed entitlements. `"production"` on App Store / TestFlight
        /// builds, `"development"` on local Xcode debug builds, `nil`
        /// when we can't read it (simulator, App Store re-sign that
        /// strips the embedded profile in edge cases).
        let apsEnvironment: String?
    }

    /// Snapshot of the sync monitor at `collect()` time. Captured
    /// here (instead of read live in `formattedOutput`) so the share
    /// export doesn't need main-actor isolation.
    struct SyncMonitorSnapshot {
        let lastSetup: CloudKitSyncMonitor.Event?
        let lastImport: CloudKitSyncMonitor.Event?
        let lastExport: CloudKitSyncMonitor.Event?
        let events: [CloudKitSyncMonitor.Event]
        let lastConnectivityCheck: CloudKitSyncMonitor.ConnectivityCheckResult?
    }
    let syncMonitor: SyncMonitorSnapshot

    @MainActor
    static func collect(from context: ModelContext) async -> DiagnosticInfo {
        let allAccounts = (try? context.fetch(FetchDescriptor<BBAccount>())) ?? []
        let allVehicles = (try? context.fetch(FetchDescriptor<BBVehicle>())) ?? []

        let accountDiagnostics = allAccounts.map { account in
            AccountDiagnostic(
                id: account.id,
                username: account.username,
                brand: account.brandEnum.displayName,
                vehicleCount: account.vehicles?.count ?? 0
            )
        }

        let vehicleDiagnostics = allVehicles.map { vehicle in
            VehicleDiagnostic(
                id: vehicle.id,
                vin: vehicle.vin,
                displayName: vehicle.displayName,
                accountId: vehicle.accountId,
                isHidden: vehicle.isHidden,
                sortOrder: vehicle.sortOrder,
                lastUpdated: vehicle.lastUpdated,
                hasEvStatus: vehicle.evStatus != nil,
                hasGasRange: vehicle.gasRange != nil,
                hasLockStatus: vehicle.lockStatus != nil,
                hasClimateStatus: vehicle.climateStatus != nil,
                hasLocation: vehicle.location != nil
            )
        }

        let containerURL: String?
        containerURL = context.container.configurations.first?.url.path

        let cloudKitStatus: CloudKitDiagnostic? = await collectCloudKitStatus(from: context)

        let monitor = CloudKitSyncMonitor.shared
        let snapshot = SyncMonitorSnapshot(
            lastSetup: monitor.lastSetup,
            lastImport: monitor.lastImport,
            lastExport: monitor.lastExport,
            events: monitor.events,
            lastConnectivityCheck: monitor.lastConnectivityCheck
        )

        return DiagnosticInfo(
            timestamp: Date(),
            deviceType: getDeviceType(),
            containerURL: containerURL,
            accountCount: allAccounts.count,
            vehicleCount: allVehicles.filter { !$0.isHidden }.count,
            hiddenVehicleCount: allVehicles.filter { $0.isHidden }.count,
            accounts: accountDiagnostics,
            vehicles: vehicleDiagnostics,
            cloudKitStatus: cloudKitStatus,
            syncMonitor: snapshot
        )
    }

    private static func getDeviceType() -> String {
        #if os(watchOS)
            return "Apple Watch"
        #elseif os(iOS)
            return "iPhone/iPad"
        #else
            return "Unknown"
        #endif
    }

    @MainActor
    private static func collectCloudKitStatus(from _: ModelContext) async -> CloudKitDiagnostic? {
        // Use the BetterBlue CloudKit container identifier
        let containerID = "iCloud.com.markschmidt.BetterBlue"
        let container = CKContainer(identifier: containerID)

        do {
            let accountStatus = try await container.accountStatus()
            let accountStatusString: String
            let isSignedIn: Bool

            switch accountStatus {
            case .available:
                accountStatusString = "Available"
                isSignedIn = true
            case .noAccount:
                accountStatusString = "No Account"
                isSignedIn = false
            case .restricted:
                accountStatusString = "Restricted"
                isSignedIn = false
            case .temporarilyUnavailable:
                accountStatusString = "Temporarily Unavailable"
                isSignedIn = false
            case .couldNotDetermine:
                accountStatusString = "Could Not Determine"
                isSignedIn = false
            @unknown default:
                accountStatusString = "Unknown"
                isSignedIn = false
            }

            return CloudKitDiagnostic(
                accountStatus: accountStatusString,
                isSignedIn: isSignedIn,
                isAvailable: accountStatus == .available,
                containerIdentifier: containerID,
                databaseScope: "Private", // SwiftData uses private database
                lastSyncAttempt: nil, // SwiftData doesn't expose this directly
                syncError: nil, // SwiftData doesn't expose this directly
                apsEnvironment: readApsEnvironment()
            )
        } catch {
            return CloudKitDiagnostic(
                accountStatus: "Error: \(error.localizedDescription)",
                isSignedIn: false,
                isAvailable: false,
                containerIdentifier: containerID,
                databaseScope: "Private",
                lastSyncAttempt: nil,
                syncError: error.localizedDescription,
                apsEnvironment: readApsEnvironment()
            )
        }
    }

    /// Read `aps-environment` from the embedded provisioning profile.
    ///
    /// The bundle ships an `embedded.mobileprovision` file (Apple
    /// strips it during App Store re-sign on macOS but keeps it on
    /// iOS / watchOS releases). The file is a CMS-wrapped XML plist;
    /// the plist body sits inside as plaintext between the `<?xml`
    /// and `</plist>` markers, so we can extract it without needing
    /// to fully decode the CMS envelope. The `Entitlements` dict
    /// inside is what's actually applied to the running process.
    ///
    /// Returns `nil` on the simulator (no embedded.mobileprovision)
    /// and on any parse failure.
    private static func readApsEnvironment() -> String? {
        guard let url = Bundle.main.url(forResource: "embedded", withExtension: "mobileprovision"),
              let data = try? Data(contentsOf: url),
              let start = data.range(of: Data("<?xml".utf8)),
              let end = data.range(of: Data("</plist>".utf8)) else {
            return nil
        }
        let plistData = data.subdata(in: start.lowerBound..<end.upperBound)
        guard let plist = try? PropertyListSerialization.propertyList(from: plistData, format: nil)
                as? [String: Any],
              let entitlements = plist["Entitlements"] as? [String: Any],
              let aps = entitlements["aps-environment"] as? String else {
            return nil
        }
        return aps
    }

    var formattedOutput: String {
        var output = """
        Diagnostic Information
        Generated: \(timestamp.formatted())
        Device: \(deviceType)

        Summary:
        • Accounts: \(accountCount)
        • Visible Vehicles: \(vehicleCount)
        • Hidden Vehicles: \(hiddenVehicleCount)
        • Container: \(containerURL ?? "Unknown")

        """

        if let cloudKit = cloudKitStatus {
            output += "\niCloud Status:\n"
            output += "• Account Status: \(cloudKit.accountStatus)\n"
            output += "• Signed In: \(cloudKit.isSignedIn ? "✅" : "❌")\n"
            if let containerID = cloudKit.containerIdentifier {
                output += "• Container: \(containerID)\n"
            }
            output += "• Database: \(cloudKit.databaseScope)\n"
            output += "• APS Environment: \(cloudKit.apsEnvironment ?? "Unknown")\n"
            if let syncError = cloudKit.syncError {
                output += "• Sync Error: \(syncError)\n"
            }
            output += "\n"
        } else {
            output += "\niCloud Status: Not configured for CloudKit sync\n\n"
        }

        // Sync activity captured into `syncMonitor` at collect() time
        // — most useful single thing for triaging "sync broken" reports.
        output += "\nSync Activity:\n"
        for (label, event) in [
            ("Last Setup", syncMonitor.lastSetup),
            ("Last Import", syncMonitor.lastImport),
            ("Last Export", syncMonitor.lastExport)
        ] {
            if let event {
                let status = event.succeeded ? "✅" : "❌"
                output += "• \(label): \(status) at \(event.date.formatted())"
                if let error = event.error {
                    output += " — \(error)"
                }
                output += "\n"
            } else {
                output += "• \(label): Never\n"
            }
        }
        if !syncMonitor.events.isEmpty {
            output += "\nRecent Sync Events (newest first, max 50):\n"
            for event in syncMonitor.events {
                let status = event.succeeded ? "✅" : "❌"
                output += "• \(event.date.formatted()) \(status) \(event.type.rawValue)"
                if let error = event.error {
                    output += " — \(error)"
                }
                output += "\n"
            }
        }
        if let check = syncMonitor.lastConnectivityCheck {
            output += "\nLast Connectivity Check (\(check.date.formatted())):\n"
            output += "• Account: \(check.accountStatus)\n"
            output += "• Container Reachable: \(check.containerHostReachable ? "✅" : "❌")\n"
            if let userRecordName = check.userRecordName {
                output += "• User Record: \(userRecordName)\n"
            }
            if let error = check.error {
                output += "• Error: \(error)\n"
            }
        }
        output += "\n"

        if !accounts.isEmpty {
            output += "\nAccounts:\n"
            for account in accounts {
                output += "• \(account.username) (\(account.brand))\n"
                output += "  ID: \(account.id.uuidString.prefix(8))...\n"
                output += "  Vehicles: \(account.vehicleCount)\n"
                output += "\n"
            }
        }

        if !vehicles.isEmpty {
            output += "\nVehicles:\n"
            for vehicle in vehicles {
                output += "• \(vehicle.displayName) (\(vehicle.vin))\n"
                output += "  ID: \(vehicle.id.uuidString.prefix(8))...\n"
                output += "  Account: \(vehicle.accountId.uuidString.prefix(8))...\n"
                output += "  Hidden: \(vehicle.isHidden ? "Yes" : "No")\n"
                output += "  Sort Order: \(vehicle.sortOrder)\n"
                if let lastUpdated = vehicle.lastUpdated {
                    output += "  Last Updated: \(lastUpdated.formatted())\n"
                } else {
                    output += "  Last Updated: Never\n"
                }
                output += "  Status Data:\n"
                output += "    EV: \(vehicle.hasEvStatus ? "✅" : "❌")\n"
                output += "    Gas: \(vehicle.hasGasRange ? "✅" : "❌")\n"
                output += "    Lock: \(vehicle.hasLockStatus ? "✅" : "❌")\n"
                output += "    Climate: \(vehicle.hasClimateStatus ? "✅" : "❌")\n"
                output += "    Location: \(vehicle.hasLocation ? "✅" : "❌")\n"
                output += "\n"
            }
        }

        return output
    }
}

struct DiagnosticInfoView: View {
    @Environment(\.modelContext) private var modelContext
    @State private var diagnosticInfo: DiagnosticInfo?
    @State private var isLoading = true
    @State private var isRunningCheck = false
    /// Process-lifetime singleton — read directly so the view picks
    /// up live event updates as SwiftData runs imports / exports.
    @State private var syncMonitor = CloudKitSyncMonitor.shared
    private let containerIdentifier = "iCloud.com.markschmidt.BetterBlue"

    var body: some View {
        Group {
            if isLoading {
                VStack {
                    ProgressView("Collecting diagnostics...")
                        .padding()
                }
            } else if let diagnosticInfo = diagnosticInfo {
                List {
                    summarySection(diagnosticInfo)

                    if let cloudKit = diagnosticInfo.cloudKitStatus {
                        cloudKitSection(cloudKit)
                    }

                    syncActivitySection
                    connectivityCheckSection

                    if !diagnosticInfo.accounts.isEmpty {
                        accountsSection(diagnosticInfo.accounts)
                    }

                    if !diagnosticInfo.vehicles.isEmpty {
                        ForEach(diagnosticInfo.vehicles.indices, id: \.self) { index in
                            vehicleSection(diagnosticInfo.vehicles[index])
                        }
                    }
                }
                #if os(watchOS)
                .listStyle(.automatic)
                #else
                .listStyle(.insetGrouped)
                #endif
            } else {
                VStack {
                    Text("Failed to collect diagnostic information")
                        .foregroundColor(.red)
                        .padding()
                }
            }
        }
        .navigationTitle("Sync Diagnostics")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            if let diagnosticInfo = diagnosticInfo {
                #if !os(watchOS)
                    ToolbarItem(placement: .navigationBarTrailing) {
                        ShareLink(
                            item: diagnosticInfo.formattedOutput,
                            subject: Text("BetterBlue Sync Diagnostics"),
                            message: Text("Diagnostic information from BetterBlue app")
                        ) {
                            Image(systemName: "square.and.arrow.up")
                        }
                    }
                #endif
            }
        }
        .task {
            await loadDiagnostics()
        }
    }

    @ViewBuilder
    private func summarySection(_ info: DiagnosticInfo) -> some View {
        Section {
            diagnosticRow("Generated", info.timestamp.formatted())
            diagnosticRow("Device", info.deviceType)
            diagnosticRow("Accounts", "\(info.accountCount)")
            diagnosticRow("Visible Vehicles", "\(info.vehicleCount)")
            diagnosticRow("Hidden Vehicles", "\(info.hiddenVehicleCount)")
            diagnosticRow("Container", info.containerURL ?? "Unknown")
        } header: {
            Text("Summary")
        }
    }

    /// Live CloudKit sync activity — last setup / import / export
    /// event, plus a rolling event log. Sourced from the singleton
    /// monitor that's been listening since app launch.
    @ViewBuilder
    private var syncActivitySection: some View {
        Section {
            syncEventRow("Last Setup", event: syncMonitor.lastSetup)
            syncEventRow("Last Import", event: syncMonitor.lastImport)
            syncEventRow("Last Export", event: syncMonitor.lastExport)
            if !syncMonitor.events.isEmpty {
                // Rolling log — newest first, capped to the most
                // recent 10 in the UI. The full log (up to 50) ships
                // in the diagnostic share. DisclosureGroup isn't
                // available on watchOS, so the watch always shows
                // the inline list under a small header row.
                #if os(watchOS)
                Text("Recent Events (\(syncMonitor.events.count))")
                    .font(.caption)
                    .foregroundColor(.secondary)
                ForEach(syncMonitor.events.prefix(10)) { event in
                    recentEventRow(event)
                }
                #else
                DisclosureGroup("Recent Events (\(syncMonitor.events.count))") {
                    ForEach(syncMonitor.events.prefix(10)) { event in
                        recentEventRow(event)
                    }
                }
                #endif
            }
        } header: {
            Text("Sync Activity")
        } footer: {
            if syncMonitor.lastSetup == nil
                && syncMonitor.lastImport == nil
                && syncMonitor.lastExport == nil {
                let message = """
                    No CloudKit sync events observed since app launch. \
                    Either the app just launched (give it a few seconds) \
                    or CloudKit isn't reaching this device — try the \
                    Connectivity Check below.
                    """
                Text(message)
                    .font(.caption2)
            }
        }
    }

    /// "Run Connectivity Check" — verifies the iCloud account is
    /// signed in AND that the app can reach the CloudKit container.
    /// If this passes but sync still isn't happening, the problem
    /// is APNs (push environment mismatch), not network or account.
    @ViewBuilder
    private var connectivityCheckSection: some View {
        Section {
            Button {
                Task { await runConnectivityCheck() }
            } label: {
                HStack {
                    if isRunningCheck {
                        ProgressView()
                            #if !os(watchOS)
                            .controlSize(.small)
                            #endif
                        Text("Checking…")
                    } else {
                        Image(systemName: "antenna.radiowaves.left.and.right")
                        Text("Run Connectivity Check")
                    }
                }
            }
            .disabled(isRunningCheck)

            if let result = syncMonitor.lastConnectivityCheck {
                diagnosticRow("Checked", result.date.formatted(date: .omitted, time: .standard))
                diagnosticRow("Account", result.accountStatus)
                diagnosticRow("Container Reachable", result.containerHostReachable ? "✅ Yes" : "❌ No")
                if let userRecordName = result.userRecordName {
                    diagnosticRow("User Record", String(userRecordName.prefix(16)) + "…")
                }
                if let error = result.error {
                    Text(error)
                        .font(.caption)
                        .foregroundColor(.red)
                }
            }
        } header: {
            Text("Connectivity")
        } footer: {
            let message = """
                Checks whether the device can reach iCloud. 
                """
            Text(message)
                .font(.caption2)
        }
    }

    @ViewBuilder
    private func recentEventRow(_ event: CloudKitSyncMonitor.Event) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack {
                Text("\(event.succeeded ? "✅" : "❌") \(event.type.rawValue)")
                    .font(.caption)
                    .fontWeight(.semibold)
                Spacer()
                Text(event.date, style: .time)
                    .font(.caption2)
                    .foregroundColor(.secondary)
            }
            if let error = event.error {
                Text(error)
                    .font(.caption2)
                    .foregroundColor(.red)
            }
        }
        .padding(.vertical, 2)
    }

    @ViewBuilder
    private func syncEventRow(_ label: String, event: CloudKitSyncMonitor.Event?) -> some View {
        if let event {
            VStack(alignment: .leading, spacing: 2) {
                HStack {
                    Text(label)
                        .foregroundColor(.secondary)
                    Spacer()
                    Text("\(event.succeeded ? "✅" : "❌") \(event.date, style: .relative) ago")
                        .font(.caption)
                }
                if let error = event.error {
                    Text(error)
                        .font(.caption2)
                        .foregroundColor(.red)
                }
            }
        } else {
            diagnosticRow(label, "Never")
        }
    }

    private func runConnectivityCheck() async {
        isRunningCheck = true
        await syncMonitor.runConnectivityCheck(containerIdentifier: containerIdentifier)
        isRunningCheck = false
    }

    @ViewBuilder
    private func cloudKitSection(_ cloudKit: DiagnosticInfo.CloudKitDiagnostic) -> some View {
        Section {
            diagnosticRow("Account Status", cloudKit.accountStatus)
            diagnosticRow("Signed In", cloudKit.isSignedIn ? "✅ Yes" : "❌ No")
            diagnosticRow("Available", cloudKit.isAvailable ? "✅ Yes" : "❌ No")
            if let containerID = cloudKit.containerIdentifier {
                diagnosticRow("Container", containerID)
            }
            diagnosticRow("Database", cloudKit.databaseScope)
            // Embedded-profile `aps-environment`. Production = correct
            // for TestFlight + App Store; development = correct for
            // local Xcode debug builds. A mismatch here means CloudKit
            // silent pushes won't reach this device.
            diagnosticRow("APS Environment", cloudKit.apsEnvironment ?? "Unknown")
            if let syncError = cloudKit.syncError {
                diagnosticRow("Sync Error", syncError)
            }
        } header: {
            Text("iCloud Status")
        }
    }

    @ViewBuilder
    private func accountsSection(_ accounts: [DiagnosticInfo.AccountDiagnostic]) -> some View {
        Section {
            ForEach(accounts.indices, id: \.self) { index in
                let account = accounts[index]
                VStack(alignment: .leading, spacing: 4) {
                    Text("\(account.username) (\(account.brand))")
                        .font(.headline)
                    Text("ID: \(account.id.uuidString.prefix(8))...")
                        .font(.caption)
                        .foregroundColor(.secondary)
                    Text("Vehicles: \(account.vehicleCount)")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
                .padding(.vertical, 2)
            }
        } header: {
            Text("Accounts")
        }
    }

    @ViewBuilder
    private func vehicleSection(_ vehicle: DiagnosticInfo.VehicleDiagnostic) -> some View {
        Section {
            diagnosticRow("VIN", vehicle.vin)
            diagnosticRow("ID", "\(vehicle.id.uuidString.prefix(8))...")
            diagnosticRow("Account", "\(vehicle.accountId.uuidString.prefix(8))...")
            diagnosticRow("Hidden", vehicle.isHidden ? "Yes" : "No")
            diagnosticRow("Sort Order", "\(vehicle.sortOrder)")

            if let lastUpdated = vehicle.lastUpdated {
                diagnosticRow("Last Updated", lastUpdated.formatted())
            } else {
                diagnosticRow("Last Updated", "Never")
            }

            diagnosticRow("EV Status", vehicle.hasEvStatus ? "✅ Available" : "❌ Not Available")
            diagnosticRow("Gas Range", vehicle.hasGasRange ? "✅ Available" : "❌ Not Available")
            diagnosticRow("Lock Status", vehicle.hasLockStatus ? "✅ Available" : "❌ Not Available")
            diagnosticRow("Climate Status", vehicle.hasClimateStatus ? "✅ Available" : "❌ Not Available")
            diagnosticRow("Location", vehicle.hasLocation ? "✅ Available" : "❌ Not Available")
        } header: {
            Text(vehicle.displayName)
        }
    }

    @ViewBuilder
    private func diagnosticRow(_ label: String, _ value: String) -> some View {
        HStack {
            Text(label)
                .foregroundColor(.secondary)
            Spacer()
            Text(value)
            #if !os(watchOS)
                .textSelection(.enabled)
            #endif
        }
    }

    private func loadDiagnostics() async {
        isLoading = true
        diagnosticInfo = await DiagnosticInfo.collect(from: modelContext)
        isLoading = false
    }
}
