import AppKit
import ApplicationServices
import Foundation

/// This client's own preferences (UserDefaults, domain me.saffer.sill.macclient).
enum ClientPrefs {
    private static let d = UserDefaults.standard
    /// Posted on the main thread after a preference changes.
    static let changed = Notification.Name("SillClientPrefsChanged")

    /// Ask the Mac for this screen's full rate (120 on a ProMotion MacBook Pro). Off by default: the
    /// stream's bitrate doubles at 120 fps (it is per 60 fps) and the Mac's encoder works twice as
    /// hard, for motion few desktop apps have.
    static var wantsFullRate: Bool {
        get { d.bool(forKey: "wantsFullRate") }
        set { d.set(newValue, forKey: "wantsFullRate"); NotificationCenter.default.post(name: changed, object: nil) }
    }

    /// Send the shortcuts macOS keeps for itself (⌘Tab, Spotlight, Mission Control, Spaces,
    /// screenshots) to the Mac while the picture has the keyboard. On by default; it needs
    /// Accessibility for this app.
    static var sendsSystemShortcuts: Bool {
        get { d.object(forKey: "sendsSystemShortcuts") as? Bool ?? true }
        set { d.set(newValue, forKey: "sendsSystemShortcuts"); NotificationCenter.default.post(name: changed, object: nil) }
    }

    /// Send three- and four-finger trackpad gestures (Mission Control, Spaces, App Exposé, Apps,
    /// Show Desktop) to the Mac while the picture has the keyboard. On by default; it rides on the
    /// same capture as the system shortcuts, so it needs Accessibility too.
    static var sendsTrackpadGestures: Bool {
        get { d.object(forKey: "sendsTrackpadGestures") as? Bool ?? true }
        set { d.set(newValue, forKey: "sendsTrackpadGestures"); NotificationCenter.default.post(name: changed, object: nil) }
    }

    /// The rate this client asks for on a screen that can show `screenFPS`.
    static func rate(screenFPS: Int) -> Int {
        let screen = max(1, screenFPS)
        return wantsFullRate ? screen : min(60, screen)
    }
}

/// While the picture has the keyboard, every key reaches the Mac, the ones macOS acts on before any
/// app sees them included (ClientPrefs.sendsSystemShortcuts):
/// - a keyboard event tap at the head of this session's tap point sees each key first and swallows
///   it, handing it to the stream view as an NSEvent (needs Accessibility: without it the tap
///   cannot be made, and keys go through the stream view's local monitor as before);
/// - the system's own shortcuts that WindowServer matches before any tap (⌘Tab, ⌘`, Spotlight,
///   Mission Control, Spaces, screenshots: "symbolic hot keys") are turned off for as long as the
///   capture lasts, through SkyLight's private setter, and turned back on when it ends. The ones
///   turned off are written to UserDefaults first, so a crash or a kill leaves them for the next
///   launch to turn back on (`restoreLeftovers`).
///
/// ⌃⌥⌘ chords always stay this app's (Disconnect ⌃⌥⌘D, Full Screen ⌃⌥⌘F). Leaving the app by the
/// mouse (another window, the Dock) ends the capture.
final class SystemShortcuts {
    static let shared = SystemShortcuts()

    /// Called on the main thread with each key the tap took; returns false to let it through.
    var onKey: ((NSEvent) -> Bool)?
    private(set) var capturing = false
    private var tap: CFMachPort?
    private var source: CFRunLoopSource?

    // MARK: Permission

    static var trusted: Bool { AXIsProcessTrusted() }

    /// Shows macOS's Accessibility prompt (once; after that it opens nothing) and System Settings.
    static func askForAccess() {
        _ = AXIsProcessTrustedWithOptions(["AXTrustedCheckOptionPrompt": true] as CFDictionary)
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") {
            NSWorkspace.shared.open(url)
        }
    }

    // MARK: Capture

    /// Starts the capture; false when the tap could not be made (no Accessibility).
    @discardableResult
    func start() -> Bool {
        if capturing { return true }
        guard ClientPrefs.sendsSystemShortcuts || ClientPrefs.sendsTrackpadGestures, Self.trusted else { return false }
        let types: [CGEventType] = [.keyDown, .keyUp, .flagsChanged]
        var mask = types.reduce(CGEventMask(0)) { $0 | (CGEventMask(1) << CGEventMask($1.rawValue)) }
        // The trackpad's gestures (TrackpadGestureCapture): NSEvent's gesture events (29) and the
        // Dock's control events (30), which have no CGEventType case.
        mask |= CGEventMask(1) << CGEventMask(TrackpadGestureCapture.gestureType)
        mask |= CGEventMask(1) << CGEventMask(TrackpadGestureCapture.dockControlType)
        guard let tap = CGEvent.tapCreate(tap: .cgSessionEventTap, place: .headInsertEventTap, options: .defaultTap,
                                          eventsOfInterest: mask, callback: tapCallback,
                                          userInfo: Unmanaged.passUnretained(self).toOpaque()) else {
            return false
        }
        self.tap = tap
        source = CFMachPortCreateRunLoopSource(nil, tap, 0)
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
        if ClientPrefs.sendsSystemShortcuts { HotKeys.disable() }
        TrackpadGestureCapture.shared.reset()
        capturing = true
        return true
    }

    /// Ends the capture: the tap gone, the system's shortcuts back on. Safe to call at any time.
    func stop() {
        if let tap { CGEvent.tapEnable(tap: tap, enable: false); CFMachPortInvalidate(tap) }
        if let source { CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .commonModes) }
        tap = nil; source = nil
        HotKeys.restore()
        TrackpadGestureCapture.shared.reset()
        capturing = false
    }

    fileprivate func handle(_ type: CGEventType, _ event: CGEvent) -> Unmanaged<CGEvent>? {
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            if let tap { CGEvent.tapEnable(tap: tap, enable: true) }
            return Unmanaged.passUnretained(event)
        }
        guard capturing else { return Unmanaged.passUnretained(event) }
        let raw = type.rawValue
        if raw == TrackpadGestureCapture.gestureType || raw == TrackpadGestureCapture.dockControlType {
            return TrackpadGestureCapture.shared.handle(rawType: raw, event)
        }
        guard ClientPrefs.sendsSystemShortcuts, let ns = NSEvent(cgEvent: event) else { return Unmanaged.passUnretained(event) }
        if type == .keyDown, ns.modifierFlags.intersection(.deviceIndependentFlagsMask).isSuperset(of: [.control, .option, .command]) {
            return Unmanaged.passUnretained(event)   // ⌃⌥⌘: this app's own
        }
        return onKey?(ns) == true ? nil : Unmanaged.passUnretained(event)
    }

    /// At launch and at the end: the shortcuts a capture turned off and never turned back on (a crash,
    /// a kill) are turned back on.
    static func restoreLeftovers() { HotKeys.restore() }
}

private func tapCallback(proxy: CGEventTapProxy, type: CGEventType, event: CGEvent,
                         refcon: UnsafeMutableRawPointer?) -> Unmanaged<CGEvent>? {
    guard let refcon else { return Unmanaged.passUnretained(event) }
    let me = Unmanaged<SystemShortcuts>.fromOpaque(refcon).takeUnretainedValue()
    // The tap's source is on the main run loop, so this runs on the main thread.
    return me.handle(type, event)
}

/// The system's symbolic hot keys, through SkyLight's private getter and setter (the host reads the
/// same table in SymbolicHotKeys.swift). Only the ones on are turned off, and only those are turned
/// back on.
enum HotKeys {
    /// ⌘Tab, ⌘⇧Tab, ⌘`; the screenshots (⌘⇧3, ⌃⌘⇧3, ⌘⇧4, ⌃⌘⇧4, ⌘⇧5); Mission Control, App windows
    /// and Show Desktop (and their slow variants); Spotlight and Finder search; the input source keys;
    /// Spaces left and right; Desktop 1 to 9.
    static let ids: [Int32] = [1, 2, 6, 28, 29, 30, 31, 184, 32, 33, 34, 35, 36, 37, 64, 65, 60, 61,
                               79, 80, 81, 82, 118, 119, 120, 121, 122, 123, 124, 125, 126]
    private static let key = "hotKeysTurnedOff"

    private typealias IsEnabled = @convention(c) (Int32) -> Bool
    private typealias SetEnabled = @convention(c) (Int32, Bool) -> Int32

    private static let handle: UnsafeMutableRawPointer? = dlopen("/System/Library/PrivateFrameworks/SkyLight.framework/SkyLight", RTLD_LAZY)
    private static let isEnabled: IsEnabled? = symbol("CGSIsSymbolicHotKeyEnabled")
    private static let setEnabled: SetEnabled? = symbol("CGSSetSymbolicHotKeyEnabled")

    private static func symbol<T>(_ name: String) -> T? {
        guard let p = dlsym(handle ?? UnsafeMutableRawPointer(bitPattern: -2), name) else { return nil }
        return unsafeBitCast(p, to: T.self)
    }

    static func disable() {
        guard let isEnabled, let setEnabled else { return }
        var off = UserDefaults.standard.array(forKey: key) as? [Int] ?? []
        for id in ids where isEnabled(id) {
            off.append(Int(id))
            // Written before each change, so a crash leaves the record of what to turn back on.
            UserDefaults.standard.set(off, forKey: key)
            _ = setEnabled(id, false)
        }
    }

    static func restore() {
        guard let setEnabled else { return }
        let off = UserDefaults.standard.array(forKey: key) as? [Int] ?? []
        for id in Set(off) { _ = setEnabled(Int32(id), true) }
        UserDefaults.standard.removeObject(forKey: key)
    }
}
