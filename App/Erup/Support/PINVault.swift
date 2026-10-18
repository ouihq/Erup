import Foundation
import LocalAuthentication
import Security

/// Keeps the scooter PIN in the Keychain, on this device only. The scooter cannot be asked for it.
enum PINVault {
    private static let service = "me.ouihq.erup.scooter-pin"
    private static let account = "lock-pin"
    private static let legacyDefaultsKey = "scooter.lockPIN"

    static var pin: String? {
        get {
            migrateLegacyValue()
            return read()
        }
        set {
            if let newValue { write(newValue) } else { delete() }
        }
    }

    private static var query: [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
    }

    private static func read() -> String? {
        var request = query
        request[kSecReturnData as String] = true
        request[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: AnyObject?
        guard SecItemCopyMatching(request as CFDictionary, &result) == errSecSuccess,
              let data = result as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    private static func write(_ value: String) {
        delete()
        var item = query
        item[kSecValueData as String] = Data(value.utf8)
        item[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly
        SecItemAdd(item as CFDictionary, nil)
    }

    private static func delete() {
        SecItemDelete(query as CFDictionary)
    }

    /// Earlier builds kept the PIN in UserDefaults. Move it once and remove the plain copy.
    private static func migrateLegacyValue() {
        let defaults = UserDefaults.standard
        guard let legacy = defaults.string(forKey: legacyDefaultsKey) else { return }
        if read() == nil { write(legacy) }
        defaults.removeObject(forKey: legacyDefaultsKey)
    }
}

/// Face ID, Touch ID or the device passcode before sensitive actions.
enum BiometricGate {
    /// Returns true when the person proves they are the owner. If the phone has no passcode there is nothing to ask for.
    @MainActor
    static func authenticate(reason: String) async -> Bool {
        let context = LAContext()
        var error: NSError?
        guard context.canEvaluatePolicy(.deviceOwnerAuthentication, error: &error) else { return true }
        do {
            return try await context.evaluatePolicy(.deviceOwnerAuthentication, localizedReason: reason)
        } catch {
            return false
        }
    }
}
