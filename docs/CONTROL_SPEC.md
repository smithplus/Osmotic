# Osmotic — camera control + live view spec (Pocket 3, Wi-Fi datalink)

Implementation-ready spec, written 2026-09-14 from source reading only. Implemented in `19ecd04`
(see `docs/CONTROL.md`); not yet hardware-tested. `ours …:N` line references are from before the
implementation and the swift-format pass and no longer match. The `research/…` paths were a session
scratchpad and are not in the repo (clone the upstream projects to follow the citations).

## 0. Sources, citation keys, evidence

| Key | Path (all under the session scratchpad unless noted) | Commit | License |
|---|---|---|---|
| **K** | `research/brianmerchant_Kaze-for-DJI` (iOS Swift, Pocket 3 hardware-tested) | `341a35d` | MIT, © 2026 Brian Merchant |
| **P3D** | `research/brianmerchant_Pocket3Direct-Android` (same author, Kotlin transport) | `f30c364` | MIT |
| **OPC** | `research/erik-sutton95_OpenPocketCine` (iOS/Android, Pocket 3/4/Nano tested) | `9b30b93` | Apache-2.0 (+NOTICE) |
| **OSM** | `osmosis` (upstream KonradIT/osmosis, `MEDIA_PROTOCOL.md`) | local clone | MIT |
| ours | `/Users/martinsmith/projects/personal/osmosis mac/…` | `30f1546` | — |

Citations are `KEY path:line`. Evidence tags: **HW** = a source says physically confirmed on a
Pocket 3; **SRC** = present in a working implementation; **UNVERIFIED** = conflicting or not
established for Pocket 3; **INFERRED** = my reading of the evidence.

Every DUML frame quoted in §3/§4 was re-encoded with our CRC/packing (same algorithm as
`Sources/OsmoticCore/DUML/DjiMessage.swift:5-62` + `DatalinkTransport.sendDuml` `:153-162`) and
matches OSM's published examples byte-for-byte (script: `scratchpad/duml_check.py`).

**Attribution if code is ported:** Kaze is MIT — keep its copyright line (add to `LICENSE`/README
credits next to Osmosis, and a header comment in ported files, e.g. `// Adapted from Kaze for DJI
(MIT, © 2026 Brian Merchant), ios/Pocket3Controller/Pocket3VideoOutput.swift`). OPC is Apache-2.0:
prefer re-implementing from its docs; if code is copied, carry its `NOTICE` and mark modifications.

---

## 1. Datalink framing needed for control (Q1)

### 1.1 Packet types (byte 6 of the 8-byte transport header)

| pktType | Direction | Content | Source |
|---|---|---|---|
| `0x00` | both | handshake (our 40-byte SYN; camera echoes a `0x00`) | K docs/POCKET3_DUML_PROTOCOL.md:72-80; ours DatalinkTransport.swift:25-30,109-117 |
| `0x01` | cam→app | (a) **34-byte window status** (no DUML); (b) unsolicited DUML pushes: `02/80`, `02/DC`, `0D/02`, `04/05`, `00/99` pushes | K docs:79; OPC docs/live-session.md:43-46 |
| `0x02` | cam→app | **live-view media fragments** (H.264 on Pocket 3) | K docs:76, 785-833; OPC handbook/.../live-view.md:21-23 |
| `0x03` | cam→app | "ackedData": **replies to our commands** (record/stop, `0x8E` GET/SET, `04/50`, zoom ACK…) — a separate reliable window | OPC docs/live-session.md:43-53; OPC handbook/.../duml-transport.md:38; K docs:77 |
| `0x04` | app→cam | our window ACK (transport seq always 0) | K DumlTransport.swift:130-146; P3D DumlTransport.kt:214-228 |
| `0x05` | app→cam | our DUML commands (`[12B routing][DUML]`) | K docs:75; ours DatalinkTransport.swift:153-162 |

Note on `0x02` bytes 8..19: OPC's offline tool reads them as `[8:12]` routing-like
`[ack][seq]`, `[12:16]` zero, `[16]` frame no. (mod 256), `[17]` `0e`/`8e`, `[18:20]` fragment
index (OPC tools/extract_liveview.py:9-16). Kaze ignores them and reassembles by the declared
length (§4.3). We do the same.

### 1.2 What we do today vs. what control needs

| Item | Ours now | Needed (Kaze/P3D = Mimo capture) |
|---|---|---|
| Routing header `r0-1` | `seq − 8` (ours DatalinkTransport.swift:16-21) | **`peerAckedTx`** = camera's ACK of our TX, from `0x01`-status @24 (K DumlFraming.swift:186-198; P3D DumlTransport.kt:373-389, 438-445). Vector: `seq=5678 peerAck=1234 ctr=9a → 34127856000000009A010000` (K protocol/test-vectors/transport/transport.json) |
| ACK group 1 | `0x01`-status @10 only (ours :200-203) | latest **inbound pktType-0x02 transport seq**; seed from status @10 only until the first `0x02` is seen; never rewind after (K DumlTransport.swift:283-305; OPC Sources/OpenPocketViewCore/DumlTransport.swift:114-156) |
| ACK group 2 | `0x01`-status @18 only | latest **inbound pktType-0x03 seq**; seed from status @18 until the first `0x03`; never rewind (same cites). **This is "extend the ACK to the pktType 0x03 group".** |
| ACK group 3 | `baseSeq` duplicated (constant) (ours :147) | `[peerAckedTx:u16][lastTx:u16][00×4]` (K DumlFraming.swift:155-169; P3D :408-412). P3D :71-73: "v0.11 incorrectly kept groups 2/3 pinned to the session base, which let unsolicited telemetry continue while the command/reply window eventually wedged." |
| `lastTx` tracking | none | seq of the last non-`0x00`, non-ACK packet we sent (K DumlTransport.swift:113-128, 183-195) |
| ACK cadence | ~2 Hz (keep-alive tick) + after job receives | ≥ 40 Hz while video flows (OPC DatalinkDriver.swift:1045-1052: Mimo "~41 Hz (p50 24.4 ms)"); Kaze ACKs after every non-empty 12 ms receive burst + 250 ms fallback (K Pocket3GimbalSession.swift:1442-1448) |
| Inbound session filter | by source IP only (ours :193) | Kaze also drops datagrams whose session id ≠ ours (K DumlTransport.swift:242-248). Optional; FakeCamera currently answers with a fixed `0x1234` (Tests/…/FakeCamera.swift:157) and would need to echo ours. |

### 1.3 Exact wire layouts

Transport header (8 B), unchanged: `[u16 0x8000|total][u16 session][u16 seq][u8 pktType][u8 xor(b0..b6)]`
(K DumlFraming.swift:101-122; ours :8-14). Vector: `pktType=05 len=34 session=1234 seq=5678 → 2A803412785605A7`.

Routing header (12 B, pktType `0x05` only):
```
[0-1]  peerAckedTx  u16 LE   ← CHANGE (was seq-8)
[2-3]  this packet's transport seq u16 LE (== header seq)
[4-7]  00 00 00 00
[8]    cmdCounter u8 (+1 per DUML sent)
[9]    01
[10]   00 (camera; 0x60 = drone)
[11]   00
```

ACK (pktType `0x04`, transport seq = **0**, does not consume our seq; 8 + 26 = 34 B):
```
[0-1] rxType2 [2-3] rxType2 [4-7] 00000000      group 1 (video)
[8-9] rxType3 [10-11] rxType3 [12-15] 00000000  group 2 (command replies)
[16-17] peerAckedTx [18-19] lastTx [20-23] 00000000  group 3 (our TX window)
[24-25] 00 00
```
Vector: `rx2=1111 rx3=2222 peerAck=3333 lastTx=4444 → 1111111100000000222222220000000033334444000000000000`
(K docs:96-105, 994-996). OPC instead duplicates the status @26 value in group 3
(OPC Sources/OpenPocketViewCore/DumlTransport.swift:161-185); in the Mimo capture @24 == @26
always (P3D DumlTransport.kt:310-312), so both are equivalent. Use Kaze's.

Inbound 34-byte pktType-`0x01` window status (offsets into the whole datagram):
```
@8/@10  camera type-2 cursor (dup)   → seed rxType2 until first 0x02 seen (read @10)
@16/@18 camera type-3 cursor (dup)   → seed rxType3 until first 0x03 seen (read @18)
@24/@26 camera ACK of OUR tx seq     → peerAckedTx = @24 when non-zero
```
(K DumlTransport.swift:296-310; P3D :303-316; OPC reads @10/@18/@26, DumlTransport.swift:159-165).

Seq/cursor fields summary:
- Our transport seq: handshake packets start at 0 (+8 each); after the post-handshake drain
  `udpSeq = cameraChannel + 8`, `lastTx = peerAckedTx = cameraChannel`, then +8 per `0x05`
  (K DumlTransport.swift:107-111; P3D :171-176). `cameraChannel` = inbound bytes 8-9 (non-zero)
  learned during the 5×(recv 400 ms + ACK) drain (ours CameraSession.swift:255-259 already does this).
- DUML id (frame bytes 6-7): `dumlSeq` from `0xA000`, +1 per frame (ours :42, 159).
- Health metric: `txLagSlots = ((lastTx − peerAckedTx) & 0xFFFF) / 8`; Kaze warns > 24
  (K Pocket3GimbalSession.swift:1657-1663). Handshake proposes window **100** (`0x64`) / MTU 1472
  (OPC DumlTransport.swift:74-76) — so > ~100 un-ACKed slots stalls the camera (INFERRED).

### 1.4 State machine to add to `DatalinkTransport` (port of K DumlTransport.swift:250-311)

```swift
// Adapted from Kaze for DJI (MIT) DumlTransport.observeTransportState.
private(set) var rxType2Seq = 0, rxType3Seq = 0, peerAckedTxSeq = 0, lastTxSeq = 0
private var seenType2 = false, seenType3 = false
// open(): all four = baseSeq; seen* = false.  syncSeqToPeerChannel(): udpSeq = ch+8; lastTx = peerAck = ch.

func observe(_ d: [UInt8]) {                       // call for EVERY accepted inbound datagram
    guard d.count >= 8 else { return }
    let type = d[6], seq = d.u16le(4)
    if d.count >= 10, d.u16le(8) != 0 { cameraChannel = d.u16le(8) }   // existing behaviour
    if seq != 0 {
        if type == 0x02 { rxType2Seq = seq; seenType2 = true }
        if type == 0x03 { rxType3Seq = seq; seenType3 = true }
    }
    if type == 0x01, d.count >= 34 {                // was: == 34
        if !seenType2, d.u16le(10) != 0 { rxType2Seq = d.u16le(10) }
        if !seenType3, d.u16le(18) != 0 { rxType3Seq = d.u16le(18) }
        if d.u16le(24) != 0 { peerAckedTxSeq = d.u16le(24) }
    }
}
```
OPC notes seq `0` is a valid cursor once seen (OPC DumlTransport.swift:126-129); Kaze ignores
seq 0. Minor; follow Kaze (proven on Pocket 3).

### 1.5 Keeping the session alive

- `0x00/0x88` APP presence `17 00 46 23 7c 41 50 50 00 00 00 00 00 02` to rcv type 8 id 1,
  cmdType 2, ~1 Hz (K docs:268-281; K Pocket3GimbalSession.swift:1480-1489). We already do this (ours :55, 202).
- Kaze additionally sends `0x04/0x50` payload `01 04 05` to rcv type 4 id 0, cmdType 2, every 1 s
  and treats a missing reply > 3 s as a command-path health warning (K docs:297-313;
  Pocket3GimbalSession.swift:1469-1478, 1665-1669). Its reply rides pktType `0x03`, so it also
  keeps that window exercised. It is a gimbal-params GET (OPC handbook/.../commands.md:48) — read-only.
- **The "re-register after > 40 s" note** comes from OSM MEDIA_PROTOCOL.md:642-644 ("A registered
  session stops accepting writes after ~40–70 s … Re-register before a write once the session is
  older than 40 s"), written for the `ackSeq = ownSeq − 8` model (OSM :629-637). P3D explains that
  exact signature — reads/telemetry flowing, writes silently dropped — as caused by `r0 = seq−8`
  and pinned ACK groups (P3D DumlTransport.kt:16-21, 64-74, 378-386). Kaze/OPC hold control and
  video for minutes on one session with the corrected windows (OPC docs/feed-watchdog.md:26:
  "A session-preserving UDP rebuild does not reset the camera's `0x03` window — only echoing that
  seq (or a new handshake) does"). **Plan: adopt §1.2 instead of timed re-registration**; keep
  re-registration only as a fallback (§6.4). Kaze has no periodic re-register anywhere.

---

## 2. Playback vs. control (Q2)

Facts:
1. **Kaze never enters playback.** Connect = TCP 7001 poke (SetPairingPIN "osmo", hold 400 ms,
   close) → UDP open → handshake → 5×(recv 400 ms + ACK) → sync → `00/81` → `00/88` → `03/DA`
   → `04/50` readiness gate (reply required; one fresh-transport retry) → live-view START sequence
   → queue `00/99` subscriptions → pump (K Pocket3GimbalSession.swift:663-864, 999-1039, 918-997).
   Media browsing is out of Kaze's scope (K docs/CAMERA_SETTINGS_PROTOCOL.md:143-145).
2. Live view is refused in playback: `0x09/0xA8` while in playback ACKs `E0`/`D6` and produces no
   video; Mimo exits playback first (OPC Sources/OpenPocketViewCore/MediaLiveResume.swift:3-7;
   OPC handbook/.../live-view.md:57; OPC ios/OpenPocketCine/CameraSession.swift:4146-4155 refuses to
   enable while `inPlayback`).
3. Playback is camera-wide; "a gimballed body stops filming while it is held" (OSM :581-582).
   Record/photo/mode while in playback: **UNVERIFIED** on Pocket 3 (expect `D9` wrong-state per
   OSM reply table :717-727). Treat control as requiring capture (bit 30 of `02/80` clear).
4. Pocket 3 answers `E0` to `0x02/0x0C` enter and is put into playback via `0x01/0x01`
   `03 00000000 04000000 07 01` ×~6 then `00 00000000 04000000 04 01` at ~20 Hz until bit 30
   (OSM :775-787; ours CameraSession.swift:345-369). OSM :787: "No exit command. The camera returns
   to capture on its own a few seconds after the link drops."
5. `0x01/0x01` is a UI/work-state command (INFERRED from K + OSM): `03…07 01` = playback (K
   docs:898-914 marks it UNSAFE as a live-view stop because it enters playback), `01…05 01` =
   live START, `00…04 01` = IDLE/hold (K docs:725-759). Our "enter" frame is byte-identical to
   Kaze's LIVE_IDLE.
6. OPC leaves playback with `0x02/0x0C 01 01 00 00`, repeated (≤ 8 attempts, 180 ms apart, 450 ms
   reply wait) until bit 30 clears, then `0x02/0x68 [08]` + `0x09/0xA8` (OPC
   ios/OpenPocketCine/CameraMedia.swift:555-592; MediaLiveResume.swift:8-32). OPC never uses
   the `0x01/0x01` route, and lists the **newest** page without playback (OPC MediaLiveResume.swift:49-66;
   handbook/.../media.md:26), whereas OSM says a Pocket 3 "serves an incomplete first page when
   listed while still in capture" (OSM :135). Keep our playback-based listing.

**Recommended procedure — leave playback (job `enterCaptureMode`)**, stop at the first step that
clears bit 30 of `02/80` (`StatusTracker.playbackReported == false`):
1. Stop the keep-alive's playback re-assert (ours CameraSession.swift:539) and set `playbackHeld = false`.
2. `0x02/0x0C 01 01 00 00` (our `playbackLeave`, ours :57) to rcv 0x01; wait ≤ 450 ms, up to 2×.
   On a `E0` reply skip to 3. (Pocket 3 behaviour for *leave*: **UNVERIFIED**.)
3. Send the Kaze live START sequence (§4.1). **UNVERIFIED** that it exits playback — INFERRED
   from the `0x01/0x01` semantics above. Wait ≤ 1.5 s for bit 30 clear.
4. Fallback: fresh session (close socket, new handshake + register **without** playback entry),
   then wait ≤ ~5 s for bit 30 to clear in `02/80` (OSM :787; duration UNVERIFIED).

**Re-enter playback to list again (job `enterMediaMode`)**: stop live decoding (§4.6), then the
existing `enterPlaybackConfirmed()` (ours :313-341, P3 route :345-369), then listing as today.
Keep ACKing `0x02` during this (leftover video may continue; see §4.6).

**Downloads:** HTTP was only exercised with playback held. Whether `/v2` works in capture is
**UNVERIFIED** → V1: block entering capture while transfers run (or test first).

---

## 3. Control commands (Q3)

Routing for all: sender App `0x02`, receiver Camera type 1 id 0 (target `0x0102`), cmdType 2 →
DUML flags `0x40` (request). Our call: `send(0x02, cmd, payload, rType: 0x01, rId: 0)` (ours :188-190).
Reply: same set/cmd, flags `0xC0`, payload[0] = status, arrives on **pktType 0x03** (OPC
docs/live-session.md:46-49). The camera may first send an empty-payload transport ACK with the same
set/cmd — skip empty payloads (OSM :639-640; ours `DumlScanner.findReply` already does, DjiMessage.swift:138-147).

### 3.1 Frames (hex = full DUML frame with id `0x0402`, verified against OSM examples)

| Action | set/cmd | Payload | Frame example (id 0x0402) | Source |
|---|---|---|---|---|
| Record start | `02/02` | `01` | `550e046602010204400202014e61` | K docs:524-541 (HW); OSM :736-742; K Pocket3CameraDomain.swift:56-63 |
| Record stop | `02/02` | `00` | `550e04660201020440020200c770` | same; OSM :744-749 |
| Photo (shutter) | `02/01` | `01` | `550e04660201020440020101264b` | K Pocket3CameraSettings.swift:536-542; OSM :729-734; OPC Commands.swift:217 |
| Panorama start | `02/01` | `07` | — | K Pocket3CameraSettings.swift:668-675; K docs/CAMERA_SETTINGS_PROTOCOL.md:39 |
| Set mode | `02/E1` | `[mode]` | `550e0466020102044002e1` + `mm` + crc (e.g. Video `…e101bfa2`, Photo `…e1059be4`) | OSM :759-773; K Pocket3CameraSettings.swift:414-419 |
| Video format | `02/18` | `[res][fps] 00 [slowmo] 00` | — | K Pocket3CameraSettings.swift:429-443; K docs/CAMERA_SETTINGS_PROTOCOL.md:45-72 |

Mode codes (`02/E1` writer = `02/80`@57 readback; sparse, **table it, never enumerate** — sweeping
`02/E1` froze a Nano, OSM :687-688; OPC Commands.swift:224-235):
`00` Slow Motion · `01` Video · `02` Timelapse · `05` Photo · `0A` Hyperlapse · `0C` Panorama ·
`18` Motionlapse · `28` Low-Light (SuperNight) (K Pocket3CameraReadback.swift:19-28; K docs:581-592).
Writer status on Pocket 3: Kaze exposes all but `18` as writer values (K Pocket3CameraSettings.swift:42-50),
but its docs call only the Timelapse `02` ↔ Motionlapse `18` transition hardware-validated and warn
"readback IDs should not automatically be treated as safe writer values" (K docs:594-595;
CAMERA_SETTINGS_PROTOCOL.md:118). OSM lists Nano+Pocket 3 examples for `00 01 02 05 0A 28 0C`
(OSM :713-715, 762-770). → V1 writer set: `01` Video, `05` Photo (most used); others behind a flag,
UNVERIFIED-writer. `0x17` is Photo on Pocket 4, not Pocket 3 (OPC Commands.swift:225-228).

Do **not** send `02/02` with any other value: `02/02` is also DJI's 0–3 "work mode" (OSM :751-757).

### 3.2 Reply codes (payload[0]) — OSM :717-727; OPC CameraControl.swift:229-265

`00` ok · `D8` resource not ready · `D9` wrong state (photo in a video mode, OSM :734) · `DF` wrong
parameter (OSM :749 and OPC Commands.swift:210: `[01]` while recording → `df`)
· `E3` bad/missing param · `E0` unsupported (and `09/A8` in playback) · no reply = receiver absent.
Kaze: `02/02` reply `00` = accepted, "command acceptance is not proof that recording actually
reached the requested state" (K docs:536-539).

### 3.3 `0x02/0x80` status push (~10 Hz, 60 B, pktType 0x01) — confirmation source

| Offset | Type | Meaning | Source |
|---|---|---|---|
| @0 | u8 | record state: `01` idle, `41` transition, `81` recording, `C1` transition+rec; bit7 = recording, bit6 = transition | K docs:543-567; K Pocket3CameraDomain.swift:87-110 |
| @0..3 | u32 LE | flags word; **bit 30 (`@3 & 0x40`) = in playback** | OSM :913-926; ours StatusTracker.swift:37-42 |
| @4 | u8 | `1` video-like mode, `0` Photo | K Pocket3CameraDomain.swift:73; OSM :847 |
| @5 | u32 LE | active-store total MiB | K :68; OSM :848 |
| @9 | u32 LE | active-store free MiB | K :69; OSM :849 |
| @13 | u16 LE | photos remaining (Photo only) | OSM :850, 862-863 |
| @17 | u16 LE | remaining record seconds (0 in Photo) | K :70; OSM :851 (OPC reads u32 @17, CameraStatus.swift:157-160 — use u16) |
| @29 | u16 LE | **elapsed record seconds** | K :71; OSM :852 |
| @57 | u8 | current shooting mode (codes above) | K :72; OSM :853 |

Parse the extended fields only when `payload.count >= 58` (K :65-66). Render @17/@29 only when
@4 == 1, @13 only when @4 == 0 (K Pocket3CameraDomain.swift:25-31; OSM :862-863).

### 3.4 Confirmation rules and timing

- **Record** (K Pocket3GimbalSession.swift:1197-1238, 1947-1974; K Pocket3CameraDomain.swift:95-100):
  require a fresh `02/80` before allowing the command; refuse if a record command is in flight or
  @0 has the transition bit; refuse if already in the target state; send once; the request is
  resolved when a `02/80` shows the transition bit **or** recording bit == target; give up after
  **2 s** (K :36). Final state: start `01→41→81` (~600 ms on Pocket 3), stop `81→C1→01`
  (~700 ms) (OSM :738-746). Test `== 0x81`, not "any change" (OSM :741-742).
- **Photo**: one-shot, **never retransmit** (OPC CameraSession.swift:1248-1255 `retransmits: false`).
  Only in Photo mode (@57 == `05`); otherwise `D9`. Confirmation: reply `00`; optional @13 decrement
  (UNVERIFIED timing).
- **Mode**: reply `00`, then @57 == requested within ~1 s (UNVERIFIED timing). OPC updates optimistically
  and reverts on failure (OPC CameraSession.swift:1265-1273). Block while recording (UNVERIFIED
  that the camera refuses; safer to block).
- **Retransmit policy** (OPC CameraSession.swift:3164-3167): retransmit once after 300 ms of silence
  (not photo), settle/fail at 2 s. With the §1.2 windows, Kaze does no retransmits at all. V1: no
  retransmit for photo; record may resend once at 300 ms only if no reply **and** @0 unchanged.
- **One in flight per opcode**; SETs can pause live video briefly — OPC holds stall-repair 4 s
  after any SET (OPC docs/feed-watchdog.md:45).
- **Timelapse/Hyperlapse start**: OPC's Pocket 3 survey saw Timelapse start/stop as `02/01 [01]/[00]`,
  not `02/02` (OPC handbook/.../pocket3.md:398-400); Kaze uses `02/02` for every non-Photo mode
  (K CameraControlScreen.swift:2171-2190). **UNVERIFIED** → V1 supports record in `01`/`00`/`28`,
  photo in `05`; disable the shutter in other modes.

---

## 4. Live view (Q4)

### 4.1 Start request — two proven variants

**Variant A (Kaze, HW on Pocket 3)** — K Pocket3GimbalSession.swift:43-46, 999-1039;
K android/.../Pocket3LiveViewCommands.kt:17-29; K docs:725-783:
```
START = 01/01  payload 01 00 00 00 00 04 00 00 00 05 01   rcv type1 id0, cmdType 0 (flags 0x00)
A8    = 09/A8  payload 00 04 02 00 00 00 00 00 00 00      rcv type1 id2 (=0x41), cmdType 2
IDLE  = 01/01  payload 00 00 00 00 00 04 00 00 00 04 01   rcv type1 id0, cmdType 0
Order: START,1ms, A8,1ms, START,1ms, A8,1ms, START×5 (2ms gaps), IDLE×4 (2ms gaps)
```
Frames (id 0xA000): START `55180420020100a00001010100000000040000000501c321`,
A8→0x41 `55170438024100a04009a800040200000000000000b20a`,
IDLE `55180420020100a000010100000000000400000004018a6d`.
Kaze sends it only after the `04/50` reply gate (K :805-809) and before queuing subscriptions.

**Variant B (OPC)** — `0x02/0x68 [08]` then `0x09/0xA8` same payload to **rcv `0x08`** (type 8 id 0)
(OPC Commands.swift:184-200, 290-304; CameraModel.swift:53-55; handbook/.../live-view.md:36, 50-57).
A8→0x08 frame (id 0xA000): `55170438020800a04009a8000402000000000000006442`. OPC used `0x41` only
for Nano ("Pocket `0x08` to Nano ACKs E0"). OPC: register + subscribe **before** enable ("Enable
before subscribe is ignored on first boot", OPC DatalinkDriver.swift:229, 284-287).

Which receiver Pocket 3 strictly needs: **UNVERIFIED** (both projects report Pocket 3 video with
their own variant). Plan: Variant A first (full sequence); if no pktType `0x02` within 8 s,
Variant B once (§4.5 ladder).

Do **not** wait for a DUML reply to `09/A8` before ingesting — OPC lost the IDR with a 200 ms wait
(OPC docs/live-session.md:88-97). Arm `0x02` ingest before sending.

### 4.2 Fragment format (pktType `0x02`)

```
datagram[0..7]   transport header (seq advances by 8 per fragment; K Pocket3VideoOutput.swift:561-570; OPC live-view.md:94)
datagram[8..19]  fragment header (ignored; see §1.1)
datagram[20..]   fragment
First fragment of a message:
  +0  00 00 01 FF
  +4  u32 LE   assembled H.264 byte count (excludes this 16-byte header)
  +8  8 B metadata (+12..+15 u32 LE timestamp-like; 2500 Hz INFERRED)
  +16 Annex-B H.264
Continuation fragments: append datagram[20..]
```
(K Pocket3VideoOutput.swift:9-22, 572-606; K docs:785-833; OPC live-view.md:96-98.)
Each completed message is either SPS/PPS or one access unit; parse every NAL anyway (K :20-22).
Parameter sets come only with IDRs and may be a separate message ~1 ms before the IDR
(OPC live-view.md:102). Pocket 3 live = AVC 720p ~25 fps in OPC tests (OPC live-view.md:13);
Kaze's cadence detector allows 24–60 fps because "recording mode can change the live-view cadence"
(K :95-99) → don't hard-code fps.

### 4.3 Reassembler (port of K :572-639 + OPC continuity check)

```swift
// Adapted from Kaze for DJI (MIT) Pocket3VideoOutput.consume; continuity rule after OPC HevcDepacketizer.
struct LiveReassembler {
    private var buf: [UInt8] = [], expected: Int?, lastSeq: Int?, startedAt: UInt64 = 0
    var droppedPartial = 0, joinedMid = 0, invalid = 0
    mutating func feed(_ d: [UInt8], now: UInt64) -> [UInt8]? {      // d = whole datagram, d[6]==0x02
        guard d.count > 20 else { return nil }
        let seq = d.u16le(4)
        let first = d.count >= 36 && d[20] == 0 && d[21] == 0 && d[22] == 1 && d[23] == 0xFF
        if first {
            if expected != nil { droppedPartial += 1 }
            let len = d.u32le(24)
            guard len > 0, len <= 8 << 20 else { invalid += 1; reset(); return nil }   // K :585-592
            expected = len; buf.removeAll(keepingCapacity: true); buf.reserveCapacity(len)
            buf += d[36...]; startedAt = now
        } else {
            guard expected != nil else { joinedMid += 1; return nil }             // K :600-603
            if let l = lastSeq, seq != (l + 8) & 0xFFFF { droppedPartial += 1; reset(); return nil } // OPC :104-110
            if now - startedAt > 1_500_000_000 { droppedPartial += 1; reset(); return nil }   // K android Reassembler :18
            buf += d[20...]
        }
        lastSeq = seq
        guard let e = expected, buf.count >= e else { return nil }
        let msg = Array(buf.prefix(e)); reset(); return msg
    }
    mutating func reset() { buf.removeAll(keepingCapacity: true); expected = nil; lastSeq = nil }
}
```
Drop duplicate seqs (OPC HevcDepacketizer.swift:96). A lost fragment corrupts only that AU, but
there is **no periodic GOP**, so later P-frames stay damaged until the next IDR (OPC live-view.md:59)
→ on a drop, mark `needsIDR` and let the §4.5 ladder decide (rate-limited `09/A8`).

### 4.4 Decode/display (port of K :641-890, 1130-1301)

1. **NAL split** — Annex-B, 3- and 4-byte start codes (K :1266-1301). Type = `byte & 0x1F`.
2. **SPS (7)/PPS (8)** — keep latest; on change build
   `CMVideoFormatDescriptionCreateFromH264ParameterSets(…, parameterSetCount: 2, nalUnitHeaderLength: 4, …)`
   (K :1130-1168), then `waitingForIDR = true` and flush the layer (K :674-690).
3. **Sample NALs** — drop 7, 8, 9 (AUD); require a VCL NAL (1…5); `isIDR` = contains type 5
   (K :694-710). While `waitingForIDR`, discard until an IDR (K :721-725) — handles leftover GOP
   P-frames after reconnect (OPC live-view.md:36, 41-42; docs/live-session.md:130-131).
4. **AVCC** — each NAL → 4-byte big-endian length + bytes, one contiguous buffer; `CMBlockBufferCreateWithMemoryBlock`
   + `CMBlockBufferReplaceDataBytes` (Kaze: writing via `CMBlockBufferGetDataPointer` produced no
   renderable samples on device, K :1182-1186), `CMSampleBufferCreateReady` with timing
   `{duration: 1/fps, pts: host clock, dts: .invalid}` (K :1170-1241).
5. **Attachments** — `kCMSampleAttachmentKey_DisplayImmediately = true` (V1: always; Kaze does it
   until its cadence detector locks, K :727-763, 1249-1255) and `kCMSampleAttachmentKey_NotSync = !isIDR` (K :1256-1260).
6. **Display** — `AVSampleBufferDisplayLayer` hosted in an `NSView` (`makeBackingLayer`) via
   `NSViewRepresentable`; black background; if `status == .failed` → `flush()`, wait for IDR
   (K :846-853). Kaze enqueues on the main queue (K :831-889). On the macOS 15 SDK prefer
   `layer.sampleBufferRenderer` (AVSampleBufferVideoRenderer) — layer-level `enqueue/flush` are
   deprecated there (verify at compile time). `CMSampleBuffer` Sendability under Swift 6.2: wrap
   in an `@unchecked Sendable` box for the hop (verify).
7. `ImageRenderer` snapshots can't show this layer (CLAUDE.md) → demo mode shows a still.

V2 (optional): Kaze's cadence lock + 1-frame presentation lead (K :95-115, 727-776, 1004-1107)
smooths jitter; not needed for a preview.

### 4.5 Keyframes, stalls, recovery (ordering matters)

- `09/A8` **is** the IDR request; there is no separate PLI and no periodic keyframe; a 30 s run of
  P-frames is normal (OPC live-view.md:59; docs/feed-watchdog.md:11). **Never loop `09/A8`** —
  resending every second resets the encoder GOP and the IDR never lands (OPC live-view.md:72-74;
  Commands.swift:190-192; docs/protocol-notes.md:54-59).
- Stall = no new AU for 2 s, **except** 8 s after a `09/A8`, 4 s after any SET (OPC feed-watchdog.md:37, 45).
- Ladder when status (`02/80`) is fresh but video stale: `09/A8` ×2 with ≥ 5 s between, then one
  **fresh-handshake** session (not a socket swap) + one enable (OPC feed-watchdog.md:47-58).
  A replacement socket gets a new ephemeral port and the camera keeps sending to the old one until a
  new handshake (OPC live-view.md:27-32; docs/live-session.md:23-28).
- Kaze uses single light `09/A8` refreshes after resume/PiP (K :562-571, 1491-1504).
- **Pocket 3 first picture black**: body boots 4K 25/30, status/gimbal live, no picture until a
  `02/18` format round-trip or a colour change. OPC's one-shot fix after one failed enable: wait for
  the current format (`cam_video_param_v2` `[res][fps]`), SET the other of 1080p/4K at the same fps
  (`02/18 [0A|10][fps] 00 00 00`), restore the original, then one `09/A8` (OPC live-view.md:61-70;
  docs/live-session.md:117-128; CameraControl.swift:1135-1156; CameraModel.swift:68). Needs a
  `cam_video_param_v2` subscription — **not** in our `paramSubs` today (ours CameraSession.swift:49-52).

### 4.6 Stopping

There is **no live-stop command** (OPC live-view.md:36; docs/live-session.md:130). Kaze's teardown
for a non-user session replacement: final neutral, `01/01 IDLE` ×8 (3 ms apart), then drain+ACK
750 ms, close (K :366-431). For a user disconnect Kaze sends nothing and closes promptly (K :373-374).
Never use `01/01 03…07 01` as a stop — it enters playback (K docs:898-914). So "stop live view" =
stop decoding locally; keep ACKing group 1 with the latest `0x02` seq while any arrive.

### 4.7 Socket caveats

- Keep the client on an **ephemeral** local port; binding `:9004` locally kept telemetry but dropped
  all pktType `0x02` on Samsung (OPC docs/live-session.md:19-21; handbook/.../duml-transport.md:20-24).
  Ours is already unbound `sendto` + `IP_BOUND_IF` (ours DatalinkTransport.swift:68-81, 98-105). Keep it.
- OPC keeps the TCP 7001 poke open for the whole session ("Closing it RSTs the camera",
  OPC handbook/.../duml-transport.md:14-16); Kaze closes it after 400 ms (K :995-996) and works.
  Ours closes after 0.4 s (ours :243-244). Keep as-is; try "hold open" if video/control is flaky (UNVERIFIED impact).
- `SO_RCVTIMEO` is 200 ms (ours :72-73): `recvAll(ms: 12)` can overshoot to ~200 ms on an idle
  socket → use `poll(POLLIN, remainingMs)` before `recvfrom` in the new burst receive.
- Local VPN/ad-blockers can swallow the UDP flow (OPC docs/live-session.md:226-239).

---

## 5. Pitfalls and ordering constraints (Q5)

1. Wrong routing `r0` / pinned ACK groups → writes silently dropped while telemetry flows (§1.2, P3D :16-21, 71-73, 378-386).
2. Not echoing the latest pktType-`0x03` seq in ACK group 2 → command replies stop after a few dozen
   (OPC DumlTransport.swift:90-94; docs/live-session.md:46-53). Status `0x01` must not rewind groups 1/2
   after the real seq was seen (OPC :114-146).
3. ACK at ≥ 40 Hz once video flows; 1 Hz is not enough (OPC live-view.md:108).
4. Every UDP write (commands, ACKs, beats) must be serialized on the one owner — interleaving
   starved window ACKs in OPC (docs/live-session.md:55-58). Matches our single-thread rule.
5. Register + subscribe before `09/A8` (OPC DatalinkDriver.swift:229, 284-287). Kaze: `04/50` reply
   gate before live START (K :795-809).
6. No `09/A8` loops; ≥ 5 s spacing; hold repair 8 s after enable / 4 s after SETs (§4.5).
7. `09/A8` in playback → `E0`/`D6`, no video (§2).
8. Pocket 3 first picture may stay black until a `02/18` round-trip (§4.5).
9. Leftover GOP after reconnect: gate on IDR (§4.4).
10. Record is not a toggle: `[01]` while recording → `DF`; photo in video mode → `D9`; empty photo
    payload → `E3` (OSM :734, 749). Never enumerate `02/E1`.
11. Pocket 3 passes through `0x41` before `0x81` and `0xC1` before `0x01` — wait on the bit, not a delay (OSM :738-746).
12. **Our scanner false positive:** `DumlScanner.walk` checks only CRC8 (ours DjiMessage.swift:123-134);
    running `StatusTracker.ingest` over H.264 fragments could decode a bogus `02/80` and flip playback/record
    state. Exclude pktType `0x02` from status ingest and from manifest blobs (ours CameraSession.swift:192-200, 386, 412, 458, 488).
13. Don't re-sync `udpSeq` from `cameraChannel` mid-session: video datagrams also overwrite bytes 8-9
    (OPC tools/extract_liveview.py:10). OPC flags channel/ACK-state ordering at startup as a candidate
    stall seam (OPC docs/pocket3-startup-investigation.md:62-73).
14. "Do not poll `0x02/0x8E` while playback is held" — it drops playback on some bodies (OSM :606-609;
    OPC handbook/.../commands.md:17).
15. WB/sliders: one in flight, coalesce ~100 ms, don't flood (OPC commands.md:40).
16. Mimo sends `02/68 [08]` right before the first enable after a SoftAP join or gallery (OPC live-view.md:36).
17. Kaze's `04/14` "recenter" drove the gimbal toward a mechanical limit — never send (K docs:880-896). (Out of scope, listed because it is the one known-dangerous opcode.)

---

## 6. Integration plan for Osmotic (Q6)

### 6.1 `DatalinkTransport` changes (Sources/OsmoticCore/Datalink/DatalinkTransport.swift)

1. Add the window state + `observe()` (§1.4); call it in `recvAll` for every accepted datagram
   (replaces :196-203).
2. `DatalinkHeaders.routingHeader(seq:peerAck:cmdCounter:drone:)` (new `peerAck` param); `sendDuml`
   passes `peerAckedTxSeq`; `sendDuml`/`sendRaw(≠0x00)` set `lastTxSeq = seqSent` on success.
3. `sendAck()` builds the §1.3 layout from the four cursors.
4. `syncSeqToPeerChannel()` also sets `lastTxSeq = peerAckedTxSeq = cameraChannel`; `open()` seeds all to `baseSeq`.
5. `var onVideo: (([UInt8]) -> Void)?` — pktType `0x02` datagrams go here (synchronously, on the
   session thread) and are **not** returned from `recvAll`/`recvBurst`.
6. `recvBurst(ms:)` using `poll()`; `txLagSlots`.
7. Temporary A/B switch `windowModel: .mimo | .legacy` (default `.mimo`) so the first hardware run can
   fall back if listing regresses — our listing is proven only with the legacy ACK (ours docs/STATUS.md).
8. Update `ProtocolTests` `the ack trails our own seq…` (Tests/…/ProtocolTests.swift:74-78) to the
   Kaze vectors.

### 6.2 `CameraSession` changes (single owner thread kept)

State (worker-thread only):
```swift
enum Mode { case media, capture, live }     // media = playback held (today's only mode)
var mode = Mode.media
var liveGeneration = 0                      // bump on every start/stop; decoder drops stale AUs
var lastEnableAt: UInt64 = 0, enableCount = 0, lastSetAt: UInt64 = 0
var recordInFlight: (target: Bool, deadline: UInt64)?
var lastAckAt: UInt64 = 0, lastBeatAt: UInt64 = 0, lastHeartbeatReplyAt: UInt64 = 0
var reassembler = LiveReassembler()
```
`StatusTracker`/`CameraStatus`: add `recordState: UInt8?`, `recording: Bool?`, `transitioning`,
`elapsedSec`, `remainingSec`, `photosRemaining`, `shootingMode: UInt8?`, `videoLike`,
`inPlayback` (already `playbackReported`); include them in the change signature
(ours StatusTracker.swift:27-31, 37-46).

Jobs (each via `submit`, same as `connect`/`nextPage`):

| Job | Body |
|---|---|
| `enterCaptureMode()` | §2 procedure; on success `mode = .capture`, `playbackHeld = false`, subscribe `cam_video_param_v2` (one `00/99`, next subId), start `04/50` 1 Hz |
| `startLiveView()` | require `.capture` (auto-run `enterCaptureMode`); `liveGeneration += 1`; reset reassembler; arm `onVideo`; send Variant A (§4.1) with the 1–2 ms gaps; `mode = .live` |
| `stopLiveView()` | `liveGeneration += 1`; disarm decoding (keep ACKing); `mode = .capture` |
| `setRecording(_:)` | guards per §3.4; send `02/02`; pump-wait ≤ 2 s for reply (`flags 0xC0`, non-empty) **and** `02/80` resolution; returns `.ok / .refused(code) / .timeout` |
| `shootPhoto()` | require @57 == 05; send `02/01 [01]` once; wait ≤ 2 s for reply |
| `setShootingMode(_:)` | table-checked value; refuse while recording; send `02/E1`; wait reply + @57 |
| `enterMediaMode()` | `stopLiveView()`; `enterPlaybackConfirmed()`; `mode = .media` (listing/paging jobs require this; `nextPage` calls it first if needed) |

Reply wait helper: loop `recvBurst(12)` → `observe`, route video, `ingest` non-video, ACK if
≥ 25 ms since last ACK or anything arrived, until a frame with the same set/cmd, response flags and
non-empty payload is seen (our `DumlScanner.Frame` has no flags field — add `flags` (byte 8)).
Optionally also match DUML id (OSM MEDIA_PROTOCOL.md:11 says the camera echoes it — stated for
BLE; UNVERIFIED on the datalink, Kaze matches set/cmd only, K DumlFraming.swift:67-89).

Keep-alive split (ours :160-177, 520-542):
- `.media`: today's tick unchanged (recv 200 ms, ACK, beat /3 ticks, playback re-assert /33).
- `.capture`/`.live`: **pump tick** — `recvBurst(12)`; ACK when anything arrived or ≥ 25 ms elapsed
  (40 Hz floor); `00/88` every 1 s; `04/50` every 1 s; stall watchdog (§4.5) in `.live`; record
  deadline check; **no** playback re-assert; no `pause()` — check `jobs` non-blockingly each loop so
  jobs start within ~12 ms. Link-lost logic reuses `silentTicks` scaled to time (8 s).

Video path: `onVideo` → `reassembler.feed` on the session thread (cheap byte copies) → completed
message + `liveGeneration` dispatched to a serial `DispatchQueue("osmotic-video")` owning
`LiveDecoder` (§4.4: NAL/SPS/PPS/format/sample) in **OsmoticCore** (CoreMedia is not UI) → sample
handed to the app via callback → `@MainActor` view enqueues. Decoder ignores messages whose
generation ≠ current.

Public API (OsmoticCore, `async` like today): `enterCaptureMode() -> Bool`, `startLiveView()`,
`stopLiveView()`, `setRecording(_:) -> ControlResult`, `shootPhoto() -> ControlResult`,
`setShootingMode(_:) -> ControlResult`, `enterMediaMode() -> Bool`;
`onLiveSample: (@Sendable (SampleBox) -> Void)?`, `onLiveState` (waiting / rendering / stalled).
App side: `AppModel` gets a control panel state; `LiveView` = `NSViewRepresentable` over the
display layer; UI copy in Spanish rioplatense ("Grabar", "Detener", "Foto", "Modo", "Vista en vivo").

### 6.3 Teardown

`teardown()` (ours :544-553): if `.live`/`.capture`, send nothing special (Kaze user-disconnect
behaviour, K :373-374) — or `01/01 IDLE` ×8 + 750 ms drain for a session replacement (K :382-401);
only send the playback leave when `mode == .media`. Wi-Fi restore rules unchanged (CLAUDE.md).

### 6.4 Fallback re-registration

If a control reply times out while `02/80` is fresh and `txLagSlots > 24` (or `04/50` replies stopped
> 3 s): log a transport snapshot (Kaze's format, K :2248-2261), re-open + handshake + register (our
`openAndRegister`), restore mode, retry the command once. Never on a timer.

### 6.5 Tests (Swift Testing; extend `Tests/OsmoticCoreTests/FakeCamera.swift`)

Pure unit tests (new `ControlProtocolTests`, `LiveVideoTests`):
- Kaze vectors: routing header, ACK payload, UDP header (K protocol/test-vectors/transport/transport.json).
- OSM frame goldens: record start/stop and all 7 mode frames above (exact hex, id `0x0402`).
- Window observer: seeds from 34-B status until first `0x02`/`0x03`; never rewinds after; `peerAck` from @24; `txLagSlots` wrap.
- `StatusTracker` `02/80`: `01/41/81/C1` sequences, @29, @17, @57, @4 gating, `< 58 B` ignored.
- `LiveReassembler`: single-fragment msg; multi-fragment; new marker mid-message drops; seq gap drops;
  oversize/zero length rejected; mid-join ignored; 1.5 s partial expiry.
- NAL split (3/4-byte start codes), AVCC lengths, `waitingForIDR` gating, format description from a real SPS/PPS.
- Real H.264 fixture without committing binaries: generate in-test with `VTCompressionSession` from
  synthetic `CVPixelBuffer`s (e.g. 320×180, 10 frames), convert AVCC→Annex-B + SPS/PPS, then decode
  back through `LiveDecoder` into `VTDecompressionSession` (no display layer needed; `ImageRenderer` can't show it).

FakeCamera extensions:
1. Echo the client's session id (needed if we filter by session).
2. Reply to commands on **pktType `0x03`** with its own `+8` seq; emit 34-B pktType-`0x01` window
   status every 100 ms (@10 last `0x02` seq, @18 last `0x03` seq, @24/@26 last client TX seq seen).
3. Window enforcement (the regression that matters): keep `0x03` replies/`0x02` fragments only while
   `(sent − clientAckGroup) / 8 ≤ W` (W small, e.g. 16); otherwise stop sending. Test: 200 control
   commands over > 60 s simulated all get replies (fails with the legacy ACK — proves §1.2).
4. Record state machine: `02/02 [01]` → reply `00`, @0 `41` for 300 ms then `81`, @29 counts up;
   `[00]` → `C1` for 300 ms then `01`; `[01]` while recording → `DF`; `02/01` when @57 ≠ 05 → `D9`;
   `02/E1 [m]` → `00`, @57 = m, @4 = (m != 05). While in playback: `02/02`, `02/01`, `02/E1` → `D9`,
   `09/A8` → `E0` (behaviour chosen for the fake; real Pocket 3 UNVERIFIED).
5. Playback exit modes (parameter): leave via `0x02/0x0C 01010000`, or only via `01/01 START`, or
   only after the link drops — to exercise all three §2 steps.
6. Live: on `09/A8` to a configurable receiver (`0x41`/`0x08`) outside playback, stream the fixture
   GOP at 25 fps as `00 00 01 FF`+len+8 B meta, fragmented at ~1400 B, `+8` seqs; option to start
   with leftover P-frames before the IDR; option to drop one fragment; option "black until `02/18`
   round-trip" for the first-picture workaround; stop streaming if ACK group 1 lags > W.
7. Assertions on the client side: ACK rate ≥ 30 Hz during live (fake counts pktType-`0x04` per second),
   no `09/A8` more often than every 5 s, playback leave sent only in `.media`.

### 6.6 Rollout order and first hardware checklist

1. Transport window model (+ A/B switch) → run today's library flow on the Pocket 3; must still list/page/download.
2. `.capture` + record/photo/mode (no video) → verify: bit 30 clears (which §2 step did it), replies
   `00`, `02/80` sequences, elapsed @29, mode @57, `txLagSlots` stays < 8 over 5 min.
3. Live view Variant A → time-to-first-IDR, fps, `0x41` vs `0x08`, first-picture-black workaround.
4. Back to library: `enterMediaMode` re-enters playback; listing complete; downloads OK.
Log lines to add: `control: sent 02/02 01 seq=… id=…`, `control: reply 02/02 00 (pktType 03)`,
`status: rec 01→41→81 elapsed=…`, `live: first IDR after … ms`, `live diag/5s: udp=… AU=… fps=… drops=… ackHz=… txLag=…`.

---

## 7. Open / UNVERIFIED (to settle on hardware)

1. How Pocket 3 leaves `0x01/0x01` playback without dropping the link (`0x02/0x0C` leave reply? Kaze START?).
2. `09/A8` receiver `0x41` (Kaze) vs `0x08` (OPC) on Pocket 3; whether the `01/01` START burst is required.
3. Record/photo/mode behaviour while playback is held (expected `D9`).
4. Timelapse/Hyperlapse start opcode (`02/01` per OPC survey vs `02/02` per Kaze).
5. `02/E1` writer safety for `00 02 0A 0C 28` on Pocket 3 (readback-only per Kaze docs).
6. Whether HTTP `/v2` downloads work in capture/live mode.
7. Whether listing still completes with the Mimo ACK model (expected yes; A/B switch covers it).
8. Live fps vs recording fps on Pocket 3 (OPC ~25; Kaze capture hints at 60 Hz pictures, K docs:823-830).
9. Real ~40–70 s write-death with the corrected windows (expected gone).
