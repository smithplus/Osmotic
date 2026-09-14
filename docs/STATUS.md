# Estado

_Última actualización: 2026-09-14._

## Hecho y verificado sin hardware

- Núcleo del protocolo portado de Osmosis (Kotlin → Swift). `swift test`: **49 tests en verde**.
  - Decodificador idéntico al upstream en las **14 capturas golden** (6 de Pocket 3).
  - Tramas BLE/datalink idénticas a capturas reales (pairing, wake, wifi getters, list query).
  - Sesión completa contra `FakeCamera`: handshake, rechazo `0x02/0x0c`, playback por `0x01/0x01`, lista, paginación inline, salida de playback al cerrar.
  - Descargas contra `FakeHTTPServer`: cortes con reanudación byte a byte, 404/500 transitorios, Range ignorado, pausa tras 5 intentos sin progreso. Throughput de escritura ~2,4 GB/s.
- App SwiftUI completa: cámaras cercanas/guardadas, stepper de conexión con aviso de aprobación y contraseña manual, biblioteca por día con miniaturas/badges/filtros/selección, vista previa (proxy LRF), cola de descargas con velocidad y ETA, Ajustes, Registro.
- Revisión de código independiente aplicada (cancelación de conexión, restauración de Wi-Fi no cancelable, sesión cerrada, falsos positivos de red 192.168.2.x, cola de descargas por generación, SSID perdido).

## NO verificado todavía (necesita la Pocket 3 real)

1. CoreBluetooth contra la cámara: arming de fff4, MTU que negocia macOS, recepción de `0x07/0x46`.
2. `WiFiService.join` en macOS 26: si `CWInterface.associate` funciona o hace falta `networksetup`; si macOS se queda en una red sin Internet.
3. Permisos: Bluetooth, Ubicación (para leer el SSID), Red local (primer paquete UDP).
4. Que el Pocket 3 real entre en playback con `0x01/0x01` desde el Mac.
5. Vista previa `.LRF` con `AVURLAssetOverrideMIMETypeKey`.
6. Restauración del Wi-Fi con y sin permiso de ubicación.

## Cómo diagnosticar una prueba real

Pedir el log `~/Library/Logs/Osmotic/osmotic-*.log`. Líneas clave:
- `BLE: control channel armed` → GATT OK. `BLE: pairing reply 0x01/0x02` → pairing. `BLE: Wi-Fi password received` → credenciales.
- `wifi: camera reachable at 192.168.2.1 (ssid …, ip …)` y `route … via en0 ✓` → Wi-Fi OK.
- `datalink: handshake OK on udp/9004` → `playback mode held via 0x01/0x01` → `per-store lists — SD N` → lista OK.
- `transfer: … saved` / `link dropped … resuming` → descargas.

## Pendiente / ideas

- Probar con hardware y ajustar según el log (prioridad 1).
- Expandir ráfagas/intervalos (`_001` → frames) con el group-expand `0x00/0x26` modo `0x10` (hoy solo baja el primero).
- Favoritos y borrado en la cámara (`0x02/0xbf`, `0x00/0x28`) — portado en Kotlin, no en Swift.
- Firma con Developer ID + notarización para distribuir (hoy ad-hoc: los permisos se vuelven a pedir en cada build).
- Recorte de clips (trim) con `AVAssetExportSession` passthrough.
