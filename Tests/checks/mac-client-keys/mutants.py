"""Mutants of the Mac client's MacKeys.swift and StreamGeometry.swift (Sources/SillMacClient): each
changes one place, is compiled with the check and must make it fail. usage: mutants.py ROOT"""
import os, sys
sys.path.insert(0, os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
import module
K = "Sources/SillMacClient/MacKeys.swift"
G = "Sources/SillMacClient/StreamGeometry.swift"
M = [
    ("A and S swapped", K, "0: 0x04, 11: 0x05, 8: 0x06, 2: 0x07, 14: 0x08, 3: 0x09, 5: 0x0A, 4: 0x0B,", "0: 0x16, 11: 0x05, 8: 0x06, 2: 0x07, 14: 0x08, 3: 0x09, 5: 0x0A, 4: 0x0B,"),
    ("left and right arrows swapped", K, "124: 0x4F,  // Right\n        123: 0x50,  // Left", "124: 0x50,  // Right\n        123: 0x4F,  // Left"),
    ("right ⌘ missing", K, "        54: 0xE7,   // Right Command\n", ""),
    ("fn travels", K, "| KeyModifiers.option.rawValue | KeyModifiers.command.rawValue)", "| KeyModifiers.option.rawValue | KeyModifiers.command.rawValue | (1 << 23))"),
    ("shift dropped from the wire", K, "raw & (KeyModifiers.shift.rawValue | KeyModifiers.control.rawValue", "raw & (KeyModifiers.control.rawValue"),
    ("return types \\r", K, 'case 36, 76: return "\\n"', 'case 36, 76: return "\\r"'),
    ("delete types DEL", K, 'case 51: return "\\u{8}"', 'case 51: return "\\u{7F}"'),
    ("private-use characters typed", K, "!(0xF700...0xF8FF).contains(s.value) && ", ""),
    ("every key goes as text", K, "if let usage = hidUsages[keyCode], let event = forwarded.began(usage, modifiers: modifiers) {", "if false, let usage = hidUsages[keyCode], let event = forwarded.began(usage, modifiers: modifiers) {"),
    ("a key's up never goes", K, "        guard let usage = hidUsages[keyCode] else { return nil }\n        return forwarded.ended(usage)", "        return nil"),
    ("a held modifier pressed again goes again", K, "            guard !forwarded.down.contains(usage) else { return [] }\n", ""),
    ("only the released side goes up", K, "return siblings(usage).compactMap { forwarded.ended($0) }", "return [usage].compactMap { forwarded.ended($0) }"),
    ("siblings from the wrong side", K, "let left = usage >= 0xE4 ? usage - 4 : usage", "let left = usage"),
    ("pictures stretched", G, "let scale = min(bounds.width / frame.width, bounds.height / frame.height)", "let scale = max(bounds.width / frame.width, bounds.height / frame.height)"),
    ("pictures at the top left", G, "return CGRect(x: bounds.midX - size.width / 2, y: bounds.midY - size.height / 2,", "return CGRect(x: bounds.minX, y: bounds.minY,"),
    ("y not flipped", G, "if !flipped { y = 1 - y }", ""),
    ("no clamp", G, "        x = min(max(x, 0), 1)\n        y = min(max(y, 0), 1)\n", ""),
    ("scroll sign flipped", G, "return (dx * k / Double(picture.width), dy * k / Double(picture.height))", "return (dx * k / Double(picture.width), -dy * k / Double(picture.height))"),
    ("wheel lines as points", G, "let k = precise ? 1.0 : lineHeight", "let k = 1.0"),
]
sys.exit(0 if module.mutate("mac-client-keys", M, sys.argv[1]) else 1)
