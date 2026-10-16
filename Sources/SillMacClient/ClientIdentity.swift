import Foundation
import Security
import StreamProtocol

/// This Mac's key as a Sill device (docs/remote-access-plan.md §3.4): one P-256 key per install, the
/// pin every Mac it pairs with keeps for it. Made at the first pairing or session and never sent
/// anywhere; its certificate is rebuilt from it at every launch (RemoteIdentity).
///
/// Where it lives:
/// - By default the login keychain, as a generic password holding the key's X9.63 bytes (service
///   `ClientIdentity.service`, account `ClientIdentity.account`). Like Sill.app's own unentitled
///   builds (docs/keychain-plan.md), the login keychain: the data-protection keychain needs a
///   provisioning profile this SwiftPM-built app does not have. Signed with an Apple Development
///   identity the item stays readable across rebuilds without a prompt; an ad hoc build's every
///   rebuild is a new app to the keychain, which then asks once to allow it.
/// - `SILL_CLIENT_IDENTITY_DIR=<dir>` (TEST ONLY): a 0600 file `client-key` in that 0700 folder, for
///   headless tests that must never touch the keychain.
enum ClientIdentity {
    /// The app was called Sill Mac Client until 0.5.1-plus.1; the key keeps that service name, so a
    /// Mac paired before the rename stays paired.
    static let service = "Sill Mac Client"
    static let account = "device-key"
    static let testDirectoryVariable = "SILL_CLIENT_IDENTITY_DIR"

    enum Failure: Error, CustomStringConvertible {
        case keychain(OSStatus)
        case file(String)
        case key

        var description: String {
            switch self {
            case .keychain(let s):
                let text = (SecCopyErrorMessageString(s, nil) as String?) ?? "status \(s)"
                return "the keychain refused this Mac's Sill key (\(text))"
            case .file(let why): return "the test identity file: \(why)"
            case .key: return "the stored key is not a P-256 key"
            }
        }
    }

    /// The identity, made and stored at the first call.
    static func loadOrCreate() -> Result<RemoteIdentity, Failure> {
        if let dir = ProcessInfo.processInfo.environment[testDirectoryVariable], !dir.isEmpty {
            return fileIdentity(dir: URL(fileURLWithPath: dir))
        }
        return keychainIdentity()
    }

    /// Forgets this Mac's key: every Mac it paired with then knows it no longer (pair again).
    static func reset() {
        if let dir = ProcessInfo.processInfo.environment[testDirectoryVariable], !dir.isEmpty {
            try? FileManager.default.removeItem(at: URL(fileURLWithPath: dir).appendingPathComponent("client-key"))
            return
        }
        SecItemDelete(baseQuery() as CFDictionary)
    }

    // MARK: The login keychain

    private static func baseQuery() -> [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: service,
         kSecAttrAccount as String: account]
    }

    private static func keychainIdentity() -> Result<RemoteIdentity, Failure> {
        var query = baseQuery()
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        if status == errSecSuccess, let data = item as? Data {
            guard let key = RemoteKey.importPrivate(data), let identity = RemoteIdentity(privateKey: key) else {
                return .failure(.key)
            }
            return .success(identity)
        }
        guard status == errSecItemNotFound else { return .failure(.keychain(status)) }
        guard let key = RemoteKey.generate(), let bytes = RemoteKey.export(key),
              let identity = RemoteIdentity(privateKey: key) else { return .failure(.key) }
        var add = baseQuery()
        add[kSecValueData as String] = bytes
        add[kSecAttrLabel as String] = "Sill Mac Client key"
        add[kSecAttrDescription as String] = "This Mac's key as a Sill device"
        let added = SecItemAdd(add as CFDictionary, nil)
        guard added == errSecSuccess else { return .failure(.keychain(added)) }
        return .success(identity)
    }

    // MARK: TEST ONLY: a file

    private static func fileIdentity(dir: URL) -> Result<RemoteIdentity, Failure> {
        let fm = FileManager.default
        do {
            try fm.createDirectory(at: dir, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        } catch {
            return .failure(.file("cannot make \(dir.path): \(error.localizedDescription)"))
        }
        let file = dir.appendingPathComponent("client-key")
        if let data = try? Data(contentsOf: file) {
            guard let key = RemoteKey.importPrivate(data), let identity = RemoteIdentity(privateKey: key) else {
                return .failure(.key)
            }
            return .success(identity)
        }
        guard let key = RemoteKey.generate(), let bytes = RemoteKey.export(key),
              let identity = RemoteIdentity(privateKey: key) else { return .failure(.key) }
        guard fm.createFile(atPath: file.path, contents: bytes, attributes: [.posixPermissions: 0o600]) else {
            return .failure(.file("cannot write \(file.path)"))
        }
        return .success(identity)
    }
}
