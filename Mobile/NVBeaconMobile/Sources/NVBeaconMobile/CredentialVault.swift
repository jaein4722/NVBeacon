import Foundation
import Security

public protocol CredentialStorage: Sendable {
    func read(_ id: UUID) throws -> MobileCredential?
    func write(_ credential: MobileCredential, for id: UUID) throws
    func delete(_ id: UUID) throws
}

public struct CredentialVault: CredentialStorage {
    private let service: String
    public init(service: String = "com.nvbeacon.ios.credentials") { self.service = service }

    private func query(_ id: UUID) -> [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: service, kSecAttrAccount as String: id.uuidString]
    }

    public func read(_ id: UUID) throws -> MobileCredential? {
        var request = query(id)
        request[kSecReturnData as String] = true
        request[kSecMatchLimit as String] = kSecMatchLimitOne
        var item: CFTypeRef?
        let status = SecItemCopyMatching(request as CFDictionary, &item)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess, let data = item as? Data else { throw MobileError.keychain(status) }
        return try JSONDecoder().decode(MobileCredential.self, from: data)
    }

    public func write(_ credential: MobileCredential, for id: UUID) throws {
        let attributes: [String: Any] = [
            kSecValueData as String: try JSONEncoder().encode(credential),
            kSecAttrAccessible as String: kSecAttrAccessibleWhenUnlockedThisDeviceOnly,
        ]
        let status = SecItemUpdate(query(id) as CFDictionary, attributes as CFDictionary)
        if status == errSecItemNotFound {
            let addStatus = SecItemAdd(query(id).merging(attributes) { _, new in new } as CFDictionary, nil)
            guard addStatus == errSecSuccess else { throw MobileError.keychain(addStatus) }
        } else if status != errSecSuccess { throw MobileError.keychain(status) }
    }

    public func delete(_ id: UUID) throws {
        let status = SecItemDelete(query(id) as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else { throw MobileError.keychain(status) }
    }
}
