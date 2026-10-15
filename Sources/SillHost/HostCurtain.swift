import AppKit
import CoreGraphics
import Foundation

/// Hide this Mac's screens while a device is connected (HostConfig.hideScreens; fork of Sill, the
/// Mac client's "locked" host, as Screens' curtain mode does it):
///
/// - Every physical display's gamma table goes to black (CGSetDisplayTransferByTable). The table
///   applies at the display's output, after the framebuffer that ScreenCaptureKit reads, so the
///   stream is unchanged while the monitors show nothing (measured 2026-10-15 on the Mac mini: a
///   capture taken with both monitors at zero gamma read a mean byte value of 150, not 0). No window
///   covers anything, so no app is occluded and stops drawing (a covered window freezes, CLAUDE.md).
///   Sill's own virtual displays are left alone (no monitor). macOS resets gamma when a display is
///   reconfigured (Sill's own virtual display coming and going does that), so the tables are set
///   again after every reconfiguration while hidden. CoreGraphics puts every table back when this
///   process ends, crash included.
/// - This Mac's own keyboard and mouse are ignored meanwhile: an event tap at the head of the
///   session swallows every key, click, move and scroll that this process did not post. The
///   device's input, which InputInjector posts from this process, passes. Needs Accessibility, which
///   Sill already has for input; without it only the screens go dark. The tap goes with the process.
///
/// Off the moment the last device leaves, the setting goes off, or Sill quits; with `lockOnLeave`,
/// the last device's leaving instead keeps everything dark for `lockGrace` seconds (a device that
/// comes back meanwhile finds the Mac as it left it), then locks the Mac and only then shows the
/// screens, so a dropped session never leaves an unlocked Mac for whoever is in the room. Sill
/// quitting while hidden locks at once. Turning the setting off from a device shows the screens
/// unlocked: that is the device's own choice.
///
/// A locked Mac cannot be unlocked through Sill (measured 2026-10-15 on the Mac mini, macOS 27.0.1):
/// while the session is locked ScreenCaptureKit finds nothing to capture (SCStreamError -3815,
/// "Failed to find any displays or windows to capture"), so a device sees no picture and sends no
/// input. Unlock it at the Mac, or remotely with macOS Screen Sharing (which shows the lock
/// screen), and Sill streams again.
@MainActor
package final class HostCurtain {
    /// How long a Mac stays dark and ignores its own input after the last device leaves, before it
    /// locks and shows its screens.
    package static let lockGrace: TimeInterval = 10
    private(set) var engaged = false
    /// HostConfig.lockOnLeave.
    var lockOnLeave = false
    private var lockTask: Task<Void, Never>?
    private var devices = 0
    private var enabled: Bool
    private var tap: CFMachPort?
    private var tapSource: CFRunLoopSource?
    private var watching = false
    /// Only under the AppKit loop (Sill.app, the CLI with --virtual-display): a tap is served by the
    /// main run loop, which `dispatchMain` never runs, and an unserved tap holds up every event.
    private let canBlockInput: Bool

    init(enabled: Bool, canBlockInput: Bool) {
        self.enabled = enabled
        self.canBlockInput = canBlockInput
    }

    /// The setting changed: applied at once while a device is connected.
    func setEnabled(_ on: Bool, devices: Int) {
        guard on != enabled else { return }
        enabled = on
        if !on { cancelLock() }
        update(devices: devices)
    }

    /// The number of connected devices changed.
    func update(devices: Int) {
        self.devices = devices
        if devices > 0, lockTask != nil {
            cancelLock()
            print("A device is back before the lock: this Mac stays hidden, and unlocked.")
        }
        let want = enabled && devices > 0
        if want && !engaged { engage(); return }
        guard !want, engaged else { return }
        if enabled && lockOnLeave {
            guard lockTask == nil else { return }
            print("Last device left: this Mac locks in \(Int(Self.lockGrace)) s unless one reconnects; its screens stay dark until then.")
            lockTask = Task { @MainActor [weak self] in
                try? await Task.sleep(nanoseconds: UInt64(Self.lockGrace * 1_000_000_000))
                guard let self, !Task.isCancelled, self.lockTask != nil else { return }
                self.lockTask = nil
                await self.lockThenRelease()
            }
        } else {
            release()
        }
    }

    private func cancelLock() {
        lockTask?.cancel()
        lockTask = nil
    }

    /// Locks the Mac, waits (up to 3 s) until the session reads locked, then shows the screens.
    /// A lock that never takes still shows them, with a line saying so: a Mac left dark with its
    /// own input ignored and nobody connected would be stuck for whoever is at it.
    private func lockThenRelease() async {
        let how = Self.lockScreen()
        var locked = false
        for _ in 0..<30 {
            if Self.sessionLocked() { locked = true; break }
            try? await Task.sleep(nanoseconds: 100_000_000)
        }
        // A device that connected while the lock was taking keeps the screens hidden (locked now).
        guard engaged, devices == 0 else { return }
        if locked {
            try? await Task.sleep(nanoseconds: 300_000_000)   // the lock screen drawn before the gamma comes back
            print("Locked this Mac (\(how)): no device for \(Int(Self.lockGrace)) s.")
        } else {
            print("Could not lock this Mac (\(how); the session never read locked); its screens are shown anyway.")
        }
        release()
    }

    /// The session's own lock (login.framework's SACLockScreenImmediate, what the Lock Screen menu
    /// item calls); without it, the Lock Screen shortcut ⌃⌘Q posted from this process (which the
    /// tap lets through).
    private static func lockScreen() -> String {
        typealias Lock = @convention(c) () -> Int32
        if let h = dlopen("/System/Library/PrivateFrameworks/login.framework/Versions/Current/login", RTLD_LAZY),
           let sym = dlsym(h, "SACLockScreenImmediate") {
            let r = unsafeBitCast(sym, to: Lock.self)()
            return "SACLockScreenImmediate \(r)"
        }
        let src = CGEventSource(stateID: .hidSystemState)
        for down in [true, false] {
            guard let e = CGEvent(keyboardEventSource: src, virtualKey: 12, keyDown: down) else { continue }   // Q
            e.flags = [.maskControl, .maskCommand]
            e.setIntegerValueField(.eventSourceUserData, value: sillDeviceEventMark)
            e.post(tap: .cghidEventTap)
        }
        return "the Lock Screen shortcut"
    }

    static func sessionLocked() -> Bool {
        guard let d = CGSessionCopyCurrentDictionary() as? [String: Any] else { return false }
        if let b = d["CGSSessionScreenIsLocked"] as? Bool { return b }
        return (d["CGSSessionScreenIsLocked"] as? Int) == 1
    }

    private func engage() {
        engaged = true
        blackOut()
        if !watching {
            watching = true
            CGDisplayRegisterReconfigurationCallback({ _, flags, _ in
                guard !flags.contains(.beginConfigurationFlag) else { return }
                Task { @MainActor in HostCurtain.current?.reapply() }
            }, nil)
        }
        HostCurtain.current = self
        if canBlockInput { startTap() }
        print("Screens hidden while a device is connected: \(Self.physicalDisplays().count) display(s) dark, this Mac's own keyboard and mouse \(tap != nil ? "ignored" : "still working (no Accessibility)").")
    }

    private func release() {
        engaged = false
        stopTap()
        CGDisplayRestoreColorSyncSettings()
        print("Screens shown again: no device connected.")
    }

    /// Sill quitting: everything back now rather than at the process's end, locked first when
    /// locking is on (whether a device is still connected or the grace is running).
    func releaseForQuit() {
        cancelLock()
        guard engaged else { return }
        if enabled && lockOnLeave {
            let how = Self.lockScreen()
            let deadline = Date().addingTimeInterval(2)
            while !Self.sessionLocked() && Date() < deadline { usleep(50_000) }
            print(Self.sessionLocked() ? "Locked this Mac (\(how)): Sill is quitting." : "Could not lock this Mac as Sill quit (\(how)).")
        }
        release()
    }

    fileprivate static weak var current: HostCurtain?

    fileprivate func reapply() {
        guard engaged else { return }
        blackOut()
    }

    private func blackOut() {
        let zero = [CGGammaValue](repeating: 0, count: 256)
        for d in Self.physicalDisplays() {
            _ = CGSetDisplayTransferByTable(d, UInt32(zero.count), zero, zero, zero)
        }
    }

    /// Online displays that are not Sill's own virtual ones.
    static func physicalDisplays() -> [CGDirectDisplayID] {
        var ids = [CGDirectDisplayID](repeating: 0, count: 32)
        var count: UInt32 = 0
        guard CGGetOnlineDisplayList(32, &ids, &count) == .success else { return [] }
        return ids.prefix(Int(count)).filter { !StreamCoordinator.isSillVirtualDisplay($0) }
    }

    // MARK: This Mac's own input

    private func startTap() {
        guard tap == nil else { return }
        let types: [CGEventType] = [.keyDown, .keyUp, .flagsChanged, .leftMouseDown, .leftMouseUp, .rightMouseDown,
                                    .rightMouseUp, .otherMouseDown, .otherMouseUp, .mouseMoved, .leftMouseDragged,
                                    .rightMouseDragged, .otherMouseDragged, .scrollWheel]
        let mask = types.reduce(CGEventMask(0)) { $0 | (CGEventMask(1) << CGEventMask($1.rawValue)) }
        guard let t = CGEvent.tapCreate(tap: .cgSessionEventTap, place: .headInsertEventTap, options: .defaultTap,
                                        eventsOfInterest: mask, callback: curtainTapCallback, userInfo: nil) else { return }
        tap = t
        tapSource = CFMachPortCreateRunLoopSource(nil, t, 0)
        CFRunLoopAddSource(CFRunLoopGetMain(), tapSource, .commonModes)
        CGEvent.tapEnable(tap: t, enable: true)
        curtainTapPort = t
    }

    private func stopTap() {
        if let tap { CGEvent.tapEnable(tap: tap, enable: false); CFMachPortInvalidate(tap) }
        if let tapSource { CFRunLoopRemoveSource(CFRunLoopGetMain(), tapSource, .commonModes) }
        tap = nil; tapSource = nil
        curtainTapPort = nil
    }
}

/// The tap, for its callback to turn back on (read and written on the main thread only).
nonisolated(unsafe) private var curtainTapPort: CFMachPort?
private let curtainOwnPID = Int64(getpid())

/// Lets through what this process posted (the device's input) and nothing else.
private func curtainTapCallback(proxy: CGEventTapProxy, type: CGEventType, event: CGEvent,
                                refcon: UnsafeMutableRawPointer?) -> Unmanaged<CGEvent>? {
    if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
        if let port = curtainTapPort { CGEvent.tapEnable(tap: port, enable: true) }
        return Unmanaged.passUnretained(event)
    }
    if event.getIntegerValueField(.eventSourceUserData) == sillDeviceEventMark
        || event.getIntegerValueField(.eventSourceUnixProcessID) == curtainOwnPID {
        return Unmanaged.passUnretained(event)
    }
    return nil
}
