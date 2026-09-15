# Protocol (what we use)

Full source: the upstream's [`MEDIA_PROTOCOL.md`](https://github.com/KonradIT/osmosis/blob/main/MEDIA_PROTOCOL.md). This is the summary, so you don't have to reread it. Capture control and live view (Live tab): `docs/CONTROL.md`.

## DUML frame

`55 | len(10 bits)+ver(6 bits)=1 | crc8(init 0x77, poly 0x8C) | target u16 | id u16 | type u24 | payload | crc16(init 0x3692, poly 0x8408)`
`type = flags | cmdSet<<8 | cmdId<<16` (flags `0x40` request, `0xC0` response, `0x00` push). Receiver byte = `(id<<5)|type`: App `0x02`, Camera `0x01`, WiFi `0x07`, DM368 `0x08`, session `0xF0`, `0x1C`, RTC `0x28`.

## BLE (GATT `fff0`)

1. Notify on **fff4 and fff5**; write `01 00` to the fff4 value (with response); wait ~200 ms.
2. fff5: write-without-response only; space out writes (we use 60 ms).
3. Sequence: `0x00/0x2b [04 00]`→`0xF0` · `0x07/0x45` PackString(identity)+PackString("osmo") · reply `[00][01]` already paired / `[00][02]` approve on the camera → `0x07/0x46` arrives as a **request** (it must be answered) · `0x53/0x10`→`0x1C` (Pocket 3 replies `e0` but brings up the AP anyway) · `0x07/0x07` SSID · `0x07/0x0e` password (`[status][PackString]`).
4. Every incoming request (`flags 0x40`) gets a response: inverted target, same id, flags `0xC0`, echoed payload (or `appDeviceInfo` for `0x00/0x81`).
5. Identity used: `284ae5b8d76b3375a04a6417ad71bea3` (the same one Osmosis Android uses for cameras).

## Datalink (UDP to 192.168.2.1)

- Pocket 3 / Nano / Action 5-6 / Pocket 4: **UDP 9004** + TCP 7001 poke (SetPairingPIN). Xtra: 10004 without poke. Drones (Mavic 3, Neo 2): 9003 without poke. If there is no handshake, the alternative is tried. Only packets from the camera's IP are accepted.
- Packet: `[8B: 0x8000|total, session, seq, pktType, xor][12B routing: ack=seq-8, seq, 0000, counter, 01, 00, 00][DUML]`. pktType `00` handshake, `01` telemetry, `02` live video, `03` responses (in capture mode), `04` window ACK (echo of the peer's download cursor; in capture mode, the official app's model: see `docs/CONTROL.md`), `05` command.
- Registration: `0x00/0x81` (deviceinfo, cmdType 4, DM368 id2) → `0x00/0x88` APP presence → `0x03/0xDA 05ffffffff` → 8 `0x00/0x99` subscriptions → `0x00/0x6a` time+TZ to `0x28`.
- **Playback**: `0x02/0x0c 01010001`; confirmed only by **bit 30 of `0x02/0x80`**. Pocket 3 replies `e0` → `0x01/0x01` route (cmdType 0): 6× `0300000000040000000701` and then `0000000000040000000401` at ~20 Hz until the bit is set. Leave: `0x02/0x0c 01010000`.
- List: `0x00/0x26` with a counter at `@4` and a u32 cursor at `@10`: ctr1 `0x00000001` (SD), trigger `4a040e10…`, ctr2 `0x40000001` (internal). Response: `0x00/0x27` chunks `[4A sub 00 00 ctr 00 seq16 00 00][data]`, sub `04` start / `01` data / `03` end. The session builds the blob only from these frames, walking each datagram separately (8 MB cap). Page = 45; next page = cursor at the oldest handle of each store; end = TLV `0c 01 0d`.
- Keep-alive: ACK + beat `0x00/0x88 170046237c415050000000000002` ~1 Hz. Without it, the camera drops playback and the AP.

## HTTP

`GET http://192.168.2.1/v2?storage=N&path=DCIM/…` (Pocket 3: always `storage=0`). Thumbnail `MISC/THM/….scr` (photos: `.thm`). Video proxy: same path with `.LRF`. Unlisted sidecars: `.DNG` next to JPG, `.WAV` next to MP4. The camera cuts long transfers and returns transient 404/500 → retry with Range and backoff.
