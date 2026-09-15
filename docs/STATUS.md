# Status

_Last updated: 2026-09-15. Two tests with a real Pocket 3: Files (build `776be7d`) and Files + Live (build 25, branch `ui/te-style`). Not yet tested with hardware: Webcam, photo in Photo mode, permissions with the app opened from Finder, first pairing._

## Next hardware test (in this order)

1. **Progress bar with clips > 4 GiB** — download a long clip (the manifest size is u32): the total and the time remaining must be correct from the start (log: `library: … is N MB (listed as M MB)`).
2. **Photo** in Photo mode (Live); pagination with > 45 files; first pairing if possible (reset the camera).
3. **Webcam** — plug in over USB-C, choose Webcam on the camera, check the picture; camera permission.
4. **Permissions with the app opened from Finder** (not Terminal): Bluetooth, Location (grant and deny), Local Network (deny, then allow), Downloads, Camera, Notifications.

Ask for the log `~/Library/Logs/Osmotic/osmotic-*.log` from each test.

## Verified with a real Pocket 3 (2026-09-15, build 25, log `osmotic-20260915-023644.log`)

Files + Live, everything worked on the first try: BLE (already paired), Wi-Fi via CoreWLAN on the first attempt, playback via `0x01/0x01`, 11 files. **Live**: leaving playback (`0x02/0x0c` → `e0`, then START), live view 17 ms after the request, 0 fragments lost; record → `camera recording: YES`, stop → `no`; Photo, Slow-mo and Low light modes confirmed by the camera status; back to the card with a relist (1 new clip). Downloads at ~33 MB/s, backup `.WAV`, resume at 3685 MB of a clip over 4 GiB, cancel and disconnect; back on the home network in 4 s (again `-3900 tmpErr` from `networksetup`, but macOS rejoins on its own).

Fixed after this test: (1) the manifest size is u32, and a clip over 4 GiB showed a "wrapped-around" size — the bar reached 100% with 00:00 remaining. Now the real size is requested via HEAD for videos longer than 2 min, and the downloader reports the server's size (`onTotal`). (2) The `networksetup` error repeated the home network name in the log: it is now masked. (3) Free space was logged every 400 ms while recording: now once per GB.

## Verified with a real Pocket 3 (2026-09-14, build `776be7d`, log `osmotic-20260914-175922.log`)

The whole Files flow worked on the first try: BLE armed (MTU 512), already paired (`0x01`), SSID and password over BLE, CoreWLAN `associate` on the first attempt (no `networksetup`), route via `en0`, handshake udp/9004, `0x02/0x0c` → `e0` → playback via `0x01/0x01` in 5 frames, 9 files (SD), 4 MP4 + 4 WAV downloaded (1.97 GB at ~32 MB/s), leaving playback, back on the home network. The files are valid MP4s. On restore, `networksetup -setairportnetwork` returned `-3900 tmpErr`, but macOS was already rejoining on its own; the IP check detected it in 4 s.

## Verified without hardware

`swift test`: **83 tests in 20 suites**, green; also in CI (GitHub Actions, macos-26).
- Decoder identical to upstream on the **14 golden captures** (6 from Pocket 3); BLE/datalink frames identical to real captures.
- Session against `FakeCamera`: handshake, `0x02/0x0c` rejection, playback via `0x01/0x01`, list, inline pagination, leaving playback on close.
- Control against `FakeCamera` (`ControlTests`): leaving playback (two paths), record/stop, photo, mode, reassembled H.264 live view; Kaze byte vectors for ACK and routing.
- Downloads against `FakeHTTPServer`: drops with byte-exact resume, 404/500, Range ignored, manifest size smaller than the real one, HTML, redirects, 416.
- Robustness: untrusted file names (`PathSafetyTests`), random data in every network parser (`FuzzTests`, clean under AddressSanitizer).
- UI reviewed with `scripts/snapshot.sh` in English and Spanish (all screens).

## Changes to the Files path since the first test (tested with hardware on 2026-09-15)

- Manifest built only from `0x00/0x27` frames, per datagram (before: concatenated datagrams; a stray `0x55` with a valid CRC could swallow fragments — short list).
- Datalink: drops packets that don't come from the camera's IP; 8 MB cap on the manifest; pktType 0x02 is diverted away from the status parser only in capture mode.
- Downloads: complete only if the bytes match Content-Length/Content-Range (the manifest size is a hint); 416 with a complete `.part` finishes; HTML and redirects are rejected; local names sanitized; never deletes at the destination; `.part` never follows a symlink.
- Wi-Fi: only forgets the camera's network if the app added it; doesn't join an open network with the camera's name; `networksetup` with the password only from the 4th attempt; notice if it doesn't rejoin your network on its own.
- Camera password in the Keychain (only if typed by hand).
- Signed with hardened runtime + location and camera entitlements (`Resources/Osmotic.entitlements`); no `NSAllowsArbitraryLoads`. `NSAllowsLocalNetworking` is what enables HTTP to `192.168.2.1` on macOS 14+: don't remove it.
- Connection: "Try Again" fixed; a new connection waits for the previous Wi-Fi restore and for recoveries; `CameraSession.close()` idempotent.

## Reviews done (2026-09-14)

Measured performance (M4, demo): connection screen 7–15% → 0.3% CPU; cameras 13% → ~0%; Live 4% → 0.2%. Logs from demo/snapshot runs go to a temporary folder (before, they rotated out the real logs: the one from the hardware test was lost that way).

Security, implementation, UI/accessibility, Apple guidelines (distribution, privacy, HIG), formatting (`swift-format`). What was applied is in `CHANGELOG.md`; what depends on an Apple Developer account is below.

## To do (in order)

1. **Next hardware test** (above) and adjust based on the log.
2. Live: Timelapse/Hyperlapse (trigger via `02/01` or `02/02`?), "black first picture" trick (`02/18`), fallback re-registration if writes are lost, downloads in capture mode. See `docs/CONTROL.md`.
3. **Distribution**: Apple Developer account → `SIGN_IDENTITY=… NOTARY_PROFILE=… scripts/notarize.sh` (notarized DMG). Without it, macOS asks for permissions again on every build, and anyone who downloads it has to use "Open Anyway".
4. Move the app's testable logic (network decisions, download queue) into a library with tests.
5. Accessibility: visible focus ring on `CassetteKeyStyle` with full keyboard access; Increase Contrast variants.
6. Expand bursts/intervals (`_001` → frames) with the group-expand `0x00/0x26` mode `0x10` (today only the first one is downloaded).
7. Favorites and deletion on the camera (`0x02/0xbf`, `0x00/0x28`) — ported in Kotlin, not in Swift.
8. Clip trimming with `AVAssetExportSession` passthrough; updates with Sparkle 2.
9. Two files with the same name in different folders/cards go to the same destination (the Pocket 3 uses date-and-time names; it doesn't happen in practice).

Open question from the user: can the camera join the home Wi-Fi so the Mac doesn't lose Internet? The Pocket 3 joins networks only for RTMP *livestream*; nobody has documented downloads in that mode. Today: Ethernet or a tethered iPhone (cable) keeps Internet.

## How to diagnose a real test

Key log lines:
- `BLE: control channel armed` → GATT OK. `BLE: pairing reply 0x01/0x02` → pairing. `BLE: Wi-Fi password received` → credentials.
- `wifi: camera reachable at 192.168.2.1 (ssid …, ip …)` and `wifi: route to 192.168.2.1 goes via en0 ✓` → Wi-Fi OK.
- `datalink: handshake OK on udp/9004` → `playback mode held via 0x01/0x01` → `per-store lists — SD N` → list OK. `SD slice TRUNCATED` → short list (report it).
- `transfer: … saved` / `link dropped … resuming` → downloads.
- Live: `control: …` and `live: …` (see `docs/CONTROL.md`). Webcam: `webcam: found …`.
- Back home: `wifi: back on "X…" (N chars)` or `wifi: could not rejoin a network automatically`.
