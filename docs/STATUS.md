# Estado

_Última actualización: 2026-09-14 (primera prueba con Pocket 3 real: OK)._

## Hecho y verificado sin hardware

- Núcleo del protocolo portado de Osmosis (Kotlin → Swift). `swift test`: **49 tests en verde**.
  - Decodificador idéntico al upstream en las **14 capturas golden** (6 de Pocket 3).
  - Tramas BLE/datalink idénticas a capturas reales (pairing, wake, wifi getters, list query).
  - Sesión completa contra `FakeCamera`: handshake, rechazo `0x02/0x0c`, playback por `0x01/0x01`, lista, paginación inline, salida de playback al cerrar.
  - Descargas contra `FakeHTTPServer`: cortes con reanudación byte a byte, 404/500 transitorios, Range ignorado, pausa tras 5 intentos sin progreso. Throughput de escritura ~2,4 GB/s.
- App SwiftUI completa: cámaras cercanas/guardadas, stepper de conexión con aviso de aprobación y contraseña manual, biblioteca por día con miniaturas/badges/filtros/selección, vista previa (proxy LRF), cola de descargas con velocidad y ETA, Ajustes, Registro.
- Revisión de código independiente aplicada (cancelación de conexión, restauración de Wi-Fi no cancelable, sesión cerrada, falsos positivos de red 192.168.2.x, cola de descargas por generación, SSID perdido).

## Verificado con la Pocket 3 real (2026-09-14, log `osmotic-20260914-175922.log`)

Todo el flujo funcionó a la primera: BLE armado (MTU 512), ya emparejada (`0x01`), SSID y password por BLE, CoreWLAN `associate` al primer intento (sin `networksetup`), ruta por `en0`, handshake udp/9004, `0x02/0x0c` → `e0` → playback por `0x01/0x01` en 5 tramas, 9 archivos (SD), 4 MP4 + 4 WAV bajados (1,97 GB a ~32 MB/s), salida de playback, vuelta a la red de casa. Los archivos son MP4 válidos.

Detalle: al restaurar, `networksetup -setairportnetwork` devolvió `-3900 tmpErr` pero macOS ya estaba volviendo solo; el chequeo por IP lo detectó en 4 s.

## Revisión de seguridad e implementación (2026-09-14)

Corregido (con tests en `PathSafetyTests` y `DownloaderTests`):
- **Nombres de archivo de la cámara** (entrada no confiable): `CameraFile.localName` solo deja nombres planos; un archivo `..` podía hacer que el downloader borrara la carpeta padre (p. ej. `~/Downloads`). El downloader rechaza nombres inseguros y nunca borra en el destino.
- **Wi-Fi**: solo se olvida la red de la cámara si la agregó la app (un SSID falso igual al de casa ya no la borra); nunca se une a una red abierta con el nombre de la cámara.
- **Contraseña Wi-Fi de la cámara**: en el Llavero, guardada solo si el usuario la escribe, leída solo si la cámara no la manda por BLE; se migran las copias viejas de UserDefaults.
- **Descargas**: completas solo si los bytes coinciden con Content-Length/Content-Range (el tamaño del manifiesto es una pista); 416 con `.part` completo termina; se rechazan HTML y redirecciones; miniaturas se cachean solo si son imágenes.
- **Flujo**: "Try Again" volvía a no hacer nada; una conexión nueva espera la restauración de Wi-Fi anterior, la recuperación de arranque y la de enlace; la recuperación se cancela al desconectar y, si se rinde, la biblioteca ofrece Reconectar/Desconectar; `CameraSession.close()` idempotente y sin doble `close(fd)`.
- **UI/accesibilidad**: VoiceOver en celdas (acciones seleccionar/vista previa), filtros (`isSelected`), LEDs y etapas (valor + ✓/✕ además del color); LEDs respetan Reducir movimiento; contraste ≥ 4.5:1; plurales en español; confirmación al desconectar desde el menú; estados de Bluetooth apagado/sin permiso con acceso a Ajustes.

Pendiente (bajo): socket UDP sin `connect()` (acepta paquetes de cualquier host de la red de la cámara), tope de tamaño del manifiesto, `NSAllowsArbitraryLoads` (verificar que `NSAllowsLocalNetworking` alcanza), hardened runtime/firma Developer ID, SSIDs en el log, navegación por flechas en la grilla y foco visible, colisión de nombres entre carpetas/tarjetas.

## Todavía sin probar con hardware

1. Primer emparejamiento (aprobación en pantalla, `0x07/0x46`): la cámara ya estaba emparejada.
2. Vista previa `.LRF` en streaming desde la cámara (verificado contra un servidor de rangos local: requiere `AVURLAssetOverrideMIMETypeKey`).
3. Restauración del Wi-Fi sin permiso de ubicación; paginación con >45 archivos; recuperación de enlace caído.
4. Selección con casillas, ⇧-rango, espacio para vista previa, ← → en la vista previa, sonido/aviso al terminar (agregados después de la prueba).

## Cómo diagnosticar una prueba real

Pedir el log `~/Library/Logs/Osmotic/osmotic-*.log`. Líneas clave:
- `BLE: control channel armed` → GATT OK. `BLE: pairing reply 0x01/0x02` → pairing. `BLE: Wi-Fi password received` → credenciales.
- `wifi: camera reachable at 192.168.2.1 (ssid …, ip …)` y `route … via en0 ✓` → Wi-Fi OK.
- `datalink: handshake OK on udp/9004` → `playback mode held via 0x01/0x01` → `per-store lists — SD N` → lista OK.
- `transfer: … saved` / `link dropped … resuming` → descargas.

## Pendiente / ideas

- Pregunta abierta del usuario: ¿puede la cámara unirse al Wi-Fi de casa (modo estación) para no perder Internet? El Pocket 3 se une a redes para *livestream* RTMP, pero nadie documentó offload de media en ese modo; habría que capturar Mimo. Hoy: Ethernet o iPhone por cable mantienen Internet.

- Probar con hardware y ajustar según el log (prioridad 1).
- Expandir ráfagas/intervalos (`_001` → frames) con el group-expand `0x00/0x26` modo `0x10` (hoy solo baja el primero).
- Favoritos y borrado en la cámara (`0x02/0xbf`, `0x00/0x28`) — portado en Kotlin, no en Swift.
- Firma con Developer ID + notarización para distribuir (hoy ad-hoc: los permisos se vuelven a pedir en cada build).
- Recorte de clips (trim) con `AVAssetExportSession` passthrough.
