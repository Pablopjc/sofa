# Sofa — Privacy

Sofa is built so that your movie night stays yours. This document lists everything Sofa stores or transmits, and everything it deliberately does not.

## What never leaves your Mac

- **Your video.** Sofa never captures, encodes or transmits the movie you're watching. Each participant plays their own copy or their own streaming account.
- **Your call audio.** The optional FaceTime volume slider processes the call's audio *in memory* on your Mac (attenuating it and playing it straight back out). Samples are never written to disk or sent anywhere.
- **Your screen.** Sofa takes no screenshots and does no screen recording.

## What is transmitted, and to whom

**To your party (through the sync relay or your LAN):**

- Playback state: play/pause, position in seconds, occasional position ticks.
- The **title** of what you're playing (e.g. the page title of a YouTube tab or a file name) and, when available, its public poster/artwork URL — shown to friends in the party so everyone can see you're on the same thing.
- Your **display name** (whatever you type in "Watching as") and presence (joined/left).

**To the sync relay (a Cloudflare Worker operated for Sofa):**

- The messages above, in transit between party members. Online rooms are addressed by a random ID and protected by a random 256-bit secret carried only in the invite link. Rooms expire automatically after 24 hours.
- For the saved-friends feature: your display name, your friends list (device IDs and names), and pending party invitations (which expire after minutes). The device credential that authenticates you is generated randomly at first launch and stored in the **macOS Keychain**; it contains no personal information and is never shown or logged.

There are **no analytics, no tracking, no ads, and no accounts** (no email, no password — the anonymous device credential is all there is).

**To GitHub:**

- "Check for Updates…" fetches the latest release metadata from the public GitHub API. GitHub sees an ordinary HTTPS request from your IP, the same as visiting the page in a browser.

## What is stored on your Mac

- Preferences (your display name, whether you've seen the welcome tour) in the standard app preferences.
- The anonymous social credential in the Keychain (service `com.pablo.sofa.native.social`). Deleting it resets your friends identity.

## Deleting your data

- Quit Sofa and delete the app; preferences live in the standard `~/Library/Preferences` location.
- Delete the Keychain item `com.pablo.sofa.native.social` to destroy your friends identity; server-side friend records reference only that anonymous ID and expire from inactivity.
- Rooms self-delete after 24 h; invitations after minutes.
