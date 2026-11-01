# Privacy Policy

_Last updated: 1 November 2026_

Jib is an iPhone and Apple Watch app that controls Wi‑Fi smart bulbs on your own local
network. It is built to work without any server, account, or tracking.

## What the app stores

Jib keeps the following on your device only. The iPhone holds one copy, shared between
the app and its Control Center control; the Apple Watch holds its own copy, shared between
the watch app and its complication, and refreshed from the phone:

- The bulbs you have added: a name you choose, the bulb's IP address, and an identifier
  the app generates.
- The last state the app saw for each bulb (on or off, brightness, colour), so widgets and
  the watch complication can show it while the bulb is unreachable.

Deleting the app deletes this data from that device. Nothing is backed up by Jib itself;
iCloud or computer backups of the device may include it under Apple's own policies.

Schedules are different: they are written to the bulb and run from the bulb's own clock.
Removing a bulb from Jib, or uninstalling Jib, does not remove schedules already stored on
the bulb. Delete them from the bulb's schedule screen first if you no longer want them.

## What the app sends

Jib talks directly to bulbs on your Wi‑Fi network, and relays commands between the iPhone
and the paired Apple Watch over Apple's WatchConnectivity. It does not contact any server
operated by the developer or anyone else, and it contains no analytics, advertising, or
crash‑reporting software.

Scanning for bulbs probes the 254 addresses of one IPv4 /24 range over TCP, sending only
the request needed to tell whether a device is a compatible bulb. By default that range is
the Wi‑Fi network the iPhone is on. You can type a different range, in which case the probes
go wherever that range routes; use ranges that belong to your own network.

The bulbs' protocol is unauthenticated and only lightly obfuscated. Anyone on the same
network can read or send the same commands. Jib is intended for a home network you trust,
and bulb ports should never be exposed to the internet.

## Permissions

- **Local Network.** Required to reach the bulbs. iOS asks for it the first time the app
  connects. Without it the app cannot control anything.

No other permissions are requested. Jib does not access your location, contacts, photos,
microphone, camera, or any identifier for advertising.

## Data collection

Jib collects no personal data and does not track you across apps or websites. There is
nothing for the developer to see, share, or sell.

## Children

Jib is a general‑purpose utility and does not knowingly collect any information from anyone,
including children.

## Changes

If a future version changes what the app stores or sends, this document will be updated and
the change noted in the release notes.

## Contact

Questions about this policy can be raised as an issue on the project's source repository.
Security concerns should go through the private reporting route described in SECURITY.md.
