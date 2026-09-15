# Changelog

Format: [Keep a Changelog](https://keepachangelog.com/en/1.1.0/); versions: [SemVer](https://semver.org/). The `.app` build number is the commit count.

## [Unreleased]

### Changed
- README and project docs are in English only (the app itself stays in English and Spanish).

## [0.2.0] — 2026-09-15

Tested with an Osmo Pocket 3: connection, file list, downloads, live view, start/stop recording, and mode switching.

### Added
- **Files · Live · Webcam** tabs. Live: start/stop recording, photo, modes (Video, Photo, Slow-mo, Low light), and live view over Wi-Fi. Webcam: the camera plugged in over USB in webcam mode.
- `.dmg` installer (drag to Applications) with every release, with a note for the first launch of a non-notarized build.
- New README in English and Spanish, with screenshots.
- English interface with a Spanish translation; dark audio-gear theme (cassette keys, LCD screens, LEDs).
- Arrow-key navigation in the grid; VoiceOver on cells, filters, LEDs, and stages; Reduce Motion.
- Universal binary (Apple silicon + Intel); licenses and credits inside the app; Developer ID signing and notarization scripts.

### Updates and credits
- Automatic updates from GitHub Releases (Settings › Updates, Check for Updates… menu): downloads, verifies the Ed25519 signature and the bundle, replaces the app, and relaunches it. `scripts/release.sh` builds and signs the release; it publishes only with `--publish`.
- Settings › Credits: the people who made the app possible (Osmosis, Kaze for DJI, OpenPocketCine, the protocol research, and the Osmosis testers).

### Performance
- The app now uses almost nothing when idle: LEDs blink in two steps (no continuous animation), and everything animated, Bluetooth scanning, and the webcam pause while the window is hidden (cameras screen: 13% → ~0% CPU).
- Thumbnails are scaled down to 560 px on arrival (~40 KB instead of ~460 KB) and kept in a size-limited cache; sorting and grouping a large card no longer freezes the window; download progress no longer redraws the whole grid.
- Long downloads with the window in the background: no App Nap while connected and no sleep while downloading.

### Fixed
- Clips over 4 GB: the camera's list reports the size in 32 bits, so the bar reached 100% with 00:00 remaining while the download continued. The real size (queried from the camera) is now used in the bar, the remaining time, and the grid.
- The Technical Log could include your Wi-Fi network name inside a `networksetup` error.
- In Spanish, each clip's size was truncated ("69,8…") because of the "p. m." time format: the resolution is now shortened first.
- **Security**: a camera file named `..` could delete the folder containing the downloads folder; a fake SSID could delete a saved network from the Mac; the camera's Wi-Fi password was stored in plain text.
- "Try Again" did nothing; connections and Wi-Fi restores could overlap; downloads could be marked complete with missing bytes or an HTML page.
- The card's file list could come back short (a status packet "swallowed" fragments).
- Location permission under the hardened runtime (without it, your Wi-Fi name could not be read).

## [0.1.0] — 2026-09-14

First version: downloads from an Osmo Pocket 3 over BLE + Wi-Fi, verified with real hardware.
