# Osmotic — guide for agents (and people)

Single entry point: read this first. It tells you where everything is and how to make the usual changes without walking the code. `AGENTS.md` is a link to this file.

## What it is

Native macOS app (Swift 6.2, SwiftUI, macOS 15+) for DJI Osmo cameras (target: **Pocket 3**), with three tabs:
- **Files**: downloads media over BLE → the camera's Wi-Fi → UDP datalink → HTTP to `~/Downloads/DJI`.
- **Live**: capture control (record, photo, mode) and live view over the same datalink.
- **Webcam**: the camera plugged in over USB-C as a UVC webcam (Zoom, Meet and OBS see it too).

Port of [KonradIT/osmosis](https://github.com/KonradIT/osmosis) (Android/Kotlin); control and live view follow [Kaze for DJI](https://github.com/brianmerchant/Kaze-for-DJI) (MIT). Repo `github.com/smithplus/Osmotic`, branch `main`; releases on GitHub Releases (v0.2.0 is the first with a DMG).

Languages: the UI is **English, localized to Rioplatense Spanish** (String Catalog); code, comments, commits and docs are in English.

## Status in one line

Tested with a real Pocket 3: Files (2026-09-14) and Files + Live (2026-09-15: live view, record/stop, modes, relist). Not yet tested on hardware: Webcam, a photo in Photo mode, permissions from Finder, first-time pairing. Details: `docs/STATUS.md`.

## Where to read

| For… | Read |
|---|---|
| what's done / tested / pending | `docs/STATUS.md` |
| file map, flows, threads | `docs/ARCHITECTURE.md` (use it instead of walking the code) |
| protocol (BLE, datalink, list, HTTP) | `docs/PROTOCOL.md`; details in upstream's `MEDIA_PROTOCOL.md` |
| Live tab (control, live view) | `docs/CONTROL.md`; spec with sources: `docs/CONTROL_SPEC.md` (§7 = unverified) |
| security and privacy | `SECURITY.md` |
| user-facing history | `CHANGELOG.md` |
| credits (shown in Settings › Credits) | `Sources/Osmotic/App/Credits.swift` |
| landing page (GitHub Pages) | `site/` (static HTML/CSS/JS, the app's tokens in CSS), `.github/workflows/pages.yml` |

## Commands

```bash
swift build                      # app + core
swift test                       # 83 tests in 20 suites (~50 s; the session and control e2e tests take 10–16 s each)
swift test --filter Golden       # only the decoder snapshots
scripts/lint.sh [--fix]          # swift-format (.swift-format: 4 spaces, 130 columns); CI enforces it
scripts/sync_strings.sh          # new strings → Resources/Localizable.xcstrings; lists the untranslated ones
scripts/package_app.sh [debug]   # build/Osmotic.app (release = universal arm64+x86_64); ad-hoc unless SIGN_IDENTITY
scripts/notarize.sh              # Developer ID build + DMG + notarization (needs an Apple Developer account; see the script)
scripts/snapshot.sh out.png [library|connecting|cameras|camera|webcam] [manifest.bin]   # render without hardware; needs build/Osmotic.app
scripts/release.sh X.Y.Z [--publish]   # DMG + signed zip for the updater (see "Release")
scripts/build_site.sh            # landing page → build/site (site/ + docs/images); preview: "site" in .claude/launch.json
swift scripts/make_icon.swift .  # Resources/AppIcon.icns + docs/images/icon.png ("o." on graphite)
```

- CI: `.github/workflows/ci.yml` (macos-26): format, build, tests, packaging on every push to `main`/`ui/**`. `pages.yml` publishes the landing page on pushes to `main` that touch `site/` or `docs/images/`.
- Every run writes a log to `~/Library/Logs/Osmotic/osmotic-*.log` (Window › Technical Log, ⌥⌘L). It is the source of truth for diagnosing tests with the real camera; the key lines are in `docs/STATUS.md` and `docs/CONTROL.md`.
- Demo mode: `OSMOTIC_DEMO_MANIFEST=<fixture.bin> [OSMOTIC_DEMO_SCREEN=connecting|cameras|camera|webcam] [OSMOTIC_DEMO_THUMBS=<folder of .jpg>] [OSMOTIC_LANG=es]`. No screen: library with a download half done; `camera` = Live tab recording.
- No screen-recording permission: `screencapture` doesn't work; `scripts/snapshot.sh` uses `ImageRenderer` (AppKit controls and the live view aren't drawn; `ScrollView`s come out blank — that's why views take `scrolls: false`).
- Permissions: launching from Terminal hides Local Network problems (they don't apply to Terminal's processes); test them by opening the app with `open build/Osmotic.app` or from Finder.

## Recipes

**New UI text.** Write it in English. `Text("…")`, `Button("…")`, `.help("…")`, `Silk("…")`, `LCDPair(label:)`, `BankLegend`, `SectionIndex(title:)`, `Notice(text:)`, `LED(label:)` are localized automatically (`LocalizedStringKey`). For a `String` (model messages, `LCDText(text:)`): `String(localized: "…")`. For data (file name, date): `Silk(verbatim:)`, `Notice(verbatim:)`, `Text(verbatim:)`. Then run `scripts/sync_strings.sh` and add the Spanish in `Resources/Localizable.xcstrings` (plurals: `plural` variations, see `"%lld files"`).

**New system permission.** Usage key in `Resources/Info.plist` (English) + the same in `Resources/es.lproj/InfoPlist.strings` + an entitlement in `Resources/Osmotic.entitlements` if the hardened runtime protects the resource (location, camera, microphone…) + a row in the README's permissions table and in `SECURITY.md`.

**New camera command.** Always as a job on `CameraSession`'s thread (never from another thread). In capture mode: `drainStale()` → `send(set, cmd, payload, rType:, rId:)` → `awaitReply(set:cmd:timeout:)` and, if the state needs confirming, `pumpUntil { tracker.status… }`. New status field: `StatusTracker.apply` + `CameraStatus` + `displaySignature`. Test it against `FakeCamera` (add the behavior in `command(_:)`).

**New screen or tab.** `AppModel.Workspace` + `setWorkspace` + `WorkspaceTabs`; a view with `TopPlate` and `Theme` parts; a case in `SnapshotView`/`loadDemo` so `snapshot.sh` can render it.

**Release (and auto-update).** A `## [X.Y.Z]` section in `CHANGELOG.md`, commit, `scripts/release.sh X.Y.Z` (dry run: local tag, universal app, `build/Osmotic-X.Y.Z.dmg` for manual installs — with `scripts/dmg_readme.txt` as "Read Me First" — and `build/Osmotic-X.Y.Z.zip` + `.sig` signed with the Keychain key, for the updater) and, **only with the user's explicit permission**, `scripts/release.sh X.Y.Z --publish` (pushes the tag and creates the release with `gh`; `NOTES_FILE=…` for notes other than the CHANGELOG section). The installed app finds it through `UpdateService` (`api.github.com/.../releases/latest`) and installs it if the signature matches `OsmoticUpdatePublicKey` (Info.plist). The private key: `swift scripts/update_key.swift` (Keychain, service `io.github.smithplus.osmotic.update-signing`); if it's lost, generate another and change the public one — users then install that version by hand once. For Developer ID + notarization: `SIGN_IDENTITY=… NOTARY_PROFILE=… scripts/notarize.sh`.

## Project rules

- `OsmoticCore` is **nonisolated** and has no UI; `Osmotic` (the app) uses `defaultIsolation(MainActor)`. Exception: `LiveVideoRenderer` is `nonisolated` (it receives H.264 on the session's thread and decodes on its own queue). Every `@unchecked Sendable` carries a comment justifying why it's safe.
- The decoder (`ManifestDecoder`) must match upstream's golden files **byte for byte** (`Tests/OsmoticCoreTests/Fixtures/golden`). Improvements go in a later step (e.g. `inferMissingExtensions`) or in what it's fed (`CameraSession.collect` builds the blob only from `0x00/0x27` frames), never in the decode itself.
- `CameraSession`: **one thread** owns the socket; every protocol step is a job on its queue. Modes `.media` (playback, list, downloads — the tested path, `.legacy` ACK) and `.capture`/`.live` (`.mimo` ACK). Don't change `.media` behavior without testing it on hardware again.
- The camera is an **untrusted** peer: validate everything it sends (names → `CameraFile.localName`, sizes, frames, HTTP). The manifest's file size is a u32 (wraps above 4 GiB): only the server's `Content-Length`/`Content-Range` counts (`FileDownloader`, `AppModel.probeRealSizes`). Robustness tests: `FuzzTests`, `PathSafetyTests`, `DownloaderTests`.
- Restoring Wi-Fi must finish even if the task that asked for it was cancelled: `WiFiService.pause` (not cancellable) and `AppModel.cleanup` (its own task, kept in `teardownTask`; a new connection waits for it).
- Logs never carry the user's SSID (`redactedSSID`, also inside `networksetup` output) or passwords (length only).
- Credits: Osmosis (MIT) in README, LICENSE and comments; Kaze for DJI (MIT, parts adapted; LICENSE names it); OpenPocketCine (Apache-2.0, only re-implemented from its documentation: if code is ever copied, add its NOTICE). Don't use "DJI"/"Osmo" as a product name.
- New tests use Swift Testing (`@Test`, `#expect`). Simulators: `FakeCamera` (the Pocket 3 datalink: playback, list, capture mode with pktType 0x03 replies, fragmented H.264 stream) and `FakeHTTPServer` (in `DownloaderTests.swift`: cuts, 404/500, ignored Range, HTML, redirects, 416). `ThroughputProbe` only runs with `OSMOTIC_PERF=1`.

## UI (design system)

- Dark audio-gear look (graphite, amber `LABEL: value` readouts, LEDs). Few elements per panel: no decorative icons. Dark mode forced on every scene; there is no light theme. Colors, spacing (`Theme.s1…s6`) and radii (`radiusS/M/L`) come from `Theme`.
- One kind of button: `CassetteKeyStyle` inside a `CassetteKeyBank`. Orange (`.primaryKey`) only for the screen's main action; everything else `.secondaryKey`/`.compactKey`. Exclusive groups (tabs, filters, modes): `CassetteKeyStyle(latched: selected, width:)`. Exceptions: the checkbox and play button on photos (`.plain` + `Depth.onImage`); Settings, dialogs and the Log use system controls. Same action → same name across the app ("Show in Finder", "Disconnect", "Download …").
- Shadows only through the `Depth` tokens: `raisedShadow()` for raised things, `Pocket`/`recessed()` for sunken ones (`deep` for screens and slots), `Depth.glow` for lit ones, `Depth.onImage` over photos. No loose `.shadow(color:radius:)`; the only radius-0 token is `Depth.lipLight` (screws).
- Motion only through `Motion` via `.motion(_:value:)` (respects Reduce Motion): key down `press`, up `release`, panels `panel` with `.panelFromTop`/`.trayFromBottom`, lights `bloom`, state `quick`. LCD screens don't fade (`LCDGlass` already applies `LCDBoot` and `.transaction { $0.animation = nil }`). No `scaleEffect` on hover.
- Accessibility: every control has a VoiceOver label and state (`.isSelected` in groups, value on LEDs); contrast ≥ 4.5:1 (`Theme.muted` meets it).
- Visual references the user approved: Teenage Engineering's EP-133 and the "BASSBOI" VST (Dribbble). Check with `snapshot.sh` before showing anything.
- Window chrome: `.hiddenTitleBar`; the window buttons sit in a 32-pt band above the content (x 9…69, y 9…23 pt — `snapshot.sh` logs it), so `TopPlate` keeps no room for them and the wordmark lines up with the panels. Wordmark: "osmotic." with the dot on the baseline; the icon is its "o.".
- Landing page (`site/`): same tokens as `Theme` in CSS (keys, LCD, panels with screws), no web fonts, no dependencies, strict CSP (no inline script/style). Keep its copy in step with the README.
- README screenshots (`docs/images/`): `snapshot.sh` with `OSMOTIC_LANG=en OSMOTIC_LOCALE=en_US`, fixture `op3_15.bin` and `OSMOTIC_DEMO_THUMBS` pointing at synthetic scenes (never the user's footage or saved cameras: demo mode doesn't read them), cropped and framed (title-bar band with the window buttons, rounded corners, shadow) at 1280–1400 px. Regenerate them when the UI changes; the landing page uses the same files.

## Saved state (where it lives)

- Bundle id `io.github.smithplus.osmotic`. Preferences in UserDefaults (`Preferences`; `pending*` = recovering an interrupted session).
- Download history: `~/Library/Application Support/Osmotic/downloaded.json`. Thumbnails: `~/Library/Caches/io.github.smithplus.osmotic/thumbs`.
- The camera's Wi-Fi password (only if typed by hand): Keychain, service `io.github.smithplus.osmotic.camera-wifi`.

## Known traps

- `Settings` clashes with the SwiftUI scene → preferences are `Preferences`.
- macOS `sed` supports neither `\b` nor `\|`: use `perl -pi -e` or Python for replacements. macOS bash is 3.2: empty arrays with `set -u` → `${a[@]+"${a[@]}"}`.
- `git mv` doesn't work on uncommitted files.
- `String(format: "%d")` truncates to 32 bits: use `%ld` with `Int`.
- Hardened runtime: without the location entitlement the SSID stays hidden and the Mac doesn't go back to the home network.
- Ad-hoc signing makes macOS ask for permissions (and Keychain access) again on every build.
- A short `recvAll(ms:)` without `precise:` doubles as the pause between sends in the list flow (tuned on hardware); `precise: true` only in the capture pump.
