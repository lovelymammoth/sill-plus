# `mac-client-keys`

**Checks:** the Mac client (docs/mac-client.md): its virtual-key table is exactly the host's `KeyStrokes.virtualKeys` read backwards; which keys go as keys and which as the text they typed (`ForwardedKeys`); the modifier keys' flags-changed, left and right sharing a bit; typical sessions through the host's `KeyStrokes` leave no key down and no modifier in the HID table; the aspect-fit picture, a point as fractions of the frame, scrolls and the viewport; the bar's monitor buttons (`DisplayPicker`) from this fork's 0.6.2 and 0.5.1 hosts' lists and from upstream 0.6.2's stops (the stepper, kind 47), and kind 40's payload

**Compiles:** `Sources/SillMacClient/MacKeys.swift`, `StreamGeometry.swift` and `DisplayPicker.swift` with `Sources/SillHost/KeyStrokes.swift`, `iOSClient/KeyChords.swift` and `Sources/StreamProtocol` (`module.txt`, `-package-name sill`)
