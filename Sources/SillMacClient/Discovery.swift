import Foundation
import Network
import StreamProtocol

/// The Macs running Sill on this Mac's network (docs/mac-client.md, "Finding the Mac"): Bonjour
/// `_sill._tcp`, as the iOS client browses it, never over peer-to-peer Wi-Fi. Each row carries the
/// Mac's TXT record: `p`, how its home door speaks (HomeDoorTXT), and `r`, the recognition tag that
/// names a saved Mac whatever its Bonjour name (RecognitionTag; resolved with the recognition key
/// this Mac got when it paired).
///
/// `SILL_CLIENT_SERVICE_TYPE=_silltest._tcp` (TEST ONLY) browses a test host's type instead.
final class Discovery: ObservableObject {
    struct Row: Identifiable, Equatable {
        var id: String { name }
        let name: String
        let endpoint: NWEndpoint
        let door: HomeDoorTXT.Door
        let tag: String?
    }

    @Published private(set) var rows: [Row] = []
    @Published private(set) var problem: String?
    private var browser: NWBrowser?

    static var serviceType: String {
        if let t = ProcessInfo.processInfo.environment["SILL_CLIENT_SERVICE_TYPE"], t.hasPrefix("_"), t.hasSuffix("._tcp") { return t }
        return "_sill._tcp"
    }

    func start() {
        guard browser == nil else { return }
        let params = NWParameters()
        params.includePeerToPeer = false
        let b = NWBrowser(for: .bonjourWithTXTRecord(type: Self.serviceType, domain: nil), using: params)
        b.stateUpdateHandler = { [weak self] state in
            DispatchQueue.main.async {
                switch state {
                case .waiting(let e), .failed(let e):
                    if case .dns(let code) = e, code == RemoteDialPolicy.dnsPolicyDenied {
                        self?.problem = "To find Macs on your network, allow Local Network for Sill Mac Client in System Settings › Privacy & Security."
                    } else {
                        self?.problem = "Looking for Macs failed (\(e))."
                    }
                case .ready: self?.problem = nil
                default: break
                }
            }
        }
        b.browseResultsChangedHandler = { [weak self] results, _ in
            let rows = results.compactMap { r -> Row? in
                guard case .service(let name, _, _, _) = r.endpoint else { return nil }
                var door = HomeDoorTXT.Door.plain
                var tag: String?
                if case .bonjour(let txt) = r.metadata {
                    door = HomeDoorTXT.door(txt)
                    if case .string(let t)? = txt.getEntry(for: RecognitionTag.txtKey) { tag = t }
                }
                return Row(name: name, endpoint: r.endpoint, door: door, tag: tag)
            }
            // One row per service name: Bonjour reports one per interface.
            var seen = Set<String>()
            let unique = rows.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
                .filter { seen.insert($0.name).inserted }
            DispatchQueue.main.async { self?.rows = unique }
        }
        b.start(queue: DispatchQueue(label: "sill.client.browse"))
        browser = b
    }

    func stop() {
        browser?.cancel()
        browser = nil
    }
}
