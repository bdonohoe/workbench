import CryptoKit
import Foundation
import Security

/// The phone's notification keys, one per paired Mac, kept where its
/// notification extension can read them. Only the derived keys are shared;
/// the pairing tokens stay private to the app.
public enum NotificationKeys {
    /// Must match `keychain-access-groups` in both the app's and the
    /// extension's entitlements. Both Info.plists carry it as
    /// BenchSharedKeychainGroup, built from the signing team and bundle id
    /// prefix, so a copy built from source with its own team works too.
    public static let accessGroup = Bundle.main.object(forInfoDictionaryKey: "BenchSharedKeychainGroup") as? String
        ?? "ZPU7B69KH3.me.birchtree.BenchPhone.shared"
    private static let account = "notification-keys"

    /// Replaces the saved keys with ones for these pairings.
    public static func save(_ pairings: [PairingInfo]) {
        var keys: [String: String] = [:]
        for pairing in pairings {
            let key = NotificationSeal.key(token: pairing.token, host: pairing.host)
            keys[NotificationSeal.keyID(host: pairing.host)] = key.withUnsafeBytes { Data($0).base64EncodedString() }
        }
        guard let data = try? JSONEncoder().encode(keys) else { return }
        let match: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrAccount as String: account,
            kSecAttrAccessGroup as String: accessGroup,
        ]
        SecItemDelete(match as CFDictionary)
        guard !keys.isEmpty else { return }
        var add = match
        add[kSecValueData as String] = data
        // Notifications arrive while the phone is locked.
        add[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        SecItemAdd(add as CFDictionary, nil)
    }

    public static func key(id: String) -> SymmetricKey? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrAccount as String: account,
            kSecAttrAccessGroup as String: accessGroup,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var result: AnyObject?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess, let data = result as? Data,
              let keys = try? JSONDecoder().decode([String: String].self, from: data),
              let encoded = keys[id], let raw = Data(base64Encoded: encoded) else { return nil }
        return SymmetricKey(data: raw)
    }
}
