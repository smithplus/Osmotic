# Arquitectura

## Flujo de una conexión

```
CamerasView ──connect──▶ AppModel.runConnect
  1. BluetoothService  scan/connect, GATT fff0: notify fff4+fff5, write 01 00 → fff4, cola de escrituras a fff5
     PairingFlow       00/2b wake → 07/45 SetPairingPIN("osmo") → [07/46 aprobación] → 53/10 → 07/07 SSID → 07/0e pass
  2. WiFiService.join  CoreWLAN associate (+ networksetup fallback) hasta que 192.168.2.1:80 responde
  3. CameraSession     UDP 9004 (+poke TCP 7001): handshake → registro → hora → playback → lista (0x00/0x26)
  4. CameraHTTP        resolveStorage → LibraryView; FileDownloader baja a ~/Downloads/DJI
Desconectar: CameraSession.close (sale de playback) → BLE off → WiFiService.restore
```

## Mapa de archivos

### `Sources/OsmoticCore` (protocolo, sin UI, nonisolated)

| Archivo | Qué hace |
|---|---|
| `DUML/Bytes.swift` | helpers `[UInt8]` (hex, u16le/u32le, latin1, LE builders) |
| `DUML/DjiMessage.swift` | CRC8/CRC16, `DjiMessage` encode/decode, `DumlScanner` (frames en blobs), `DumlFrameAccumulator` (notificaciones BLE) |
| `DUML/OsmoCommands.swift` | tramas BLE: pairing, wifi getters, session ping/wake, respuesta a requests, `appDeviceInfo` |
| `BLE/CameraModel.swift` | `BleAdvert` (model id de manufacturer data), `Brand`, `CameraModel` (puerto/poke/storage por modelo) |
| `BLE/PairingFlow.swift` | máquina de estados BLE → eventos `.approvalRequired/.paired/.credentials/.needsPassword/.notActivated` |
| `Datalink/DatalinkTransport.swift` | socket UDP POSIX, headers (8B transporte + 12B routing), handshake, ACK de ventanas, `TCPProbe` |
| `Camera/CameraSession.swift` | sesión completa: registro, playback (`0x02/0x0c` y ruta Pocket 3 `0x01/0x01`), lista, paginación inline/fresh, keep-alive, link lost/restored |
| `Camera/ManifestDecoder.swift` | decodificador CompositePack (port 1:1), reensamblado de chunks `0x00/0x27`, `inferMissingExtensions` |
| `Camera/Pagination.swift` | cursores por store, `SliceInfo`, `collectStores` (split SD/interno por contador de request) |
| `Camera/StatusTracker.swift` | pushes de estado: batería `0x0d/02`, storage `0x02/dc`, flags/playback `0x02/80` |
| `Camera/CameraFile.swift` | modelo de archivo + URLs `/v2?storage=N&path=…`, `CameraStatus` |
| `HTTP/CameraHTTP.swift` | URLSession efímera, HEAD/data/range, `resolveStorage` |
| `HTTP/FileDownloader.swift` | descarga a `.part` con reanudación por Range, backoff, 5 intentos sin progreso = pausa |
| `HTTP/ThumbnailFetcher.swift` | actor: `.scr` → `.thm` → EXIF, concurrencia 4, caché en disco |
| `HTTP/EmbeddedJpeg.swift` | miniatura EXIF desde los primeros 64 KiB |

### `Sources/Osmotic` (app, MainActor por defecto)

| Archivo | Qué hace |
|---|---|
| `App/AppModel.swift` | **orquestador**: pantallas, etapas de conexión, cancelación por `connectGeneration`, teardown, biblioteca, auto-paginado mientras haya nuevos, cola de descargas (`transferGeneration`), recuperación de enlace |
| `App/OsmoticApp.swift` | escenas (ventana, Ajustes, Registro), menú Cámara, `AppDelegate` (desconecta al salir, hook `OSMOTIC_SNAPSHOT`) |
| `App/Persistence.swift` | `Preferences` (UserDefaults), `SavedCameraStore`, `DownloadHistory`, `DownloadPaths` |
| `App/AppLog.swift` | `log()` thread-safe → archivo + `LogStore` visible |
| `Services/BluetoothService.swift` | CoreBluetooth (central creado lazy, delegados `@preconcurrency` en main queue) |
| `Services/WiFiService.swift` | join/restore, `pause` no cancelable, IPs, ruta, `LocationPermission`, `LocalNetworkPermission` |
| `Views/*` | `RootView` → `CamerasView` / `ConnectingView` / `LibraryView` (+ `MediaCell`, `TransferBar`, `PreviewView`), `SettingsView`, `LogView`, `Theme` (tokens), `SnapshotView` (debug) |

### Tests (`Tests/OsmoticCoreTests`)

`ManifestTests` (golden ×14 + Pocket 3), `ProtocolTests` (tramas contra capturas reales), `PairingFlowTests` (reloj falso), `SessionEndToEndTests` + `FakeCamera` (sesión completa por loopback, incl. paginación), `DownloaderTests` + `FakeHTTPServer`, `ThroughputProbe` (solo con `OSMOTIC_PERF=1`).

## Modelo de concurrencia

- **CameraSession**: hilo propio + cola de jobs (`NSCondition`). API pública `async` (`connect`, `nextPage`, `close`) encola y espera. Entre jobs corre `keepAliveTick` (~0,5 s: drenar, ACK, beat `0x00/0x88` ~1 Hz, re-afirmar playback cada ~15 s). `close()` marca `isClosed` → los loops abortan; jobs pendientes devuelven vacío.
- **Callbacks de sesión** (`onStatus`, `onLinkLost`…) llegan en el hilo de la sesión → saltar a `@MainActor`. `AppModel` ignora callbacks de sesiones reemplazadas (`session === s`).
- **FileDownloader**: delegate URLSession en cola serial, handlers por `taskIdentifier`, `completedEarly` para la carrera cancel/start.
- **Conexión**: cada intento tiene `connectGeneration`; `live()` después de cada `await`; un intento nuevo espera (`await previous.value`) a que el anterior limpie.
