import AppKit
import Foundation
import Network
import QuartzCore
import StreamProtocol

/// Where the picture goes: the stream window's display layer, or the headless check's decoder. Called
/// on the session's network queue, in order.
protocol FrameSink: AnyObject {
    func apply(_ sets: ParameterSets)
    func enqueue(_ frame: Data, isKeyframe: Bool)
    func clear()
}

/// One session with one Mac (docs/mac-client.md, "How it works"): a pinned TLS connection with
/// `sill/1`, this Mac's hello first, then the Mac's catalog and stream, and this Mac's picks, viewport
/// and input, on the wire the iPhone and iPad app speaks (StreamMessage.swift). Kept to what a Mac
/// client needs now: no moves between paths (a lost session ends, and the window offers to reconnect),
/// no menus mirror (the Mac's menus are not mirrored yet); three- and four-finger gestures as kind 28.
///
/// Published state on the main thread; the connection, the reader, pings, the frame sink and input
/// on `queue`.
final class StreamSession: ObservableObject {
    enum Phase: Equatable {
        case idle
        case connecting(String)
        /// At the first window list: the Mac has admitted this key.
        case connected
        /// The session ended, with the words to show; `reconnect` when trying again makes sense.
        case ended(String, reconnect: Bool)
    }

    struct Stats: Equatable {
        var fps = 0
        var frameAgeMs: Int?
        var rttMs: Int?
        var mbps: Double = 0
    }

    /// A session's target: a Bonjour row of the home door, or the saved Mac's addresses (the remote
    /// door: Tailscale, a VPN, a forwarded port; or a typed home-door address).
    enum Target {
        case home(NWEndpoint)
        case addresses([RemoteDialPolicy.Candidate])
    }

    @Published private(set) var phase: Phase = .idle
    @Published private(set) var macName = ""
    @Published private(set) var windows: [WindowInfo] = []
    @Published private(set) var active: StreamSource = .none
    @Published private(set) var apps: [AppInfo] = []
    @Published private(set) var thumbnails: [UInt32: NSImage] = [:]
    @Published private(set) var icons: [String: NSImage] = [:]
    @Published private(set) var cursor: NSCursor?
    @Published private(set) var stats = Stats()
    @Published private(set) var hostVersion: String?
    /// `WindowList.gestures`: 1 or more when the Mac takes kind 28's trackpad gestures.
    private(set) var hostGestures: Int?
    @Published private(set) var route = ""
    @Published private(set) var frameSize: CGSize = .zero
    /// The Mac's streaming settings as it last told this connection (kind 16); nil from a Mac that
    /// sends none, which then has no Quality menu here.
    @Published private(set) var hostSettings: HostSettingsState?
    /// The Mac's own displays (kind 40's list) and the one its Desktop shows; empty from a Mac that
    /// takes no kind 40 (Sill.app from Noah's releases), whose Desktop is its main display.
    @Published private(set) var displays: [DisplayInfo] = []
    @Published private(set) var desktopDisplay: UInt32?
    /// fn-Esc: this Mac's keyboard, pointer and scrolling stay here until the picture is clicked or
    /// fn-Esc comes again (StreamNSView). Nothing goes to the Mac meanwhile.
    @Published var released = false

    let macID: String
    private let pin: Data
    private let identity: RemoteIdentity
    private weak var store: SavedMacStore?

    let queue = DispatchQueue(label: "sill.client.session", qos: .userInteractive)
    /// On `queue`.
    weak var sink: FrameSink?
    /// The live connection, on `queue`.
    private var connection: NWConnection?
    private var reader: MessageReader?
    private var dials: [NWConnection] = []
    private var goodbye: Goodbye?
    private var lastReceivedAt = 0.0
    private var ping: DispatchSourceTimer?
    private var frameAges: [Double] = []
    private var rtts: [Double] = []
    private var frames = 0
    private var bytes = 0
    private var lastViewport: Viewport?
    private var pendingMove: InputEvent?
    private var lastMoveAt = 0.0
    private var moveFlushScheduled = false
    private var listed = false
    private var lastAutoDesktop = Date.distantPast
    private var ended = false

    /// Session events for the headless check and the log, on `queue`.
    var onEvent: ((String) -> Void)?

    init(macID: String, pin: Data, identity: RemoteIdentity, store: SavedMacStore?, name: String) {
        self.macID = macID
        self.pin = pin
        self.identity = identity
        self.store = store
        self.macName = name
    }

    // MARK: Connecting

    /// Starts the session. A list of addresses is dialed as the iOS client dials a saved Mac from afar
    /// (RemoteConnector): in RemoteDialPolicy's order, a new attempt every second or as soon as one
    /// fails, the first pinned connection to be ready wins and the others are cancelled.
    func start(_ target: Target) {
        phase = .connecting(macName)
        queue.async { [self] in
            switch target {
            case .home(let endpoint):
                undialed = 0
                dial(endpoint, remote: false, via: "your network")
            case .addresses(let candidates):
                guard !candidates.isEmpty else {
                    endOnQueue("\(macName) has no address to reach it by. Pair it at home with Remote Access on, or add its Tailscale address.", reconnect: false)
                    return
                }
                undialed = candidates.count
                for (i, c) in candidates.enumerated() {
                    queue.asyncAfter(deadline: .now() + Double(i) * RemoteDialPolicy.stagger) { [self] in
                        undialed -= 1
                        guard connection == nil, !ended else { return }
                        let endpoint = NWEndpoint.hostPort(host: NWEndpoint.Host(c.host), port: NWEndpoint.Port(integerLiteral: UInt16(c.port)))
                        let via = c.via.isEmpty ? c.display : "\(c.via) (\(c.display))"
                        dial(endpoint, remote: c.kind != MacAddress.lan || RemoteDialPolicy.isVPNAddress(c.host), via: via)
                    }
                }
            }
            queue.asyncAfter(deadline: .now() + RemoteDialPolicy.wholeDial) { [self] in
                guard !listed, !ended else { return }
                if let goodbye {
                    let (words, again) = GoodbyeWords.ending(goodbye, mac: macName)
                    endOnQueue(words, reconnect: again)
                } else {
                    let why = lastDialError.map { " (\($0))" } ?? ""
                    endOnQueue("\(macName) didn't answer\(why). Check that Sill is running there, and for Tailscale that Remote Access is on.", reconnect: true)
                }
            }
        }
    }

    /// On `queue`.
    private func dial(_ endpoint: NWEndpoint, remote: Bool, via: String) {
        let params = ClientTLS.parameters(identity: identity, alpn: RemoteTLS.sessionALPN, pin: pin, queue: queue, remote: remote,
                                          onPinRefused: { [weak self] in self?.onEvent?("pin refused at \(via)") })
        let c = NWConnection(to: endpoint, using: params)
        dials.append(c)
        c.stateUpdateHandler = { [weak self, weak c] state in
            guard let self, let c else { return }
            switch state {
            case .ready: self.won(c, via: via)
            case .failed(let e):
                self.onEvent?("dial \(via) failed: \(e)")
                self.dialEnded(c, error: e)
            case .waiting(let e):
                // Waiting before ready (refused, no route, a pin refused) ends that attempt: the
                // next address goes at once, as RemoteConnector's do. Once the connection is the
                // session's, waiting means its path is gone.
                self.onEvent?("dial \(via) waiting: \(e)")
                self.dialEnded(c, error: e)
            case .cancelled:
                if c === self.connection { self.lost(error: nil) }
            default: break
            }
        }
        c.start(queue: queue)
    }

    private func dialEnded(_ c: NWConnection, error: NWError) {
        c.cancel()
        dials.removeAll { $0 === c }
        if c === connection { lost(error: error); return }
        guard connection == nil, !ended else { return }
        lastDialError = error
        // Every attempt failed and none is still to start: the dial is over now, with the most
        // telling words (a refused pin says it is another Mac), not at the whole-dial timeout.
        if dials.isEmpty, undialed == 0 { lost(error: error) }
    }
    private var lastDialError: NWError?
    /// Candidates whose attempt has not started yet. On `queue`.
    private var undialed = 0

    /// The first ready connection: the session's. On `queue`.
    private func won(_ c: NWConnection, via: String) {
        guard connection == nil, !ended else {
            if c !== connection { c.cancel() }
            return
        }
        connection = c
        for other in dials where other !== c { other.cancel() }
        dials = [c]
        lastReceivedAt = ProcessInfo.processInfo.systemUptime
        onEvent?("connected through \(via)")
        let routeText = via
        DispatchQueue.main.async { self.route = routeText }
        // The hello first, before anything else on this connection (Compatibility.swift).
        let hello = Hello(appVersion: ClientTLS.appVersion, build: ClientTLS.buildNumber, protocol: SillProtocol.current,
                          device: ClientTLS.deviceLabel)
        sendNow(.hello, Wire.encode(hello))
        if let v = lastViewport { sendNow(.viewport, Wire.encode(v)) }
        startPings(c)
        let reader = MessageReader(connection: c, stillReads: { [weak self, weak c] in
            guard let self, let c else { return false }
            return self.connection === c
        }, onBytes: { [weak self] n in
            self?.lastReceivedAt = ProcessInfo.processInfo.systemUptime
            self?.bytes += n
        }, onMessage: { [weak self] header, data in
            self?.handle(header, data)
        }, onEnd: { [weak self] end in
            guard let self else { return }
            switch end {
            case .closed(let e): self.lost(error: e)
            case .tooBig: self.lost(error: nil)
            }
        })
        self.reader = reader
        reader.start()
        queue.asyncAfter(deadline: .now() + RemoteDialPolicy.firstListDeadline) { [weak self, weak c] in
            guard let self, let c, self.connection === c, !self.listed else { return }
            self.endOnQueue("\(self.macName) let the connection in but sent nothing. Is this Mac paired with it?", reconnect: true)
        }
    }

    /// The connection ended. On `queue`.
    private func lost(error: NWError?) {
        guard !ended else { return }
        var words: String
        var reconnect = true
        if let goodbye {
            (words, reconnect) = GoodbyeWords.ending(goodbye, mac: macName)
        } else if let error, let s = RemoteTLS.status(of: error), s == -9825 || s == -9829 {
            words = "\(macName) doesn't accept this Mac's key any more. Pair again."
            reconnect = false
        } else if let error, RemoteTLS.status(of: error) == -9808 {
            words = "The Mac that answered isn't \(macName) (another key)."
            reconnect = false
        } else if !listed {
            words = "\(macName) didn't let this Mac in."
        } else {
            words = "The connection to \(macName) ended."
        }
        endOnQueue(words, reconnect: reconnect)
    }

    private func endOnQueue(_ words: String, reconnect: Bool) {
        guard !ended else { return }
        ended = true
        ping?.cancel(); ping = nil
        let c = connection
        connection = nil
        c?.cancel()
        for d in dials { d.cancel() }
        dials = []
        sink?.clear()
        onEvent?("ended: \(words)")
        DispatchQueue.main.async { self.phase = .ended(words, reconnect: reconnect) }
    }

    /// This Mac leaves: the session ends with no words of the Mac's. Any thread.
    func disconnect() {
        queue.async { self.endOnQueue("Disconnected.", reconnect: true) }
    }

    // MARK: Pings and statistics

    private func startPings(_ c: NWConnection) {
        let t = DispatchSource.makeTimerSource(queue: queue)
        var tick = 0
        t.schedule(deadline: .now() + 0.25, repeating: 0.25, leeway: .milliseconds(5))
        t.setEventHandler { [weak self] in
            guard let self, self.connection === c else { return }
            var payload = Data()
            var bits = CACurrentMediaTime().bitPattern.bigEndian
            withUnsafeBytes(of: &bits) { payload.append(contentsOf: $0) }
            self.sendNow(.ping, payload)
            // Liveness: no byte for 6 s (or four times the worst round trip) is a lost session.
            let silence = ProcessInfo.processInfo.systemUptime - self.lastReceivedAt
            let limit = max(6.0, 4 * (self.rtts.max() ?? 0) / 1000)
            if silence > limit {
                self.onEvent?("silent for \(Int(silence)) s")
                self.lost(error: nil)
                return
            }
            tick += 1
            if tick % 4 == 0 { self.closeSecond() }
        }
        ping = t
        t.resume()
    }

    /// One second's statistics, to the window and to the Mac (ClientStats, which its log shows).
    private func closeSecond() {
        func median(_ xs: [Double]) -> Int? { xs.isEmpty ? nil : Int(xs.sorted()[xs.count / 2].rounded()) }
        let s = Stats(fps: frames, frameAgeMs: median(frameAges), rttMs: median(rtts), mbps: Double(bytes) * 8 / 1_000_000)
        let report = ClientStats(fps: frames, frameAgeMs: s.frameAgeMs ?? -1, rttMs: s.rttMs ?? -1, device: ClientTLS.deviceLabel,
                                 frameAgeMaxMs: frameAges.max().map { Int($0.rounded()) } ?? -1,
                                 rttMaxMs: rtts.max().map { Int($0.rounded()) } ?? -1)
        if listed { sendNow(.clientStats, Wire.encode(report)) }
        frames = 0; bytes = 0; frameAges = []; rtts = []
        DispatchQueue.main.async { if self.stats != s { self.stats = s } }
    }

    // MARK: Host → client

    private func handle(_ header: StreamHeader, _ data: Data) {
        switch header.kind {
        case .parameterSets:
            if let ps = ParameterSets(encoded: data) { sink?.apply(ps) }
        case .frame:
            let age = (Date().timeIntervalSince1970 - header.timestamp) * 1000
            if age.isFinite { frameAges.append(min(max(age, 0), 86_400_000)) }
            frames += 1
            sink?.enqueue(data, isKeyframe: header.isKeyframe)
        case .windowList:
            guard let list = Wire.decode(WindowList.self, from: data) else { return }
            let first = !listed
            listed = true
            if first { onEvent?("first window list: \(list.windows.count) windows, host \(list.hostVersion ?? "without a version")") }
            DispatchQueue.main.async {
                if first {
                    self.phase = .connected
                    self.store?.update(self.macID) { $0.lastConnectedAt = Date() }
                }
                self.hostVersion = list.hostVersion
                self.hostGestures = list.gestures
                if !list.macName.isEmpty { self.macName = list.macName }
                self.windows = list.windows
                self.active = list.active
                self.displays = list.displays ?? []
                self.desktopDisplay = list.desktopDisplay
                let live = Set(list.windows.map(\.id))
                self.thumbnails = self.thumbnails.filter { live.contains($0.key) }
                // Start on the Desktop, never an empty window, as the iOS client does; at most every
                // 10 s, so a Mac that cannot start the Desktop is not asked in a loop.
                if list.active == .none, Date().timeIntervalSince(self.lastAutoDesktop) > 10 {
                    self.lastAutoDesktop = Date()
                    self.select(.desktop)
                }
            }
        case .thumbnail:
            guard let (id, jpeg) = ImageBlob.decodeThumbnail(data), let image = NSImage(data: jpeg) else { return }
            DispatchQueue.main.async { self.thumbnails[id] = image }
        case .appIcon:
            guard let (bundleID, png) = ImageBlob.decodeIcon(data), let image = NSImage(data: png) else { return }
            DispatchQueue.main.async { self.icons[bundleID] = image }
        case .appList:
            guard let apps = Wire.decode([AppInfo].self, from: data) else { return }
            DispatchQueue.main.async { self.apps = apps.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending } }
        case .cursorShape:
            guard let (hotspot, size, png) = CursorShapeBlob.decode(data), let image = NSImage(data: png) else { return }
            image.size = size   // the PNG is the 2× representation; the cursor is drawn at its point size
            let cursor = NSCursor(image: image, hotSpot: hotspot)
            DispatchQueue.main.async { self.cursor = cursor }
        case .pong:
            guard data.count >= 8 else { return }
            var raw: UInt64 = 0
            _ = withUnsafeMutableBytes(of: &raw) { data.prefix(8).copyBytes(to: $0) }
            let rtt = (CACurrentMediaTime() - Double(bitPattern: UInt64(bigEndian: raw))) * 1000
            if rtt.isFinite, rtt >= 0 { rtts.append(min(rtt, 86_400_000)) }
        case .macInfo:
            // Only a kind 18 signed by the key this session pinned speaks for this Mac: its name,
            // remote port and addresses for afar (SavedMacs.refreshed).
            guard let signed = Wire.decode(SignedMacInfo.self, from: data), let v = signed.verified(), v.fingerprint == pin else { return }
            DispatchQueue.main.async { self.store?.refresh(self.macID, info: v.info, fingerprint: v.fingerprint) }
        case .goodbye:
            goodbye = Wire.decode(Goodbye.self, from: data) ?? Goodbye(reason: "")
        case .hostSettings:
            guard let state = Wire.decode(HostSettingsState.self, from: data) else { return }
            if let link = state.link, link.isBehind {
                onEvent?("link: behind at \(link.bitrate / 1_000_000) Mbps, carried \(link.carriedKbps.map { "\($0) kbps" } ?? "unmeasured")")
            }
            DispatchQueue.main.async { if self.hostSettings != state { self.hostSettings = state } }
        default:
            break   // ticks, settings, the Mac's pointer and menus, and kinds a newer host adds
        }
    }

    /// Records the frame's size for input mapping; called by the sink on `queue`.
    func noteFrameSize(_ size: CGSize) {
        DispatchQueue.main.async { if self.frameSize != size { self.frameSize = size } }
    }

    // MARK: Client → host

    /// Any thread. Sent in order on `queue`; nothing before the connection is the session's.
    func send(_ kind: StreamMessageKind, _ payload: Data) {
        queue.async { self.sendNow(kind, payload) }
    }

    private func sendNow(_ kind: StreamMessageKind, _ payload: Data) {
        guard let c = connection else { return }
        let m = StreamMessage(kind: kind, timestamp: Date().timeIntervalSince1970, isKeyframe: false, payload: payload)
        c.send(content: m.serialized(), completion: .contentProcessed { _ in })
    }

    /// One control's change to the Mac's settings (kind 17): absolute values, a token strictly
    /// increasing for this process. The Mac answers with a kind 16 to this connection alone; a value
    /// it refuses comes back unchanged. Only the Mac menu's own values are ever sent
    /// (SettingsChoices), and only fields the Mac reported.
    func changeSettings(_ change: HostSettingsChange) {
        var c = change
        StreamSession.settingsToken += 1
        c.token = StreamSession.settingsToken
        send(.changeSettings, Wire.encode(c))
    }

    private static var settingsToken = 0

    /// Shows `display` as the Desktop (kind 40, only to a Mac that lists its displays), and the
    /// Desktop if something else streams.
    func pickDisplay(_ display: UInt32) {
        guard displays.contains(where: { $0.id == display }) else { return }
        send(.pickDisplay, Wire.encode(PickDisplay(display: display)))
        if active != .desktop { select(.desktop) }
    }

    /// A three- or four-finger gesture from this Mac's trackpad (main thread), as the iOS client
    /// sends it: only to a Mac that takes gestures, and the Desktop first while a window streams, so
    /// Mission Control and the rest show in the picture. False when nothing was sent.
    func sendGesture(_ name: String, fingers: Int) -> Bool {
        guard (hostGestures ?? 0) >= TrackpadGesture.generation else { return false }
        if case .window = active { select(.desktop) }
        let payload = Wire.encode(TrackpadGesture(gesture: name, fingers: fingers))
        queue.async { [self] in
            flushMove()
            sendNow(.gesture, payload)
        }
        return true
    }

    func select(_ source: StreamSource) {
        send(.selectSource, Wire.encode(source))
    }

    func launch(_ bundleID: String) {
        send(.launchApp, Wire.encode(LaunchApp(bundleID: bundleID)))
    }

    func command(_ action: WindowCommand.Action, window: UInt32) {
        send(.windowCommand, Wire.encode(WindowCommand(id: window, action: action)))
    }

    /// The stream view's size (Viewport.swift) and this screen's rate. Sent again only when it changes.
    ///
    /// The rate asked for is 60 unless ClientPrefs.wantsFullRate (ProMotion's 120 doubles the
    /// stream's bitrate and the Mac's encoding for little gain on a desktop).
    func setViewport(width: Double, height: Double, screenFPS: Int) {
        let v = Viewport(width: width, height: height, scale: nil, localCursor: true, fps: ClientPrefs.rate(screenFPS: screenFPS))
        queue.async {
            guard v != self.lastViewport else { return }
            self.lastViewport = v
            self.sendNow(.viewport, Wire.encode(v))
        }
    }

    /// Input, in order. Pointer moves are coalesced to at most one every 8 ms (125 Hz), as the iOS
    /// client sends them; any other input first sends the move still waiting.
    func input(_ event: InputEvent) {
        queue.async { [self] in
            guard case .pointer(.move, _, _) = event else {
                flushMove()
                sendNow(.input, Wire.encode(event))
                return
            }
            let now = CACurrentMediaTime()
            if now >= lastMoveAt + 0.008 {
                pendingMove = nil
                lastMoveAt = now
                sendNow(.input, Wire.encode(event))
            } else {
                pendingMove = event
                if !moveFlushScheduled {
                    moveFlushScheduled = true
                    queue.asyncAfter(deadline: .now() + (lastMoveAt + 0.008 - now)) { [self] in
                        moveFlushScheduled = false
                        flushMove()
                    }
                }
            }
        }
    }

    private func flushMove() {
        guard let move = pendingMove else { return }
        pendingMove = nil
        lastMoveAt = CACurrentMediaTime()
        sendNow(.input, Wire.encode(move))
    }
}

/// How a session's end reads (the iOS client's GoodbyePolicy, kept to its words).
enum GoodbyeWords {
    static func ending(_ g: Goodbye, mac: String) -> (String, Bool) {
        switch g.reason {
        case Goodbye.quit: return ("\(mac) quit Sill.", true)
        case Goodbye.removed: return ("\(mac) removed this Mac. Pair again to connect.", false)
        case Goodbye.remoteOff: return ("Remote Access is off on \(mac).", false)
        case Goodbye.internetOff: return ("\(mac) doesn't take connections from the internet.", false)
        case Goodbye.busy: return ("\(mac) has as many devices connected as it takes.", true)
        case Goodbye.pairingRequired: return ("\(mac) now asks devices to pair. Pair this Mac to connect.", false)
        default:
            let words = SafeText.label(g.message ?? "", limit: 300)
            return (words.isEmpty ? "\(mac) ended the session." : words, g.reconnect ?? false)
        }
    }
}
