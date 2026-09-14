# Protocolo (lo que usamos)

Fuente completa: [`MEDIA_PROTOCOL.md`](https://github.com/KonradIT/osmosis/blob/main/MEDIA_PROTOCOL.md) del upstream. Esto es el resumen para no tener que releerlo.

## Trama DUML

`55 | len(10 bits)+ver(6 bits)=1 | crc8(init 0x77, poly 0x8C) | target u16 | id u16 | type u24 | payload | crc16(init 0x3692, poly 0x8408)`
`type = flags | cmdSet<<8 | cmdId<<16` (flags `0x40` request, `0xC0` response, `0x00` push). Byte receptor = `(id<<5)|type`: App `0x02`, Cámara `0x01`, WiFi `0x07`, DM368 `0x08`, sesión `0xF0`, `0x1C`, RTC `0x28`.

## BLE (GATT `fff0`)

1. Notify en **fff4 y fff5**; escribir `01 00` al valor de fff4 (con respuesta); esperar ~200 ms.
2. fff5: solo write-without-response, espaciar escrituras (usamos 60 ms).
3. Secuencia: `0x00/0x2b [04 00]`→`0xF0` · `0x07/0x45` PackString(identity)+PackString("osmo") · respuesta `[00][01]` ya emparejado / `[00][02]` aprobar en cámara → llega `0x07/0x46` como **request** (hay que responderla) · `0x53/0x10`→`0x1C` (Pocket 3 responde `e0`, igual levanta el AP) · `0x07/0x07` SSID · `0x07/0x0e` password (`[status][PackString]`).
4. Toda request entrante (`flags 0x40`) se responde: target invertido, mismo id, flags `0xC0`, payload eco (o `appDeviceInfo` para `0x00/0x81`).
5. Identity usada: `284ae5b8d76b3375a04a6417ad71bea3` (la misma que Osmosis Android para cámaras).

## Datalink (UDP a 192.168.2.1)

- Pocket 3 / Nano / Action 5-6 / Pocket 4: **UDP 9004** + poke TCP 7001 (SetPairingPIN). Xtra: 10004 sin poke. Si no hay handshake se prueba el alternativo.
- Paquete: `[8B: 0x8000|total, session, seq, pktType, xor][12B routing: ack=seq-8, seq, 0000, counter, 01, 00, 00][DUML]`. pktType `00` handshake, `01` telemetría, `04` ACK de ventanas (eco del cursor de descarga del peer), `05` comando.
- Registro: `0x00/0x81` (deviceinfo, cmdType 4, DM368 id2) → `0x00/0x88` APP presence → `0x03/0xDA 05ffffffff` → 8 suscripciones `0x00/0x99` → `0x00/0x6a` hora+TZ a `0x28`.
- **Playback**: `0x02/0x0c 01010001`; confirmado solo por **bit 30 de `0x02/0x80`**. Pocket 3 responde `e0` → ruta `0x01/0x01` (cmdType 0): 6× `0300000000040000000701` y luego `0000000000040000000401` a ~20 Hz hasta el bit. Salir: `0x02/0x0c 01010000`.
- Lista: `0x00/0x26` con contador en `@4` y cursor u32 en `@10`: ctr1 `0x00000001` (SD), trigger `4a040e10…`, ctr2 `0x40000001` (interno). Respuesta: chunks `0x00/0x27` `[4A sub 00 00 ctr 00 seq16 00 00][datos]`, sub `04` start / `01` datos / `03` fin. Página = 45; siguiente página = cursor al handle más viejo de cada store; fin = TLV `0c 01 0d`.
- Keep-alive: ACK + beat `0x00/0x88 170046237c415050000000000002` ~1 Hz. Sin esto la cámara suelta playback y el AP.

## HTTP

`GET http://192.168.2.1/v2?storage=N&path=DCIM/…` (Pocket 3: siempre `storage=0`). Miniatura `MISC/THM/…​.scr` (fotos: `.thm`). Proxy de video: misma ruta con `.LRF`. Sidecars no listados: `.DNG` junto a JPG, `.WAV` junto a MP4. La cámara corta transferencias largas y da 404/500 transitorios → reintentar con Range y backoff.
