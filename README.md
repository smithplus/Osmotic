# Osmotic

Bajá los videos y fotos de tu **DJI Osmo** directo al Mac, sin cables, sin la app del teléfono y sin cuentas. Además podés controlar la cámara y verla en vivo por Wi-Fi, o usarla como webcam por USB.

Osmotic es una app nativa para macOS basada en [**Osmosis**](https://github.com/KonradIT/osmosis), la app de Android de Konrad Iturbe, que hizo la ingeniería inversa del protocolo DUML de DJI. El protocolo y el decodificador de la lista de archivos son un port a Swift de su trabajo.

Pensado para la **Osmo Pocket 3**; el protocolo es el mismo en Pocket 4 / 4 Pro, Nano y Action 4 / 5 Pro / 6, así que esas cámaras deberían funcionar igual. La interfaz está en inglés y en español, según el idioma del Mac.

## Pestañas

- **Files**: la tarjeta de la cámara, por Wi-Fi (ver "Cómo funciona").
- **Live** (experimental, sin probar todavía con hardware): grabar/detener, foto, modo (Video, Photo, Slow-mo, Low light) y vista en vivo, con la cámara conectada.
- **Webcam**: la cámara enchufada por USB-C en modo webcam; se puede elegir en Zoom, Meet, FaceTime u OBS aunque Osmotic esté cerrada.

## Cómo funciona (Files)

1. El Mac encuentra la cámara por **Bluetooth** y se empareja (la primera vez aprobás en la pantalla de la cámara).
2. La cámara le pasa al Mac el nombre y la contraseña de **su propia red Wi-Fi**.
3. El Mac se conecta a esa red. Mientras dura la conexión **el Mac no tiene Internet por Wi-Fi** (con Ethernet o el iPhone por cable, sí).
4. Por un enlace UDP (el "datalink") la app pone la cámara en modo reproducción y lee la lista de archivos.
5. Los archivos bajan por HTTP a **`~/Downloads/DJI`** (Finder la muestra como Descargas; se cambia en Ajustes), con reanudación si la conexión se corta.
6. Al desconectar, la cámara vuelve a su modo normal y el Mac vuelve a tu red Wi-Fi.

## Uso

Requisitos: macOS 15 o posterior (Apple silicon o Intel). Para compilar: Xcode 26 (Swift 6.2 o más; `package_app.sh` usa `xcstringstool` de Xcode).

```bash
scripts/package_app.sh
```

```bash
open build/Osmotic.app
```

- **Download New** (Descargar nuevos, ⇧⌘D) baja todo lo que todavía no está en tu carpeta; **Download Selection** (⌘D) baja lo seleccionado.
- Clic selecciona, ⌘-clic suma o quita, ⇧-clic selecciona un rango; la casilla de cada miniatura suma o quita sin teclas. Flechas para moverse por la grilla (⇧ extiende), espacio o doble clic para la vista previa (usa el proxy `.LRF`, liviano), ← → dentro de la vista previa.
- Los archivos quedan con la fecha de captura como fecha de creación.
- Ajustes (⌘,): carpeta de descargas, subcarpetas por fecha, RAW `.DNG` y audio `.WAV` de respaldo, sonido y aviso al terminar, volver a tu Wi-Fi, desconexión automática al terminar, olvidar las cámaras guardadas y abrir la carpeta del registro.

### Permisos que pide macOS

| Permiso | Para qué |
|---|---|
| Bluetooth | Encontrar la cámara y emparejarla |
| Ubicación | macOS solo le muestra el nombre de tu red Wi-Fi a apps con este permiso; se usa para volver a tu red. No se registra la ubicación. |
| Red local | Hablar con la cámara en `192.168.2.1` |
| Descargas | Guardar en `~/Downloads/DJI` |
| Cámara | Mostrar la imagen en la pestaña Webcam (se pide solo cuando hay una cámara por USB) |
| Notificaciones | Avisar cuando termina una descarga (se pide en la primera descarga) |

Si no das el permiso de ubicación, igual funciona: al terminar, la app se desconecta de la cámara y macOS vuelve a una red conocida. Nada sale del Mac: ver [`SECURITY.md`](SECURITY.md).

La build de este repo está firmada ad-hoc: macOS vuelve a pedir los permisos en cada build nueva, y al abrirla por primera vez hay que ir a Ajustes del Sistema › Privacidad y seguridad › "Abrir igualmente". Una build firmada con Developer ID y notarizada (`scripts/notarize.sh`) no tiene ninguno de los dos problemas.

## Si algo falla

La app guarda un registro técnico en `~/Library/Logs/Osmotic/` (menú Window › Technical Log — Ventana › Registro técnico —, ⌥⌘L, o Ajustes › Maintenance › Open Folder). Ese archivo es lo que hace falta para diagnosticar una cámara que no responde. Problemas y sugerencias: [issues](https://github.com/smithplus/Osmotic/issues).

## Desarrollo

```bash
swift build
```

```bash
swift test
```

```bash
scripts/lint.sh --fix
```

- `Sources/OsmoticCore`: el protocolo sin interfaz (tramas DUML, advertising BLE, flujo de emparejamiento, datalink UDP, decodificador del manifiesto CompositePack, descargas HTTP, control de captura y vista en vivo). El listado y las descargas son un port 1:1 del original en Kotlin; el control y la vista en vivo siguen a Kaze for DJI.
- `Sources/Osmotic`: la app SwiftUI (CoreBluetooth, CoreWLAN, AVFoundation, interfaz).
- `Tests/`: el decodificador se valida contra los **snapshots golden de 14 capturas reales** del proyecto original (6 de Pocket 3). Una cámara simulada por UDP reproduce el Pocket 3 (reproducción por `0x01/0x01`, lista, modo captura y el stream H.264 de la vista en vivo) y un servidor HTTP corta y rechaza transferencias como la cámara. Tests con datos aleatorios cubren todo lo que llega de la red.

Guía para colaboradores y agentes de IA: [`CLAUDE.md`](CLAUDE.md) (también `AGENTS.md`) y `docs/`. Para revisar la interfaz sin cámara, después de `scripts/package_app.sh`: `scripts/snapshot.sh salida.png [library|connecting|cameras|camera|webcam]`.

## Créditos y licencia

MIT. El protocolo es obra de [KonradIT/osmosis](https://github.com/KonradIT/osmosis) y de los proyectos en los que se apoya (dji-remote, osmo-download, DJI-Wifi-Connect, lib-osmo-ble, dji_protocol, reverse-engineering-dji, los DJI OGs). Las capturas de prueba en `Tests/OsmoticCoreTests/Fixtures` vienen de ese repositorio. El control de la cámara y la vista en vivo (pestaña Live) siguen a [Kaze for DJI](https://github.com/brianmerchant/Kaze-for-DJI) de Brian Merchant (MIT; partes adaptadas) y las notas de [OpenPocketCine](https://github.com/erik-sutton95/OpenPocketCine) (Apache-2.0; re-implementado a partir de su documentación, sin copiar código).

Proyecto independiente, **sin afiliación con DJI**. "DJI" y "Osmo" son marcas de sus dueños.
