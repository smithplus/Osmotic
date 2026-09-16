# Changelog

Format: [Keep a Changelog](https://keepachangelog.com/en/1.1.0/); versions: [SemVer](https://semver.org/). The `.app` build number is the commit count.

## [Unreleased]

### Added
- **Files off the card over USB-C.** With the camera plugged in and set to storage mode, its card mounts as a disk and Osmotic reads it directly: no Bluetooth, no Wi-Fi, no phone, and your Internet stays on. The cameras screen lists it under "Plugged in" with how fast the cable negotiated, and the library works as usual (day folders, dated when shot, skips what you already have, copies the `.WAV` beside a clip). Eject when you're done.

## [0.3.0] - 2026-09-15

Safer around the camera, easier to find your way, and a new look for the lights. Updating from 0.2.0 happens inside the app; macOS asks for its permissions once more because this build is not notarized yet.

### Added
- A Settings key on the top plate, next to Bluetooth and in the library beside Disconnect.
- A user guide (`docs/GUIDE.md`), which the Help menu now opens: every screen, the keyboard shortcuts and what to try when something fails.
- Settings › Credits names the maker and links a way to support the work.

### Security
- Sizes stated by the camera's web server are bounded, and small reads (thumbnails, preview stills) are capped: a device answering at the camera's address could otherwise crash the app or make it buffer without end.
- Quitting waits for Wi-Fi work still running (a Cancel or Disconnect handing the network back), and downloads can't start while Live is starting.

### Changed
- New app icon: the wordmark's "o." (a lowercase o and the orange dot) on a graphite plate.
- LEDs look like panel lamps: a domed lens in its bezel, with a halo on the plate when lit.
- Day folders are on by default.
- Orange keys are a shade darker so their white text stays readable (WCAG AA).
- VoiceOver: the LCD readouts read as one, progress meters report their value, and Connect and Download Day keys say which camera or day.
- Notices say what to do next; Spanish follows Latin American macOS ("la Mac", "Configuración del Sistema").
- The wordmark lines up with the panels below it, its dot on the baseline like a period.
- Thumbnails already decoded show at once when the grid redraws, instead of blinking in again.

### Website and docs
- A landing page at https://smithplus.github.io/Osmotic/: static HTML and CSS in the app's style, with a looping video of a whole session drawn by the app itself, a Live video, install steps, a comparison and an FAQ.
- README and project docs are in English only (the app itself stays in English and Spanish).

## [0.2.0] - 2026-09-15

Tested with an Osmo Pocket 3: connection, file list, downloads, live view, start/stop recording, and mode switching.

### Added
- **Files · Live · Webcam** tabs. Live: start/stop recording, photo, modes (Video, Photo, Slow-mo, Low light), and live view over Wi-Fi. Webcam: the camera plugged in over USB in webcam mode.
- `.dmg` installer (drag to Applications) with every release, with a note for the first launch of a non-notarized build.
- New README in English and Spanish, with screenshots.
- English interface with a Spanish translation; dark audio-gear theme (cassette keys, LCD screens, LEDs).
- Arrow-key navigation in the grid; VoiceOver on cells, filters, LEDs, and stages; Reduce Motion.
- Universal binary (Apple silicon + Intel); licenses and credits inside the app; Developer ID signing and notarization scripts.

### Updates and credits
- Automatic updates from GitHub Releases (Settings › Updates, Osmotic › Check for Updates…): downloads, verifies the Ed25519 signature and the bundle, replaces the app, and relaunches it. `scripts/release.sh` builds and signs the release; it publishes only with `--publish`.
- Settings › Credits: the people who made the app possible (Osmosis, Kaze for DJI, OpenPocketCine, the protocol research, and the Osmosis testers).

### Performance
- Idle CPU drops to ~0% (the cameras screen was at 13%). LEDs blink in two steps instead of animating, and animation, Bluetooth scanning and the webcam pause while the window is hidden.
- Thumbnails are scaled down to 560 px on arrival (~40 KB instead of ~460 KB) and kept in a size-limited cache; sorting and grouping a large card no longer freezes the window; download progress no longer redraws the whole grid.
- Long downloads with the window in the background: no App Nap while connected and no sleep while downloading.

### Fixed
- Clips over 4 GB: the camera's list reports the size in 32 bits, so the bar reached 100% with 00:00 remaining while the download continued. The real size (queried from the camera) is now used in the bar, the remaining time, and the grid (not yet tested with hardware).
- The Technical Log could include your Wi-Fi network name inside a `networksetup` error.
- In Spanish, each clip's size was truncated ("69,8…") because of the "p. m." time format: the resolution is now shortened first.
- **Security**: a camera file named `..` could delete the folder containing the downloads folder; a fake SSID could delete a saved network from the Mac; the camera's Wi-Fi password was stored in plain text.
- "Try Again" did nothing; connections and Wi-Fi restores could overlap; downloads could be marked complete with missing bytes or an HTML page.
- The card's file list could come back short (a status packet "swallowed" fragments).
- Location permission under the hardened runtime (without it, your Wi-Fi name could not be read).

## [0.1.0] - 2026-09-14

First version: downloads from an Osmo Pocket 3 over BLE + Wi-Fi, verified with real hardware.
