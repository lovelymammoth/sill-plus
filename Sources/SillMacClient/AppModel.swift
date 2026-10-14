import AppKit
import Foundation
import Network
import StreamProtocol

/// The Mac client's state (main thread): this Mac's key, the saved Macs, the Macs Bonjour lists, a
/// pairing in progress, and the session. The windows (ClientViews.swift) only read it and call it.
final class AppModel: ObservableObject {
    enum Pairing: Equatable {
        case idle
        /// Waiting for a Mac's answer (an ask or a proof).
        case working(String)
        /// The Mac shows a code: type it here. `row` is the Bonjour row the ask went to, nil for an
        /// address.
        case needsCode(mac: String, rowName: String?)
        case failed(String)
    }

    @Published var pairing: Pairing = .idle
    @Published private(set) var saved: [SavedMac] = []
    @Published private(set) var session: StreamSession?
    @Published var status = ""

    let discovery = Discovery()
    let store = SavedMacStore()
    private(set) var identity: RemoteIdentity?
    private var exchange: PairingExchange?
    /// The address a typed pairing used, kept for the record and the session after it.
    private var pairingAddress: (NWEndpoint, MacAddress)?

    init() {
        saved = store.list
    }

    func start() {
        discovery.start()
    }

    /// This Mac's key, made at first use; the words when the keychain refuses it.
    private func requireIdentity() -> RemoteIdentity? {
        if let identity { return identity }
        switch ClientIdentity.loadOrCreate() {
        case .success(let id):
            identity = id
            return id
        case .failure(let f):
            status = "Sill can't use this Mac's key: \(f)."
            return nil
        }
    }

    func savedMac(for row: Discovery.Row) -> SavedMac? {
        store.recognize(tag: row.tag).flatMap { store.mac($0) }
    }

    // MARK: Connecting

    /// A row of this network: a saved Mac's session at its home door, pinned; a Mac this Mac has not
    /// paired with gets an ask ("pair me"), whose answer opens its pairing window and brings the
    /// code field here.
    func connect(_ row: Discovery.Row) {
        guard let identity = requireIdentity() else { return }
        if row.door == .plain {
            status = "\(row.name) runs a Sill for Mac older than 0.4, or a development host without --pairing. Update Sill there: this client only speaks to a Mac over TLS."
            return
        }
        if let mac = savedMac(for: row), let pin = mac.fingerprintData, mac.revoked != true {
            store.update(mac.macID) { $0.bonjourName = row.name; $0.homeTLS = true }
            openSession(mac: mac, pin: pin, identity: identity, target: .home(row.endpoint))
            return
        }
        pairing = .working("Asking \(row.name) to pair…")
        let x = PairingExchange()
        exchange = x
        x.run(endpoint: row.endpoint, remote: false, identity: identity, method: .ask) { [weak self] outcome in
            guard let self else { return }
            self.exchange = nil
            switch outcome {
            case .answered(let r) where r.reason == PairResult.shown:
                self.pairing = .needsCode(mac: row.name, rowName: row.name)
            case .answered(let r):
                self.pairing = .failed(PairingExchange.words(for: r, mac: row.name))
            case .paired:
                self.pairing = .failed("\(row.name) answered as if this Mac were on its USB cable; that is not how a Mac pairs. Try again.")
            case .failed(let words):
                self.pairing = .failed(words)
            }
        }
    }

    /// The 12 digits the Mac shows, typed after an ask (`rowName`) or with an address.
    func submitCode(_ raw: String, rowName: String?) {
        guard let identity = requireIdentity() else { return }
        let code: String
        switch PairingCode.check(raw) {
        case .failure(.length): pairing = .failed("A code has 12 digits."); return
        case .failure(.typo): pairing = .failed("That code has a typo. Check it against the Mac."); return
        case .success(let c): code = c
        }
        let endpoint: NWEndpoint
        let remote: Bool
        let label: String
        if let rowName, let row = discovery.rows.first(where: { $0.name == rowName }) {
            endpoint = row.endpoint; remote = false; label = row.name
        } else if let (e, a) = pairingAddress {
            endpoint = e; remote = a.kind != MacAddress.lan || RemoteDialPolicy.isVPNAddress(a.host); label = a.host
        } else {
            pairing = .failed("That Mac is no longer listed. Try again.")
            return
        }
        pairing = .working("Checking the code with \(label)…")
        let typed = rowName == nil ? pairingAddress?.1 : nil
        let x = PairingExchange()
        exchange = x
        x.run(endpoint: endpoint, remote: remote, identity: identity, method: .code(code)) { [weak self] outcome in
            self?.exchange = nil
            self?.pairingEnded(outcome, label: label, rowName: rowName, endpoint: endpoint, typed: typed)
        }
    }

    /// "Add a Mac by address": the address its pairing window shows (Tailscale's name or IP), and the
    /// code. Dials the remote door (Remote Access on, or the pairing window open, on the Mac).
    func pair(address raw: String, code: String) {
        switch ClientTLS.endpoint(typed: raw.trimmingCharacters(in: .whitespacesAndNewlines)) {
        case .failure:
            pairing = .failed("That isn't an address: a name like mac-mini.tail1234.ts.net, or an IP address, with :port if not 7455.")
        case .success(let pair):
            pairingAddress = pair
            submitCode(code, rowName: nil)
        }
    }

    /// A `sill://pair?…` link copied from another device or a QR reader: pinned to the link's key, at
    /// the link's own addresses (the first that answers).
    func pair(link raw: String) {
        guard let identity = requireIdentity() else { return }
        guard case .success(let link) = PairLink.parse(raw) else {
            pairing = .failed("That isn't a Sill pairing link (sill://pair?…).")
            return
        }
        guard let first = link.addresses.first else {
            pairing = .failed("That link carries no address. Use the code with the Mac's address instead.")
            return
        }
        let address = RemoteDialPolicy.address(for: first)
        let endpoint = NWEndpoint.hostPort(host: NWEndpoint.Host(first.host), port: NWEndpoint.Port(integerLiteral: UInt16(first.port ?? link.port)))
        pairingAddress = (endpoint, address)
        pairing = .working("Pairing with \(link.name)…")
        let x = PairingExchange()
        exchange = x
        x.run(endpoint: endpoint, remote: true, identity: identity, method: .link(link)) { [weak self] outcome in
            guard let self else { return }
            self.exchange = nil
            if case .paired(var mac) = outcome {
                mac.remotePort = link.port
                mac.addresses = SavedMacs.filtered(link.addresses.map(RemoteDialPolicy.address(for:)), allowLoopback: self.store.allowLoopback)
                mac.method = "qr"
                self.pairingEnded(.paired(mac), label: link.name, rowName: nil, endpoint: endpoint, typed: nil)
            } else {
                self.pairingEnded(outcome, label: link.name, rowName: nil, endpoint: endpoint, typed: nil)
            }
        }
    }

    private func pairingEnded(_ outcome: PairingExchange.Outcome, label: String, rowName: String?, endpoint: NWEndpoint,
                              typed: MacAddress?) {
        switch outcome {
        case .paired(var mac):
            if let typed {
                mac.typedAddresses = SavedMacs.filtered([typed], allowLoopback: store.allowLoopback)
                if let p = typed.port { mac.remotePort = p }
            }
            if let rowName { mac.bonjourName = rowName; mac.homeTLS = true }
            store.add(mac)
            saved = store.list
            pairing = .idle
            status = "Paired with \(mac.name)."
            guard let identity, let pin = mac.fingerprintData else { return }
            if rowName != nil {
                openSession(mac: mac, pin: pin, identity: identity, target: .home(endpoint))
            } else {
                connectRemotely(mac.macID)
            }
        case .answered(let r):
            pairing = .failed(PairingExchange.words(for: r, mac: label))
        case .failed(let words):
            pairing = .failed(words)
        }
    }

    func cancelPairing() {
        exchange?.cancel()
        exchange = nil
        pairing = .idle
    }

    /// A saved Mac from afar: its addresses (the Mac's own from its signed kind 18, and any typed
    /// here) in the iOS client's dial order, Tailscale's first.
    func connectRemotely(_ macID: String) {
        guard let identity = requireIdentity(), let mac = store.mac(macID), let pin = mac.fingerprintData else { return }
        let candidates = RemoteDialPolicy.order(mac.allAddresses, remotePort: mac.remotePort, lastWorked: mac.lastWorked,
                                                localIPv4: LocalNetwork.ipv4())
        openSession(mac: mac, pin: pin, identity: identity, target: .addresses(candidates))
    }

    /// The best way to a saved Mac: its Bonjour row when this network lists it, else its addresses.
    func connect(saved macID: String) {
        if let row = discovery.rows.first(where: { store.recognize(tag: $0.tag) == macID }) {
            connect(row)
        } else {
            connectRemotely(macID)
        }
    }

    private func openSession(mac: SavedMac, pin: Data, identity: RemoteIdentity, target: StreamSession.Target) {
        session?.disconnect()
        let s = StreamSession(macID: mac.macID, pin: pin, identity: identity, store: store, name: store.displayName(mac.macID))
        s.onEvent = { line in print("Sill: \(line)") }
        session = s
        status = ""
        s.start(target)
    }

    func endSession() {
        session?.disconnect()
        session = nil
        saved = store.list
    }

    func forget(_ macID: String) {
        store.remove(macID)
        saved = store.list
    }

    func addAddress(_ raw: String, to macID: String) {
        guard case .success(let (_, address)) = ClientTLS.endpoint(typed: raw) else {
            status = "That isn't an address."
            return
        }
        let allowLoopback = store.allowLoopback
        store.update(macID) { mac in
            var typed = mac.typedAddresses ?? []
            typed.removeAll { $0.host.lowercased() == address.host.lowercased() && $0.port == address.port }
            typed.append(address)
            mac.typedAddresses = SavedMacs.filtered(typed, allowLoopback: allowLoopback)
        }
        saved = store.list
    }
}

/// This Mac's IPv4 networks, for RemoteDialPolicy.order's "a LAN address in a subnet this Mac shares".
enum LocalNetwork {
    static func ipv4() -> [(address: [UInt8], prefix: Int)] {
        var out: [(address: [UInt8], prefix: Int)] = []
        var list: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&list) == 0, let first = list else { return out }
        defer { freeifaddrs(list) }
        var p: UnsafeMutablePointer<ifaddrs>? = first
        while let a = p {
            defer { p = a.pointee.ifa_next }
            guard let addr = a.pointee.ifa_addr, addr.pointee.sa_family == UInt8(AF_INET), let mask = a.pointee.ifa_netmask else { continue }
            let ip = addr.withMemoryRebound(to: sockaddr_in.self, capacity: 1) { $0.pointee.sin_addr.s_addr }
            let m = mask.withMemoryRebound(to: sockaddr_in.self, capacity: 1) { $0.pointee.sin_addr.s_addr }
            let bytes = withUnsafeBytes(of: ip) { Array($0) }
            let prefix = UInt32(bigEndian: m).nonzeroBitCount
            out.append((bytes, prefix))
        }
        return out
    }
}
