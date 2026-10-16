# Sill Viewer: a Mac's windows on another Mac

Sill Viewer shows the windows or the whole desktop of a Mac running Sill for Mac (Sill.app) on
another Mac, and sends that Mac its mouse, trackpad and keyboard. To Sill.app it is a device like an
iPhone or iPad: it pairs the same way, with the same 12-digit code, over the same pinned TLS 1.3, on
the same wire (`Sources/StreamProtocol`). Nothing changes on the host: Sill.app 0.4.0 or later serves
it as it is.

Sill Viewer and the host features it relies on (picking a monitor, hidden screens, lock on
disconnect) are additions of this fork, **lovelymammoth/sill-plus**; they are marked *(sill-plus)*
below. Ready-made builds of both apps are on the fork's
[Releases page](https://github.com/lovelymammoth/sill-plus/releases) (signed ad hoc, not notarized:
right-click › Open the first time). What it does and does not do yet is under [Scope](#scope).

## Setup: Mac mini as the host, MacBook Pro as the client

### On the Mac mini (the Mac you want to see)

1. Install Sill from this fork's Releases page (`Sill-<version>.dmg`), or build it with
   `Scripts/make-app.sh --install --open`, and grant it Screen Recording and Accessibility, as for an
   iPad; then quit and reopen it. Sill for Mac 0.4.0 or later from getsill.app also serves the
   Viewer, but without monitor picking, hidden screens or lock on disconnect.
2. Leave Settings › Devices › Require pairing on (the default).
3. For use away from home through Tailscale: install Tailscale on the Mac mini, sign in, and turn on
   Settings › Remote Access in Sill. Sill then listens on its remote door (port 7455 unless you
   change it) and tells paired devices its Tailscale name and addresses. "Allow connections from the
   internet" stays off: Tailscale counts as your own VPN.
4. Keep the Mac mini awake and logged in (Energy settings: prevent automatic sleeping when the
   display is off). Sill holds off idle sleep only while a device is connected.
5. *(sill-plus)* Settings › General has **Hide this Mac's screens while a device is connected** and
   **Lock this Mac when the last device disconnects**, both on by default (see
   [The host while you are connected](#the-host-while-you-are-connected-sill-plus)).
6. *(sill-plus)* For a way back in if the Mac mini is locked while you are away, turn on macOS
   Screen Sharing (System Settings › General › Sharing); it works over Tailscale.

### On the MacBook Pro (the Mac you sit at)

1. Download `Sill-Viewer-<version>.zip` from the fork's Releases page, unzip it into Applications
   and open it with right-click › Open; or build and install it from this repository (Xcode 27
   selected as the developer directory):

   ```
   Scripts/make-client-app.sh --install --open
   ```

   It is signed with your Apple Development identity when the keychain has one, ad hoc otherwise
   (then the keychain asks once after each rebuild to let the new build read its key). Another
   bundle identifier: `SILL_CLIENT_BUNDLE_ID=com.example.sill.client`.
2. At the first launch macOS 15 and later ask for Local Network: allow it, or Bonjour finds nothing.
   Grant Sill Viewer Accessibility too (System Settings › Privacy & Security › Accessibility), for
   system shortcuts and trackpad gestures; after every new build, grant it again.
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
  stay the client's: ⌃⌥⌘D disconnects, ⌃⌥⌘F full screen. With Accessibility granted to Sill Viewer
  and Session › Send System Shortcuts to the Mac on (the default), the ones macOS keeps for
  itself go too while the picture has the keyboard: a keyboard event tap takes every key first, and
  the system's symbolic hot keys (⌘`, screenshots, Mission Control, Spaces, Spotlight, ⌘Tab where
  macOS lists them) are turned off for that time and back on the moment the app or the picture loses
  the keyboard, at quit, on a signal, and at the next launch after a crash. Click another app or the
  Dock to get this Mac's shortcuts back.
- **Monitors** *(sill-plus)*: when the Mac mini has more than one display, the bar shows a button for
  each, "Display 1 · LG HDR 4K" (the number keeps two monitors of one model apart). The Desktop
  streams the one you pick, and switches at once if it is already streaming.
- **Trackpad gestures** *(sill-plus)*: while the picture has control, three- and four-finger swipes
  and pinches go to the Mac mini instead of this Mac, with Session › Send Trackpad Gestures to the
  Mac on (the default; needs Accessibility). Swipe up: Mission Control. Swipe down: App Exposé.
  Swipe left or right: the next or previous Space. Pinch: Apps. Spread: Show Desktop. The client
  recognizes the gesture when the first finger lifts and the Mac mini runs its own shortcut for that
  action, so a gesture over a window first switches the picture to the Desktop, where Mission
  Control and Spaces show. If this Mac reacts as well (its Dock takes the gesture before the client
  can), turn those gestures off in System Settings › Trackpad › More Gestures while you use the
  Viewer.
- **fn-Esc** *(sill-plus)*: gives this Mac its own keyboard, trackpad and shortcuts back while the
  window stays open; the bar says "Control is on this Mac: click the picture or press fn-Esc". A
  click on the picture, or fn-Esc again, hands control back to the Mac mini.
- **Quality** (the bar's slider menu, from a Mac that sends kind 16): the Mac's Quality preset and
  Resolution, as its own menu has them (away from home they set its away quality), and the frame
  rate this client asks for: 60 fps by default; 120 on a ProMotion screen only when chosen, since
  the bitrate is per 60 fps and doubles. When the Mac reports that the link can't keep up, a line
  under the bar says so with the Mac's suggestion as a button.
- **Disconnect** (⌃⌥⌘D, or the button) ends the session; the Mac mini stops capturing once no device
  is connected.

## The host while you are connected *(sill-plus)*

Two settings in Sill › Settings › General on the Mac mini, both on by default (the CLI:
`--hide-screens`, `--lock-on-leave`):

- **Hide this Mac's screens while a device is connected**: while any device is connected, every
  monitor of the Mac mini goes dark and its own keyboard and mouse do nothing. The picture you see
  is unaffected: the screens are darkened at the displays' output (their gamma tables), after
  ScreenCaptureKit has read the frame, and no window covers anything. Input from the connected
  device is marked by Sill and passes; everything else is dropped. Without Accessibility only the
  screens go dark.
- **Lock this Mac when the last device disconnects**: when the last device leaves, the screens stay
  dark and the Mac mini ignores its own input for 10 seconds; a device that reconnects within that
  time finds it exactly as it left it. Then the Mac mini locks, and only once macOS reports it
  locked do the screens come back, showing the lock screen. Quitting Sill while the screens are
  hidden locks at once. Turning hiding off from a connected device shows the screens unlocked: that
  is your choice.

Unlocking from afar: right after Sill locks the Mac mini, macOS gives ScreenCaptureKit nothing to
capture, so a device that connects sees no picture. Once the lock screen has been woken (a key or a
mouse move at the Mac mini), a connected device sees it and can type the password; that is how the
Mac mini was unlocked from an iPhone on 2026-10-16. Away from home, keep macOS Screen Sharing on as
the way back in.

Known issue (2026-10-16, cause not found): after an overnight lock by Sill the Mac mini's own
keyboard and clicks did nothing on its lock screen while the pointer moved and an iPhone connected
through Sill could still type; it lasted until a restart. If it happens, don't restart: unlock it
through Sill from another device, then quit the Mac mini's other input utilities one at a time to
see which brings its keyboard back.

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

Built:

- Bonjour discovery, pairing at home (ask, then the code) and by address (the code, or a
  `sill://pair` link), saved Macs, sessions at home and through the remote door (Tailscale, a VPN, a
  forwarded port), dialed in the iOS client's order.
- The Desktop and single windows, app launch, window close/minimize/full screen.
- Mouse, right click, drag, phased trackpad scrolling, keys and text, the Mac's cursor shape.
- Statistics to the Mac (its log and menu show this Mac like any device).
- The host settings panel (kinds 16 and 17): the Quality menu.
- *(sill-plus)* System shortcuts and trackpad gestures (kind 28) to the Mac; fn-Esc; monitor
  picking (kind 40, `pickDisplay`); on the host, hidden screens and lock on disconnect.
- *(sill-plus)* Releases with both apps, signed ad hoc.

Not yet:

- The Mac's menus (kinds 24, 25, 27), the Mac's pointer while it moves (kind 26), Aa (window
  scaling) and a viewport scale.
- The clipboard (kind 32): Sill shares it with the iPhone and iPad app, but the Viewer does not
  subscribe to it yet.
- Two-finger pinch-to-zoom, rotate and smart zoom inside apps.
- Moving a live session between paths (home ⇄ Tailscale) without a reconnect; the automatic
  reconnect after a loss (the window offers Reconnect).
- A Retina-aware viewport (the client sends its size in points; the host streams at its own
  resolution setting).
- Pairing over a Thunderbolt or USB cable without a code (Sill.app's cable rule is for an iPhone's or
  iPad's NCM interface, not a Mac).
- An icon of its own and notarization (no Apple Developer ID: every build asks for its permissions
  again).
