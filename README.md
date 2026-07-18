# 🛋️ Sofa (native Swift version)

Native macOS rewrite of Sofa — watch movies and listen to music **together, in sync, from anywhere**. Menu bar app built with Swift, SwiftUI and AppKit. ~14 MB on disk (the Electron legacy version is ~239 MB).

The Electron original lives in `../Sofa` and is installed as **Sofa Legacy.app** — same sync protocol, so a Swift Sofa and a Legacy Sofa can share a room.

## Features (same as Legacy)

- **Online watch parties**: both Macs connect out to an encrypted public WSS relay, so friends on different home networks can join through a `sofa://` invite link. Only tiny sync/presence messages cross the relay; video and call audio never do.
- **Local mode remains available**: the embedded WebSocket relay on port 7420 still powers Test Zone, same-Wi-Fi parties and old invite links.
- **Syncs your real players**: QuickTime, VLC, Chrome/Safari (YouTube, Netflix via its internal player API, Disney+…), Apple Music, Spotify — via AppleScript polling, plus a built-in AVPlayer with drag & drop and a bundled test video.
- Play/pause/seek mirroring with latency compensation and periodic drift correction.
- Audio card: built-in movie volume + system volume slider.
- Adaptive light/dark app icon (macOS 26+), template menu bar icon, popover-material panel.

## Build

```bash
./build.sh          # → dist/Sofa.app (universal: arm64 + x86_64)
```

## Installing and sharing

Send friends the single `Sofa-<version>.dmg` file. They open it, drag Sofa to
Applications, then use right-click → Open the first time. The extra first-open
step is required until Sofa is signed and notarized with an Apple Developer ID.

The browser Theater helper is already embedded in Sofa; friends do not need the
separate extension archive.

## Releasing a new version

Sofa's **Check for Updates…** (⋯ menu in the panel) reads the latest GitHub
release of the repo named in `Info.plist` → `SofaUpdateRepo`.

One-time setup:

```bash
gh auth login                      # sign in to GitHub
gh repo create sofa --public --source=. --remote=origin --push
```

Once the source and `Info.plist` already contain the new version, publish it with:

```bash
./release.sh 0.1.26 "FaceTime support in Theater mode"
```

The release script requires a clean `master` already pushed to GitHub. It builds
and validates the universal app, tags that exact source commit, uploads the DMG
and updater ZIP as a draft, downloads both again for a byte-for-byte check, and
only then makes the release public. Everyone's **Check for Updates…** then
offers the new version.

The repo must be **public** — a private one would need an API token baked into
the app for the update check to work.

Requires Xcode command line tools (Swift 6+). If Xcode 26+ is installed, the build embeds the adaptive light/dark icon via `actool`; otherwise it falls back to the classic `.icns`.

## Project layout

- `Sources/Sofa/main.swift` — entry point
- `Sources/Sofa/App.swift` — status item, panel (NSVisualEffectView popover), sofa:// handling
- `Sources/Sofa/AppState.swift` — central observable state + room lifecycle
- `Sources/Sofa/SyncEngine.swift` — public WSS + local WebSocket clients, embedded LAN relay and JSON protocol
- `Sources/Sofa/RoomTarget.swift` — strict parser for versioned online and legacy LAN invitations
- `Sources/Sofa/PlayerBridge.swift` — AppleScript bridge to external players
- `Sources/Sofa/BuiltinPlayer.swift` — AVPlayer with sync events
- `Sources/Sofa/Views.swift` — SwiftUI UI (idle + room)
- `Resources/` — demo video, icns, Icon Composer bundle
- `Relay/` — Cloudflare Worker + Durable Object used by online rooms

## Gotchas learned the hard way

- `NWConnection` + WebSocket **requires a URL endpoint** (`.url(ws://…)`); a host:port endpoint aborts with POSIX 53.
- Use `application(_:open:)` for URL schemes — manual `NSAppleEventManager` registration gets overwritten by AppKit.
- If multiple app copies register the `sofa:` scheme, macOS may route links to whichever is running — keep dev builds unregistered (`lsregister -u`).
