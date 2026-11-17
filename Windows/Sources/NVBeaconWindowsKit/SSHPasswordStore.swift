import Foundation
import WinSDK

/// SSH passwords in Windows Credential Manager, one generic credential per server
/// (the macOS app keeps them in Keychain).
///
/// Credential Manager protects them with the user's Windows logon (DPAPI); like any
/// per-user secret store, programs running as the same user can read them.
public struct SSHPasswordStore: Sendable {
    public let prefix: String

    public init(prefix: String = "NVBeacon/ssh-password/") {
        self.prefix = prefix
    }

    func targetName(for serverID: String) -> String { prefix + serverID }

    public func password(for serverID: String) -> String? {
        var credential: PCREDENTIALW?
        let found = targetName(for: serverID).withCString(encodedAs: UTF16.self) {
            CredReadW($0, DWORD(CRED_TYPE_GENERIC), 0, &credential)
        }
        guard found, let credential else { return nil }
        defer { CredFree(credential) }
        let size = Int(credential.pointee.CredentialBlobSize)
        guard size >= 2, let blob = credential.pointee.CredentialBlob else { return nil }
        // UTF-16LE, like Credential Manager itself and cmdkey.
        let count = size / 2
        var units = [UInt16](repeating: 0, count: count)
        units.withUnsafeMutableBytes { $0.copyMemory(from: UnsafeRawBufferPointer(start: blob, count: count * 2)) }
        defer { for index in units.indices { units[index] = 0 } }
        return String(decoding: units, as: UTF16.self)
    }

    public func hasPassword(for serverID: String) -> Bool { password(for: serverID) != nil }

    /// Saves the password; an empty one removes it, as on macOS.
    @discardableResult
    public func save(_ password: String, for serverID: String) -> Bool {
        let trimmed = password.trimmingCharacters(in: .newlines)
        guard !trimmed.isEmpty else { return delete(for: serverID) }
        var units = Array(trimmed.utf16)
        defer { for index in units.indices { units[index] = 0 } }
        return targetName(for: serverID).withCString(encodedAs: UTF16.self) { target in
            "NVBeacon".withCString(encodedAs: UTF16.self) { user in
                units.withUnsafeMutableBytes { blob in
                    var credential = CREDENTIALW()
                    credential.Type = DWORD(CRED_TYPE_GENERIC)
                    credential.TargetName = UnsafeMutablePointer(mutating: target)
                    credential.UserName = UnsafeMutablePointer(mutating: user)
                    credential.CredentialBlobSize = DWORD(blob.count)
                    credential.CredentialBlob = blob.baseAddress?.assumingMemoryBound(to: UInt8.self)
                    credential.Persist = DWORD(CRED_PERSIST_LOCAL_MACHINE)
                    return CredWriteW(&credential, 0)
                }
            }
        }
    }

    @discardableResult
    public func delete(for serverID: String) -> Bool {
        targetName(for: serverID).withCString(encodedAs: UTF16.self) {
            CredDeleteW($0, DWORD(CRED_TYPE_GENERIC), 0)
        } || GetLastError() == DWORD(ERROR_NOT_FOUND)
    }

    /// Server ids that have a saved password.
    public func savedServerIDs() -> Set<String> {
        var count: DWORD = 0
        var credentials: UnsafeMutablePointer<PCREDENTIALW?>?
        let found = (prefix + "*").withCString(encodedAs: UTF16.self) {
            CredEnumerateW($0, 0, &count, &credentials)
        }
        guard found, let credentials else { return [] }
        defer { CredFree(credentials) }
        var ids = Set<String>()
        for index in 0..<Int(count) {
            guard let name = credentials[index]?.pointee.TargetName else { continue }
            let target = String(decodingCString: name, as: UTF16.self)
            if target.hasPrefix(prefix) { ids.insert(String(target.dropFirst(prefix.count))) }
        }
        return ids
    }
}

/// NVBeacon.exe as ssh's `SSH_ASKPASS` program.
///
/// ssh starts it with the prompt as its argument and reads one line from its
/// standard output. It answers only a password prompt, with the password saved for
/// the server named in `NVBEACON_ASKPASS_ACCOUNT`, and declines everything else
/// (host-key questions, key passphrases, one-time codes, password changes), so a
/// wrong answer is never sent and an unexpected prompt fails the connection.
public enum AskPass {
    public static let accountVariable = "NVBEACON_ASKPASS_ACCOUNT"

    /// Accepts only the two prompts a password login shows: ssh's own
    /// `user@host's password:` and PAM's `Password:` through keyboard-interactive,
    /// which recent OpenSSH prefixes with `(user@host) `.
    public static func isPasswordPrompt(_ prompt: String) -> Bool {
        var text = prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        if text.hasSuffix("'s password:") {
            let login = text.dropLast("'s password:".count)
            return login.contains("@") && !login.contains(where: \.isWhitespace)
        }
        if text.hasPrefix("("), let close = text.firstIndex(of: ")") {
            text = text[text.index(after: close)...].trimmingCharacters(in: .whitespaces)
        }
        return text.lowercased() == "password:"
    }

    /// The process exit code for ssh: 0 with the password written, 1 to decline.
    public static func run(arguments: [String], account: String, store: SSHPasswordStore = SSHPasswordStore()) -> Int32 {
        let prompt = arguments.dropFirst().joined(separator: " ")
        guard isPasswordPrompt(prompt), let password = store.password(for: account) else { return 1 }
        FileHandle.standardOutput.write(Data((password + "\n").utf8))
        return 0
    }
}
