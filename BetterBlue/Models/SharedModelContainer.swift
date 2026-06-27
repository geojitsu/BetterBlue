//
//  SharedModelContainer.swift
//  BetterBlue
//
//  Created by Mark Schmidt on 9/4/25.
//

import BetterBlueKit
import Foundation
import SwiftData

func getSimulatorStoreURL() -> URL {
    // In simulator, use a fixed shared location to work around App Group container isolation
    let sharedSimulatorPath = "/tmp/BetterBlue_Shared"
    try? FileManager.default.createDirectory(
        atPath: sharedSimulatorPath,
        withIntermediateDirectories: true,
        attributes: nil,
    )
    return URL(fileURLWithPath: sharedSimulatorPath).appendingPathComponent("BetterBlue.sqlite")
}

func getAppGroupStoreURL() throws -> URL {
    let appGroupID = "group.com.betterblue.shared"
    if let appGroupURL = FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: appGroupID) {
        return appGroupURL.appendingPathComponent("BetterBlue.sqlite")
    } else {
        BBLogger.warning(.app, "BetterBlue: App Group container not accessible from current context")
        throw NSError(
            domain: "BetterBlue",
            code: 1001,
            userInfo: [
                NSLocalizedDescriptionKey:
                    "Vehicle data not accessible. Please open the BetterBlue app first to sync your vehicles.",
                NSLocalizedRecoverySuggestionErrorKey:
                    "Open the BetterBlue app and try again."
            ],
        )
    }
}

func createContainer(storeURL: URL, schema: Schema, cloudKitDatabase: ModelConfiguration.CloudKitDatabase = .automatic) throws -> ModelContainer {
    do {
        let modelConfiguration = ModelConfiguration(url: storeURL, cloudKitDatabase: cloudKitDatabase)
        return try ModelContainer(for: schema, configurations: [modelConfiguration])
    } catch {
        BBLogger.error(.app, "BetterBlue: Failed to create ModelContainer: \(error)")
        throw NSError(
            domain: "BetterBlue",
            code: 1002,
            userInfo: [
                NSLocalizedDescriptionKey:
                    "Failed to create data storage",
                NSLocalizedRecoverySuggestionErrorKey:
                    "Try restarting the app. If the problem persists, contact support."
            ],
        )
    }
}

/// Removes orphaned climate presets that have no vehicle relationship.
/// These are leftover from before the relationship was properly set during creation.
@MainActor
func cleanupOrphanedClimatePresets(container: ModelContainer) {
    let context = container.mainContext

    do {
        let presetDescriptor = FetchDescriptor<ClimatePreset>()
        let allPresets = try context.fetch(presetDescriptor)

        var deletedCount = 0
        for preset in allPresets where preset.vehicle == nil {
            context.delete(preset)
            deletedCount += 1
        }

        if deletedCount > 0 {
            try context.save()
            BBLogger.info(.app, "Cleaned up \(deletedCount) orphaned climate preset(s)")
        }
    } catch {
        BBLogger.error(.app, "Failed to cleanup orphaned climate presets: \(error)")
    }
}

/// Removes "zombie" vehicles whose parent `BBAccount` no longer exists.
/// Normally `BBAccount` → `BBVehicle` is cascade-delete, but interrupted
/// CloudKit syncs and earlier schema iterations can leave orphan vehicle
/// rows that Siri/App Intents/widget pickers would otherwise still list.
/// Their cascaded `climatePresets` are dropped by SwiftData automatically
/// once the vehicle goes away.
@MainActor
func cleanupOrphanedVehicles(container: ModelContainer) {
    let context = container.mainContext

    do {
        let vehicleDescriptor = FetchDescriptor<BBVehicle>()
        let allVehicles = try context.fetch(vehicleDescriptor)

        var deletedCount = 0
        for vehicle in allVehicles where vehicle.account == nil {
            BBLogger.info(.app, "Purging orphaned vehicle \(vehicle.vin) (\(vehicle.displayName))")
            context.delete(vehicle)
            deletedCount += 1
        }

        if deletedCount > 0 {
            try context.save()
            BBLogger.info(.app, "Cleaned up \(deletedCount) orphaned vehicle(s)")
        }
    } catch {
        BBLogger.error(.app, "Failed to cleanup orphaned vehicles: \(error)")
    }
}

/// Migrates credential fields (`password`, `pin`, `serializedAuthToken`) from every
/// `BBAccount` in SwiftData to the iOS Keychain. Guarded by a UserDefaults flag so
/// it runs exactly once per device across the lifetime of the install.
///
/// Called synchronously during app startup, before `MainView` loads, so that the
/// Keychain-backed computed properties on `BBAccount` are ready before any API call.
///
/// - Note: CloudKit multi-device caveat — once the SwiftData backing fields are
///   cleared on the primary device and synced via CloudKit, secondary devices will
///   receive empty fields and cannot self-migrate. Users with multiple devices will
///   need to re-enter credentials on secondary devices after the first run on their
///   primary device. This is an acceptable trade-off for a personal-use app.
@MainActor
func migrateAccountCredentials(container: ModelContainer) {
    let migrationKey = "keychain_migration_v1_complete"
    guard !UserDefaults.standard.bool(forKey: migrationKey) else { return }

    let context = container.mainContext
    let accounts = (try? context.fetch(FetchDescriptor<BBAccount>())) ?? []

    let migratedCount = accounts.filter { $0.migrateCredentialsToKeychain() }.count

    if migratedCount > 0 {
        do {
            try context.save()
        } catch {
            BBLogger.error(.auth, "Keychain migration: failed to save context after migration: \(error)")
        }
    }

    UserDefaults.standard.set(true, forKey: migrationKey)
    BBLogger.info(.auth, "Keychain migration complete: \(migratedCount) account(s) migrated, \(accounts.count - migratedCount) already clean")
}

/// Creates a shared ModelContainer for use across main app, widget, and watch app.
/// - Parameter enableCloudKit: Whether to enable CloudKit sync. Set to `false` for
///   App Intents and widgets running in the background to avoid `0xdead10cc` crashes
///   caused by holding SQLite file locks during process suspension.
func createSharedModelContainer(enableCloudKit: Bool = true) throws -> ModelContainer {
    let schema = Schema([
        BBAccount.self,
        BBVehicle.self,
        BBHTTPLog.self,
        ClimatePreset.self
    ], version: .init(1, 0, 10))

    let cloudKitDatabase: ModelConfiguration.CloudKitDatabase = enableCloudKit ? .automatic : .none

    #if targetEnvironment(simulator)
        let storeURL = getSimulatorStoreURL()
        return try createContainer(storeURL: storeURL, schema: schema, cloudKitDatabase: cloudKitDatabase)
    #else
        let cloudConfig = ModelConfiguration(
            "iCloud.com.markschmidt.BetterBlue",
            cloudKitDatabase: cloudKitDatabase
        )

        if let container = try? ModelContainer(
            for: schema,
            configurations: [cloudConfig]
        ) {
            return container
        }
        let storeURL = try getAppGroupStoreURL()
        return try createContainer(storeURL: storeURL, schema: schema, cloudKitDatabase: cloudKitDatabase)
    #endif
}
