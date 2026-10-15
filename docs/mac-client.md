# Sill Viewer: a Mac's windows on another Mac

Sill Viewer shows the windows or the whole desktop of a Mac running Sill for Mac (Sill.app) on
another Mac, and sends that Mac its mouse, trackpad and keyboard. To Sill.app it is a device like an
iPhone or iPad: it pairs the same way, with the same 12-digit code, over the same pinned TLS 1.3, on
the same wire (`Sources/StreamProtocol`). Nothing changes on the host: Sill.app 0.4.0 or later serves
it as it is.

This is a first, incremental client (branch `mac-client`). What it does and does not do yet is under
[Scope](#scope).

## Setup: Mac mini as the host, MacBook Pro as the client

### On the Mac mini (the Mac you want to see)

1. Install Sill for Mac 0.4.0 or later (getsill.app/download, or `Scripts/make-app.sh --install
   --open` from this repository) and grant it Screen Recording and Accessibility, as for an iPad.
2. Leave Settings › Devices › Require pairing on (the default).
3. For use away from home through Tailscale: install Tailscale on the Mac mini, sign in, and turn on
   Settings › Remote Access in Sill. Sill then listens on its remote door (port 7455 unless you
   change it) and tells paired devices its Tailscale name and addresses. "Allow connections from the
   internet" stays off: Tailscale counts as your own VPN.
4. Keep the Mac mini awake and logged in (Energy settings: prevent automatic sleeping when the
   display is off). Sill holds off idle sleep only while a device is connected.

### On the MacBook Pro (the Mac you sit at)

1. Build and install the client from this repository (Xcode 27 selected as the developer directory):

   ```
   Scripts/make-client-app.sh --install --open
   ```

   It is signed with your Apple Development identity when the keychain has one, ad hoc otherwise
   (then the keychain asks once after each rebuild to let the new build read its key). Another
   bundle identifier: `SILL_CLIENT_BUNDLE_ID=com.example.sill.client`.
2. At the first launch macOS 15 and later ask for Local Network: allow it, or Bonjour finds nothing.
3. For Tailscale, install Tailscale on the MacBook Pro too, in the same tailnet.

### Pairing, at home

The two Macs on the same network: the Mac mini is listed under "On this network". Click **Pair…**.
The Mac mini opens its pairing window by itself (the client sends the same "pair me" ask an iPad's
tap sends) and shows a 12-digit code; type it in the client. From then on **Connect** goes straight
in, pinned to the Mac mini's key, and the Mac mini lists the MacBook Pro in Settings › Devices, where
you can remove it.

If the Mac mini answers that you should open its window yourself, choose **Pair iPhone or iPad…**
from Sill's menu on the Mac mini and type the code it shows.

### Pairing, or connecting, through Tailscale

- **First pairing away from home**: on the Mac mini choose **Pair iPhone or iPad…**. Its window shows
  the code and the address to type: the Mac mini's MagicDNS name (`mac-mini.tailXXXX.ts.net`) with its
  Tailscale IPv4 under it. In the client, under **Add a Mac by address**, type that address and the
  code, then **Pair**. The client dials the remote door (port 7455), pairs, saves the Mac mini and
  connects.
- **A Mac mini paired at home**: once a session at home has run with Remote Access on, the client has
  the Mac mini's own signed list of addresses (kind 18), Tailscale's first. Away, **Connect** dials
  them in the iOS client's order, one a second, and the first pinned connection wins. **Connect
  Remotely** (the row's … menu) skips Bonjour even at home. **Add an Address…** adds one by hand
  (a Tailscale name or IP, with `:port` if it is not 7455).

### Using it

The bar above the picture: **Desktop**, the window menu (every window the Mac mini streams; pick one
to stream just that window), **Apps** (launch an app there), the window's close, minimize and full
screen, and the session's frame rate, frame age, round trip, bitrate and route. The window resizes
freely and goes full screen (⌃⌥⌘F).

- **Mouse and trackpad**: moves, clicks, right-clicks and drags go to the Mac mini where you point;
  your pointer takes the Mac mini's cursor shape over the picture. Two-finger scrolling keeps its
  phases and momentum, so apps there rubber-band and coast. Shift-click holds shift around the click.
- **Keys**: while the picture has the keyboard, every key goes to the Mac mini, ⌘ shortcuts
  included (⌘C, ⌘W, ⌘Q act on the Mac mini). Plain keys go as the text they type on this Mac's
  keyboard layout, so layouts, dead keys and input methods follow the Mac you type on. ⌃⌥⌘ shortcuts
  stay the client's: ⌃⌥⌘D disconnects, ⌃⌥⌘F full screen. With Accessibility granted to Sill Mac
  Client and Session › Send System Shortcuts to the Mac on (the default), the ones macOS keeps for
  itself go too while the picture has the keyboard: a keyboard event tap takes every key first, and
  the system's symbolic hot keys (⌘`, screenshots, Mission Control, Spaces, Spotlight, ⌘Tab where
  macOS lists them) are turned off for that time and back on the moment the app or the picture loses
  the keyboard, at quit, on a signal, and at the next launch after a crash. Click another app or the
  Dock to get this Mac's shortcuts back.
- **Quality** (the bar's slider menu, from a Mac that sends kind 16): the Mac's Quality preset and
  Resolution, as its own menu has them (away from home they set its away quality), and the frame
  rate this client asks for: 60 fps by default; 120 on a ProMotion screen only when chosen, since
  the bitrate is per 60 fps and doubles. When the Mac reports that the link can't keep up, a line
  under the bar says so with the Mac's suggestion as a button.
- **Disconnect** (⌃⌥⌘D, or the button) ends the session; the Mac mini stops capturing once no device
  is connected.

## How it works

- `Sources/SillMacClient/` is a new SwiftPM executable target. It links only `StreamProtocol`, never
  the host (`SillHostCore`).
- Reused unchanged, as symlinks into `iOSClient/` (the pattern `Sources/VirtualDisplayProbe` already
  uses), so both clients read, save and key the same way: `MessageReader.swift` (the session's reader,
  payloads in 256 KB pieces, liveness by bytes), `SavedMacs.swift` (the saved Mac records and their
  rules: TXT-tag recognition, kind 18 refresh, the cap), `RemoteDialPolicy.swift` (the dial order of
  a saved Mac's addresses, Tailscale's first), `KeyChords.swift` (`ForwardedKeys`, which keys go as
  keys and which as text).
- From `StreamProtocol`: `RemoteTLS` (the one TLS builder), `RemoteIdentity`/`RemoteKey` (the P-256
  key and its self-signed certificate), `PairingCode`/`PairingProof`/`PairLink`/`RecognitionTag`/
  `HomeDoorTXT` (pairing), and every message type.
- New: `ClientIdentity` (this Mac's key), `SavedMacStore` (the records in a 0600 JSON file),
  `ClientTLS`, `PairingExchange` (one `sill-pair/1` exchange: ask, code, link, cancel),
  `StreamSession` (the session: hello first, the reader, pings every 0.25 s, ClientStats each second,
  liveness, picks, viewport, input with moves coalesced to 125 Hz), `VideoSinks`
  (`AVSampleBufferDisplayLayer`, and a VideoToolbox decoder for the headless check), `Discovery`
  (Bonjour `_sill._tcp` with TXT), `MacKeys` and `StreamGeometry` (pure, checked), `StreamView`
  (the picture and input), `ClientViews` and `AppModel` (SwiftUI and its state), `HeadlessCheck`.

### Security

- Every connection is TLS 1.3 with both keys pinned (`RemoteTLS`); this client has no plain path at
  all. A home row without the TXT key `p` (a Sill for Mac older than 0.4.0, or `SillHost` without
  `--pairing`) is shown as needing an update and never dialed.
- Pairing never trusts a message for a key: each side takes the other's fingerprint from the TLS
  session. With the code, the key is PBKDF2 (600,000 rounds) of the code salted with the Mac's key as
  this connection saw it; a relay in the middle would make the Mac reject the proof. Nothing is saved
  unless the Mac's own proof checks and its Mac ID is its key's.
- A session dials only pinned to the saved key; another key at a saved address ends the dial at once
  ("The Mac that answered isn't … (another key)"), and nothing of this Mac's is sent to it.
- A kind 18 (addresses for afar) is taken only when signed by the pinned key.
- This Mac's key lives in the login keychain (service "Sill Mac Client", the name before Sill Viewer, account "device-key"), as
  Sill.app's own unentitled builds keep theirs; the data-protection keychain would need a provisioning
  profile this SwiftPM build does not have (docs/keychain-plan.md). Removing the item makes this Mac a
  new device to every Mac (pair again). Saved Macs: `~/Library/Application Support/Sill Mac
  Client/saved-macs.json` (0600).

### What is stored

The key (keychain) and the saved Macs (that JSON file: Mac ID, pin, name, recognition key, remote
port, the Mac's addresses and any typed here, when it paired and last connected). Nothing else; no
server, no account.

## Testing

Pure checks, as CI runs them (`Tests/checks/run-all.sh` picks the new folder up by itself):

```
Tests/checks/mac-client-keys/run.sh             # MacKeys against the host's KeyStrokes table, key routing, geometry
Tests/checks/mac-client-keys/run.sh --mutants   # each one-line mutant of MacKeys.swift and StreamGeometry.swift must fail it
```

End to end, headless, on one Mac (no window, no device, no hardware encoder):

```
Scripts/mac-client-check.sh
```

It starts `SillHost --synthetic --pairing` hosts on 127.0.0.1 alone (`SILL_TEST_LOOPBACK`, the
software encoder, a throwaway identity) and runs `SillMacClient --headless` with its key and saved
Macs in a throwaway folder (`SILL_CLIENT_IDENTITY_DIR`, never the keychain): pairing with the code at
the remote door with loopback counting as a VPN (the Tailscale path) and a pinned session that
decodes the test pattern with VideoToolbox and sends input (a synthetic host counts it as `in.dry`
and posts nothing); the saved Mac again with no pairing; a wrong code refused with the tries left and
nothing saved; pairing and streaming at the TLS home door; the saved Mac there again; and another
key at the saved Mac's address refused by the pin.

`SillMacClient --headless` by hand:

```
SILL_CLIENT_IDENTITY_DIR=$T/client .build/release/SillMacClient --headless --address 127.0.0.1:PORT --code DIGITS [--home] [--seconds 6] [--input]
SILL_CLIENT_IDENTITY_DIR=$T/client .build/release/SillMacClient --headless --saved [--home]
```

`--input` is refused unless every address is loopback. `SILL_CLIENT_SERVICE_TYPE=_silltest._tcp`
makes the app browse a test host registered with `SILL_TEST_SERVICE_TYPE` instead of real Macs.

## Scope

In this first step:

- Bonjour discovery, pairing at home (ask, then the code) and by address (the code, or a
  `sill://pair` link), saved Macs, sessions at home and through the remote door (Tailscale, a VPN, a
  forwarded port), dialed in the iOS client's order.
- The Desktop and single windows, app launch, window close/minimize/full screen.
- Mouse, right click, drag, phased trackpad scrolling, keys and text, the Mac's cursor shape.
- Statistics to the Mac (its log and menu show this Mac like any device).

Not yet:

- The Mac's menus (kinds 24, 25, 27), trackpad gestures (kind 28), the Mac's pointer while it moves
  (kind 26), the host settings panel (kinds 16 and 17), Aa (window scaling) and a viewport scale.
- Moving a live session between paths (home ⇄ Tailscale) without a reconnect; the automatic
  reconnect after a loss (the window offers Reconnect).
- A Retina-aware viewport (the client sends its size in points; the host streams at its own
  resolution setting).
- Pairing over a Thunderbolt or USB cable without a code (Sill.app's cable rule is for an iPhone's or
  iPad's NCM interface, not a Mac).
- An icon of its own, notarization, a release workflow, and the UI tested on a second Mac.
