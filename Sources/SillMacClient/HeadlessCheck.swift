import Foundation
import Network
import StreamProtocol

/// TEST ONLY: the client's whole path with no window, against a host on this Mac (docs/mac-client.md,
/// "Testing"): pair with a code at an address (the home door's or the remote door's), save the Mac,
/// open a pinned session through its saved addresses, pick the Desktop, decode every frame with
/// VideoToolbox, send a little input, and say what happened. Exits 0 only when the session was
/// admitted and frames decoded.
///
///   SILL_CLIENT_IDENTITY_DIR=$T/client SillMacClient --headless --address 127.0.0.1:PORT --code DIGITS \
///       [--home] [--seconds 6] [--input]
///   SILL_CLIENT_IDENTITY_DIR=$T/client SillMacClient --headless --saved [--seconds 6]   (the saved Mac again: no pairing)
///
/// `--home`: the address is a home door (TLS, a session there counts as on this network); without it,
/// a remote door (Remote Access, Tailscale). `--input`: a pointer move, a click, a scroll, a key and
/// text, which a `--synthetic` host counts as `in.dry` and never posts. Refuses to run without
/// SILL_CLIENT_IDENTITY_DIR, so a test never touches the keychain or the saved Macs of the app, and
/// sends input only to a loopback address.
enum HeadlessCheck {
    static func run(_ args: [String]) -> Never {
        guard let dir = ProcessInfo.processInfo.environment[ClientIdentity.testDirectoryVariable], !dir.isEmpty else {
            print("headless: refused: set \(ClientIdentity.testDirectoryVariable) to a test folder (the keychain and the app's saved Macs are never used here)")
            exit(2)
        }
        func value(_ flag: String) -> String? {
            guard let i = args.firstIndex(of: flag), i + 1 < args.count else { return nil }
            return args[i + 1]
        }
        let seconds = Double(value("--seconds") ?? "6") ?? 6
        let wantsInput = args.contains("--input")
        let home = args.contains("--home")

        let identity: RemoteIdentity
        switch ClientIdentity.loadOrCreate() {
        case .success(let id): identity = id
        case .failure(let f): print("headless: identity: \(f)"); exit(1)
        }
        print("headless: this Mac's key \(RemoteIdentity.shortName(identity.fingerprint)) in \(dir)")
        let store = SavedMacStore()

        func stream(_ mac: SavedMac) {
            guard let pin = mac.fingerprintData else { print("headless: the saved record has no pin"); exit(1) }
            let candidates = RemoteDialPolicy.order(mac.allAddresses, remotePort: mac.remotePort, lastWorked: mac.lastWorked,
                                                    localIPv4: LocalNetwork.ipv4())
            print("headless: dialing \(mac.name) (\(mac.macID)) at \(candidates.map(\.display).joined(separator: ", "))")
            if wantsInput, !candidates.allSatisfy({ $0.host.hasPrefix("127.") || $0.host == "::1" }) {
                print("headless: refused: --input goes only to a host on this Mac (127.0.0.1 or ::1)")
                exit(2)
            }
            let session = StreamSession(macID: mac.macID, pin: pin, identity: identity, store: store, name: mac.name)
            let sink = DecodingCounterSink()
            session.queue.sync { session.sink = sink }
            session.onEvent = { print("headless: session: \($0)") }
            session.setViewport(width: 1280, height: 800, screenFPS: 60)
            let target: StreamSession.Target = home && candidates.count == 1
                ? .home(.hostPort(host: NWEndpoint.Host(candidates[0].host), port: NWEndpoint.Port(integerLiteral: UInt16(candidates[0].port))))
                : .addresses(candidates)
            session.start(target)
            if wantsInput {
                DispatchQueue.main.asyncAfter(deadline: .now() + seconds / 2) {
                    print("headless: sending input")
                    session.input(.pointer(.move, x: 0.25, y: 0.25))
                    session.input(.pointer(.leftDown, x: 0.5, y: 0.5))
                    session.input(.pointer(.leftUp, x: 0.5, y: 0.5))
                    session.input(.scrollGesture(.began, x: 0.5, y: 0.5))
                    session.input(.scroll(x: 0.5, y: 0.5, dx: 0, dy: 0.05))
                    session.input(.scrollGesture(.ended, x: 0.5, y: 0.5))
                    var keys = ForwardedKeys()
                    if case .key(let e) = MacKeys.down(keyCode: 0, modifiers: KeyModifiers.command.rawValue, characters: "a", forwarded: &keys) {
                        session.input(e)   // ⌘A: a key with ⌘ goes as a key
                    }
                    if let up = MacKeys.up(keyCode: 0, forwarded: &keys) { session.input(up) }
                    if case .text(let t) = MacKeys.down(keyCode: 4, modifiers: 0, characters: "h", forwarded: &keys) {
                        session.input(.text(t))   // a plain key goes as text
                    }
                }
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + seconds) {
                let connected = session.phase == .connected
                let decoded = sink.decoded
                print("headless: result: \(connected ? "connected" : "not connected (\(session.phase))"), \(session.windows.count) windows, active \(session.active), frame \(Int(sink.size.width))×\(Int(sink.size.height)), \(decoded) frames decoded, \(sink.failed) failed, last second \(session.stats.fps) fps, rtt \(session.stats.rttMs.map(String.init) ?? "–") ms, route \(session.route)")
                session.disconnect()
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { exit(connected && decoded > 0 ? 0 : 1) }
            }
        }

        if args.contains("--saved") {
            guard let mac = store.list.last else { print("headless: no saved Mac in \(dir)"); exit(1) }
            stream(mac)
        } else {
            guard let raw = value("--address"), let code = value("--code") else {
                print("usage: SillMacClient --headless (--address HOST:PORT --code DIGITS [--home] | --saved) [--seconds N] [--input]")
                exit(2)
            }
            guard case .success(let (endpoint, address)) = ClientTLS.endpoint(typed: raw) else { print("headless: not an address: \(raw)"); exit(2) }
            guard case .success(let digits) = PairingCode.check(code) else { print("headless: not a code: \(code)"); exit(2) }
            let x = PairingExchange()
            print("headless: pairing at \(raw) (\(home ? "home door" : "remote door"))")
            x.run(endpoint: endpoint, remote: !home, identity: identity, method: .code(digits)) { outcome in
                _ = x
                switch outcome {
                case .paired(var mac):
                    mac.typedAddresses = SavedMacs.filtered([address], allowLoopback: true)
                    if let p = address.port { mac.remotePort = p }
                    store.add(mac)
                    print("headless: paired with \(mac.name) (\(mac.macID)), its key \(RemoteIdentity.shortName(mac.fingerprintData ?? Data()))")
                    stream(mac)
                case .answered(let r):
                    print("headless: refused: \(PairingExchange.words(for: r, mac: "the Mac")) (reason \(r.reason ?? "?"))")
                    exit(1)
                case .failed(let words):
                    print("headless: failed: \(words)")
                    exit(1)
                }
            }
        }
        dispatchMain()
    }
}
