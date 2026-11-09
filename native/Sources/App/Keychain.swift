import Foundation
import Security
import BridgeCore

/// Login Keychain record for this app only (service "T3ForWoW", account "t3-grant"). All decisions
/// about the results (absent / malformed / denied / delete outcome) live in BridgeCore's GrantVault.
struct KeychainBackend: SecretBackend {
    static let service = "T3ForWoW", account = "t3-grant"
    private var base: [String: Any] { [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: Self.service, kSecAttrAccount as String: Self.account] }

    func read() -> (status: Int32, data: Data?) {
        var q = base
        q[kSecReturnData as String] = true
        q[kSecMatchLimit as String] = kSecMatchLimitOne
        var out: CFTypeRef?
        let st = SecItemCopyMatching(q as CFDictionary, &out)
        return (st, out as? Data)
    }

    /// Single-record update in place, or add when absent. Never delete-then-add.
    func write(_ data: Data) -> Int32 {
        let st = SecItemUpdate(base as CFDictionary, [kSecValueData as String: data] as CFDictionary)
        if st != errSecItemNotFound { return st }
        var add = base
        add[kSecValueData as String] = data
        return SecItemAdd(add as CFDictionary, nil)
    }

    func delete() -> Int32 { SecItemDelete(base as CFDictionary) }
}
