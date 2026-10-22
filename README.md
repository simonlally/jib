# Jib

iPhone app with an Apple Watch companion for Wi‑Fi smart bulbs that speak the local
port‑9999 JSON protocol (length‑prefixed frames, autokey‑XOR obfuscation). It talks to the
bulbs directly on your network. No cloud, no account.

Tested with a color bulb and a dimmable white bulb. Anything that answers `get_sysinfo`
with a `light_state` should work.

## What it does

**iPhone**
- Scan your subnet to find bulbs, or add one by IP address.
- Toggle power from the list; open a bulb for brightness, white temperature, hue/saturation,
  and the four presets stored on the bulb.
- Rename, re‑address, reorder and remove bulbs. The list is saved on the phone.

**Apple Watch**
- The bulb list syncs from the phone automatically.
- Tap a row to toggle. Swipe a row to open brightness (turn the crown) and presets.
- Every command is relayed through the iPhone over WatchConnectivity. watchOS doesn't let
  ordinary apps open raw TCP connections (Apple TN3135), so the watch needs the phone nearby.
  The simulator hides this restriction; only a real watch shows it.

## Controls outside the apps

**iPhone: Control Center and Lock Screen (iOS 18 or later)**
- Open the Control Center editor (long‑press Control Center, then *Add a Control*) or the Lock
  Screen customiser, add *Jib › Bulb*, and pick which saved bulb it toggles.
- The toggle runs in the `JibWidget` extension and talks to the bulb directly, so the app doesn't
  need to be running. Each time Control Center opens it asks the bulb for its real state, falling
  back to the last state the app saw if the bulb doesn't answer within a few seconds.
- The same action appears in Shortcuts as *Set Bulb Power*, with the bulb as a parameter.

**Apple Watch: complication and Smart Stack**
- Add *Jib › Bulb* to a watch face or the Smart Stack and pick a bulb. It shows the bulb's
  last‑seen state (on/off and brightness) in the rectangular, circular, corner and inline slots.
- Tapping it opens the watch app, which flips the bulb through the iPhone. A widget extension
  can't use WatchConnectivity, and watchOS blocks raw TCP, so the app has to do the relaying.
- The phone pushes state changes to the watch (application context, plus a complication
  user‑info transfer when a bulb goes on or off), so the complication keeps up while the watch
  app is closed.

Both read the saved bulb list from the App Group `group.dev.simonlally.Jib`
(`Shared/Store/BulbStorage.swift`), which also holds the last state seen for each bulb. The list
used to live in the app's own defaults; an existing list is moved over on first launch. To run on
devices, enable that group on the App IDs of all four targets (`Jib`, `JibWidget`, `JibWatch`,
`JibWatchWidget`) alongside setting your team.

## Building

Requirements: Xcode 26 or later, iOS 17 / watchOS 10 deployment targets.

Open `Jib.xcodeproj` and run the `Jib` scheme. The project file is the source of truth; there is
no generator step.

To run on your own devices, set your team under *Signing & Capabilities* for all four app
targets (`Jib`, `JibWidget`, `JibWatch`, `JibWatchWidget`). A free Apple ID (Personal Team)
is enough: App Groups work without a paid membership, but the profile expires after a week,
so re-run from Xcode when the app stops launching. Running the `Jib` scheme on an iPhone with
a paired watch installs both apps.

The first time the phone app touches a bulb, iOS asks for Local Network access. Allow it;
if you decline, every request fails until you re‑enable it in Settings → Privacy → Local Network.

## Layout

```
Jib.xcodeproj        Xcode project (targets: Jib, JibWidget, JibWatch, JibWatchWidget, JibTests)
Shared/Protocol/     Protocol code compiled into both apps
  FrameCipher.swift    autokey XOR framing
  BulbClient.swift     one request/reply over NWConnection, with connect + reply deadlines
  BulbCommands.swift   get_sysinfo / transition_light_state
  BulbModels.swift     LightState, BulbInfo, BulbAction, parsing
  BulbDiscovery.swift  subnet sweep
Shared/Models/       Bulb record, watch↔phone relay types, display colors
Shared/Store/        App Group storage: saved bulbs, last-seen states, jib:// links
Shared/Intents/      BulbEntity, the saved bulb as an App Intents entity
Jib/                 iPhone app (SwiftUI, @Observable store, WCSession host side)
JibWidget/           Control Center / Lock Screen control (ControlWidget + SetValueIntent)
JibWatch/            Watch app (list, crown brightness, WCSession client side)
JibWatchWidget/      Watch complication / Smart Stack widget
JibTests/            Unit tests for framing, parsing and actions
Tools/mockbulb.rb    Fake bulb on port 9999 for testing writes without touching real lamps
```

## Tests

```bash
xcodebuild test -project Jib.xcodeproj -scheme Jib -destination 'platform=iOS Simulator,name=iPhone 17'
```

To exercise the write path (toggles, sliders, the control) without switching real lamps, run the
fake bulb and add `127.0.0.1` in the simulator (or this Mac's LAN address on a device):

```bash
ruby Tools/mockbulb.rb
```

`LiveBulbTests` is skipped unless you point it at a real bulb:

```bash
TEST_RUNNER_TEST_BULB_HOST=192.168.1.23 xcodebuild test -project Jib.xcodeproj -scheme Jib \
  -destination 'platform=iOS Simulator,name=iPhone 17' -only-testing:JibTests/LiveBulbTests
```

## Protocol notes

- Request and reply frames are `[4‑byte big‑endian length][XOR'd JSON]`.
- `transition_light_state` echoes the resulting `light_state`, so set commands don't need a
  follow‑up `get_sysinfo`.
- When a bulb is off, `light_state` carries the remembered color under `dft_on_state`.
- Bulbs waking from Wi‑Fi power save can take 2–3 s to answer their first request, so the
  client bounds the TCP handshake tightly (1.5 s in sweeps) but allows a longer reply window.
- The bulbs' native discovery is a UDP broadcast, which iOS reserves for apps with the multicast
  entitlement. Jib sweeps the /24 over TCP instead.
