import Foundation
import CoreGraphics

// The Mac client's keys and geometry (docs/mac-client.md, "Keys", "Pointer and scrolling"):
// - MacKeys.hidUsages is exactly the host's KeyStrokes.virtualKeys read backwards, key for key, so
//   every key this client sends lands on the same key of the Mac it streams;
// - which keys go as keys (ForwardedKeys, the iOS client's rule) and which as text, and the text;
// - the modifier keys' flags-changed, left and right sharing one bit;
// - through the host's own KeyStrokes, typical sessions (⌘S, ⌘⇧Z, ⌥←, both ⌘ keys, a held ⌘ at the
//   window's resign) leave no key down and no modifier in the Mac's HID state table;
// - StreamGeometry: the aspect-fit picture, a point as fractions of the frame, scrolls, the viewport.
//
// Compiled with Sources/StreamProtocol, Sources/SillHost/KeyStrokes.swift, iOSClient/KeyChords.swift,
// Sources/SillMacClient/MacKeys.swift and StreamGeometry.swift as one module (module.txt).

var failures = 0, checks = 0
func check(_ ok: Bool, _ what: @autoclosure () -> String, line: Int = #line) {
    checks += 1
    if !ok { failures += 1; print("FAIL (line \(line)): \(what())") }
}

let cmd = KeyModifiers.command.rawValue, shift = KeyModifiers.shift.rawValue
let opt = KeyModifiers.option.rawValue, ctrl = KeyModifiers.control.rawValue
/// NSEvent.ModifierFlags' capsLock (1 << 16) and function (1 << 23) and numericPad (1 << 21): never on the wire.
let capsLock: UInt64 = 1 << 16, function: UInt64 = 1 << 23, numericPad: UInt64 = 1 << 21

// MARK: The table, against the host's

check(MacKeys.hidUsages.count == KeyStrokes.virtualKeys.count,
      "the client knows \(MacKeys.hidUsages.count) keys, the host \(KeyStrokes.virtualKeys.count)")
for (usage, vk) in KeyStrokes.virtualKeys {
    check(MacKeys.hidUsages[vk] == usage, "virtual key \(vk) should send usage \(usage), sends \(String(describing: MacKeys.hidUsages[vk]))")
}
for (vk, usage) in MacKeys.hidUsages {
    check(KeyStrokes.virtualKeys[usage] == vk, "usage \(usage) (from virtual key \(vk)) lands on virtual key \(String(describing: KeyStrokes.virtualKeys[usage]))")
}
check(Set(MacKeys.hidUsages.values).count == MacKeys.hidUsages.count, "two virtual keys send the same usage")

// MARK: Modifiers on the wire

check(MacKeys.wireModifiers(cmd | shift | opt | ctrl) == cmd | shift | opt | ctrl, "the four modifiers travel")
check(MacKeys.wireModifiers(capsLock | function | numericPad) == 0, "caps lock, fn and the keypad bit stay home")
check(MacKeys.wireModifiers(cmd | function) == cmd, "⌘ with fn sends ⌘ alone")

// MARK: Text

check(MacKeys.text(keyCode: 36, characters: "\r") == "\n", "return types \\n")
check(MacKeys.text(keyCode: 76, characters: "\u{3}") == "\n", "keypad enter types \\n")
check(MacKeys.text(keyCode: 48, characters: "\t") == "\t", "tab types \\t")
check(MacKeys.text(keyCode: 51, characters: "\u{7F}") == "\u{8}", "delete types backspace")
check(MacKeys.text(keyCode: 0, characters: "a") == "a", "a types a")
check(MacKeys.text(keyCode: 0, characters: "A") == "A", "shift-a types A")
check(MacKeys.text(keyCode: 14, characters: "é") == "é", "a composed é is typed as it is")
check(MacKeys.text(keyCode: 123, characters: "\u{F702}") == nil, "an arrow's private-use character types nothing")
check(MacKeys.text(keyCode: 122, characters: "\u{F704}") == nil, "F1's private-use character types nothing")
check(MacKeys.text(keyCode: 0, characters: "") == nil, "a dead key's first press types nothing")
check(MacKeys.text(keyCode: 0, characters: nil) == nil, "no characters types nothing")
check(MacKeys.text(keyCode: 0, characters: "\u{1B}") == nil, "a control character types nothing")
check(MacKeys.text(keyCode: 49, characters: " ") == " ", "space types a space")

// MARK: Keys or text

func down(_ vk: UInt16, _ mods: UInt64, _ chars: String?, _ f: inout ForwardedKeys) -> MacKeys.Down {
    MacKeys.down(keyCode: vk, modifiers: mods, characters: chars, forwarded: &f)
}

do {
    var f = ForwardedKeys()
    check(down(0, 0, "a", &f) == .text("a"), "a plain key goes as text")
    check(MacKeys.up(keyCode: 0, forwarded: &f) == nil, "its up sends nothing")
    check(down(0, shift, "A", &f) == .text("A"), "shift alone goes as text")
    check(MacKeys.up(keyCode: 0, forwarded: &f) == nil, "its up sends nothing")
    check(down(1, cmd, "s", &f) == .key(.key(hidUsage: 0x16, down: true, modifiers: cmd)), "⌘S goes as the S key with ⌘")
    check(MacKeys.up(keyCode: 1, forwarded: &f) == .key(hidUsage: 0x16, down: false, modifiers: 0), "⌘S's up follows, nothing held")
    check(down(6, cmd | shift, "z", &f) == .key(.key(hidUsage: 0x1D, down: true, modifiers: cmd | shift)), "⌘⇧Z carries both")
    _ = MacKeys.up(keyCode: 6, forwarded: &f)
    check(down(123, 0, "\u{F702}", &f) == .key(.key(hidUsage: 0x50, down: true, modifiers: 0)), "← goes as a key")
    check(MacKeys.up(keyCode: 123, forwarded: &f) == .key(hidUsage: 0x50, down: false, modifiers: 0), "←'s up follows")
    check(down(53, 0, "\u{1B}", &f) == .key(.key(hidUsage: 0x29, down: true, modifiers: 0)), "escape goes as a key")
    _ = MacKeys.up(keyCode: 53, forwarded: &f)
    check(down(117, 0, "\u{F728}", &f) == .key(.key(hidUsage: 0x4C, down: true, modifiers: 0)), "forward delete goes as a key")
    _ = MacKeys.up(keyCode: 117, forwarded: &f)
    check(down(51, 0, "\u{7F}", &f) == .text("\u{8}"), "delete goes as a backspace")
    check(down(36, 0, "\r", &f) == .text("\n"), "return goes as \\n")
    check(down(48, 0, "\t", &f) == .text("\t"), "tab goes as \\t")
    check(down(51, opt, "\u{7F}", &f) == .key(.key(hidUsage: 0x2A, down: true, modifiers: opt)), "⌥delete goes as a key (word delete)")
    _ = MacKeys.up(keyCode: 51, forwarded: &f)
    check(down(122, 0, "\u{F704}", &f) == .key(.key(hidUsage: 0x3A, down: true, modifiers: 0)), "F1 goes as a key")
    _ = MacKeys.up(keyCode: 122, forwarded: &f)
    check(down(0x48, 0, nil, &f) == .nothing, "a key with no usage and no text sends nothing (volume up)")
    check(down(0, capsLock, "A", &f) == .text("A"), "caps lock alone types text")
    check(f.down.isEmpty, "nothing is left down after every up: \(f.down)")
    // A key's up after its modifier went first still goes up as a key.
    check(down(8, cmd, "c", &f) == .key(.key(hidUsage: 0x06, down: true, modifiers: cmd)), "⌘C")
    check(MacKeys.up(keyCode: 8, forwarded: &f) == .key(hidUsage: 0x06, down: false, modifiers: 0), "C's up as a key, though ⌘ went first")
}

// MARK: The modifier keys

do {
    var f = ForwardedKeys()
    check(MacKeys.modifierChanged(keyCode: 55, modifiers: cmd, forwarded: &f) == [.key(hidUsage: 0xE3, down: true, modifiers: cmd)],
          "left ⌘ down: its own key, carrying ⌘ once it is down (as KeyChord.modifiersDown)")
    check(MacKeys.modifierChanged(keyCode: 55, modifiers: cmd, forwarded: &f) == [], "left ⌘ again while held: nothing more")
    check(MacKeys.modifierChanged(keyCode: 54, modifiers: cmd, forwarded: &f) == [.key(hidUsage: 0xE7, down: true, modifiers: cmd)],
          "right ⌘ down too")
    check(MacKeys.modifierChanged(keyCode: 55, modifiers: cmd, forwarded: &f) == [], "left ⌘ up while right holds the bit: nothing yet")
    check(MacKeys.modifierChanged(keyCode: 54, modifiers: 0, forwarded: &f)
          == [.key(hidUsage: 0xE3, down: false, modifiers: cmd), .key(hidUsage: 0xE7, down: false, modifiers: 0)],
          "the bit clears: both ⌘ keys go up")
    check(f.down.isEmpty, "nothing left down")
    check(MacKeys.modifierChanged(keyCode: 56, modifiers: shift, forwarded: &f) == [], "shift's own key never goes (it makes text)")
    check(MacKeys.modifierChanged(keyCode: 56, modifiers: 0, forwarded: &f) == [], "nor its up")
    check(MacKeys.modifierChanged(keyCode: 57, modifiers: capsLock, forwarded: &f) == [], "caps lock is no modifier key here")
    check(MacKeys.modifierChanged(keyCode: 58, modifiers: opt, forwarded: &f) == [.key(hidUsage: 0xE2, down: true, modifiers: opt)], "⌥ down")
    check(MacKeys.modifierChanged(keyCode: 59, modifiers: opt | ctrl, forwarded: &f) == [.key(hidUsage: 0xE0, down: true, modifiers: opt | ctrl)], "⌃ down with ⌥ held")
    check(MacKeys.modifierChanged(keyCode: 62, modifiers: opt, forwarded: &f) == [.key(hidUsage: 0xE0, down: false, modifiers: opt)],
          "right ⌃'s flags-changed with the ⌃ bit clear lets left ⌃ go")
    check(f.releaseAll() == [.key(hidUsage: 0xE2, down: false, modifiers: 0)], "letting go of everything: ⌥ up")
    check(MacKeys.siblings(0xE3) == [0xE3, 0xE7] && MacKeys.siblings(0xE7) == [0xE3, 0xE7]
          && MacKeys.siblings(0xE0) == [0xE0, 0xE4] && MacKeys.siblings(0xE6) == [0xE2, 0xE6], "siblings")
}

// MARK: Through the host's KeyStrokes: nothing left held

/// A keyboard's events (NSEvent's keyDown, keyUp and flagsChanged) through this client and then the
/// host's KeyStrokes, as InputInjector would post them; the HID table holds the last keyboard event's
/// flags (the key-strokes check's model).
enum Key { case down(UInt16, String?), up(UInt16), flags(UInt16) }

final class Session {
    var f = ForwardedKeys()
    var strokes = KeyStrokes()
    var table: UInt64 = 0
    var mods: UInt64 = 0      // what this Mac's own keyboard holds
    let me = ObjectIdentifier(NSObject())
    let modBits: [UInt16: UInt64] = [55: cmd, 54: cmd, 56: shift, 60: shift, 58: opt, 61: opt, 59: ctrl, 62: ctrl]
    var held: [UInt16: Bool] = [:]

    func send(_ e: InputEvent) {
        switch e {
        case .key(let usage, let isDown, let m):
            for s in strokes.key(usage: usage, down: isDown, modifiers: m, from: me) ?? [] { table = s.flags }
        case .text:
            for s in strokes.text(from: me) { table = s.flags }
            table = 0   // text goes out with no flags
        default: break
        }
    }

    func play(_ keys: [Key]) {
        for k in keys {
            switch k {
            case .down(let vk, let chars):
                switch MacKeys.down(keyCode: vk, modifiers: mods, characters: chars, forwarded: &f) {
                case .key(let e): send(e)
                case .text(let t): send(.text(t))
                case .nothing: break
                }
            case .up(let vk):
                if let e = MacKeys.up(keyCode: vk, forwarded: &f) { send(e) }
            case .flags(let vk):
                held[vk] = !(held[vk] ?? false)
                let bit = modBits[vk] ?? 0
                let anyHeld = held.contains { modBits[$0.key] == bit && $0.value }
                if anyHeld { mods |= bit } else { mods &= ~bit }
                for e in MacKeys.modifierChanged(keyCode: vk, modifiers: mods, forwarded: &f) { send(e) }
            }
        }
    }
}

func session(_ name: String, _ keys: [Key], resign: Bool = false) {
    let s = Session()
    s.play(keys)
    if resign { for e in s.f.releaseAll() { s.send(e) } }
    let bits = cmd | shift | opt | ctrl
    check(s.strokes.down.isEmpty, "\(name): keys left down on the Mac: \(s.strokes.down.keys.sorted())")
    check(s.table & bits == 0, "\(name): the Mac's HID table still holds \(String(s.table & bits, radix: 16))")
}

session("⌘S", [.flags(55), .down(1, "s"), .up(1), .flags(55)])
session("⌘ let go before S", [.flags(55), .down(1, "s"), .flags(55), .up(1)])
session("⌘⇧Z", [.flags(55), .flags(56), .down(6, "z"), .up(6), .flags(56), .flags(55)])
session("⌥←", [.flags(58), .down(123, "\u{F702}"), .up(123), .flags(58)])
session("both ⌘ keys", [.flags(55), .flags(54), .down(0, "a"), .up(0), .flags(55), .flags(54)])
session("typing with shift", [.down(4, "h"), .up(4), .flags(56), .down(14, "E"), .up(14), .flags(56), .down(37, "l"), .up(37)])
session("⌘ held when the window resigns", [.flags(55), .down(13, "w")], resign: true)
session("⌃⌥ held when the window resigns", [.flags(59), .flags(58)], resign: true)

// MARK: Geometry

let bounds = CGRect(x: 0, y: 0, width: 1000, height: 500)
let wide = StreamGeometry.pictureRect(frame: CGSize(width: 1600, height: 1000), in: bounds)
check(wide == CGRect(x: 100, y: 0, width: 800, height: 500), "16:10 in 2:1 is pillarboxed: \(wide)")
let tall = StreamGeometry.pictureRect(frame: CGSize(width: 2000, height: 500), in: bounds)
check(tall == CGRect(x: 0, y: 125, width: 1000, height: 250), "4:1 in 2:1 is letterboxed: \(tall)")
check(StreamGeometry.pictureRect(frame: .zero, in: bounds) == bounds, "no frame yet: the whole view")

func near(_ a: (x: Double, y: Double)?, _ x: Double, _ y: Double) -> Bool {
    guard let a else { return false }
    return abs(a.x - x) < 1e-9 && abs(a.y - y) < 1e-9
}
check(near(StreamGeometry.fraction(of: CGPoint(x: 500, y: 250), picture: wide, flipped: true), 0.5, 0.5), "the middle is 0.5, 0.5")
check(near(StreamGeometry.fraction(of: CGPoint(x: 100, y: 0), picture: wide, flipped: true), 0, 0), "flipped: the picture's top left is 0, 0")
check(near(StreamGeometry.fraction(of: CGPoint(x: 100, y: 0), picture: wide, flipped: false), 0, 1), "unflipped: y grows up, so the bottom left is 0, 1")
check(near(StreamGeometry.fraction(of: CGPoint(x: 300, y: 125), picture: wide, flipped: true), 0.25, 0.25), "a quarter in")
check(near(StreamGeometry.fraction(of: CGPoint(x: 50, y: 600), picture: wide, flipped: true), 0, 1), "off the picture: clamped to its edge")
check(near(StreamGeometry.fraction(of: CGPoint(x: 950, y: -10), picture: wide, flipped: true), 1, 0), "off the other edge")
check(StreamGeometry.fraction(of: .zero, picture: .zero, flipped: true) == nil, "no picture, no point")
check(StreamGeometry.isOnPicture(CGPoint(x: 50, y: 250), picture: wide) == false, "the bar beside the picture is not on it")
check(StreamGeometry.isOnPicture(CGPoint(x: 500, y: 250), picture: wide), "the middle is on it")

if let d = StreamGeometry.scrollFraction(dx: 8, dy: -50, precise: true, picture: wide) {
    check(abs(d.dx - 0.01) < 1e-12 && abs(d.dy + 0.1) < 1e-12, "precise deltas: points over the picture's size, sign kept: \(d)")
} else { check(false, "precise scroll gave nothing") }
if let d = StreamGeometry.scrollFraction(dx: 0, dy: 1, precise: false, picture: wide) {
    check(abs(d.dy - 12.0 / 500) < 1e-12 && d.dx == 0, "a wheel's line is 12 points: \(d)")
} else { check(false, "wheel scroll gave nothing") }
check(StreamGeometry.scrollFraction(dx: 1, dy: 1, precise: true, picture: .zero) == nil, "no picture, no scroll")

check(StreamGeometry.viewportSize(CGSize(width: 1099.6, height: 0.2)) == (1100, 1), "the viewport rounds, at least a point")

print(failures == 0 ? "mac-client-keys: all \(checks) checks passed" : "mac-client-keys: \(failures) of \(checks) checks FAILED")
exit(failures == 0 ? 0 : 1)
