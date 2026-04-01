import Foundation
import LocalAuthentication
import Security

struct SSHPasswordStore {
    private let service = "com.leejaein.NVBeacon.ssh-password"
    private let account = "current"

    func hasPasswordWithoutPrompt() -> Bool {
        let context = LAContext()
        context.interactionNotAllowed = true

        var query = baseQuery
        query[kSecReturnAttributes as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        query[kSecUseAuthenticationContext as String] = context

        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)

        switch status {
        case errSecSuccess, errSecInteractionNotAllowed, errSecAuthFailed:
            return true
        case errSecItemNotFound:
            return false
        default:
            return false
        }
    }

    func loadPassword() throws -> String {
        var query = baseQuery
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne

        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)

        switch status {
        case errSecSuccess:
            guard
                let data = result as? Data,
                let password = String(data: data, encoding: .utf8)
            else {
                throw PasswordStoreError.invalidData
            }

            return password
        case errSecItemNotFound:
            return ""
        default:
            throw PasswordStoreError.osStatus(status)
        }
    }

    func savePassword(_ password: String?) throws {
        let trimmed = password?.trimmingCharacters(in: .newlines) ?? ""

        guard !trimmed.isEmpty else {
            try deletePassword()
            return
        }

        let data = Data(trimmed.utf8)
        let attributes = [kSecValueData as String: data]
        let status = SecItemUpdate(baseQuery as CFDictionary, attributes as CFDictionary)

        switch status {
        case errSecSuccess:
            return
        case errSecItemNotFound:
            var query = baseQuery
            query[kSecValueData as String] = data

            let addStatus = SecItemAdd(query as CFDictionary, nil)
            guard addStatus == errSecSuccess else {
                throw PasswordStoreError.osStatus(addStatus)
            }
        default:
            throw PasswordStoreError.osStatus(status)
        }
    }

    func deletePassword() throws {
        let status = SecItemDelete(baseQuery as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw PasswordStoreError.osStatus(status)
        }
    }

    private var baseQuery: [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
    }
}

enum PasswordStoreError: LocalizedError {
    case invalidData
    case osStatus(OSStatus)

    var errorDescription: String? {
        let language = AppLocalizer.currentLanguage()
        switch self {
        case .invalidData:
            return language.text("Could not read the saved SSH password.", "저장된 SSH 비밀번호를 읽을 수 없습니다.")
        case .osStatus(let status):
            switch status {
            case errSecUserCanceled:
                return language.text("The Keychain prompt was canceled.", "키체인 확인 창이 취소되었습니다.")
            case errSecAuthFailed:
                return language.text("The Keychain password or confirmation was rejected.", "키체인 암호 또는 확인이 거부되었습니다.")
            case errSecInteractionNotAllowed:
                return language.text("The Keychain item needs to be unlocked from Settings.", "설정에서 Keychain 항목을 한 번 해제해야 합니다.")
            default:
                return language.text("The Keychain operation failed. (OSStatus \(status))", "키체인 작업이 실패했습니다. (OSStatus \(status))")
            }
        }
    }
}
