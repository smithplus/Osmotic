# Control panel and live view — research (2026-09-14)

Summary of a survey of repos (commits: Moblin `58d400e`, Kaze `341a35d`, OpenPocketCine `9b30b93`).

## Implementation status (2026-09-14)

Implemented and tested against `FakeCamera` (`ControlTests`), **not yet tested with the Pocket 3**:
- **Live** tab (`AppModel.Workspace.camera`, `CameraControlView`): leaves playback, records/stops, photo, mode (Video, Photo, Slow-mo, Low light), live view; on returning to **Files** it re-enters playback and rereads the card.
- `DatalinkTransport.windowModel`: `.legacy` (listing/downloads, tested) and `.mimo` (the official app's ACK: video/responses/TX groups, routing with the camera's ack) — capture mode only.
- `CameraSession` modes `.media/.capture/.live`; 12 ms pump (`recvAll(precise:)`) with ACK ≥ 40 Hz while there is video (50 ms / 10 Hz in capture without video); `drainStale()` before each command (a stale `E0` reply to the playback re-assert was mistaken for the command's reply).
- Leaving playback: `0x02/0x0C 01010000` ×2 → START of `0x01/0x01` without `09/A8` (so the keyframe isn't lost) → otherwise, error.
- Live view: Kaze's burst (receiver `0x41`); after 8 s without video, once, the OpenPocketCine variant (`0x02/0x68 [08]` + `09/A8` to `0x08`); `LiveReassembler` → `LiveVideoRenderer` (`AVSampleBufferDisplayLayer`); the monitor takes the stream's aspect ratio (portrait if the camera shoots portrait).
- Robust live view: a lost message makes the decoder wait for a keyframe and `09/A8` is requested (at most every 5 s; if it can't be sent yet, it stays pending and `controlTick` requests it); seq gaps are only counted (Kaze's rule).
- Tabs: leaving Live always returns to playback (`leaveLive`); you can't leave while recording or with a command in progress; Live only for Pocket models and with no downloads in progress.
- Status `0x02/0x80`: recording (bit 7 of @0), transition (bit 6), seconds @29, mode @57.

First hardware test — look in the log for: `control: 0x02/0x0c leave → …`, `control: out of playback (…)`, `control: record start → 0x00`, `camera recording: YES`, `live: first picture data … ms`, `live: no video 8 s … alternate`. If leaving playback fails or the picture stays black, see `docs/CONTROL_SPEC.md` (full specification with sources; §7 = unverified points).

To do: Timelapse/Hyperlapse (trigger via `02/01` or `02/02`?), "black first picture" trick (`02/18` round trip), fallback re-registration if writes are lost (`txLagSlots`), downloads in capture mode (today, entering Live with downloads in progress is blocked).

## Useful sources

| Repo | What it provides | Pocket 3 | License |
|---|---|---|---|
| brianmerchant/Kaze-for-DJI (Swift/iOS) | record, photo, modes, settings, gimbal, **direct H.264 live view** over datalink 9004 | tested | MIT |
| erik-sutton95/OpenPocketCine | live monitor, record, ISO/EV/WB, capture of Mimo's RTMP, recovery notes | tested (fw 01.06.10.04) | Apache-2.0 (only re-implemented from its documentation: no NOTICE needed as long as no code is copied) |
| eerimoq/moblin, dimadesu/dji-remote | RTMP livestream setup over BLE; Moblin has a Swift RTMP server | listed | MIT (+ HaishinKit BSD-3) |
| xaionaro-go/djictl | Wi-Fi join + RTMP | yes | CC0 |
| DJI Osmo-GPS-Controller-Demo (R-SDK) | official control over BLE | **no** (Action/360 only) | DJI EULA |

## Control commands (App `0x02` → Camera `0x01`, cmd_type `0x40`, over the datalink)

- Record: `0x02/0x02` `[01]` start / `[00]` stop (not a toggle: `[01]` while recording → `df`). Confirm via `0x02/0x80` byte 0 bit 7 (Pocket 3: `01→41→81`, stop `c1→01`).
- Photo: `0x02/0x01 [01]` (`d9` in video mode). Panorama `[07]`.
- Mode: `0x02/0xE1 [m]` — `00` SlowMo, `01` Video, `02` Timelapse, `05` Photo, `0A` Hyperlapse, `0C` Panorama, `18` Motionlapse, `28` Low-Light. Read back in `0x02/0x80` byte 57.
- Resolution/fps: `0x02/0x18` `[res][fps] 00 00 00`. Parameters: `0x02/0x8E` GET/SET.
- Before writing: widen the ACK (the pktType `0x03` group) and re-register if the session is >40 s old.

## Direct live view (recommended)

- Request: `0x09/0xA8` payload `00 04 02 00 00 00 00 00 00 00` (OpenPocketCine to receiver `0x08`; Kaze to `0x41` + `0x01/0x01` bursts). Which one is needed: **unverified**.
- Arrives as pktType `0x02`: first fragment `00 00 01 FF` + u32 LE length + 8 B meta + H.264 Annex-B 720p (~25 fps measured).
- ACK pktType `0x04` at ~40 Hz with the latest seq of `0x02` and `0x03` and our TX cursor. Ephemeral local port (binding :9004 cuts the video).
- Keyframes only by re-requesting `0x09/0xA8` after a drop (with a cooldown). Pocket 3: the first picture may stay black until a format change and revert with `0x02/0x18`.
- Decode with `AVSampleBufferDisplayLayer` (Kaze `Pocket3VideoOutput.swift`).

## RTMP (1080p alternative, later)

Over BLE: pair → `0x02/0x8E 01 01 1A 00 01 02` → `0x02/0xE1 [1A]` → `0x07/0x47` (ssid/psk of YOUR network) → `0x08/0x78` (res/kbps/fps/url) → `0x02/0x8E 01 01 1A 00 01 01`. The camera joins your Wi-Fi (the Mac doesn't lose Internet) and pushes to an RTMP server on the Mac (Moblin's, MIT). Cons: the camera switches to Live mode (it's not a preview while recording); latency not measured.
