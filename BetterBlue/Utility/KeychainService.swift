//
//  KeychainService.swift
//  BetterBlue
//
//  Thin wrapper around Security.framework for storing per-account credentials.
//  All items use kSecAttrAccessibleAfterFirstUnlock so background vehicle status
//  checks (charging, location) can read credentials when the screen is off after
//  the user has unlocked the device at least once since boot.
//
//  Items are scoped to the shared App Group access group (group.com.betterblue.shared)
//  so that widget and LiveActivity extensions running in a separate process can read
//  the same credentials. The com.apple.security.application-groups entitlement (already
//  present on all targets) is sufficient for App Group Keychain sharing — no separate
//  keychain-access-groups entitlement is required.
//

import Foundation
import Security

// MARK: - KeychainKey

/// Identifies a single credential item scoped to a specific account UUID.
/// Using associated values rather than a flat string enum makes the per-account
/// scoping explicit at the call site and prevents accidental cross-account reads.
enum KeychainKey {
    case password(accountId: UUID)
    case pin(accountId: UUID)
    case authToken(accountId: UUID)

    /// The kSecAttrService value shared by all BetterBlue Keychain items.
    static let service = "com.markschmidt.BetterBlue"

    /// The kSecAttrAccount value that uniquely identifies this item.
    var accountString: String {
        switch self {
        case .password(let id):  return "\(id.uuidString).password"
        case .pin(let id):       return "\(id.uuidString).pin"
        case .authToken(let id): return "\(id.uuidString).authToken"
        }
    }
}

// MARK: - KeychainService

/// Static helpers for reading and writing BetterBlue credentials in the Keychain.
/// `save()` returns a Bool so callers can detect write failures and avoid silently
/// discarding credentials that were never actually persisted.
enum KeychainService {

    /// Shared App Group used as the Keychain access group.
    /// All BetterBlue targets declare this group in com.apple.security.application-groups,
    /// which enables cross-process Keychain sharing for widgets and extensions.
    static let accessGroup = "group.com.betterblue.shared"

    // MARK: Save

    /// Writes `value` to the Keychain for `key`.
    /// If an item already exists it is updated in-place; otherwise a new item is added.
    /// - Returns: `true` on success, `false` if the Security framework returned an error.
    ///   Callers MUST treat `false` as a signal that the credential was NOT persisted
    ///   and should NOT discard any in-memory copy.
    @discardableResult
    static func save(_ value: String, for key: KeychainKey) -> Bool {
        guard let data = value.data(using: .utf8) else { return false }

        let searchQuery: [CFString: Any] = [
            kSecClass:           kSecClassGenericPassword,
            kSecAttrService:     KeychainKey.service,
            kSecAttrAccount:     key.accountString,
            kSecAttrAccessGroup: KeychainService.accessGroup,
        ]

        let updateAttributes: [CFString: Any] = [
            kSecValueData:      data,
            kSecAttrAccessible: kSecAttrAccessibleAfterFirstUnlock,
        ]

        let updateStatus = SecItemUpdate(searchQuery as CFDictionary, updateAttributes as CFDictionary)

        if updateStatus == errSecItemNotFound {
            var addQuery = searchQuery
            addQuery[kSecValueData]      = data
            addQuery[kSecAttrAccessible] = kSecAttrAccessibleAfterFirstUnlock
            let addStatus = SecItemAdd(addQuery as CFDictionary, nil)
            if addStatus != errSecSuccess {
                AppLogger.auth.error(
                    "KeychainService: add failed for \(key.accountString, privacy: .public) " +
                    "status=\(addStatus)"
                )
                return false
            }
        } else if updateStatus != errSecSuccess {
            AppLogger.auth.error(
                "KeychainService: update failed for \(key.accountString, privacy: .public) " +
                "status=\(updateStatus)"
            )
            return false
        }
        return true
    }

    // MARK: Load

    /// Returns the stored string for `key`, or `nil` if not found or on any error.
    static func load(for key: KeychainKey) -> String? {
        let query: [CFString: Any] = [
            kSecClass:           kSecClassGenericPassword,
            kSecAttrService:     KeychainKey.service,
            kSecAttrAccount:     key.accountString,
            kSecAttrAccessGroup: KeychainService.accessGroup,
            kSecReturnData:      true,
            kSecMatchLimit:      kSecMatchLimitOne,
        ]

        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)

        guard status == errSecSuccess,
              let data = result as? Data,
              let string = String(data: data, encoding: .utf8) else {
            return nil
        }
        return string
    }

    // MARK: Delete

    /// Removes the item for `key` from the Keychain. Silent no-op if not found.
    static func delete(for key: KeychainKey) {
        let query: [CFString: Any] = [
            kSecClass:           kSecClassGenericPassword,
            kSecAttrService:     KeychainKey.service,
            kSecAttrAccount:     key.accountString,
            kSecAttrAccessGroup: KeychainService.accessGroup,
        ]
        let status = SecItemDelete(query as CFDictionary)
        if status != errSecSuccess && status != errSecItemNotFound {
            AppLogger.auth.error(
                "KeychainService: delete failed for \(key.accountString, privacy: .public) " +
                "status=\(status)"
            )
        }
    }
}
