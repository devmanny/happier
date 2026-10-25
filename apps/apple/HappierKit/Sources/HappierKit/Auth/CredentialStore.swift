import Foundation
import Security

/// Keychain persistence of `Credentials`, one item per server URL.
public struct CredentialStore: Sendable {
    public struct KeychainError: Error { public let status: OSStatus }

    private let service: String

    public init(service: String = "com.devmanny.happier.credentials") {
        self.service = service
    }

    public func load(server: URL) throws -> Credentials? {
        var query = baseQuery(server)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess, let data = result as? Data else { throw KeychainError(status: status) }
        return try JSONDecoder().decode(Credentials.self, from: data)
    }

    public func save(_ credentials: Credentials, server: URL) throws {
        let data = try JSONEncoder().encode(credentials)
        let update = [kSecValueData as String: data] as CFDictionary
        var status = SecItemUpdate(baseQuery(server) as CFDictionary, update)
        if status == errSecItemNotFound {
            var add = baseQuery(server)
            add[kSecValueData as String] = data
            add[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
            status = SecItemAdd(add as CFDictionary, nil)
        }
        guard status == errSecSuccess else { throw KeychainError(status: status) }
    }

    public func delete(server: URL) {
        SecItemDelete(baseQuery(server) as CFDictionary)
    }

    private func baseQuery(_ server: URL) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: server.absoluteString,
        ]
    }
}
