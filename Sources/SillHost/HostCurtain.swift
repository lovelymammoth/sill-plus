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
/// Off the moment the last device leaves, the setting goes off, or Sill quits.
@MainActor
final class HostCurtain {
    private(set) var engaged = false
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
        update(devices: devices)
    }

    /// The number of connected devices changed.
    func update(devices: Int) {
        let want = enabled && devices > 0
        if want && !engaged { engage() } else if !want && engaged { release() }
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

    /// Sill quitting: everything back now rather than at the process's end.
    func releaseForQuit() {
        if engaged { release() }
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
