import Foundation
import Network
import StreamProtocol

/// Every connection this client makes to a Mac (docs/mac-client.md, "Security"): TLS 1.3 with both
/// keys pinned, through StreamProtocol's one builder (RemoteTLS), exactly as the iOS client's
/// DeviceTLS dials: this Mac presents its own key (ClientIdentity) and accepts the Mac's only when it
/// is the pin. Only a pairing dial takes any P-256 key (`pin` nil), and the pairing proof then binds
/// the key it saw, so a relay in the middle makes the Mac reject the proof. No plain connection
/// exists in this client: Sill.app's home door speaks TLS since 0.4.0, and its remote door always has.
enum ClientTLS {
    /// The remote door's usual port (HostConfig.defaultRemotePort), for an address typed without one.
    static let defaultRemotePort = 7455

    /// `alpn`: `RemoteTLS.sessionALPN` for a session, `RemoteTLS.pairingALPN` for pairing. `pin`: the
    /// Mac's key, nil for any P-256 key. `onPinRefused` runs on `queue` when the pin refused the key
    /// that answered (-9808): a connection to a Bonjour service whose pin fails goes back to
    /// preparing again and again instead of failing, so a dial that must end there hears it here.
    static func parameters(identity: RemoteIdentity, alpn: String, pin: Data?, queue: DispatchQueue,
                           remote: Bool, onPinRefused: (() -> Void)? = nil) -> NWParameters {
        let tls = RemoteTLS.options(identity: identity.tls, role: .client(alpn: alpn), verify: { fp in
            guard let pin else { return fp != nil }
            guard fp == pin else { onPinRefused?(); return false }
            return true
        }, queue: queue)
        if remote {
            // The remote door (Tailscale, a VPN, a forwarded port): keepalive and the 15 s drop rule,
            // and a 10 s connect timeout.
            return RemoteTLS.parameters(tls: tls, dialing: true)
        }
        // The home door: no Nagle, the video service class, never peer-to-peer (this client does not
        // do Direct Wireless).
        let tcp = NWProtocolTCP.Options()
        tcp.noDelay = true
        tcp.connectionTimeout = RemoteTLS.dialTimeout
        return RemoteTLS.parameters(tls: tls, tcp: tcp, peerToPeer: false)
    }

    /// An address the user typed ("mac-mini.tail1234.ts.net", "100.101.102.103:7455", "[fd7a::1]")
    /// as an endpoint and the MacAddress a saved record keeps; nil with the parser's words.
    static func endpoint(typed raw: String) -> Result<(NWEndpoint, MacAddress), AddressParser.Failure> {
        switch AddressParser.parse(raw) {
        case .failure(let f): return .failure(f)
        case .success(let parsed):
            let address = RemoteDialPolicy.address(for: parsed)
            let port = parsed.port ?? defaultRemotePort
            return .success((.hostPort(host: NWEndpoint.Host(parsed.host), port: NWEndpoint.Port(integerLiteral: UInt16(port))), address))
        }
    }

    /// This Mac as a device: "MacBook Pro" (the computer's name) and its model ("Mac15,7"), as Hello
    /// and PairRequest carry them; the host cleans both (SafeText).
    static var deviceName: String {
        let name = Host.current().localizedName ?? "Mac"
        return SafeText.label(name).isEmpty ? "Mac" : SafeText.label(name)
    }

    static var model: String {
        var size = 0
        guard sysctlbyname("hw.model", nil, &size, nil, 0) == 0, size > 0 else { return "Mac" }
        var bytes = [CChar](repeating: 0, count: size)
        guard sysctlbyname("hw.model", &bytes, &size, nil, 0) == 0 else { return "Mac" }
        return String(cString: bytes)
    }

    /// ClientStats.device and Hello.device: "MacBook Pro (Mac15,7)", as the iOS client sends "iPad
    /// (iPad14,1)".
    static var deviceLabel: String { "\(deviceName) (\(model))" }

    static var appVersion: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0.1"
    }

    static var buildNumber: String? {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String
    }
}
