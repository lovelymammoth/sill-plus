import AppKit
import StreamProtocol
import SwiftUI

/// The one window: the Macs to connect to, or a session's picture.
struct RootView: View {
    @ObservedObject var model: AppModel

    var body: some View {
        Group {
            if let session = model.session {
                SessionView(model: model, session: session)
            } else {
                ConnectView(model: model, discovery: model.discovery)
            }
        }
        .frame(minWidth: 640, minHeight: 420)
    }
}

// MARK: Connecting

struct ConnectView: View {
    @ObservedObject var model: AppModel
    @ObservedObject var discovery: Discovery
    @State private var address = ""
    @State private var addressCode = ""
    @State private var link = ""
    @State private var askedCode = ""

    var body: some View {
        Form {
            Section("On this network") {
                if discovery.rows.isEmpty {
                    Text(discovery.problem ?? "Looking for Macs running Sill…").foregroundStyle(.secondary)
                }
                ForEach(discovery.rows) { row in
                    HStack {
                        Image(systemName: "desktopcomputer")
                        VStack(alignment: .leading) {
                            Text(row.name)
                            Text(rowWord(row)).font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer()
                        Button(model.savedMac(for: row) != nil ? "Connect" : "Pair…") { model.connect(row) }
                            .disabled(row.door == .plain || busy)
                    }
                }
            }

            if !model.saved.isEmpty {
                Section("Paired Macs") {
                    ForEach(model.saved) { mac in
                        SavedRow(model: model, mac: mac)
                    }
                }
            }

            Section {
                TextField("Address (mac-mini.tail1234.ts.net or 100.x.y.z)", text: $address)
                TextField("12-digit code", text: $addressCode)
                HStack {
                    Spacer()
                    Button("Pair") { model.pair(address: address, code: addressCode) }
                        .disabled(address.isEmpty || addressCode.isEmpty || busy)
                }
            } header: {
                Text("Add a Mac by address")
            } footer: {
                Text("On the Mac, choose Pair iPhone or iPad… from Sill's menu. It shows a code and the address to type, its Tailscale name when Tailscale runs there. For Tailscale, also turn on Remote Access in Sill's Settings on that Mac.")
                    .font(.caption).foregroundStyle(.secondary)
            }

            Section("Pair with a link") {
                HStack {
                    TextField("sill://pair?…", text: $link)
                    Button("Pair") { model.pair(link: link) }.disabled(link.isEmpty || busy)
                }
            }

            if !model.status.isEmpty {
                Text(model.status).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .sheet(isPresented: sheetShown) { pairingSheet }
    }

    private var busy: Bool { if case .working = model.pairing { return true }; return false }

    private var sheetShown: Binding<Bool> {
        Binding(get: { model.pairing != .idle }, set: { if !$0 { model.cancelPairing() } })
    }

    @ViewBuilder private var pairingSheet: some View {
        VStack(alignment: .leading, spacing: 14) {
            switch model.pairing {
            case .working(let words):
                HStack { ProgressView().controlSize(.small); Text(words) }
                HStack { Spacer(); Button("Cancel") { model.cancelPairing() } }
            case .needsCode(let mac, let rowName):
                Text("Enter the code from \(mac)").font(.headline)
                Text("\(mac) shows a 12-digit code in its pairing window.").foregroundStyle(.secondary)
                TextField("4829 1355 7208", text: $askedCode).font(.system(.title3, design: .monospaced))
                    .onSubmit { model.submitCode(askedCode, rowName: rowName) }
                HStack {
                    Spacer()
                    Button("Cancel") { model.cancelPairing() }
                    Button("Pair") { model.submitCode(askedCode, rowName: rowName) }.keyboardShortcut(.defaultAction)
                }
            case .failed(let words):
                Text("Couldn't pair").font(.headline)
                Text(words)
                HStack { Spacer(); Button("OK") { model.pairing = .idle }.keyboardShortcut(.defaultAction) }
            case .idle:
                EmptyView()
            }
        }
        .padding(20)
        .frame(width: 400)
    }

    private func rowWord(_ row: Discovery.Row) -> String {
        if row.door == .plain { return "Update Sill on this Mac (it speaks no TLS)" }
        if let mac = model.savedMac(for: row) { return mac.revoked == true ? "Not paired" : "Paired" }
        return row.door == .open ? "Not paired (it lets any device in)" : "Not paired"
    }
}

struct SavedRow: View {
    @ObservedObject var model: AppModel
    let mac: SavedMac
    @State private var adding = false
    @State private var newAddress = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Image(systemName: "lock.desktopcomputer")
                VStack(alignment: .leading) {
                    Text(mac.name)
                    Text(addresses).font(.caption).foregroundStyle(.secondary).lineLimit(2)
                }
                Spacer()
                Button("Connect") { model.connect(saved: mac.macID) }
                Menu {
                    Button("Connect Remotely") { model.connectRemotely(mac.macID) }
                    Button("Add an Address…") { adding = true }
                    Divider()
                    Button("Forget This Mac", role: .destructive) { model.forget(mac.macID) }
                } label: { Image(systemName: "ellipsis.circle") }
                .menuStyle(.borderlessButton).fixedSize()
            }
            if adding {
                HStack {
                    TextField("mac-mini.tail1234.ts.net", text: $newAddress)
                    Button("Add") { model.addAddress(newAddress, to: mac.macID); adding = false; newAddress = "" }
                    Button("Cancel") { adding = false }
                }
            }
        }
    }

    private var addresses: String {
        let list = mac.allAddresses.map { a in a.via.isEmpty ? a.host : "\(a.via): \(a.host)" }
        return list.isEmpty ? "No address for afar yet: connect at home with Remote Access on, or add one." : list.joined(separator: " · ")
    }
}

// MARK: A session

struct SessionView: View {
    @ObservedObject var model: AppModel
    @ObservedObject var session: StreamSession

    var body: some View {
        VStack(spacing: 0) {
            bar
            ZStack {
                StreamViewRepresentable(session: session)
                overlay
            }
        }
    }

    @ViewBuilder private var overlay: some View {
        switch session.phase {
        case .connecting(let name):
            VStack { ProgressView(); Text("Connecting to \(name)…").foregroundStyle(.white) }
        case .ended(let words, let reconnect):
            VStack(spacing: 12) {
                Text(words).foregroundStyle(.white).multilineTextAlignment(.center)
                HStack {
                    if reconnect { Button("Reconnect") { model.connect(saved: session.macID) } }
                    Button("Back to Macs") { model.endSession() }
                }
            }
            .padding(24).background(.black.opacity(0.6), in: RoundedRectangle(cornerRadius: 12))
        default:
            EmptyView()
        }
    }

    private var bar: some View {
        HStack(spacing: 10) {
            Button { session.select(.desktop) } label: { Label("Desktop", systemImage: "menubar.dock.rectangle") }
                .help("Stream the Mac's whole desktop")
            Menu {
                if session.windows.isEmpty { Text("No windows") }
                ForEach(session.windows) { w in
                    Button {
                        session.select(.window(w.id))
                    } label: {
                        Text(w.title.isEmpty ? w.appName : "\(w.appName) — \(w.title)")
                    }
                }
            } label: { Label(activeTitle, systemImage: "macwindow") }
            .fixedSize()
            Menu {
                ForEach(session.apps) { app in Button(app.name) { session.launch(app.bundleID) } }
            } label: { Label("Apps", systemImage: "square.grid.2x2") }
            .fixedSize()
            if case .window(let id) = session.active {
                Menu {
                    Button("Close Window") { session.command(.close, window: id) }
                    Button("Minimize Window") { session.command(.minimize, window: id) }
                    Button("Full Screen") { session.command(.fullScreen, window: id) }
                } label: { Image(systemName: "ellipsis.circle") }
                .menuStyle(.borderlessButton).fixedSize()
            }
            Spacer()
            Text(statsLine).font(.caption.monospacedDigit()).foregroundStyle(.secondary)
            Button("Disconnect") { model.endSession() }.keyboardShortcut("d", modifiers: [.control, .option, .command])
        }
        .padding(.horizontal, 10).padding(.vertical, 6)
        .background(.bar)
    }

    private var activeTitle: String {
        switch session.active {
        case .desktop: return "Desktop"
        case .window(let id): return session.windows.first { $0.id == id }.map { $0.title.isEmpty ? $0.appName : $0.title } ?? "Window"
        case .none: return "Windows"
        }
    }

    private var statsLine: String {
        let s = session.stats
        var parts = ["\(session.macName)", "\(s.fps) fps"]
        if let a = s.frameAgeMs { parts.append("age \(a) ms") }
        if let r = s.rttMs { parts.append("rtt \(r) ms") }
        parts.append(String(format: "%.1f Mbps", s.mbps))
        if !session.route.isEmpty { parts.append(session.route) }
        return parts.joined(separator: " · ")
    }
}
