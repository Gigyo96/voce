import Foundation
import Security

/// Chiavi API dei servizi online nel Keychain (§14), una per servizio (host): riscrittura e comandi possono usare
/// provider diversi. Lette una volta e tenute in memoria.
enum Keychain {
    private static let service = "it.dimarcantonio.voce"
    private static let legacyAccount = "llm-api-key"
    nonisolated(unsafe) private static var cache: [String: String?] = [:]

    static func apiKey(for baseURL: String) -> String? { read(account(baseURL)) }
    static func setAPIKey(_ key: String?, for baseURL: String) { write(key, account(baseURL)) }

    private static func account(_ baseURL: String) -> String {
        let trimmed = baseURL.trimmingCharacters(in: .whitespaces)
        return legacyAccount + ":" + (URL(string: trimmed)?.host() ?? trimmed).lowercased()
    }

    /// Prima c'era una chiave sola: va ai servizi online configurati che non ne hanno ancora una.
    static func migrateLegacy(to baseURLs: [String]) {
        guard let old = read(legacyAccount) else { return }
        let online = baseURLs.filter { !$0.isEmpty && !Prefs.isLocal($0) }
        guard !online.isEmpty else { return }
        for url in online where apiKey(for: url) == nil { setAPIKey(old, for: url) }
        write(nil, legacyAccount)
    }

    private static func read(_ account: String) -> String? {
        if let hit = cache[account] { return hit }
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service,
                                    kSecAttrAccount as String: account, kSecReturnData as String: true]
        var out: AnyObject?
        let value = SecItemCopyMatching(query as CFDictionary, &out) == errSecSuccess
            ? (out as? Data).flatMap { String(data: $0, encoding: .utf8) } : nil
        cache[account] = .some(value)
        return value
    }

    private static func write(_ value: String?, _ account: String) {
        let value = value?.trimmingCharacters(in: .whitespacesAndNewlines)
        let base: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service,
                                   kSecAttrAccount as String: account]
        SecItemDelete(base as CFDictionary)
        if let value, !value.isEmpty {
            var add = base
            add[kSecValueData as String] = Data(value.utf8)
            SecItemAdd(add as CFDictionary, nil)
        }
        cache[account] = .some(value?.isEmpty == false ? value : nil)
    }
}
