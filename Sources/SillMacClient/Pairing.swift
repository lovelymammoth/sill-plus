import Foundation
import Network
import CryptoKit
import StreamProtocol

/// One pairing exchange with a Mac (docs/remote-access-plan.md §3.5–3.6, docs/home-pairing-plan.md
/// §3.1), as the iOS client makes it: a `sill-pair/1` connection, exactly one kind 19 from this Mac
/// and one kind 20 back, then the Mac closes it. Methods:
/// - "code": the 12 digits the Mac's pairing window shows. The key is PBKDF2 of the code salted with
///   the Mac's key *as this connection saw it*, so the proof binds that key; any P-256 key is taken
///   (`pin` nil), and a relay presenting its own key makes the Mac reject the proof.
/// - "qr": a `sill://pair?…` link (copied from the Mac, or another device's QR): pinned to the link's
///   key, the proof made with the link's secret.
/// - "ask", home door only: "pair me": the Mac answers "shown" (its window shows a code now; type
///   it), "openOnMac", "locked", or pairs at once on the USB cable (never this client).
/// - "cancel", home door only: this Mac no longer needs the code its ask put up.
/// Nothing is saved unless the Mac's own proof checks against the same key and both keys of this
/// very session, and its Mac ID is its key's.
final class PairingExchange {
    enum Method {
        case code(String)
        case link(PairLink)
        case ask
        case cancel
    }

    enum Outcome {
        /// Paired: the record to save (no addresses yet: the caller adds what it knows).
        case paired(SavedMac)
        /// Kind 20 not ok: the Mac's reason ("shown" for an ask).
        case answered(PairResult)
        /// No answer, a broken one, or a proof that did not check: the words say which.
        case failed(String)
    }

    private let queue = DispatchQueue(label: "sill.client.pairing")
    private var connection: NWConnection?
    private var finished = false
    private var completion: ((Outcome) -> Void)?

    /// Runs the exchange against `endpoint` (a Bonjour row, or a host and port: the home door's or the
    /// remote door's). `completion` on the main thread, once.
    func run(endpoint: NWEndpoint, remote: Bool, identity: RemoteIdentity, method: Method,
             completion: @escaping (Outcome) -> Void) {
        self.completion = completion
        var pin: Data?
        if case .link(let link) = method { pin = link.fingerprint }
        let params = ClientTLS.parameters(identity: identity, alpn: RemoteTLS.pairingALPN, pin: pin, queue: queue,
                                          remote: remote, onPinRefused: { [weak self] in
            self?.finish(.failed("The Mac that answered is not the one in the link (its key is different)."))
        })
        let c = NWConnection(to: endpoint, using: params)
        connection = c
        c.stateUpdateHandler = { [weak self] state in
            guard let self else { return }
            switch state {
            case .ready: self.ready(c, identity: identity, method: method)
            case .failed(let e): self.finish(.failed(Self.words(for: e)))
            case .waiting(let e):
                if RemoteTLS.status(of: e) != nil { self.finish(.failed(Self.words(for: e))) }
            default: break
            }
        }
        c.start(queue: queue)
        queue.asyncAfter(deadline: .now() + 20) { [weak self] in
            self?.finish(.failed("The Mac didn't answer. Check that Sill is running on it and that this Mac can reach it."))
        }
    }

    func cancel() { queue.async { self.finish(.failed("Cancelled.")) } }

    private func finish(_ outcome: Outcome) {
        // Called on `queue`.
        guard !finished else { return }
        finished = true
        connection?.cancel()
        let completion = self.completion
        self.completion = nil
        DispatchQueue.main.async { completion?(outcome) }
    }

    private func ready(_ c: NWConnection, identity: RemoteIdentity, method: Method) {
        guard let fpMac = RemoteTLS.peerFingerprint(c) else {
            finish(.failed("The Mac's key is not one Sill uses."))
            return
        }
        let fpDevice = identity.fingerprint
        let wire: String
        var makeKey: (() -> SymmetricKey?)?
        switch method {
        case .code(let code):
            wire = PairRequest.code
            makeKey = { PairingProof.codeKey(code: code, macFingerprint: fpMac) }
        case .link(let link):
            wire = PairRequest.qr
            makeKey = { PairingProof.qrKey(secret: link.secret) }
        case .ask: wire = PairRequest.ask
        case .cancel: wire = PairRequest.cancel
        }
        let send: (SymmetricKey?) -> Void = { [weak self] key in
            guard let self, !self.finished else { return }
            let proof = key.map { Base64URL.encode(PairingProof.deviceProof(key: $0, deviceFingerprint: fpDevice, macFingerprint: fpMac)) } ?? ""
            let request = PairRequest(method: wire, proof: proof, name: ClientTLS.deviceName, model: ClientTLS.model)
            let message = StreamMessage(kind: .pairRequest, timestamp: Date().timeIntervalSince1970, isKeyframe: false,
                                        payload: Wire.encode(request))
            c.send(content: message.serialized(), completion: .contentProcessed { _ in })
            self.readAnswer(c, key: key, fpMac: fpMac, fpDevice: fpDevice)
        }
        guard let makeKey else { send(nil); return }
        // The typed path's PBKDF2 (600,000 rounds) takes ~100 ms: off this queue.
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let key = makeKey()
            self?.queue.async {
                guard let key else { self?.finish(.failed("That code isn't 12 digits.")); return }
                send(key)
            }
        }
    }

    private func readAnswer(_ c: NWConnection, key: SymmetricKey?, fpMac: Data, fpDevice: Data) {
        c.receive(minimumIncompleteLength: StreamMessage.headerLength, maximumLength: StreamMessage.headerLength) { [weak self] data, _, _, error in
            guard let self else { return }
            guard let data, let header = StreamMessage.parseHeader(data), header.kind == .pairResult,
                  header.payloadLength > 0, header.payloadLength <= StreamMessage.maxPairingPayload else {
                self.finish(.failed(error.map(Self.words(for:)) ?? "The Mac closed the pairing without an answer. Open its pairing window and try again."))
                return
            }
            c.receive(minimumIncompleteLength: header.payloadLength, maximumLength: header.payloadLength) { data, _, _, error in
                guard let data, let result = Wire.decode(PairResult.self, from: data) else {
                    self.finish(.failed(error.map(Self.words(for:)) ?? "The Mac's answer could not be read."))
                    return
                }
                guard result.ok else { self.finish(.answered(result)); return }
                guard let key, let proofM = result.proof.flatMap(Base64URL.decode),
                      PairingProof.isValidMacProof(proofM, key: key, macFingerprint: fpMac, deviceFingerprint: fpDevice),
                      let macID = result.macID, macID == MacID.make(fingerprint: fpMac),
                      let recognition = result.recognitionKey, Base64URL.decode(recognition)?.count == 32 else {
                    // An ok without a proof is only ever the USB cable's, to an ask that claimed it,
                    // which this client never does.
                    self.finish(.failed("The Mac's answer did not prove it knows the code. Nothing was saved."))
                    return
                }
                let name = SafeText.label(result.name ?? "Mac")
                let mac = SavedMac(macID: macID, fingerprint: Base64URL.encode(fpMac), name: name.isEmpty ? "Mac" : name,
                                   recognitionKey: recognition, remotePort: ClientTLS.defaultRemotePort, addresses: [],
                                   typedAddresses: nil, infoIssuedAt: 0, bonjourName: nil, lastWorked: nil, pairedAt: Date(),
                                   method: "code", lastConnectedAt: nil, lastRoute: nil)
                self.finish(.paired(mac))
            }
        }
    }

    /// A refused pairing's words (the iOS client's, StreamClient+Remote's `problem`).
    static func words(for r: PairResult, mac: String) -> String {
        if let words = r.unknownReasonMessage { return words }
        switch r.reason {
        case PairResult.code?:
            let left = max(0, r.triesLeft ?? 0)
            return left > 0 ? "That code didn't match. \(left) \(left == 1 ? "try" : "tries") left." : "That code didn't match, and the Mac takes no more tries. Open its pairing window again."
        case PairResult.expired?: return "That code has expired. Show a new one on \(mac)."
        case PairResult.stopped?: return "\(mac) closed its pairing window."
        case PairResult.shown?: return "\(mac) is showing a code now. Type it here."
        case PairResult.openOnMac?: return "On \(mac), choose Pair iPhone or iPad… from Sill's menu, then type the code it shows."
        case PairResult.locked?: return "Unlock \(mac), then try again."
        case PairResult.busy?:
            if let after = r.retryAfter { return "\(mac) is busy. Try again in \(Int(after.rounded(.up))) s." }
            return "\(mac) is busy. Try again in a moment."
        default: return "\(mac) isn't taking pairings now. Open its pairing window (Pair iPhone or iPad… in Sill's menu)."
        }
    }

    static func words(for e: NWError) -> String {
        if let s = RemoteTLS.status(of: e) {
            switch s {
            case -9808: return "The Mac that answered presented a different key."
            case -9825, -9829: return "The Mac refused this Mac's key."
            default: return "The secure connection failed (TLS \(s)). Is this Sill for Mac 0.4 or later?"
            }
        }
        switch e {
        case .posix(.ECONNREFUSED): return "Nothing answers at that address and port. For Tailscale, turn on Remote Access in Sill's settings on the Mac."
        case .posix(.ETIMEDOUT): return "The Mac didn't answer in time."
        case .dns: return "That name could not be found. For a Tailscale name, check that Tailscale is on."
        default: return "The connection failed (\(e))."
        }
    }
}
