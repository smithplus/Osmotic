# Panel de control y vista en vivo — investigación (2026-09-14)

Resumen de un relevamiento de repos (clones en el scratchpad de esa sesión; commits: Moblin `58d400e`, Kaze `341a35d`, OpenPocketCine `9b30b93`). **Nada de esto está implementado ni probado todavía en Osmotic.**

## Fuentes útiles

| Repo | Qué aporta | Pocket 3 | Licencia |
|---|---|---|---|
| brianmerchant/Kaze-for-DJI (Swift/iOS) | grabar, foto, modos, ajustes, gimbal, **live view H.264 directo** por datalink 9004 | probado | MIT |
| erik-sutton95/OpenPocketCine | live monitor, grabar, ISO/EV/WB, captura de RTMP de Mimo, notas de recuperación | probado (fw 01.06.10.04) | Apache-2.0 (mantener NOTICE) |
| eerimoq/moblin, dimadesu/dji-remote | setup de livestream RTMP por BLE; Moblin tiene servidor RTMP Swift | listado | MIT (+ HaishinKit BSD-3) |
| xaionaro-go/djictl | Wi-Fi join + RTMP | sí | CC0 |
| DJI Osmo-GPS-Controller-Demo (R-SDK) | control oficial por BLE | **no** (solo Action/360) | EULA DJI |

## Comandos de control (App `0x02` → Cámara `0x01`, cmd_type `0x40`, por el datalink)

- Grabar: `0x02/0x02` `[01]` start / `[00]` stop (no es toggle: `[01]` grabando → `df`). Confirmar por `0x02/0x80` byte 0 bit 7 (Pocket 3: `01→41→81`, stop `c1→01`).
- Foto: `0x02/0x01 [01]` (`d9` en modo video). Panorama `[07]`.
- Modo: `0x02/0xE1 [m]` — `00` SlowMo, `01` Video, `02` Timelapse, `05` Foto, `0A` Hyperlapse, `0C` Panorama, `18` Motionlapse, `28` Low-Light. Lectura en `0x02/0x80` byte 57.
- Resolución/fps: `0x02/0x18` `[res][fps] 00 00 00`. Parámetros: `0x02/0x8E` GET/SET.
- Antes de escribir: ampliar el ACK (grupo del pktType `0x03`) y re-registrar si la sesión tiene >40 s.

## Live view directo (recomendado)

- Pedir: `0x09/0xA8` payload `00 04 02 00 00 00 00 00 00 00` (OpenPocketCine a receptor `0x08`; Kaze a `0x41` + ráfagas `0x01/0x01`). Cuál hace falta: **sin verificar**.
- Llega como pktType `0x02`: primer fragmento `00 00 01 FF` + u32 LE largo + 8 B meta + H.264 Annex-B 720p (~25 fps medido).
- ACK pktType `0x04` a ~40 Hz con los últimos seq de `0x02` y `0x03` y nuestro cursor TX. Puerto local efímero (bindear :9004 corta el video).
- Keyframes solo re-pidiendo `0x09/0xA8` tras un corte (con cooldown). Pocket 3: la primera imagen puede quedar negra hasta un cambio y reversión de formato `0x02/0x18`.
- Decodificar con `AVSampleBufferDisplayLayer` (Kaze `Pocket3VideoOutput.swift`).

## RTMP (alternativa 1080p, más adelante)

Por BLE: pair → `0x02/0x8E 01 01 1A 00 01 02` → `0x02/0xE1 [1A]` → `0x07/0x47` (ssid/psk de TU red) → `0x08/0x78` (res/kbps/fps/url) → `0x02/0x8E 01 01 1A 00 01 01`. La cámara se une a tu Wi-Fi (el Mac no pierde Internet) y empuja a un servidor RTMP en el Mac (el de Moblin, MIT). Contras: la cámara pasa a modo Live (no es preview mientras graba); latencia sin medir.
