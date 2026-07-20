# 🛋️ Sofa

**Watch movies and shows with friends, perfectly in sync — each of you on your own Mac.**

Sofa is a tiny macOS menu bar app for long-distance movie nights. One person starts a watch party and shares a link; when a friend clicks it, both players stay in lockstep: play, pause and skips mirror instantly, with automatic drift correction. Your video and audio never leave your Mac — only tiny "play/pause/position" messages do.

## Why Sofa

- **Works with what you already use.** No special player and no re-uploading files. Sofa syncs **QuickTime, VLC, the Apple TV app**, and **YouTube, Netflix, Prime Video, Disney+ and any HTML5 video** playing in Safari or Chrome. Each person uses their own account and their own copy.
- **One link to watch together.** `sofa://` invite links carry the room and its secret — click and you're in. Works across different homes, networks and countries via an encrypted relay; same-Wi-Fi mode needs no internet relay at all.
- **Saved friends.** Exchange a friend link once, and from then on invite each other from inside the app — the invitation pops up on the friend's Mac with one-click Join.
- **Theater mode.** Blacks out the desktop, makes the movie as big as it fits, and keeps your FaceTime call beside it — no overlap. There's even an independent FaceTime volume slider so the call never drowns the movie.
- **Light on your Mac.** Native Swift, ~15 MB on disk, 0% CPU when idle, universal binary for Apple Silicon and Intel.

## Install

1. Download the latest **`Sofa-<version>.dmg`** from [Releases](https://github.com/Pablopjc/sofa/releases/latest).
2. Open it and drag **Sofa** to **Applications**.
3. Launch Sofa — it lives in your **menu bar** (🛋️ icon, no Dock icon).

Updating later is built in: menu bar 🛋️ → ⋯ → **Check for Updates…**

**Requirements:** macOS 14 Sonoma or newer, Apple Silicon or Intel.

## First-time permissions (and why)

Sofa asks only for what its features physically require, when you first use them:

| Permission | Asked when | Why |
|---|---|---|
| **Automation** (control QuickTime, Safari, etc.) | First sync with that player | This *is* the sync mechanism — Sofa presses play/pause/seek in your player for you. |
| **Allow JavaScript from Apple Events** (browser setting) | Syncing browser video | Lets Sofa read and control the web player in the active tab. One-time setup per browser. |
| **Accessibility** | First use of Theater mode | Moving/resizing other apps' windows (your player, your call) requires it. |
| **System Audio Recording** | First use of the FaceTime volume slider | The call's audio is attenuated in memory and played straight back out. It is never stored or transmitted. |

Sofa never sees, records or transmits your video or call audio. See [PRIVACY.md](PRIVACY.md) for the full picture of what data moves where.

## How syncing works (short version)

- **Online parties:** both Macs open an outbound encrypted WebSocket to a relay (a Cloudflare Worker). The relay forwards small state messages (`play`, `pause`, `seek`, position ticks, presence) between room members. Rooms need a secret carried in the invite link; the relay enforces it. Rooms expire after 24 h.
- **Local parties / Test Zone:** one Mac hosts a WebSocket server on port 7420; no internet needed.
- Sofa watches your chosen player locally (AppleScript, ~1 s cadence) and applies friends' actions to it, with latency compensation.

## Building from source

```bash
./build.sh          # → dist/Sofa.app (universal: arm64 + x86_64)
```

Requires Swift 6+ (Xcode command line tools). The relay's source and test suite live in [`Relay/`](Relay/); maintainer docs are in [`CLAUDE.md`](CLAUDE.md).

## License

[MIT](LICENSE).
