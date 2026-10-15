import Foundation
import StreamProtocol

/// The Macs this Mac paired with, on disk (docs/mac-client.md, "What is stored"). The records and
/// their rules are the iOS client's (SavedMacs.swift, compiled into this target unchanged): keyed by
/// Mac ID, the pin, the recognition key that resolves the Mac's Bonjour tag, the remote port and the
/// addresses for afar (the Mac's own from its signed kind 18, plus any typed here). Kept as the iOS
/// client keeps them in UserDefaults, as SavedMacs' JSON, but in a 0600 file of its own:
/// `~/Library/Application Support/Sill Mac Client/saved-macs.json`, or `saved-macs.json` in
/// `SILL_CLIENT_IDENTITY_DIR` (TEST ONLY) beside the test key.
///
/// Main thread.
final class SavedMacStore {
    private(set) var list: [SavedMac]
    private let file: URL
    /// Loopback addresses are saved only for tests (SavedMacs.keepable), so a headless test can dial a
    /// synthetic host on 127.0.0.1 again; never for a real pairing.
    let allowLoopback: Bool

    init() {
        let env = ProcessInfo.processInfo.environment
        if let dir = env[ClientIdentity.testDirectoryVariable], !dir.isEmpty {
            file = URL(fileURLWithPath: dir).appendingPathComponent("saved-macs.json")
            allowLoopback = true
        } else {
            let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
                ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Library/Application Support")
            // "Sill Mac Client": the app's name before Sill Viewer, kept so saved Macs stay.
            file = base.appendingPathComponent("Sill Mac Client").appendingPathComponent("saved-macs.json")
            allowLoopback = false
        }
        list = SavedMacs.decode((try? Data(contentsOf: file)).flatMap { String(data: $0, encoding: .utf8) })
    }

    func mac(_ id: String) -> SavedMac? { list.first { $0.macID == id } }

    /// Recognises a Bonjour row's TXT tag (`r`) as one of these Macs.
    func recognize(tag: String?) -> String? { SavedMacs.recognize(tag: tag, in: list) }

    func displayName(_ id: String) -> String { SavedMacs.displayNames(list)[id] ?? mac(id)?.name ?? "Mac" }

    /// After a pairing whose proof_M checked.
    func add(_ mac: SavedMac) {
        list = SavedMacs.adding(mac, to: list)
        persist()
    }

    /// A verified kind 18 from a session pinned to `id`'s key: its name, port and addresses.
    func refresh(_ id: String, info: MacInfo, fingerprint: Data) {
        guard let i = list.firstIndex(where: { $0.macID == id }),
              let next = SavedMacs.refreshed(list[i], info: info, fingerprint: fingerprint, allowLoopback: allowLoopback)
        else { return }
        list[i] = next
        persist()
    }

    func update(_ id: String, _ change: (inout SavedMac) -> Void) {
        guard let i = list.firstIndex(where: { $0.macID == id }) else { return }
        change(&list[i])
        persist()
    }

    func remove(_ id: String) {
        list.removeAll { $0.macID == id }
        persist()
    }

    private func persist() {
        let fm = FileManager.default
        try? fm.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true,
                                attributes: [.posixPermissions: 0o700])
        let data = Data(SavedMacs.encode(list).utf8)
        if fm.fileExists(atPath: file.path) {
            try? data.write(to: file, options: .atomic)
            try? fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
        } else {
            fm.createFile(atPath: file.path, contents: data, attributes: [.posixPermissions: 0o600])
        }
    }
}
