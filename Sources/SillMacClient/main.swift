import AppKit
import Foundation
import Network
import StreamProtocol
import SwiftUI

// Sill Mac Client: another Mac's windows and desktop on this Mac (docs/mac-client.md). The Mac being
// shown runs Sill for Mac (Sill.app) as it does for an iPhone or iPad; this app is a device to it,
// speaking the same wire (StreamProtocol), with the same pairing and pinned TLS.
//
//   SillMacClient                      the app (Scripts/make-client-app.sh wraps it into a bundle)
//   SillMacClient --headless …         TEST ONLY: pair and stream with no window (HeadlessCheck)

setvbuf(stdout, nil, _IOLBF, 0)
signal(SIGPIPE, SIG_IGN)

if CommandLine.arguments.contains("--headless") {
    HeadlessCheck.run(Array(CommandLine.arguments.dropFirst()))   // never returns
}

// The system shortcuts a capture turned off come back on whatever ends this process: a crash or a
// kill left them for this launch (SystemShortcuts.restoreLeftovers); a signal restores them here.
SystemShortcuts.restoreLeftovers()
var signalSources: [DispatchSourceSignal] = []
for sig in [SIGTERM, SIGINT, SIGHUP] {
    signal(sig, SIG_IGN)
    let source = DispatchSource.makeSignalSource(signal: sig, queue: .main)
    source.setEventHandler {
        SystemShortcuts.shared.stop()
        signal(sig, SIG_DFL)
        kill(getpid(), sig)
    }
    source.resume()
    signalSources.append(source)
}

final class ClientAppDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate, NSMenuItemValidation {
    let model = AppModel()
    var window: NSWindow?

    func applicationDidFinishLaunching(_ notification: Notification) {
        let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1100, height: 720),
                         styleMask: [.titled, .closable, .miniaturizable, .resizable],
                         backing: .buffered, defer: false)
        w.title = "Sill"
        w.contentView = NSHostingView(rootView: RootView(model: model))
        w.collectionBehavior.insert(.fullScreenPrimary)
        w.setFrameAutosaveName("SillMacClientWindow")
        w.center()
        w.delegate = self
        w.makeKeyAndOrderFront(nil)
        window = w
        model.start()
        NSApp.activate(ignoringOtherApps: true)
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }

    func applicationWillTerminate(_ notification: Notification) {
        SystemShortcuts.shared.stop()
        model.session?.disconnect()
    }

    func applicationDidResignActive(_ notification: Notification) {
        SystemShortcuts.shared.stop()
    }

    @objc func disconnect(_ sender: Any?) { model.endSession() }

    @objc func toggleSystemShortcuts(_ sender: Any?) {
        ClientPrefs.sendsSystemShortcuts.toggle()
        if ClientPrefs.sendsSystemShortcuts, !SystemShortcuts.trusted { SystemShortcuts.askForAccess() }
    }

    func validateMenuItem(_ item: NSMenuItem) -> Bool {
        if item.action == #selector(toggleSystemShortcuts(_:)) {
            item.state = ClientPrefs.sendsSystemShortcuts ? .on : .off
        }
        return true
    }
}

/// The app's menu bar: the standard App, Edit (for the address fields) and Window menus, and Session's
/// Disconnect on ⌃⌥⌘D, which the stream view leaves to this app (StreamNSView).
enum ClientMenu {
    static func make(_ delegate: ClientAppDelegate) -> NSMenu {
        let main = NSMenu()
        let appItem = NSMenuItem()
        let app = NSMenu()
        app.addItem(withTitle: "About Sill Mac Client", action: #selector(NSApplication.orderFrontStandardAboutPanel(_:)), keyEquivalent: "")
        app.addItem(.separator())
        app.addItem(withTitle: "Hide", action: #selector(NSApplication.hide(_:)), keyEquivalent: "h")
        app.addItem(.separator())
        app.addItem(withTitle: "Quit Sill Mac Client", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        appItem.submenu = app
        main.addItem(appItem)

        let editItem = NSMenuItem()
        let edit = NSMenu(title: "Edit")
        edit.addItem(withTitle: "Cut", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        edit.addItem(withTitle: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        edit.addItem(withTitle: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        edit.addItem(withTitle: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        editItem.submenu = edit
        main.addItem(editItem)

        let sessionItem = NSMenuItem()
        let session = NSMenu(title: "Session")
        let d = session.addItem(withTitle: "Disconnect", action: #selector(ClientAppDelegate.disconnect(_:)), keyEquivalent: "d")
        d.keyEquivalentModifierMask = [.control, .option, .command]
        d.target = delegate
        session.addItem(.separator())
        let keys = session.addItem(withTitle: "Send System Shortcuts to the Mac", action: #selector(ClientAppDelegate.toggleSystemShortcuts(_:)), keyEquivalent: "")
        keys.target = delegate
        keys.toolTip = "⌘Tab, Spotlight, Mission Control, Spaces and screenshots go to the Mac while the picture has the keyboard (needs Accessibility)"
        sessionItem.submenu = session
        main.addItem(sessionItem)

        let windowItem = NSMenuItem()
        let window = NSMenu(title: "Window")
        let fs = window.addItem(withTitle: "Enter Full Screen", action: #selector(NSWindow.toggleFullScreen(_:)), keyEquivalent: "f")
        fs.keyEquivalentModifierMask = [.control, .option, .command]
        window.addItem(withTitle: "Minimize", action: #selector(NSWindow.performMiniaturize(_:)), keyEquivalent: "")
        windowItem.submenu = window
        main.addItem(windowItem)
        NSApp.windowsMenu = window
        return main
    }
}

let app = NSApplication.shared
app.setActivationPolicy(.regular)
let delegate = ClientAppDelegate()
app.delegate = delegate
app.mainMenu = ClientMenu.make(delegate)
app.run()
