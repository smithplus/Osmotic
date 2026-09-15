# Arquitectura

## Flujos

```
Files — CamerasView ──connect──▶ AppModel.runConnect
  1. BluetoothService  scan/connect, GATT fff0: notify fff4+fff5, write 01 00 → fff4, cola de escrituras a fff5
     PairingFlow       00/2b wake → 07/45 SetPairingPIN("osmo") → [07/46 aprobación] → 53/10 → 07/07 SSID → 07/0e pass
  2. WiFiService.join  CoreWLAN associate (networksetup de respaldo desde el 4.º intento) hasta que 192.168.2.1:80 responde
  3. CameraSession     UDP 9004 (+poke TCP 7001): handshake → registro → hora → playback → lista (0x00/0x26 → tramas 0x00/0x27)
  4. CameraHTTP        resolveStorage → LibraryView; FileDownloader baja a Preferences.downloadFolder (por defecto ~/Downloads/DJI)
Desconectar: CameraSession.close (sale de playback) → BLE off → WiFiService.restore (teardownTask; una conexión nueva la espera)

Live — AppModel.setWorkspace(.camera) → CameraSession.enterControl (sale de playback, modo captura, ACK .mimo)
  → startLiveView (ráfaga de Kaze → pktType 0x02 → LiveReassembler → LiveVideoRenderer)
  Volver a Files = leaveControl (re-entra a playback y relista).

Webcam — WebcamService: AVCaptureDevice externo cuyo nombre contiene osmo/pocket/dji → AVCaptureSession → WebcamPreview.

Arranque — AppModel.recoverInterruptedSession deshace una sesión cortada (Preferences.pending*: SSID de casa y de la cámara).
```

Pestañas (`AppModel.Workspace`): **Files** (`.files`, flujo Wi-Fi: cámaras → conexión → biblioteca), **Live** (`.camera`, requiere conexión), **Webcam** (`.webcam`, USB, desde cualquier pantalla menos la de conexión). Convertir Osmotic en cámara virtual necesitaría una Camera Extension (firma Developer ID); la Pocket 3 ya es webcam UVC por cable.

## Mapa de archivos

### `Sources/OsmoticCore` (protocolo, sin UI, nonisolated)

| Archivo | Qué hace |
|---|---|
| `DUML/Bytes.swift` | helpers `[UInt8]` (hex, u16le/u32le, latin1, LE builders) |
| `DUML/DjiMessage.swift` | CRC8/CRC16, `DjiMessage` encode/decode, `DumlScanner` (frames en blobs, `findReply`), `DumlFrameAccumulator` (notificaciones BLE) |
| `DUML/OsmoCommands.swift` | tramas BLE: pairing, wifi getters, session ping/wake, respuesta a requests, `appDeviceInfo` |
| `BLE/CameraModel.swift` | `BleAdvert` (model id de manufacturer data), `Brand`, `CameraModel` (puerto/poke/storage por modelo) |
| `BLE/PairingFlow.swift` | máquina de estados BLE → eventos `.approvalRequired/.paired/.credentials/.needsPassword/.notActivated`; la contraseña guardada se lee solo si hace falta |
| `Datalink/DatalinkTransport.swift` | socket UDP POSIX (solo acepta paquetes de la IP de la cámara), headers (8B transporte + 12B routing), handshake, ACK de ventanas `windowModel` `.legacy`/`.mimo`, cursores (`observe`), desvío de video (`onVideo`/`dropVideo`), `recvAll(ms:precise:)`, `TCPProbe` |
| `Camera/CameraSession.swift` | sesión: registro, playback (`0x02/0x0c` y ruta Pocket 3 `0x01/0x01`), lista (`collect` arma el blob con tramas `0x00/0x27`, tope 8 MB), paginación, keep-alive, link lost/restored; modo captura (`enterControl`/`leaveControl`, grabar, foto, modo, vista en vivo) |
| `Camera/CaptureMode.swift` | códigos de modo (`0x02/0xE1`, byte 57 de `0x02/0x80`); `deck` = los que ofrece la UI |
| `Camera/ManifestDecoder.swift` | decodificador CompositePack (port 1:1), reensamblado de chunks `0x00/0x27`, `inferMissingExtensions` |
| `Camera/Pagination.swift` | cursores por store, `SliceInfo`, `collectStores` (split SD/interno por contador de request) |
| `Camera/StatusTracker.swift` | pushes de estado: batería `0x0d/02`, storage `0x02/dc`, `0x02/80` (playback, grabando, segundos, modo) |
| `Camera/CameraFile.swift` | modelo de archivo, `localName` (nombre local seguro ante nombres no confiables), URLs `/v2?storage=N&path=…`, `CameraStatus` (batería, storage, grabación, modo) |
| `Video/LiveReassembler.swift` | fragmentos pktType 0x02 → mensajes Annex-B (continuidad por seq, tope 8 MB) |
| `Video/H264AnnexB.swift` | NALs, AVCC |
| `HTTP/CameraHTTP.swift` | URLSession efímera sin redirecciones, HEAD/data/range, `resolveStorage` |
| `HTTP/FileDownloader.swift` | descarga a `.part` con reanudación por Range; completa solo si coincide con Content-Length/Content-Range; rechaza HTML/redirecciones; 416 = completa; nunca borra en el destino |
| `HTTP/ThumbnailFetcher.swift` | actor: `.scr` → `.thm` → EXIF, concurrencia 4, caché en disco (solo imágenes) |
| `HTTP/EmbeddedJpeg.swift` | miniatura EXIF desde los primeros 64 KiB |

### `Sources/Osmotic` (app, MainActor por defecto)

| Archivo | Qué hace |
|---|---|
| `App/AppModel.swift` | **orquestador**: pantallas, etapas de conexión (`connectGeneration`), `teardownTask`/`startupRecovery`/`recoverTask` (nunca se pisan con una conexión nueva), biblioteca, auto-paginado, cola de descargas (`transferGeneration`, `queuedIds`), recuperación de enlace (`linkGaveUp`), pestañas (`Workspace`, `setWorkspace`), control y vista en vivo, modo demo (`loadDemo`) |
| `App/OsmoticApp.swift` | escenas (`Window` principal, Ajustes, Registro), menús Camera y Help, `AppDelegate` (desconecta al salir, espera la vuelta del Wi-Fi, hook `OSMOTIC_SNAPSHOT`) |
| `App/Persistence.swift` | `Preferences` (UserDefaults), `SavedCameraStore`, `Keychain` (contraseña Wi-Fi de la cámara), `DownloadHistory`, `DownloadPaths` |
| `App/AppLog.swift` | `log()` thread-safe → archivo (sin usuario en las rutas) + `LogStore` visible; `redactedSSID` |
| `Services/BluetoothService.swift` | CoreBluetooth (central creado lazy, delegados `@preconcurrency` en main queue) |
| `Services/WiFiService.swift` | join/restore (devuelve si volvió a una red), `pause` no cancelable, redes guardadas, IPs, ruta, `LocationPermission`, `LocalNetworkPermission` |
| `Services/TransferNotifier.swift` | sonido, rebote del Dock y notificación al terminar; pide el permiso en la primera descarga |
| `Services/LiveVideoRenderer.swift` | SPS/PPS → `CMVideoFormatDescription` → `AVSampleBufferDisplayLayer` (cola propia, `nonisolated`); informa la proporción del video |
| `Services/WebcamService.swift` | la cámara por USB como webcam (UVC): detección, permiso (solo con cámara presente), vista previa |
| `Views/RootView.swift` | pantalla según `screen`, `TopPlate` (franja superior con pestañas al centro) |
| `Views/CamerasView.swift` | cámaras cercanas y guardadas, `Notice`, `ErrorBanner`, carpeta de destino |
| `Views/ConnectingView.swift` | etapas de conexión, aprobación, contraseña manual |
| `Views/LibraryView.swift` | biblioteca: `WorkspaceTabs`, `LibraryTopPlate`, `ControlDeck` (LCD de estado, filtros, transferir), grilla con flechas |
| `Views/MediaCell.swift`, `TransferBar.swift`, `PreviewView.swift` | miniatura (VoiceOver, en cola), barra de descarga, vista previa (LRF) |
| `Views/CameraControlView.swift` | pestaña Live: LCD de captura, monitor, modos, disparo |
| `Views/WebcamView.swift` | pestaña Webcam: imagen por USB o los tres pasos |
| `Views/SettingsView.swift`, `LogView.swift`, `SnapshotView.swift` | Ajustes, Registro, render para `snapshot.sh` |
| `Views/Theme.swift` | sistema de diseño: tokens de color, espaciado (`s1…s6`) y radios; `Depth`/`Pocket` (sombras), `Motion`/`LCDBoot` (movimiento), `AluminumPlate`, `raisedPanel`, `LCDGlass`/`LCDPair`/`LCDText`/`SegmentMeter`, `CassetteKeyBank`/`CassetteKeyStyle`, `LED`, `Silk`, `BankLegend`, `SectionIndex`, `Format` |

### Recursos y scripts

| Archivo | Qué es |
|---|---|
| `Resources/Info.plist`, `es.lproj/InfoPlist.strings` | bundle y textos de permisos (inglés / español) |
| `Resources/Osmotic.entitlements` | hardened runtime: ubicación (nombre del Wi-Fi) y cámara (Webcam) |
| `Resources/Localizable.xcstrings` | catálogo de textos (inglés base + español); `scripts/sync_strings.sh` lo actualiza |
| `Resources/Credits.rtf`, `PrivacyInfo.xcprivacy`, `AppIcon.icns` | "Acerca de", manifiesto de privacidad (documental), ícono |
| `scripts/package_app.sh`, `notarize.sh`, `snapshot.sh`, `lint.sh`, `sync_strings.sh`, `make_icon.swift` | ver `CLAUDE.md` |
| `.github/workflows/ci.yml` | CI: formato, build, tests, empaquetado |

### Tests (`Tests/OsmoticCoreTests`)

`ManifestTests` (golden ×14 + Pocket 3), `ProtocolTests` (tramas contra capturas reales), `PairingFlowTests` (reloj falso), `SessionEndToEndTests` + `FakeCamera` (sesión completa por loopback, incl. paginación), `ControlTests` (vectores de Kaze, estado de grabación, `LiveReassembler`, modo captura e2e contra `FakeCamera`), `H264Tests`, `DownloaderTests` (+ `FakeHTTPServer`), `PathSafetyTests`, `FuzzTests`, `ThroughputProbe` (solo con `OSMOTIC_PERF=1`).

## Modelo de concurrencia

- **CameraSession**: hilo propio + cola de jobs (`NSCondition`). API pública `async` (`connect`, `nextPage`, `enterControl`, `leaveControl`, `setRecording`, `takePhoto`, `setMode`, `startLiveView`, `stopLiveView`, `close`) encola y espera. En `.media` corre `keepAliveTick` entre jobs (~0,5 s: drenar, ACK, beat `0x00/0x88` ~1 Hz, re-afirmar playback cada ~15 s); en `.capture`/`.live`, `controlTick` (bomba de 12 ms, ACK ≥ 40 Hz, beat 1 Hz, reintento de la vista en vivo). `close()` marca `isClosed` (idempotente) → los loops abortan; jobs pendientes devuelven vacío.
- **Callbacks de sesión** (`onStatus`, `onLinkLost`…) y el video llegan en el hilo de la sesión → saltar a `@MainActor` (o a la cola de `LiveVideoRenderer`). `AppModel` ignora callbacks de sesiones reemplazadas (`session === s`).
- **FileDownloader**: delegate URLSession en cola serial, handlers por `taskIdentifier`, `completedEarly` para la carrera cancel/start.
- **Conexión**: cada intento tiene `connectGeneration`; `live()` después de cada `await`; un intento nuevo espera al anterior y a `teardownTask`/`startupRecovery`/`recoverTask`.
- **Excepciones al MainActor de la app**: `LiveVideoRenderer`, `FileSink` (log) y funciones `@concurrent`/`nonisolated` de `WiFiService`. Cada `@unchecked Sendable` justifica en un comentario por qué es seguro.
