import AppKit
import CoreGraphics
import Foundation

/// The MacBook's own three- and four-finger trackpad gestures, sent to the other Mac as kind 28
/// (Gesture.swift) while the picture has control, as the system's shortcuts are (SystemShortcuts):
/// a swipe up, down, left or right, a pinch or a spread, which the other Mac turns into Mission
/// Control, App Exposé, a Space to either side, Apps or Show Desktop (its GestureChords).
///
/// The fingers come from the gesture events (NSEvent type `.gesture`, 29) that SystemShortcuts' tap
/// sees at the head of this session: each carries the touches on the trackpad, normalized 0…1
/// (origin bottom left). While the capture runs, those with three fingers or more are swallowed, and
/// so are the Dock's swipe events (a gesture event whose HID type is the dock swipe, 23, and the
/// Dock control events, 30), so this Mac's Dock should not act on them too. That part rests on
/// private event fields and is unverified on a real trackpad: if this Mac still switches Spaces or
/// opens Mission Control as well, turn those gestures off in System Settings › Trackpad › More
/// Gestures while using the client.
struct MacGestureRecognizer {
    /// The trackpad's width over its height (a MacBook's is about 1.6), so a distance in y counts as
    /// much as the same distance in x.
    var aspect: CGFloat = 1.6
    /// The fingers' travel, in trackpad widths, that makes a swipe.
    var swipeTravel: CGFloat = 0.10
    /// How much more one axis must move than the other.
    var dominance: CGFloat = 1.3

    private var armed = false
    private var decided = false
    private var fingers = 0
    private var count = 0
    private var startCentroid = CGPoint.zero
    private var startSpread: CGFloat = 0
    private var travel = CGVector.zero          // carried across a finger added mid-stroke
    private var spreadScale: CGFloat = 1
    private var lastCentroid = CGPoint.zero
    private var lastSpread: CGFloat = 0

    /// True while a stroke of three fingers or more is under way (or decided and not yet lifted):
    /// its events are swallowed.
    var inStroke: Bool { armed || decided }

    /// One gesture event's touching fingers, normalized. Returns a gesture's name the moment the
    /// stroke is decided (the first lift that leaves fewer than three), with its fingers.
    mutating func feed(_ touches: [CGPoint]) -> (name: String, fingers: Int)? {
        let pts = touches.map { CGPoint(x: $0.x, y: $0.y / aspect) }
        defer { count = pts.count }
        if pts.isEmpty {
            let wasArmed = armed
            let outcome = wasArmed ? decide() : nil
            reset()
            return outcome
        }
        if decided { return nil }
        let c = Self.centroid(pts), s = Self.spread(pts, around: c)
        if !armed {
            guard pts.count >= 3 else { return nil }
            armed = true
            fingers = pts.count
            startCentroid = c; startSpread = s
            travel = .zero; spreadScale = 1
            lastCentroid = c; lastSpread = s
            return nil
        }
        if pts.count < 3 {
            // The first lift decides, on where the fingers were before it.
            let outcome = decide()
            decided = true
            armed = false
            return outcome
        }
        if pts.count != count {
            // A finger added or one of four lifted: the centroid jumps, so measure on from here.
            travel.dx += lastCentroid.x - startCentroid.x
            travel.dy += lastCentroid.y - startCentroid.y
            if startSpread > 0 { spreadScale *= lastSpread / startSpread }
            startCentroid = c; startSpread = s
            fingers = max(fingers, pts.count)
        }
        lastCentroid = c; lastSpread = s
        return nil
    }

    private func decide() -> (name: String, fingers: Int)? {
        let dx = travel.dx + lastCentroid.x - startCentroid.x
        let dy = travel.dy + lastCentroid.y - startCentroid.y
        let ratio = startSpread > 0 ? spreadScale * lastSpread / startSpread : 1
        let spreadDelta = abs(lastSpread - startSpread)
        let n = min(fingers, 4)
        let ax = abs(dx), ay = abs(dy), moved = max(ax, ay)
        if moved >= swipeTravel, moved >= 1.5 * spreadDelta {
            if ax >= dominance * ay { return (dx < 0 ? TrackpadGesture.swipeLeft : TrackpadGesture.swipeRight, n) }
            if ay >= dominance * ax { return (dy > 0 ? TrackpadGesture.swipeUp : TrackpadGesture.swipeDown, n) }
            return nil
        }
        if ratio <= 0.7 { return (TrackpadGesture.pinch, n) }
        if ratio >= 1.4 { return (TrackpadGesture.spread, n) }
        return nil
    }

    private mutating func reset() {
        armed = false; decided = false; fingers = 0
        travel = .zero; spreadScale = 1
    }

    static func centroid(_ p: [CGPoint]) -> CGPoint {
        let n = CGFloat(p.count)
        return CGPoint(x: p.reduce(0) { $0 + $1.x } / n, y: p.reduce(0) { $0 + $1.y } / n)
    }

    static func spread(_ p: [CGPoint], around c: CGPoint) -> CGFloat {
        p.reduce(0) { $0 + hypot($1.x - c.x, $1.y - c.y) } / CGFloat(p.count)
    }
}

/// The tap's side of the gestures (main thread: the tap's source is on the main run loop).
final class TrackpadGestureCapture {
    static let shared = TrackpadGestureCapture()

    /// Raw CGEventType values: NSEvent's gesture (touches), and 30, which is both NSEvent's magnify
    /// and the Dock's control events.
    static let gestureType: UInt32 = 29
    static let dockControlType: UInt32 = 30
    /// Private fields: the gesture's HID event type, and its value for the Dock's swipes.
    private static let hidTypeField = CGEventField(rawValue: 110)!
    private static let dockSwipe: Int64 = 23

    /// Called with each recognized gesture; true when it went to the Mac.
    var onGesture: ((String, Int) -> Bool)?
    private var recognizer = MacGestureRecognizer()
    private(set) var dockEventsSeen = 0

    /// One event from the tap; nil swallows it.
    func handle(rawType: UInt32, _ event: CGEvent) -> Unmanaged<CGEvent>? {
        guard ClientPrefs.sendsTrackpadGestures else { return Unmanaged.passUnretained(event) }
        if rawType == Self.dockControlType {
            dockEventsSeen += 1
            return nil
        }
        guard rawType == Self.gestureType else { return Unmanaged.passUnretained(event) }
        let isDockSwipe = event.getIntegerValueField(Self.hidTypeField) == Self.dockSwipe
        if isDockSwipe { dockEventsSeen += 1 }
        var points: [CGPoint] = []
        if let ns = NSEvent(cgEvent: event) {
            points = ns.touches(matching: .touching, in: nil).map { $0.normalizedPosition }
        }
        let before = recognizer.inStroke
        if let (name, fingers) = recognizer.feed(points) {
            let sent = onGesture?(name, fingers) ?? false
            NSLog("Sill gestures: %@ with %d fingers%@ (Dock events swallowed so far: %d)",
                  name, fingers, sent ? "" : ", not sent (the Mac does not take gestures)", dockEventsSeen)
        }
        if isDockSwipe || before || recognizer.inStroke || points.count >= 3 { return nil }
        return Unmanaged.passUnretained(event)
    }

    /// The capture ended mid-stroke: forget it.
    func reset() { recognizer = MacGestureRecognizer() }
}
