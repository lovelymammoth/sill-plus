import Foundation
#if canImport(StreamProtocol)
import StreamProtocol
#endif

// A Mac keyboard's keys as a Sill device sends them (docs/mac-client.md, "Keys"). The wire carries a
// key as a USB HID usage with UIKeyModifierFlags bits (Input.swift); the host turns each usage back
// into a Mac virtual key with KeyStrokes.virtualKeys (Sources/SillHost/KeyStrokes.swift). So this is
// that table read backwards, a Mac virtual key (Carbon's kVK_*, NSEvent.keyCode) to the usage the
// host maps onto the same key: Tests/checks/mac-client-keys holds the two together, key for key.
//
// Which keys go as keys and which as text is the iOS client's rule (KeyChords.swift's ForwardedKeys,
// compiled into this target unchanged): the arrows, escape, the editing and function keys and the
// modifiers themselves always go as keys, and any key while ⌘, ⌃ or ⌥ is held (a shortcut); a key
// with no modifier or shift alone goes as the text it typed, so the keyboard layout, dead keys and
// input methods of the Mac in front of the user are the ones that count. Return, tab and delete go
// as text too ("\n", "\t", "\u{8}"), which the host delivers as those keys (Input.swift).
//
// Pure: Foundation (and StreamProtocol's InputEvent) only, checked with swiftc.

enum MacKeys {
    /// Mac virtual key → USB HID usage, exactly the inverse of the host's `KeyStrokes.virtualKeys`.
    static let hidUsages: [UInt16: UInt16] = [
        // Letters A…Z
        0: 0x04, 11: 0x05, 8: 0x06, 2: 0x07, 14: 0x08, 3: 0x09, 5: 0x0A, 4: 0x0B, 34: 0x0C,
        38: 0x0D, 40: 0x0E, 37: 0x0F, 46: 0x10, 45: 0x11, 31: 0x12, 35: 0x13, 12: 0x14,
        15: 0x15, 1: 0x16, 17: 0x17, 32: 0x18, 9: 0x19, 13: 0x1A, 7: 0x1B, 16: 0x1C, 6: 0x1D,
        // Digits 1…9, 0
        18: 0x1E, 19: 0x1F, 20: 0x20, 21: 0x21, 23: 0x22, 22: 0x23, 26: 0x24, 28: 0x25,
        25: 0x26, 29: 0x27,
        // Editing and punctuation
        36: 0x28,   // Return
        53: 0x29,   // Escape
        51: 0x2A,   // Delete (backspace)
        48: 0x2B,   // Tab
        49: 0x2C,   // Space
        27: 0x2D,   // -
        24: 0x2E,   // =
        33: 0x2F,   // [
        30: 0x30,   // ]
        42: 0x31,   // \
        41: 0x33,   // ;
        39: 0x34,   // '
        50: 0x35,   // `
        43: 0x36,   // ,
        47: 0x37,   // .
        44: 0x38,   // /
        57: 0x39,   // Caps Lock
        // F1…F12
        122: 0x3A, 120: 0x3B, 99: 0x3C, 118: 0x3D, 96: 0x3E, 97: 0x3F,
        98: 0x40, 100: 0x41, 101: 0x42, 109: 0x43, 103: 0x44, 111: 0x45,
        // Navigation
        115: 0x4A,  // Home
        116: 0x4B,  // Page Up
        117: 0x4C,  // Forward Delete
        119: 0x4D,  // End
        121: 0x4E,  // Page Down
        124: 0x4F,  // Right
        123: 0x50,  // Left
        125: 0x51,  // Down
        126: 0x52,  // Up
        // Modifiers
        59: 0xE0,   // Left Control
        56: 0xE1,   // Left Shift
        58: 0xE2,   // Left Option
        55: 0xE3,   // Left Command
        62: 0xE4,   // Right Control
        60: 0xE5,   // Right Shift
        61: 0xE6,   // Right Option
        54: 0xE7,   // Right Command
    ]

    /// NSEvent.ModifierFlags' device-independent bits for shift, control, option and command: the
    /// same bit positions as UIKeyModifierFlags and CGEventFlags (KeyChords.swift's KeyModifiers), so
    /// they travel unchanged. Caps Lock, fn and the rest are left out, as the iOS client leaves them.
    static func wireModifiers(_ raw: UInt64) -> UInt64 {
        raw & (KeyModifiers.shift.rawValue | KeyModifiers.control.rawValue
               | KeyModifiers.option.rawValue | KeyModifiers.command.rawValue)
    }

    /// The text a key's down types when it goes as text rather than as a key: return, the keypad's
    /// enter, tab and delete as the wire's "\n", "\t" and "\u{8}"; anything else as the characters the
    /// Mac's own keyboard layout made, with private-use function-key characters (U+F700…U+F8FF:
    /// arrows and F-keys when they were not caught as keys) and other controls dropped. Nil when
    /// nothing is left to type.
    static func text(keyCode: UInt16, characters: String?) -> String? {
        switch keyCode {
        case 36, 76: return "\n"     // Return, keypad Enter
        case 48: return "\t"         // Tab
        case 51: return "\u{8}"      // Delete
        default: break
        }
        guard let characters, !characters.isEmpty else { return nil }
        let kept = String(String.UnicodeScalarView(characters.unicodeScalars.filter { s in
            !(0xF700...0xF8FF).contains(s.value) && !(s.value < 0x20) && s.value != 0x7F
        }))
        return kept.isEmpty ? nil : kept
    }

    /// What a key's down sends: the key (ForwardedKeys decides, and remembers it so its up follows),
    /// else the text it typed, else nothing (a key with no usage and no text: a media key, say).
    enum Down: Equatable {
        case key(InputEvent)
        case text(String)
        case nothing
    }

    static func down(keyCode: UInt16, modifiers raw: UInt64, characters: String?,
                     forwarded: inout ForwardedKeys) -> Down {
        let modifiers = wireModifiers(raw)
        if let usage = hidUsages[keyCode], let event = forwarded.began(usage, modifiers: modifiers) {
            return .key(event)
        }
        if let t = text(keyCode: keyCode, characters: characters) { return .text(t) }
        return .nothing
    }

    /// A key's up: its up when its down went as a key, else nothing (its text went with the down).
    static func up(keyCode: UInt16, forwarded: inout ForwardedKeys) -> InputEvent? {
        guard let usage = hidUsages[keyCode] else { return nil }
        return forwarded.ended(usage)
    }

    /// A modifier key pressed or let go (NSEvent's flagsChanged: its keyCode and whether its own bit
    /// is now set). The modifier keys themselves go as keys, as a hardware keyboard's do on iOS, so a
    /// click while ⌘ is held is a ⌘-click on the host.
    ///
    /// Left and right keys share one device-independent bit, so a key's own release is seen only
    /// once neither is down: then both sides' ups go (whichever is down on the host), and a key down
    /// again while its bit stays set sends nothing more.
    static func modifierChanged(keyCode: UInt16, modifiers raw: UInt64,
                                forwarded: inout ForwardedKeys) -> [InputEvent] {
        guard let usage = hidUsages[keyCode], let flag = KeyModifiers.flag(forKey: usage) else { return [] }
        if raw & flag.rawValue != 0 {
            guard !forwarded.down.contains(usage) else { return [] }
            return forwarded.began(usage, modifiers: wireModifiers(raw)).map { [$0] } ?? []
        }
        return siblings(usage).compactMap { forwarded.ended($0) }
    }

    /// A modifier's two keys, left first (0xE0…0xE3 and 0xE4…0xE7 are the same four modifiers).
    static func siblings(_ usage: UInt16) -> [UInt16] {
        let left = usage >= 0xE4 ? usage - 4 : usage
        return [left, left + 4]
    }
}
