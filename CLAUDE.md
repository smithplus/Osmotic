# Osmotic — guía para agentes

App nativa macOS (Swift 6.2, SwiftUI, macOS 15+) que baja media de cámaras DJI Osmo (objetivo: **Pocket 3**) por BLE → Wi-Fi de la cámara → datalink UDP → HTTP. Port de [KonradIT/osmosis](https://github.com/KonradIT/osmosis) (Android/Kotlin). Repo: `github.com/smithplus/Osmotic`. UI **en inglés como base, traducida al español rioplatense** (`Resources/Localizable.xcstrings`); código y comentarios en inglés.

Leé primero, según la tarea:
- `docs/STATUS.md` — qué está hecho, qué falta, qué se verificó y qué no (sin hardware todavía).
- `docs/ARCHITECTURE.md` — mapa de archivos y modelo de hilos. Usalo en vez de recorrer el código.
- `docs/PROTOCOL.md` — resumen del protocolo tal como lo usamos; el detalle está en el `MEDIA_PROTOCOL.md` del upstream.

## Comandos

```bash
swift build                      # app + core
swift test                       # 49 tests (~50 s; los e2e de sesión tardan ~12 s c/u)
swift test --filter Golden       # solo los snapshots del decodificador
scripts/package_app.sh [debug]   # build/Osmotic.app, firmado ad-hoc
scripts/snapshot.sh out.png [library|connecting|cameras]   # render de UI sin hardware (OSMOTIC_LANG=es para español)
scripts/sync_strings.sh          # textos nuevos → Resources/Localizable.xcstrings; lista los que faltan traducir
scripts/lint.sh [--fix]          # formato con swift-format (.swift-format: 4 espacios, 130 columnas); --fix reescribe
```

- Log de cada ejecución: `~/Library/Logs/Osmotic/osmotic-*.log` (también Ventana › Registro técnico). Es la fuente de verdad para diagnosticar pruebas con la cámara real.
- Modo demo: `OSMOTIC_DEMO_MANIFEST=<fixture.bin> [OSMOTIC_DEMO_SCREEN=connecting|cameras]` al lanzar el binario.
- No hay permiso de grabación de pantalla: `screencapture` no sirve; usar `scripts/snapshot.sh` (usa `ImageRenderer`; los controles AppKit salen como recuadros amarillos y los `ScrollView` en blanco — por eso las vistas tienen `scrolls: false` para snapshot).

## Reglas del proyecto

- `OsmoticCore` es **nonisolated** y sin UI; `Osmotic` (app) usa `defaultIsolation(MainActor)`.
- El decodificador (`ManifestDecoder`) debe seguir **byte a byte** con los golden del upstream (`Tests/OsmoticCoreTests/Fixtures/golden`). Cualquier mejora va en un paso posterior (ej. `inferMissingExtensions`), nunca cambiando el decode.
- `CameraSession`: **un solo hilo** es dueño del socket; todo paso de protocolo es un job en su cola. Nunca mandar tramas desde otro hilo (rompe la secuencia y la cámara descarta escrituras).
- Restaurar el Wi-Fi tiene que terminar aunque la tarea que lo pidió esté cancelada: usar `WiFiService.pause` (no cancelable) y `AppModel.cleanup` (tarea propia).
- Créditos al upstream Osmosis se mantienen en README, LICENSE y comentarios. No usar "DJI"/"Osmo" como nombre de producto.
- Tests nuevos con Swift Testing (`@Test`, `#expect`). Simuladores disponibles: `FakeCamera` (datalink UDP del Pocket 3) y `FakeHTTPServer` (cortes, 404/500, Range ignorado).

## UI

- Estética de equipo de audio oscuro (grafito, lecturas ámbar `ETIQUETA: valor`, LEDs). Pocos elementos por panel: sin íconos decorativos.
- Sombras solo con los tokens de `Depth` (Theme.swift): `raisedShadow()` para lo elevado, `Pocket`/`recessed()` para lo hundido (`deep` en pantallas y ranuras), `Depth.glow` para lo encendido, `Depth.onImage` sobre fotos. Nada de `.shadow(color:radius:)` sueltos ni sombras de radio 0.
- Movimiento solo con los tokens de `Motion` (Theme.swift) vía `.motion(_:value:)` (respeta Reducir movimiento): tecla abajo `press`, arriba `release` (resorte), paneles `panel` con `.panelFromTop`/`.trayFromBottom`, luces `bloom`, cambios de estado `quick`. Las pantallas LCD no hacen fundidos: valores instantáneos, medidores por segmentos, encendido con `LCDBoot`. Nada de `scaleEffect` al pasar el mouse.
- Un solo tipo de botón: `CassetteKeyStyle` dentro de `CassetteKeyBank`. Naranja (`.primaryKey`) solo para la acción principal de la pantalla; el resto `.secondaryKey`/`.compactKey`. Misma acción → mismo nombre en toda la app ("Show in Finder", "Disconnect", "Download …").

## Textos e idiomas

- Escribí los textos en inglés. `Text("…")`, `Button("…")`, `Silk("…")`, `LCDCaption("…")`, `Notice(text:)`, `LED(label:)` ya se traducen solos (`LocalizedStringKey`). Para `String` (mensajes del modelo, texto del LCD) usá `String(localized: "…")`. Para un `String` que ya es dato (nombre de archivo, fecha), `Silk(verbatim:)`.
- Después: `scripts/sync_strings.sh` y cargá el español en el catálogo (Xcode o JSON). Plurales: variaciones `plural` del catálogo (ver `"%lld files"`).
- `package_app.sh` compila el catálogo a `*.lproj` y copia `Resources/es.lproj/InfoPlist.strings` (textos de permisos). `swift run` sin bundle muestra inglés.

## Trampas conocidas

- `Settings` choca con la escena de SwiftUI → las preferencias son `Preferences`.
- `sed` de macOS no soporta `\b` ni `\|`: usar `perl -pi -e` o python para reemplazos.
- `git mv` no funciona sobre archivos sin commitear.
- `String(format: "%d")` trunca a 32 bits: usar `%ld` con `Int`.
