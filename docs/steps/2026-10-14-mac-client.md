**Sill Mac Client (2026-10-14, branch `mac-client` from main at 985a733; docs/mac-client.md has the
setup, the design and the scope).** A native Mac client: another Mac's windows and desktop on this
Mac, a device to Sill.app as an iPhone or iPad is. No host or wire change: Sill.app 0.4.0 and later
serve it as they are.
- `Sources/SillMacClient` (SwiftPM executable, links only StreamProtocol): pinned TLS 1.3 through
  `RemoteTLS`; pairing (`PairingExchange`: the home door's ask then the code, the code at an address,
  a `sill://pair` link) with the proofs checked as the iOS client checks them; `StreamSession` (hello
  first, `MessageReader`, pings, ClientStats, liveness, picks, viewport, input coalesced to 125 Hz;
  a saved Mac's addresses dialed in `RemoteDialPolicy.order`, Tailscale first; a refused pin ends the
  dial at once); `AVSampleBufferDisplayLayer`; Bonjour with the TXT `p` and `r`; mouse, phased
  scrolling, keys (`MacKeys`: the host's `KeyStrokes.virtualKeys` read backwards; keys or text by
  `ForwardedKeys`), the Mac's cursor shape. Reused as symlinks into `iOSClient/`: `MessageReader`,
  `SavedMacs`, `RemoteDialPolicy`, `KeyChords`. Key in the login keychain (service "Sill Mac
  Client"), saved Macs in `~/Library/Application Support/Sill Mac Client/saved-macs.json`.
- `Scripts/make-client-app.sh` (the bundle, Local Network keys), `Packaging/ClientInfo.plist`,
  `Tests/checks/mac-client-keys` (249 checks, 19 of 19 mutants; in CI's matrix),
  `Scripts/mac-client-check.sh` (headless end to end against synthetic hosts on loopback: the remote
  door as a VPN, the saved Mac, a wrong code, the home door, another key at a saved address; 6 of 6).
- **Untested:** the app's window, picture and input on a second Mac (only the headless path ran:
  pairing, pinned sessions, VideoToolbox decode, input counted `in.dry`); Tailscale between two real
  Macs; Local Network's prompt; signing with an Apple Development identity.
