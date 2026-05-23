//
//  CloudKitSyncMonitor.swift
//  BetterBlue
//
//  Observes NSPersistentCloudKitContainer.eventChangedNotification —
//  the only public signal SwiftData surfaces about its CloudKit sync
//  pipeline — and aggregates it into a single observable state object.
//
//  Use this to:
//    - Show "last import / export / setup succeeded at N minutes ago"
//      in the Diagnostics view.
//    - Surface specific CloudKit error messages (push registration
//      failed, account not signed in, schema mismatch, etc.) instead
//      of leaving the user staring at silently-broken sync.
//    - Run a "connectivity check" that proves the app can talk to
//      CloudKit at all (separate from whether SwiftData has actually
//      sync'd recently).
//
//  Install the singleton at app launch (`_ = CloudKitSyncMonitor.shared`
//  somewhere in BetterBlueApp / Watch app init) so we don't miss the
//  setup events that fire before the Diagnostics view is opened.
//

import CloudKit
import CoreData
import Foundation
import SwiftData

@MainActor
@Observable
final class CloudKitSyncMonitor {
    static let shared = CloudKitSyncMonitor()

    /// One discrete CloudKit-sync event surfaced by SwiftData. We keep
    /// a rolling history so the Diagnostics view can show "what's been
    /// happening" instead of just "what's the latest."
    struct Event: Identifiable, Sendable {
        let id = UUID()
        let date: Date
        let type: EventType
        let succeeded: Bool
        /// Localized error string when `succeeded` is false. Kept as a
        /// String so the struct stays `Sendable` and so we can ship it
        /// in the diagnostic export without dragging NSError along.
        let error: String?

        enum EventType: String, Sendable {
            case setup = "Setup"
            case `import` = "Import"
            case export = "Export"
            case unknown = "Unknown"
        }
    }

    /// Most recent event for each `EventType`. `nil` means we haven't
    /// seen that type yet (either it hasn't happened, or the app
    /// launched after it fired and we missed it).
    private(set) var lastSetup: Event?
    private(set) var lastImport: Event?
    private(set) var lastExport: Event?

    /// Rolling log of the last ~50 events, newest first. Surfaced in
    /// the diagnostic share so we can post-mortem broken syncs.
    private(set) var events: [Event] = []

    /// Filled in by `runConnectivityCheck`. Lets the Diagnostics view
    /// show a result panel without needing to round-trip through
    /// another @State property.
    private(set) var lastConnectivityCheck: ConnectivityCheckResult?

    struct ConnectivityCheckResult: Sendable {
        let date: Date
        let accountStatus: String
        let userRecordName: String?
        let containerHostReachable: Bool
        let error: String?

        var summary: String {
            if let error { return "Failed: \(error)" }
            return "OK — account \(accountStatus), userRecordName=\(userRecordName ?? "?")"
        }
    }

    private var observer: NSObjectProtocol?

    private init() {
        // `NSPersistentCloudKitContainer.eventChangedNotification` is
        // broadcast to the default notification center whenever ANY
        // CloudKit-backed Core Data / SwiftData store in the process
        // starts or finishes a setup / import / export. We can listen
        // without needing direct access to the underlying container.
        observer = NotificationCenter.default.addObserver(
            forName: NSPersistentCloudKitContainer.eventChangedNotification,
            object: nil,
            queue: .main
        ) { [weak self] note in
            // `queue: .main` runs the closure on the main thread.
            // Project the CloudKit event into a Sendable `Event`
            // INSIDE the closure (where the non-Sendable
            // `NSPersistentCloudKitContainer.Event` stays put), then
            // hand only the Sendable copy across the actor boundary.
            let key = NSPersistentCloudKitContainer.eventNotificationUserInfoKey
            guard let ckEvent = note.userInfo?[key]
                    as? NSPersistentCloudKitContainer.Event,
                  ckEvent.endDate != nil else { return }
            let projected = Event(
                date: ckEvent.endDate ?? Date(),
                type: Self.classify(ckEvent.type),
                succeeded: ckEvent.succeeded,
                error: ckEvent.error?.localizedDescription
            )
            MainActor.assumeIsolated {
                self?.handle(projected)
            }
        }
    }

    // No deinit — `CloudKitSyncMonitor` is a process-lifetime
    // singleton, so we never need to detach the observer. (And the
    // observer property is main-actor isolated, which would make a
    // nonisolated deinit awkward to write.)

    // MARK: - Event handling

    private func handle(_ event: Event) {
        events.insert(event, at: 0)
        if events.count > 50 {
            events.removeLast(events.count - 50)
        }

        switch event.type {
        case .setup:  lastSetup = event
        case .import: lastImport = event
        case .export: lastExport = event
        case .unknown: break
        }
    }

    nonisolated private static func classify(
        _ type: NSPersistentCloudKitContainer.EventType
    ) -> Event.EventType {
        switch type {
        case .setup:  return .setup
        case .import: return .import
        case .export: return .export
        @unknown default: return .unknown
        }
    }

    // MARK: - Connectivity check (user-triggered)

    /// Probes CloudKit independently of SwiftData. Reports whether
    /// the iCloud account is signed in, whether we can reach the
    /// container (`fetchUserRecordID` round-trips), and stashes the
    /// result in `lastConnectivityCheck` for the UI.
    ///
    /// This proves the *network and account* path is healthy. If
    /// this passes but sync still isn't happening, the problem is
    /// almost certainly APNs (push environment mismatch in the app
    /// bundle's entitlements, e.g. a `development` aps-environment
    /// on a TestFlight build).
    func runConnectivityCheck(containerIdentifier: String) async {
        let container = CKContainer(identifier: containerIdentifier)
        let started = Date()

        do {
            let status = try await container.accountStatus()
            let userRecordID = try await container.userRecordID()
            lastConnectivityCheck = ConnectivityCheckResult(
                date: started,
                accountStatus: Self.describe(status),
                userRecordName: userRecordID.recordName,
                containerHostReachable: true,
                error: nil
            )
        } catch {
            // accountStatus or userRecordID failed — record whatever
            // status we got (or "Unknown" if even that errored) and
            // the error text so the user can copy it out.
            let accountStatus = (try? await container.accountStatus()).map(Self.describe) ?? "Unknown"
            lastConnectivityCheck = ConnectivityCheckResult(
                date: started,
                accountStatus: accountStatus,
                userRecordName: nil,
                containerHostReachable: false,
                error: error.localizedDescription
            )
        }
    }

    static func describe(_ status: CKAccountStatus) -> String {
        switch status {
        case .available:               return "Available"
        case .noAccount:               return "No Account"
        case .restricted:              return "Restricted"
        case .temporarilyUnavailable:  return "Temporarily Unavailable"
        case .couldNotDetermine:       return "Could Not Determine"
        @unknown default:              return "Unknown"
        }
    }
}
