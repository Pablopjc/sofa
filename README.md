# 🛋️ Sofa (native Swift version)

Native macOS rewrite of Sofa — watch movies and listen to music **together, in sync, from anywhere**. Menu bar app built with Swift, SwiftUI and AppKit. ~14 MB on disk (the Electron legacy version is ~239 MB).

The Electron original lives in `../Sofa` and is installed as **Sofa Legacy.app** — same sync protocol, so a Swift Sofa and a Legacy Sofa can share a room.

## Features (same as Legacy)

- **Watch parties**: one person hosts (embedded WebSocket relay on port 7420), friends join via `sofa://` invite links (iMessage/AirDrop share sheet) or by address.
- **Syncs your real players**: QuickTime, VLC, Chrome/Safari (YouTube, Netflix via its internal player API, Disney+…), Apple Music, Spotify — via AppleScript polling, plus a built-in AVPlayer with drag & drop and a bundled test video.
- Play/pause/seek mirroring with latency compensation and periodic drift correction.
- Audio card: built-in movie volume + system volume slider.
- Adaptive light/dark app icon (macOS 26+), template menu bar icon, popover-material panel.

## Build

```bash
./build.sh          # → dist/Sofa.app (universal: arm64 + x86_64)
```

## Releasing a new version

Sofa's **Check for Updates…** (⋯ menu in the panel) reads the latest GitHub
release of the repo named in `Info.plist` → `SofaUpdateRepo`.

One-time setup:

```bash
gh auth login                      # sign in to GitHub
gh repo create sofa --public --source=. --remote=origin --push
```

Then, for every new version:

```bash
./release.sh 2.1.0 "Apple TV support and faster sync"
```

That bumps the version in `Info.plist`, builds a universal `.app`, zips it,
commits, and publishes the GitHub release with the zip attached. Everyone's
**Check for Updates…** picks it up immediately.

The repo must be **public** — a private one would need an API token baked into
the app for the update check to work.

Requires Xcode command line tools (Swift 6+). If Xcode 26+ is installed, the build embeds the adaptive light/dark icon via `actool`; otherwise it falls back to the classic `.icns`.

## Project layout

- `Sources/Sofa/main.swift` — entry point
- `Sources/Sofa/App.swift` — status item, panel (NSVisualEffectView popover), sofa:// handling
- `Sources/Sofa/AppState.swift` — central observable state + room lifecycle
- `Sources/Sofa/SyncEngine.swift` — WebSocket relay (NWListener) + client (NWConnection), JSON protocol
- `Sources/Sofa/PlayerBridge.swift` — AppleScript bridge to external players
- `Sources/Sofa/BuiltinPlayer.swift` — AVPlayer with sync events
- `Sources/Sofa/Views.swift` — SwiftUI UI (idle + room)
- `Resources/` — demo video, icns, Icon Composer bundle

## Gotchas learned the hard way

- `NWConnection` + WebSocket **requires a URL endpoint** (`.url(ws://…)`); a host:port endpoint aborts with POSIX 53.
- Use `application(_:open:)` for URL schemes — manual `NSAppleEventManager` registration gets overwritten by AppKit.
- If multiple app copies register the `sofa:` scheme, macOS may route links to whichever is running — keep dev builds unregistered (`lsregister -u`).
