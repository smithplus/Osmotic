# Architecture

## Flows

```
Files — CamerasView ──connect──▶ AppModel.runConnect
  1. BluetoothService  scan/connect, GATT fff0: notify fff4+fff5, write 01 00 → fff4, write queue to fff5
     PairingFlow       00/2b wake → 07/45 SetPairingPIN("osmo") → [07/46 approval] → 53/10 → 07/07 SSID → 07/0e pass
  2. WiFiService.join  CoreWLAN associate (networksetup fallback from the 4th attempt) until 192.168.2.1:80 responds
  3. CameraSession     UDP 9004 (+TCP 7001 poke): handshake → registration → time → playback → list (0x00/0x26 → 0x00/0x27 frames)
  4. CameraHTTP        resolveStorage → LibraryView; FileDownloader downloads to Preferences.downloadFolder (default ~/Downloads/DJI)
Disconnect: CameraSession.close (leaves playback) → BLE off → WiFiService.restore (teardownTask; a new connection waits for it)

Live — AppModel.setWorkspace(.camera) → CameraSession.enterControl (leaves playback, capture mode, ACK .mimo)
  → startLiveView (Kaze burst → pktType 0x02 → LiveReassembler → LiveVideoRenderer)
  Back to Files = leaveControl (re-enters playback and re-lists).

Webcam — WebcamService: external AVCaptureDevice whose name contains osmo/pocket/dji → AVCaptureSession → WebcamPreview.

Startup — AppModel.recoverInterruptedSession undoes an interrupted session (Preferences.pending*: home and camera SSIDs).
```

Tabs (`AppModel.Workspace`): **Files** (`.files`, Wi-Fi flow: cameras → connection → library), **Live** (`.camera`, requires a connection), **Webcam** (`.webcam`, USB, from any screen except the connection screen). Turning Osmotic into a virtual camera would require a Camera Extension (Developer ID signing); the Pocket 3 is already a UVC webcam over a cable.

## File map

### `Sources/OsmoticCore` (protocol, no UI, nonisolated)

| File | What it does |
|---|---|
| `DUML/Bytes.swift` | `[UInt8]` helpers (hex, u16le/u32le, latin1, LE builders) |
| `DUML/DjiMessage.swift` | CRC8/CRC16, `DjiMessage` encode/decode, `DumlScanner` (frames in blobs, `findReply`), `DumlFrameAccumulator` (BLE notifications) |
| `DUML/OsmoCommands.swift` | BLE frames: pairing, wifi getters, session ping/wake, replies to requests, `appDeviceInfo` |
| `BLE/CameraModel.swift` | `BleAdvert` (model id from manufacturer data), `Brand`, `CameraModel` (port/poke/storage per model) |
| `BLE/PairingFlow.swift` | BLE state machine → events `.approvalRequired/.paired/.credentials/.needsPassword/.notActivated`; the saved password is read only when needed |
| `Datalink/DatalinkTransport.swift` | POSIX UDP socket (only accepts packets from the camera's IP), headers (8B transport + 12B routing), handshake, window ACK `windowModel` `.legacy`/`.mimo`, cursors (`observe`), video diversion (`onVideo`/`dropVideo`), `recvAll(ms:precise:)`, `TCPProbe` |
| `Camera/CameraSession.swift` | session: registration, playback (`0x02/0x0c` and Pocket 3 path `0x01/0x01`), list (`collect` builds the blob from `0x00/0x27` frames, 8 MB cap), pagination, keep-alive, link lost/restored; capture mode (`enterControl`/`leaveControl`, record, photo, mode, live view) |
| `Camera/CaptureMode.swift` | mode codes (`0x02/0xE1`, byte 57 of `0x02/0x80`); `deck` = the ones the UI offers |
| `Camera/ManifestDecoder.swift` | CompositePack decoder (1:1 port), reassembly of `0x00/0x27` chunks, `inferMissingExtensions` |
| `Camera/Pagination.swift` | per-store cursors, `SliceInfo`, `collectStores` (SD/internal split by request counter) |
| `Camera/StatusTracker.swift` | status pushes: battery `0x0d/02`, storage `0x02/dc`, `0x02/80` (playback, recording, seconds, mode) |
| `Camera/CameraFile.swift` | file model, `localName` (local name that is safe against untrusted names), URLs `/v2?storage=N&path=…`, `CameraStatus` (battery, storage, recording, mode) |
| `Video/LiveReassembler.swift` | pktType 0x02 fragments → Annex-B messages (continuity by seq, 8 MB cap) |
| `Video/H264AnnexB.swift` | NALs, AVCC |
| `HTTP/CameraHTTP.swift` | ephemeral URLSession without redirects, HEAD/data/range, `resolveStorage` |
| `HTTP/FileDownloader.swift` | downloads to `.part` with Range resume; completes only if it matches Content-Length/Content-Range; rejects HTML/redirects; 416 = complete; never deletes at the destination |
| `HTTP/ThumbnailFetcher.swift` | actor: `.scr` → `.thm` → EXIF, concurrency 4, disk cache (images only) |
| `Update/Update.swift` | `SemVer`, `UpdateFeed` (release JSON, Ed25519 verification), `UpdateInstaller.script` (replacement on quit) |
| `HTTP/EmbeddedJpeg.swift` | EXIF thumbnail from the first 64 KiB |

### `Sources/Osmotic` (app, MainActor by default)

| File | What it does |
|---|---|
| `App/AppModel.swift` | **orchestrator**: screens, connection stages (`connectGeneration`), `teardownTask`/`startupRecovery`/`recoverTask` (never overlapped by a new connection), library, auto-paging, download queue (`transferGeneration`, `queuedIds`), link recovery (`linkGaveUp`), tabs (`Workspace`, `setWorkspace`), control and live view, demo mode (`loadDemo`) |
| `App/OsmoticApp.swift` | scenes (main `Window`, Settings, Technical Log), Camera and Help menus, `AppDelegate` (disconnects on quit, waits for the Wi-Fi to come back, `OSMOTIC_SNAPSHOT` hook) |
| `App/Persistence.swift` | `Preferences` (UserDefaults), `SavedCameraStore`, `Keychain` (camera Wi-Fi password), `DownloadHistory`, `DownloadPaths` |
| `App/AppLog.swift` | thread-safe `log()` → file (no username in paths) + visible `LogStore`; `redactedSSID` |
| `Services/BluetoothService.swift` | CoreBluetooth (lazily created central, `@preconcurrency` delegates on the main queue) |
| `Services/WiFiService.swift` | join/restore (returns whether it got back onto a network), non-cancelable `pause`, saved networks, IPs, route, `LocationPermission`, `LocalNetworkPermission` |
| `Services/TransferNotifier.swift` | sound, Dock bounce and notification on completion; requests permission on the first download |
| `Services/LiveVideoRenderer.swift` | SPS/PPS → `CMVideoFormatDescription` → `AVSampleBufferDisplayLayer` (own queue, `nonisolated`); reports the video's aspect ratio |
| `Services/UpdateService.swift` | updates from GitHub Releases: daily check, download (GitHub hosts only), Ed25519 signature, bundle validation, replacement on quit |
| `Services/AppVisibility.swift` | whether the window is visible; pauses animations, BLE scanning and the webcam when it isn't |
| `App/Credits.swift` | credits shown in Settings › Credits |
| `Services/WebcamService.swift` | the camera over USB as a webcam (UVC): detection, permission (only with a camera present), preview |
| `Views/RootView.swift` | screen based on `screen`, `TopPlate` (top strip with the tabs in the center) |
| `Views/CamerasView.swift` | nearby and saved cameras, `Notice`, `ErrorBanner`, destination folder |
| `Views/ConnectingView.swift` | connection stages, approval, manual password |
| `Views/LibraryView.swift` | library: `WorkspaceTabs`, `LibraryTopPlate`, `ControlDeck` (status LCD, filters, transfer), grid with arrow keys |
| `Views/MediaCell.swift`, `TransferBar.swift`, `PreviewView.swift` | thumbnail (VoiceOver, queued), download bar, preview (LRF) |
| `Views/CameraControlView.swift` | Live tab: capture LCD, monitor, modes, shutter |
| `Views/WebcamView.swift` | Webcam tab: USB image or the three steps |
| `Views/SettingsView.swift`, `LogView.swift`, `SnapshotView.swift` | Settings, Technical Log, render for `snapshot.sh` |
| `Views/Theme.swift` | design system: color tokens, spacing (`s1…s6`) and radii; `Depth`/`Pocket` (shadows), `Motion`/`LCDBoot` (motion), `AluminumPlate`, `raisedPanel`, `LCDGlass`/`LCDPair`/`LCDText`/`SegmentMeter`, `CassetteKeyBank`/`CassetteKeyStyle`, `LED`, `Silk`, `BankLegend`, `SectionIndex`, `Format` |

### Resources and scripts

| File | What it is |
|---|---|
| `Resources/Info.plist`, `es.lproj/InfoPlist.strings` | bundle and permission strings (English / Spanish) |
| `Resources/Osmotic.entitlements` | hardened runtime: location (Wi-Fi name) and camera (Webcam) |
| `Resources/Localizable.xcstrings` | string catalog (English base + Spanish); `scripts/sync_strings.sh` updates it |
| `Resources/Credits.rtf`, `PrivacyInfo.xcprivacy`, `AppIcon.icns` | "About", privacy manifest (informational), icon |
| `scripts/package_app.sh`, `notarize.sh`, `snapshot.sh`, `lint.sh`, `sync_strings.sh`, `make_icon.swift` | see `CLAUDE.md` |
| `.github/workflows/ci.yml` | CI: formatting, build, tests, packaging |

### Tests (`Tests/OsmoticCoreTests`)

`ManifestTests` (golden ×14 + Pocket 3), `ProtocolTests` (frames against real captures), `PairingFlowTests` (fake clock), `SessionEndToEndTests` + `FakeCamera` (full session over loopback, incl. pagination), `ControlTests` (Kaze vectors, recording state, `LiveReassembler`, capture mode e2e against `FakeCamera`), `H264Tests`, `DownloaderTests` (+ `FakeHTTPServer`), `PathSafetyTests`, `FuzzTests`, `ThroughputProbe` (only with `OSMOTIC_PERF=1`).

## Concurrency model

- **CameraSession**: its own thread + job queue (`NSCondition`). The public `async` API (`connect`, `nextPage`, `enterControl`, `leaveControl`, `setRecording`, `takePhoto`, `setMode`, `startLiveView`, `stopLiveView`, `close`) enqueues and waits. In `.media`, `keepAliveTick` runs between jobs (~0.5 s: drain, ACK, `0x00/0x88` beat ~1 Hz, re-assert playback every ~15 s); in `.capture`/`.live`, `controlTick` (12 ms pump with ACK ≥ 40 Hz in `.live`; 50 ms and 10 Hz in `.capture` without video; 1 Hz beat; pending keyframe; live view retry). `close()` sets `isClosed` (idempotent) → loops abort; pending jobs return empty.
- **Session callbacks** (`onStatus`, `onLinkLost`…) and video arrive on the session thread → hop to `@MainActor` (or to the `LiveVideoRenderer` queue). `AppModel` ignores callbacks from replaced sessions (`session === s`).
- **FileDownloader**: URLSession delegate on a serial queue, handlers by `taskIdentifier`, `completedEarly` for the cancel/start race.
- **Connection**: each attempt has a `connectGeneration`; `live()` after every `await`; a new attempt waits for the previous one and for `teardownTask`/`startupRecovery`/`recoverTask`.
- **Exceptions to the app's MainActor**: `LiveVideoRenderer`, `FileSink` (log) and the `@concurrent`/`nonisolated` functions in `WiFiService`. Each `@unchecked Sendable` explains in a comment why it is safe.
