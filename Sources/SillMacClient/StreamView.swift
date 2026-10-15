import AppKit
import Combine
import StreamProtocol
import SwiftUI

/// The Mac's picture, and this Mac's mouse, trackpad and keyboard going to it (docs/mac-client.md,
/// "Pointer and scrolling", "Keys"). The picture is aspect-fit (StreamGeometry); every point of it
/// goes as a fraction of the frame. This Mac's own pointer stays visible over the picture, in the
/// shape of the Mac's cursor (kind 14), since the Mac leaves its pointer out of the video.
///
/// Keys go to the Mac while this view is the first responder of the key window: ⌘ shortcuts too,
/// except those with ⌃⌥⌘ held together, which stay this app's (Disconnect is ⌃⌥⌘D). The ones macOS
/// keeps for itself (⌘Tab, Spotlight, Mission Control, Spaces, screenshots) go too while
/// SystemShortcuts captures them (Accessibility granted, and Send System Shortcuts on).
final class StreamNSView: NSView {
    let sink = DisplayLayerSink()
    weak var session: StreamSession?
    private var forwarded = ForwardedKeys()
    /// Modifiers this view pressed on the Mac around a click (shift: ForwardedKeys never sends shift
    /// as a key, since it changes typed text, so a shift-click holds it around the click itself).
    private var clickModifiers: KeyModifiers = []
    private var keyMonitor: Any?
    private var cursorWatch: AnyCancellable?
    private var frameSize: CGSize = .zero
    private var resignObserver: NSObjectProtocol?
    private var focusObservers: [NSObjectProtocol] = []

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer = CALayer()
        layer?.backgroundColor = NSColor.black.cgColor
        layer?.addSublayer(sink.layer)
        sink.onSize = { [weak self] size in
            DispatchQueue.main.async {
                guard let self else { return }
                self.frameSize = size
                self.window?.invalidateCursorRects(for: self)
            }
        }
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    func attach(_ session: StreamSession) {
        guard self.session !== session else { return }
        self.session = session
        session.queue.async { session.sink = self.sink }
        cursorWatch = session.$cursor.sink { [weak self] _ in
            guard let self else { return }
            self.window?.invalidateCursorRects(for: self)
        }
        sendViewport()
    }

    override func layout() {
        super.layout()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        sink.layer.frame = bounds
        CATransaction.commit()
        sendViewport()
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        window?.acceptsMouseMovedEvents = true
        window?.makeFirstResponder(self)
        if let resignObserver { NotificationCenter.default.removeObserver(resignObserver) }
        resignObserver = window.map { w in
            // The keyboard going elsewhere (another app, another window): nothing stays held down on
            // the Mac.
            NotificationCenter.default.addObserver(forName: NSWindow.didResignKeyNotification, object: w, queue: .main) { [weak self] _ in
                self?.releaseKeys()
            }
        }
        installKeyMonitor()
        watchFocus()
        sendViewport()
    }

    override func removeFromSuperview() {
        SystemShortcuts.shared.stop()
        focusObservers.forEach(NotificationCenter.default.removeObserver)
        focusObservers = []
        releaseKeys()
        if let keyMonitor { NSEvent.removeMonitor(keyMonitor) }
        keyMonitor = nil
        super.removeFromSuperview()
    }

    private func sendViewport() {
        guard let session, bounds.width > 0 else { return }
        let size = StreamGeometry.viewportSize(bounds.size)
        session.setViewport(width: size.width, height: size.height, screenFPS: window?.screen?.maximumFramesPerSecond ?? 60)
    }

    private var picture: CGRect { StreamGeometry.pictureRect(frame: frameSize, in: bounds) }

    private func fraction(_ event: NSEvent) -> (x: Double, y: Double)? {
        StreamGeometry.fraction(of: convert(event.locationInWindow, from: nil), picture: picture, flipped: true)
    }

    // MARK: The pointer

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: .zero, options: [.mouseMoved, .activeInKeyWindow, .inVisibleRect, .cursorUpdate],
                                       owner: self, userInfo: nil))
    }

    override func resetCursorRects() {
        addCursorRect(picture, cursor: released ? .arrow : (session?.cursor ?? .arrow))
    }

    override func cursorUpdate(with event: NSEvent) {
        let p = convert(event.locationInWindow, from: nil)
        (!released && StreamGeometry.isOnPicture(p, picture: picture) ? (session?.cursor ?? .arrow) : .arrow).set()
    }

    /// fn-Esc gave this Mac its own input back (StreamSession.released).
    private var released: Bool { session?.released ?? false }

    private func pointer(_ action: PointerAction, _ event: NSEvent) {
        guard !released, let f = fraction(event) else { return }
        session?.input(.pointer(action, x: f.x, y: f.y))
    }

    override func mouseMoved(with event: NSEvent) { pointer(.move, event) }
    override func mouseDragged(with event: NSEvent) { pointer(.move, event) }
    override func rightMouseDragged(with event: NSEvent) { pointer(.move, event) }

    override func mouseDown(with event: NSEvent) {
        window?.makeFirstResponder(self)
        if released { setReleased(false); return }   // the click that takes control back goes nowhere
        holdClickModifiers(event)
        pointer(.leftDown, event)
    }

    override func mouseUp(with event: NSEvent) {
        pointer(.leftUp, event)
        releaseClickModifiers()
    }

    override func rightMouseDown(with event: NSEvent) {
        window?.makeFirstResponder(self)
        if released { setReleased(false); return }
        holdClickModifiers(event)
        pointer(.rightDown, event)
    }

    override func rightMouseUp(with event: NSEvent) {
        pointer(.rightUp, event)
        releaseClickModifiers()
    }

    /// A shift-click: shift's own key down on the Mac around the click (KeyChord.modifiersDown), as
    /// the iOS trackpad holds a latched modifier around one. ⌘, ⌃ and ⌥ are down on the Mac already:
    /// their own keys went as keys.
    private func holdClickModifiers(_ event: NSEvent) {
        releaseClickModifiers()
        guard event.modifierFlags.contains(.shift) else { return }
        clickModifiers = .shift
        KeyChord.modifiersDown(clickModifiers).forEach { session?.input($0) }
    }

    private func releaseClickModifiers() {
        guard !clickModifiers.isEmpty else { return }
        KeyChord.modifiersUp(clickModifiers).forEach { session?.input($0) }
        clickModifiers = []
    }

    // MARK: Scrolling

    override func scrollWheel(with event: NSEvent) {
        guard !released, let f = fraction(event) else { return }
        // A trackpad's gesture: its phases, so the Mac rubber-bands and coasts as with its own
        // trackpad (Input.swift's scrollGesture). This Mac makes the momentum itself and its deltas
        // go as they come, between momentumBegan and momentumEnded.
        if event.phase.contains(.began) { session?.input(.scrollGesture(.began, x: f.x, y: f.y)) }
        if event.momentumPhase.contains(.began) { session?.input(.scrollGesture(.momentumBegan, x: f.x, y: f.y)) }
        if event.scrollingDeltaX != 0 || event.scrollingDeltaY != 0,
           let d = StreamGeometry.scrollFraction(dx: Double(event.scrollingDeltaX), dy: Double(event.scrollingDeltaY),
                                                 precise: event.hasPreciseScrollingDeltas, picture: picture) {
            session?.input(.scroll(x: f.x, y: f.y, dx: d.dx, dy: d.dy))
        }
        if event.phase.contains(.ended) || event.phase.contains(.cancelled) {
            session?.input(.scrollGesture(.ended, x: f.x, y: f.y))
        }
        if event.momentumPhase.contains(.ended) || event.momentumPhase.contains(.cancelled) {
            session?.input(.scrollGesture(.momentumEnded, x: f.x, y: f.y))
        }
    }

    // MARK: Keys

    private static let localShortcut: NSEvent.ModifierFlags = [.control, .option, .command]

    /// Keys reach the Mac through a local monitor while this view leads the key window: NSView's
    /// keyDown never sees ⌘ shortcuts (the menu takes them) nor a key's up while ⌘ is held.
    private func installKeyMonitor() {
        if let keyMonitor { NSEvent.removeMonitor(keyMonitor) }
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .keyUp, .flagsChanged]) { [weak self] event in
            guard let self, let window = self.window, event.window === window, window.isKeyWindow,
                  self.session != nil else { return event }
            // fn-Esc while released takes control back (the picture also takes it on a click).
            if self.released {
                if Self.isReleaseChord(event) { self.window?.makeFirstResponder(self); self.setReleased(false); return nil }
                return event
            }
            guard window.firstResponder === self else { return event }
            if event.type == .keyDown,
               event.modifierFlags.intersection(.deviceIndependentFlagsMask).isSuperset(of: Self.localShortcut) {
                return event   // ⌃⌥⌘: this app's own
            }
            self.route(event)
            return nil
        }
    }

    /// fn-Esc (Globe-Esc): hand this Mac its keyboard, pointer and shortcuts back, or take them again.
    static func isReleaseChord(_ event: NSEvent) -> Bool {
        event.type == .keyDown && event.keyCode == 53 && event.modifierFlags.contains(.function)
    }

    /// Releases or takes control: every key and button the Mac holds for this view goes up first,
    /// and the system's shortcuts are this Mac's again while released.
    func setReleased(_ on: Bool) {
        guard let session, session.released != on else { return }
        releaseKeys()
        session.released = on
        window?.invalidateCursorRects(for: self)
        (on ? NSCursor.arrow : (session.cursor ?? .arrow)).set()
        // Not inside the tap's own callback, which fn-Esc arrives through while captured.
        DispatchQueue.main.async { self.updateCapture() }
    }

    private func route(_ event: NSEvent) {
        guard let session else { return }
        if Self.isReleaseChord(event) { setReleased(true); return }
        let flags = UInt64(event.modifierFlags.intersection(.deviceIndependentFlagsMask).rawValue)
        switch event.type {
        case .keyDown:
            switch MacKeys.down(keyCode: event.keyCode, modifiers: flags, characters: event.characters, forwarded: &forwarded) {
            case .key(let e): session.input(e)
            case .text(let t): session.input(.text(t))
            case .nothing: break
            }
        case .keyUp:
            if let e = MacKeys.up(keyCode: event.keyCode, forwarded: &forwarded) { session.input(e) }
        case .flagsChanged:
            MacKeys.modifierChanged(keyCode: event.keyCode, modifiers: flags, forwarded: &forwarded).forEach { session.input($0) }
        default: break
        }
    }

    /// Every key and click modifier this view holds down on the Mac goes up: the window losing the
    /// keyboard, the view leaving, the session ending.
    func releaseKeys() {
        releaseClickModifiers()
        forwarded.releaseAll().forEach { session?.input($0) }
    }

    override func resignFirstResponder() -> Bool {
        releaseKeys()
        defer { DispatchQueue.main.async { self.updateCapture() } }
        return super.resignFirstResponder()
    }

    override func becomeFirstResponder() -> Bool {
        defer { DispatchQueue.main.async { self.updateCapture() } }
        return super.becomeFirstResponder()
    }

    // MARK: The system's shortcuts

    /// True while keys typed now are this view's: the app in front, its window key, this view its
    /// first responder, a session to send them to.
    private var hasKeyboard: Bool {
        guard NSApp.isActive, let window, window.isKeyWindow, window.firstResponder === self, session != nil,
              !released else { return false }
        return true
    }

    /// The capture follows the keyboard: on while this view has it, off the moment it goes (another
    /// app, another window, a field in the bar), so ⌘Tab and the rest are this Mac's again.
    func updateCapture() {
        let capture = SystemShortcuts.shared
        if hasKeyboard, ClientPrefs.sendsSystemShortcuts {
            capture.onKey = { [weak self] event in
                guard let self, self.hasKeyboard else { return false }
                self.route(event)
                return true
            }
            capture.start()
        } else if capture.capturing {
            capture.stop()
        }
    }

    private func watchFocus() {
        focusObservers.forEach(NotificationCenter.default.removeObserver)
        let nc = NotificationCenter.default
        let names: [(Notification.Name, Any?)] = [
            (NSApplication.didBecomeActiveNotification, nil), (NSApplication.didResignActiveNotification, nil),
            (NSWindow.didBecomeKeyNotification, window), (NSWindow.didResignKeyNotification, window),
            (ClientPrefs.changed, nil),
        ]
        focusObservers = names.map { name, object in
            nc.addObserver(forName: name, object: object, queue: .main) { [weak self] _ in
                self?.updateCapture()
                if name == ClientPrefs.changed { self?.sendViewport() }
            }
        }
        updateCapture()
    }
}

/// SwiftUI's host for the stream view; the one view lives as long as its session.
struct StreamViewRepresentable: NSViewRepresentable {
    let session: StreamSession

    func makeNSView(context: Context) -> StreamNSView {
        let v = StreamNSView(frame: .zero)
        v.attach(session)
        return v
    }

    func updateNSView(_ view: StreamNSView, context: Context) {
        view.attach(session)
    }

    static func dismantleNSView(_ view: StreamNSView, coordinator: ()) {
        view.releaseKeys()
        view.session?.queue.async { view.session?.sink = nil }
    }
}
