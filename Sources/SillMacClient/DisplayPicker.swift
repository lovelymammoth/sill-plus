import StreamProtocol

/// The bar's monitor buttons (pure; checked in Tests/checks/mac-client-keys): what a window list says of the
/// Mac's displays, read the same way from each kind of host.
///
/// - sill-plus 0.6.2-plus.1 and later: `displays` (the Desktop's stops with their IDs, kind 40) beside
///   upstream's `desktopDisplays`, `desktopDisplay` (the stop shown, counting from 1) and `desktopDisplayNames`.
///   A button per stop; a click sends kind 40 with its ID.
/// - sill-plus 0.5.1-plus.1 and .2: `displays`, and `desktopDisplay` the shown display's ID (the key upstream
///   0.6.2 later took for the stop's number), no `desktopDisplays`. A button per display, kind 40 as before.
/// - Upstream 0.6.2: `desktopDisplays` 2 or more with the stops' names, no `displays`: no kind 40 there. One
///   Desktop button, "Desktop 2", that steps to the next stop with kind 47 while the Desktop streams, as the
///   iPhone and iPad do.
/// - Anything else (one display, a locked Mac, an older host): the plain Desktop button.
enum DisplayPicker: Equatable {
    /// One button per display; `shown` is the one the Desktop shows (or comes back to), when known.
    case buttons([DisplayInfo], shown: UInt32?)
    /// Upstream's stepping: `count` stops, `shown` counting from 1, their names (some may be empty).
    case stepper(count: Int, shown: Int, names: [String])
    case plain

    static func read(_ list: WindowList) -> DisplayPicker {
        if let displays = list.displays, displays.count > 1 {
            if let n = list.desktopDisplays, n == displays.count {
                // This fork's host on upstream's stops: the number indexes `displays`.
                let shown = list.desktopDisplay.flatMap { $0 >= 1 && $0 <= displays.count ? displays[$0 - 1].id : nil }
                return .buttons(displays, shown: shown)
            }
            if list.desktopDisplays == nil {
                // The fork's 0.5.1 hosts: `desktopDisplay` was a display ID.
                let shown = list.desktopDisplay.flatMap { id in displays.first { Int($0.id) == id }?.id }
                return .buttons(displays, shown: shown)
            }
        }
        if let n = list.desktopDisplays, n >= 2 {
            let shown = list.desktopDisplay.map { min(max($0, 1), n) } ?? 1
            let names = list.desktopDisplayNames.map { Array($0.prefix(n)) } ?? []
            return .stepper(count: n, shown: shown, names: names + Array(repeating: "", count: max(0, n - names.count)))
        }
        return .plain
    }

    /// "Display 1 · LG HDR 4K": the number keeps two monitors of one model apart.
    static func title(_ d: DisplayInfo, index: Int) -> String {
        let n = "Display \(index + 1)"
        return d.name.isEmpty || d.name.hasPrefix("Display ") || d.name.hasPrefix("display ") ? n : "\(n) · \(d.name)"
    }

    /// The stepper's label: "Desktop 2", as upstream's devices word it.
    static func stepperTitle(shown: Int) -> String { "Desktop \(shown)" }

    /// The stepper's help: "Desktop 2 of 3 (DELL U2723QE). Click again for the next display."
    static func stepperHelp(count: Int, shown: Int, names: [String], streaming: Bool) -> String {
        let name = shown >= 1 && shown <= names.count ? names[shown - 1] : ""
        let at = "Desktop \(shown) of \(count)" + (name.isEmpty ? "" : " (\(name))")
        return streaming ? "\(at). Click for the next display." : "\(at). Stream the Mac's desktop; click again for the next display."
    }
}
