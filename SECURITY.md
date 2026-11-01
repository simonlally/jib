# Security

## Reporting a vulnerability

Please do not open a public issue for a security problem. Use the repository's private
vulnerability reporting (the *Security* tab, then *Report a vulnerability*) so the report
reaches the maintainer without being visible to others. You should hear back within a week.

## What Jib's trust model is

Jib speaks the bulbs' own local protocol: unauthenticated TCP on port 9999 with a trivial
XOR obfuscation that anyone on the network can undo. That is a property of the bulbs, not
something the app can strengthen. In practice this means:

- Anyone on the same Wi‑Fi network can control the bulbs, with or without Jib.
- Jib is meant for a home network you trust. Do not forward port 9999 to the internet.
- Bulb names, addresses, and last‑seen states stay on your devices, in storage shared
  with Jib's own extensions. Jib syncs them to your paired Apple Watch over Apple's
  WatchConnectivity and never uploads them to any server.

## Scope

Reports about the app's own code are welcome: the frame parser, discovery sweep, storage,
widget and watch relay, and anything else in this repository. Weaknesses in the bulbs'
firmware or protocol are out of scope, since the app cannot fix them.
