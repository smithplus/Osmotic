# Osmotic — guía para agentes (y personas)

Punto de entrada único: leé esto primero; te dice dónde está cada cosa y cómo hacer los cambios típicos sin recorrer el código. `AGENTS.md` es un enlace a este archivo.

## Qué es

App nativa macOS (Swift 6.2, SwiftUI, macOS 15+) para cámaras DJI Osmo (objetivo: **Pocket 3**), con tres pestañas:
- **Files**: baja la media por BLE → Wi-Fi de la cámara → datalink UDP → HTTP a `~/Downloads/DJI`.
- **Live**: control de captura (grabar, foto, modo) y vista en vivo por el mismo datalink. **Experimental**.
- **Webcam**: la cámara enchufada por USB-C como webcam UVC (la ven Zoom, Meet, OBS).

Port de [KonradIT/osmosis](https://github.com/KonradIT/osmosis) (Android/Kotlin); control y vista en vivo según [Kaze for DJI](https://github.com/brianmerchant/Kaze-for-DJI) (MIT). Repo `github.com/smithplus/Osmotic`; el trabajo actual está en la rama **`ui/te-style`** (no en `main`).

Idiomas: UI **en inglés como base, traducida al español rioplatense**; código, comentarios y commits en inglés; docs en español.

## Estado en una línea

Una sola prueba con la Pocket 3 real (build `776be7d`, Files OK). **Todo lo posterior está sin probar con hardware**, incluidos cambios en el camino de Files → en la próxima prueba: Files primero, después Live, después Webcam. Detalle: `docs/STATUS.md`.

## Dónde leer

| Para… | Leé |
|---|---|
| qué está hecho / probado / pendiente | `docs/STATUS.md` |
| mapa de archivos, flujos, hilos | `docs/ARCHITECTURE.md` (usalo en vez de recorrer el código) |
| protocolo (BLE, datalink, lista, HTTP) | `docs/PROTOCOL.md`; detalle en el `MEDIA_PROTOCOL.md` del upstream |
| pestaña Live (control, vista en vivo) | `docs/CONTROL.md`; especificación con fuentes: `docs/CONTROL_SPEC.md` (§7 = sin verificar) |
| seguridad y privacidad | `SECURITY.md` |
| historial para el usuario | `CHANGELOG.md` |
| créditos (se muestran en Ajustes › Credits) | `Sources/Osmotic/App/Credits.swift` |

## Comandos

```bash
swift build                      # app + core
swift test                       # 83 tests en 20 suites (~50 s; los e2e de sesión y de control tardan 10–16 s c/u)
swift test --filter Golden       # solo los snapshots del decodificador
scripts/lint.sh [--fix]          # formato con swift-format (.swift-format: 4 espacios, 130 columnas); CI lo exige
scripts/sync_strings.sh          # textos nuevos → Resources/Localizable.xcstrings; lista los que faltan traducir
scripts/package_app.sh [debug]   # build/Osmotic.app (release = universal arm64+x86_64); ad-hoc salvo SIGN_IDENTITY
scripts/notarize.sh              # release firmada + DMG + notarización (necesita cuenta Apple Developer; ver el script)
scripts/snapshot.sh out.png [library|connecting|cameras|camera|webcam] [manifest.bin]   # render sin hardware; necesita build/Osmotic.app
scripts/release.sh X.Y.Z [--publish]   # DMG + zip firmado para el actualizador (ver "Release")
```

- CI: `.github/workflows/ci.yml` (macos-26): formato, build, tests, empaquetado en cada push a `main`/`ui/**`.
- Log de cada ejecución: `~/Library/Logs/Osmotic/osmotic-*.log` (Window › Technical Log, ⌥⌘L). Es la fuente de verdad para diagnosticar pruebas con la cámara real; las líneas clave están en `docs/STATUS.md` y `docs/CONTROL.md`.
- Modo demo: `OSMOTIC_DEMO_MANIFEST=<fixture.bin> [OSMOTIC_DEMO_SCREEN=connecting|cameras|camera|webcam] [OSMOTIC_DEMO_THUMBS=<carpeta con .jpg>] [OSMOTIC_LANG=es]`. Sin pantalla: biblioteca con una descarga a medias; `camera` = pestaña Live grabando.
- No hay permiso de grabación de pantalla: `screencapture` no sirve; `scripts/snapshot.sh` usa `ImageRenderer` (los controles AppKit y la vista en vivo no se dibujan; los `ScrollView` salen en blanco — por eso las vistas tienen `scrolls: false`).
- Permisos: lanzar desde Terminal oculta problemas de Red local (no aplica a procesos de Terminal); probarlos abriendo la app con `open build/Osmotic.app` o desde Finder.

## Recetas

**Texto de UI nuevo.** Escribilo en inglés. `Text("…")`, `Button("…")`, `.help("…")`, `Silk("…")`, `LCDPair(label:)`, `BankLegend`, `SectionIndex(title:)`, `Notice(text:)`, `LED(label:)` se traducen solos (`LocalizedStringKey`). Para un `String` (mensajes del modelo, `LCDText(text:)`): `String(localized: "…")`. Para un dato (nombre de archivo, fecha): `Silk(verbatim:)`, `Notice(verbatim:)`, `Text(verbatim:)`. Después `scripts/sync_strings.sh` y cargá el español en `Resources/Localizable.xcstrings` (plurales: variaciones `plural`, ver `"%lld files"`).

**Permiso nuevo del sistema.** Clave de uso en `Resources/Info.plist` (inglés) + la misma en `Resources/es.lproj/InfoPlist.strings` + entitlement en `Resources/Osmotic.entitlements` si es un recurso protegido por el hardened runtime (ubicación, cámara, micrófono…) + fila en la tabla de permisos del README y en `SECURITY.md`.

**Comando nuevo a la cámara.** Siempre como job del hilo de `CameraSession` (nunca desde otro hilo). En modo captura: `drainStale()` → `send(set, cmd, payload, rType:, rId:)` → `awaitReply(set:cmd:timeout:)` y, si hay que confirmar estado, `pumpUntil { tracker.status… }`. Nuevo campo de estado: `StatusTracker.apply` + `CameraStatus` + `displaySignature`. Test contra `FakeCamera` (agregale el comportamiento en `command(_:)`).

**Pantalla o pestaña nueva.** `AppModel.Workspace` + `setWorkspace` + `WorkspaceTabs`; vista con `TopPlate` y piezas de `Theme`; caso en `SnapshotView`/`loadDemo` para poder revisarla con `snapshot.sh`.

**Release (y actualización automática).** Sección `## [X.Y.Z]` en `CHANGELOG.md`, commit, `scripts/release.sh X.Y.Z` (dry run: tag local, app universal, `build/Osmotic-X.Y.Z.dmg` para instalar a mano — con `scripts/dmg_readme.txt` como "Read Me First" — y `build/Osmotic-X.Y.Z.zip` + `.sig` firmado con la clave del Llavero para el actualizador) y, **solo con permiso explícito del usuario**, `scripts/release.sh X.Y.Z --publish` (empuja el tag y crea la release con `gh`). La app instalada la encuentra con `UpdateService` (`api.github.com/.../releases/latest`) y la instala si la firma coincide con `OsmoticUpdatePublicKey` (Info.plist). La clave privada: `swift scripts/update_key.swift` (Llavero, servicio `io.github.smithplus.osmotic.update-signing`); si se pierde, generar otra y cambiar la pública — los usuarios instalan esa versión a mano una vez. Para Developer ID + notarización: `SIGN_IDENTITY=… NOTARY_PROFILE=… scripts/notarize.sh`.

## Reglas del proyecto

- `OsmoticCore` es **nonisolated** y sin UI; `Osmotic` (app) usa `defaultIsolation(MainActor)`. Excepción: `LiveVideoRenderer` es `nonisolated` (recibe H.264 del hilo de la sesión, decodifica en su cola). Todo `@unchecked Sendable` lleva un comentario que justifica por qué es seguro.
- El decodificador (`ManifestDecoder`) debe seguir **byte a byte** con los golden del upstream (`Tests/OsmoticCoreTests/Fixtures/golden`). Mejoras en un paso posterior (ej. `inferMissingExtensions`) o en lo que se le pasa (`CameraSession.collect` arma el blob solo con tramas `0x00/0x27`), nunca cambiando el decode.
- `CameraSession`: **un solo hilo** es dueño del socket; todo paso de protocolo es un job en su cola. Modos `.media` (playback, lista, descargas — el camino probado, ACK `.legacy`) y `.capture`/`.live` (ACK `.mimo`). No cambiar el comportamiento de `.media` sin volver a probarlo con hardware.
- La cámara es un par **no confiable**: validar todo lo que manda (nombres → `CameraFile.localName`, tamaños, tramas, HTTP). Tests de robustez en `FuzzTests`, `PathSafetyTests`, `DownloaderTests`.
- Restaurar el Wi-Fi tiene que terminar aunque la tarea que lo pidió esté cancelada: `WiFiService.pause` (no cancelable) y `AppModel.cleanup` (tarea propia, guardada en `teardownTask`; una conexión nueva la espera).
- Créditos: Osmosis (MIT) en README, LICENSE y comentarios; Kaze for DJI (MIT, partes adaptadas; LICENSE lo nombra); OpenPocketCine (Apache-2.0, solo re-implementado desde su documentación: si alguna vez se copia código, agregar su NOTICE). No usar "DJI"/"Osmo" como nombre de producto.
- Tests nuevos con Swift Testing (`@Test`, `#expect`). Simuladores: `FakeCamera` (datalink del Pocket 3: playback, lista, modo captura con respuestas por pktType 0x03, stream H.264 fragmentado) y `FakeHTTPServer` (en `DownloaderTests.swift`: cortes, 404/500, Range ignorado, HTML, redirecciones, 416). `ThroughputProbe` corre solo con `OSMOTIC_PERF=1`.

## UI (sistema de diseño)

- Estética de equipo de audio oscuro (grafito, lecturas ámbar `ETIQUETA: valor`, LEDs). Pocos elementos por panel: sin íconos decorativos. Modo oscuro forzado en cada escena; no hay tema claro. Colores, espaciado (`Theme.s1…s6`) y radios (`radiusS/M/L`) salen de `Theme`.
- Un solo tipo de botón: `CassetteKeyStyle` dentro de `CassetteKeyBank`. Naranja (`.primaryKey`) solo para la acción principal de la pantalla; el resto `.secondaryKey`/`.compactKey`. Grupos exclusivos (pestañas, filtros, modos): `CassetteKeyStyle(latched: seleccionado, width:)`. Excepciones: casilla y play sobre las fotos (`.plain` + `Depth.onImage`); Ajustes, diálogos y el Registro usan controles del sistema. Misma acción → mismo nombre en toda la app ("Show in Finder", "Disconnect", "Download …").
- Sombras solo con los tokens de `Depth`: `raisedShadow()` para lo elevado, `Pocket`/`recessed()` para lo hundido (`deep` en pantallas y ranuras), `Depth.glow` para lo encendido, `Depth.onImage` sobre fotos. Nada de `.shadow(color:radius:)` sueltos; el único token de radio 0 es `Depth.lipLight` (tornillos).
- Movimiento solo con `Motion` vía `.motion(_:value:)` (respeta Reducir movimiento): tecla abajo `press`, arriba `release`, paneles `panel` con `.panelFromTop`/`.trayFromBottom`, luces `bloom`, estado `quick`. Las pantallas LCD no hacen fundidos (`LCDGlass` ya aplica `LCDBoot` y `.transaction { $0.animation = nil }`). Nada de `scaleEffect` al pasar el mouse.
- Accesibilidad: todo control con etiqueta y estado para VoiceOver (`.isSelected` en grupos, valor en LEDs); contraste ≥ 4.5:1 (`Theme.muted` ya lo cumple).
- Referencias visuales que el usuario aprobó: EP-133 de Teenage Engineering y el VST "BASSBOI" (Dribbble). Revisar con `snapshot.sh` antes de mostrar.
- Capturas del README (`docs/images/{en,es}/`): `snapshot.sh` con `OSMOTIC_LANG=en|es OSMOTIC_LOCALE=en_US|es_AR`, fixture `op3_15.bin` y `OSMOTIC_DEMO_THUMBS` con escenas sintéticas (nunca el material del usuario ni sus cámaras guardadas: el modo demo no las lee), recortadas y enmarcadas (esquinas, sombra) a 1280–1400 px. Si cambia la UI, regenerarlas en los dos idiomas.

## Estado guardado (dónde vive)

- Bundle id `io.github.smithplus.osmotic`. Preferencias en UserDefaults (`Preferences`; `pending*` = recuperación de una sesión cortada).
- Historial de descargas: `~/Library/Application Support/Osmotic/downloaded.json`. Miniaturas: `~/Library/Caches/io.github.smithplus.osmotic/thumbs`.
- Contraseña Wi-Fi de la cámara (solo si se escribió a mano): Llavero, servicio `io.github.smithplus.osmotic.camera-wifi`.

## Trampas conocidas

- `Settings` choca con la escena de SwiftUI → las preferencias son `Preferences`.
- `sed` de macOS no soporta `\b` ni `\|`: usar `perl -pi -e` o python para reemplazos. El bash de macOS es 3.2: arrays vacíos con `set -u` → `${a[@]+"${a[@]}"}`.
- `git mv` no funciona sobre archivos sin commitear.
- `String(format: "%d")` trunca a 32 bits: usar `%ld` con `Int`.
- Hardened runtime: sin el entitlement de ubicación el SSID queda oculto y no se vuelve a la red de casa.
- La firma ad-hoc hace que macOS vuelva a pedir los permisos (y el Llavero) en cada build.
- `recvAll(ms:)` corto sin `precise:` sirve de pausa entre envíos en el flujo de lista (afinado con hardware); `precise: true` solo en la bomba de captura.
