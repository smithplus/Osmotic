# Estado

_Última actualización: 2026-09-15. Dos pruebas con la Pocket 3 real: Files (build `776be7d`) y Files + Live (build 25, rama `ui/te-style`). Sin probar con hardware todavía: Webcam, foto en modo Photo, permisos desde Finder, primer emparejamiento._

## Próxima prueba con hardware (en este orden)

1. **Barra de progreso con clips > 4 GiB** — mandar a bajar un clip largo (el tamaño del manifiesto es u32): el total y el tiempo restante tienen que ser reales desde el inicio (log: `library: … is N MB (listed as M MB)`).
2. **Foto** en modo Photo (Live); paginar con > 45 archivos; primer emparejamiento si se puede (resetear la cámara).
3. **Webcam** — enchufar por USB-C, elegir Webcam en la cámara, ver la imagen; permiso de cámara.
4. **Permisos con la app abierta desde Finder** (no Terminal): Bluetooth, Ubicación (dar y negar), Red local (negar y después permitir), Descargas, Cámara, Notificaciones.

Pedir el log `~/Library/Logs/Osmotic/osmotic-*.log` de cada prueba.

## Verificado con la Pocket 3 real (2026-09-15, build 25, log `osmotic-20260915-023644.log`)

Files + Live, todo a la primera: BLE (ya emparejada), Wi-Fi por CoreWLAN al primer intento, playback por `0x01/0x01`, 11 archivos. **Live**: salida de playback (`0x02/0x0c` → `e0`, luego START), vista en vivo a los 17 ms del pedido, 0 fragmentos perdidos; grabar → `camera recording: YES`, detener → `no`; modos Photo, Slow-mo y Low light confirmados por el estado de la cámara; vuelta a la tarjeta con relistado (1 clip nuevo). Descargas a ~33 MB/s, `.WAV` de respaldo, reanudación a 3685 MB de un clip de más de 4 GiB, cancelar y desconectar; vuelta a la red de casa en 4 s (otra vez `-3900 tmpErr` de `networksetup`, pero macOS vuelve solo).

Corregido después de esta prueba: (1) el tamaño del manifiesto es u32 y un clip de más de 4 GiB aparecía con el tamaño "dado la vuelta" — la barra llegaba a 100 % con 00:00 restante. Ahora se pide el tamaño real por HEAD a los videos de más de 2 min y el descargador informa el del servidor (`onTotal`). (2) El error de `networksetup` repetía el nombre de la red de casa en el log: ahora se tapa. (3) El espacio libre se registraba cada 400 ms al grabar: ahora cada GB.

## Verificado con la Pocket 3 real (2026-09-14, build `776be7d`, log `osmotic-20260914-175922.log`)

Todo el flujo de Files funcionó a la primera: BLE armado (MTU 512), ya emparejada (`0x01`), SSID y password por BLE, CoreWLAN `associate` al primer intento (sin `networksetup`), ruta por `en0`, handshake udp/9004, `0x02/0x0c` → `e0` → playback por `0x01/0x01` en 5 tramas, 9 archivos (SD), 4 MP4 + 4 WAV bajados (1,97 GB a ~32 MB/s), salida de playback, vuelta a la red de casa. Los archivos son MP4 válidos. Al restaurar, `networksetup -setairportnetwork` devolvió `-3900 tmpErr` pero macOS ya estaba volviendo solo; el chequeo por IP lo detectó en 4 s.

## Verificado sin hardware

`swift test`: **83 tests en 20 suites**, en verde; también en CI (GitHub Actions, macos-26).
- Decodificador idéntico al upstream en las **14 capturas golden** (6 de Pocket 3); tramas BLE/datalink idénticas a capturas reales.
- Sesión contra `FakeCamera`: handshake, rechazo `0x02/0x0c`, playback por `0x01/0x01`, lista, paginación inline, salida de playback al cerrar.
- Control contra `FakeCamera` (`ControlTests`): salida de playback (dos vías), grabar/detener, foto, modo, vista en vivo H.264 reensamblada; vectores de bytes de Kaze para ACK y routing.
- Descargas contra `FakeHTTPServer`: cortes con reanudación byte a byte, 404/500, Range ignorado, tamaño del manifiesto menor que el real, HTML, redirecciones, 416.
- Robustez: nombres de archivo no confiables (`PathSafetyTests`), datos aleatorios en todos los parsers de red (`FuzzTests`, limpio con AddressSanitizer).
- UI revisada con `scripts/snapshot.sh` en inglés y español (todas las pantallas).

## Cambios en el camino de Files desde la primera prueba (probados con hardware el 2026-09-15)

- Manifiesto armado solo con tramas `0x00/0x27` por datagrama (antes: datagramas concatenados; un `0x55` suelto con CRC válido podía tragarse fragmentos — lista corta).
- Datalink: descarta paquetes que no vienen de la IP de la cámara; tope de 8 MB del manifiesto; pktType 0x02 se desvía fuera del parser de estado solo en modo captura.
- Descargas: completas solo si los bytes coinciden con Content-Length/Content-Range (el tamaño del manifiesto es una pista); 416 con `.part` completo termina; se rechazan HTML y redirecciones; nombres locales saneados; nunca borra en el destino; `.part` nunca sigue un symlink.
- Wi-Fi: solo olvida la red de la cámara si la agregó la app; no se une a una red abierta con el nombre de la cámara; `networksetup` con contraseña recién al 4.º intento; aviso si no vuelve sola a tu red.
- Contraseña de la cámara en el Llavero (solo si se escribe a mano).
- Firma con hardened runtime + entitlements de ubicación y cámara (`Resources/Osmotic.entitlements`); sin `NSAllowsArbitraryLoads`. `NSAllowsLocalNetworking` es lo que habilita HTTP a `192.168.2.1` en macOS 14+: no quitarlo.
- Conexión: "Try Again" arreglado; una conexión nueva espera la restauración de Wi-Fi anterior y las recuperaciones; `CameraSession.close()` idempotente.

## Revisiones hechas (2026-09-14)

Rendimiento medido (M4, demo): pantalla de conexión 7–15 % → 0,3 % de CPU; cámaras 13 % → ~0 %; Live 4 % → 0,2 %. Los logs de las corridas demo/snapshot van a una carpeta temporal (antes rotaban los logs reales: el de la prueba de hardware se perdió así).

Seguridad, implementación, UI/accesibilidad, guías de Apple (distribución, privacidad, HIG), formato (`swift-format`). Lo aplicado está en `CHANGELOG.md`; lo que depende de una cuenta Apple Developer está abajo.

## Pendiente (en orden)

1. **Próxima prueba con hardware** (arriba) y ajustar según el log.
2. Live: Timelapse/Hyperlapse (¿disparo por `02/01` o `02/02`?), truco de "primera imagen negra" (`02/18`), re-registro de respaldo si las escrituras se pierden, descargas en modo captura. Ver `docs/CONTROL.md`.
3. **Distribución**: cuenta Apple Developer → `SIGN_IDENTITY=… NOTARY_PROFILE=… scripts/notarize.sh` (DMG notarizado). Sin eso, macOS vuelve a pedir permisos en cada build y quien la baje tiene que usar "Abrir igualmente".
4. Mover la lógica testeable de la app (decisiones de red, cola de descargas) a una librería con tests.
5. Accesibilidad: anillo de foco visible en `CassetteKeyStyle` con acceso total por teclado; variantes de Aumentar contraste.
6. Expandir ráfagas/intervalos (`_001` → frames) con el group-expand `0x00/0x26` modo `0x10` (hoy solo baja el primero).
7. Favoritos y borrado en la cámara (`0x02/0xbf`, `0x00/0x28`) — portado en Kotlin, no en Swift.
8. Recorte de clips (trim) con `AVAssetExportSession` passthrough; actualizaciones con Sparkle 2.
9. Dos archivos con el mismo nombre en carpetas/tarjetas distintas van al mismo destino (el Pocket 3 usa nombres con fecha y hora; no pasa en la práctica).

Pregunta abierta del usuario: ¿puede la cámara unirse al Wi-Fi de casa para no perder Internet? El Pocket 3 se une a redes solo para *livestream* RTMP; nadie documentó descargas en ese modo. Hoy: Ethernet o iPhone por cable mantienen Internet.

## Cómo diagnosticar una prueba real

Líneas clave del log:
- `BLE: control channel armed` → GATT OK. `BLE: pairing reply 0x01/0x02` → pairing. `BLE: Wi-Fi password received` → credenciales.
- `wifi: camera reachable at 192.168.2.1 (ssid …, ip …)` y `wifi: route to 192.168.2.1 goes via en0 ✓` → Wi-Fi OK.
- `datalink: handshake OK on udp/9004` → `playback mode held via 0x01/0x01` → `per-store lists — SD N` → lista OK. `SD slice TRUNCATED` → lista corta (reportar).
- `transfer: … saved` / `link dropped … resuming` → descargas.
- Live: `control: …` y `live: …` (ver `docs/CONTROL.md`). Webcam: `webcam: found …`.
- Vuelta a casa: `wifi: back on "X…" (N chars)` o `wifi: could not rejoin a network automatically`.
