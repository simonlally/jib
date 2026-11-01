# Privacy Policy

_Last updated: 1 November 2026_

Jib is an iPhone and Apple Watch app that controls Wi‑Fi smart bulbs on your own local
network. It is built to work without any server, account, or tracking.

## What the app stores

Jib keeps the following on your device only, in storage shared between the app, its
widgets, and the watch app:

- The bulbs you have added: a name you choose, the bulb's IP address, and an identifier
  the app generates.
- The last state the app saw for each bulb (on or off, brightness, colour), so widgets and
  the watch complication can show it while the bulb is unreachable.

Deleting the app deletes this data. Nothing is backed up by Jib itself; iCloud or iTunes
device backups may include it under Apple's own policies.

## What the app sends

Jib talks directly to bulbs on your Wi‑Fi network, and relays commands between the iPhone
and the paired Apple Watch over Apple's WatchConnectivity. It does not contact any server
operated by the developer or anyone else, and it contains no analytics, advertising, or
crash‑reporting software.

Scanning for bulbs probes addresses on your local subnet over TCP. The scan stays on your
network and sends only the request needed to tell whether a device is a compatible bulb.

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
