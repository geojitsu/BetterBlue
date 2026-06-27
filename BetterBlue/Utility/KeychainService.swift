//
//  KeychainService.swift
//  BetterBlue
//
//  Thin wrapper around Security.framework for storing per-account credentials.
//  All items use kSecAttrAccessibleAfterFirstUnlock so background vehicle status
//  checks (charging, location) can read credentials when the screen is off after
//  the user has unlocked the device at least once since boot.
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
/// All operations are synchronous and return nil (rather than throwing) on failure
/// so callers do not need to handle unlikely Keychain errors in hot paths.
enum KeychainService {

    // MARK: Save

    /// Writes `value` to the Keychain for `key`.
    /// If an item already exists it is updated in-place; otherwise a new item is added.
    static func save(_ value: String, for key: KeychainKey) {
        guard let data = value.data(using: .utf8) else { return }

        let searchQuery: [CFString: Any] = [
            kSecClass:       kSecClassGenericPassword,
            kSecAttrService: KeychainKey.service,
            kSecAttrAccount: key.accountString,
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
            }
        } else if updateStatus != errSecSuccess {
            AppLogger.auth.error(
                "KeychainService: update failed for \(key.accountString, privacy: .public) " +
                "status=\(updateStatus)"
            )
        }
    }

    // MARK: Load

    /// Returns the stored string for `key`, or `nil` if not found or on any error.
    static func load(for key: KeychainKey) -> String? {
        let query: [CFString: Any] = [
            kSecClass:       kSecClassGenericPassword,
            kSecAttrService: KeychainKey.service,
            kSecAttrAccount: key.accountString,
            kSecReturnData:  true,
            kSecMatchLimit:  kSecMatchLimitOne,
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
            kSecClass:       kSecClassGenericPassword,
            kSecAttrService: KeychainKey.service,
            kSecAttrAccount: key.accountString,
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
