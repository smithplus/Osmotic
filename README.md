# Osmotic

Bajá los videos y fotos de tu **DJI Osmo** directo al Mac, sin cables, sin la app del teléfono y sin cuentas.

Osmotic es una app nativa para macOS basada en [**Osmosis**](https://github.com/KonradIT/osmosis), la app de Android de Konrad Iturbe, que hizo la ingeniería inversa del protocolo DUML de DJI. El protocolo y el decodificador de la lista de archivos son un port a Swift de su trabajo.

Pensado para la **Osmo Pocket 3**; el protocolo es el mismo en Pocket 4 / 4 Pro, Nano y Action 4 / 5 Pro / 6, así que esas cámaras deberían funcionar igual.

## Cómo funciona

1. El Mac encuentra la cámara por **Bluetooth** y se empareja (la primera vez aprobás en la pantalla de la cámara).
2. La cámara le pasa al Mac el nombre y la contraseña de **su propia red Wi-Fi**.
3. El Mac se conecta a esa red. Mientras dura la conexión **el Mac no tiene Internet por Wi-Fi** (con Ethernet sí).
4. Por un enlace UDP (el "datalink") la app pone la cámara en modo reproducción y lee la lista de archivos.
5. Los archivos bajan por HTTP a **`~/Descargas/DJI`**, con reanudación si la conexión se corta.
6. Al desconectar, la cámara vuelve a su modo normal y el Mac vuelve a tu red Wi-Fi.

## Uso

```bash
scripts/package_app.sh
```

```bash
open build/Osmotic.app
```

- **Descargar nuevos** baja todo lo que todavía no está en tu carpeta (⇧⌘D).
- Clic para seleccionar, ⌘-clic para sumar, doble clic para la vista previa (usa el proxy `.LRF` de la cámara, liviano).
- Los archivos quedan con la fecha de captura como fecha de creación.
- Ajustes (⌘,): carpeta de descargas, subcarpetas por fecha, RAW `.DNG` y audio `.WAV` de respaldo, volver a tu Wi-Fi y desconexión automática al terminar.

### Permisos que pide macOS

| Permiso | Para qué |
|---|---|
| Bluetooth | Encontrar la cámara y emparejarla |
| Ubicación | macOS solo le muestra el nombre de tu red Wi-Fi a apps con este permiso; se usa para volver a tu red. No se registra la ubicación. |
| Red local | Hablar con la cámara en `192.168.2.1` |

Si no das el permiso de ubicación, igual funciona: al terminar, la app se desconecta de la cámara y macOS vuelve a una red conocida.

## Si algo falla

La app guarda un registro técnico en `~/Library/Logs/Osmotic/` (menú Ventana › Registro técnico, ⌥⌘L). Ese archivo es lo que hace falta para diagnosticar una cámara que no responde.

## Desarrollo

```bash
swift test
```

- `Sources/OsmoticCore`: el protocolo sin interfaz (tramas DUML, advertising BLE, flujo de emparejamiento, datalink UDP, decodificador del manifiesto CompositePack, descargas HTTP). Es un port 1:1 del original en Kotlin.
- `Sources/Osmotic`: la app SwiftUI (CoreBluetooth, CoreWLAN, interfaz).
- `Tests/`: el decodificador se valida contra los **snapshots golden de 14 capturas reales** del proyecto original (6 de Pocket 3). Hay además una cámara simulada por UDP que reproduce el comportamiento del Pocket 3 (rechaza `0x02/0x0c` y entra en reproducción por `0x01/0x01`) y un servidor HTTP que corta y rechaza transferencias como lo hace la cámara.

Para revisar la interfaz sin cámara: `scripts/snapshot.sh salida.png [library|connecting|cameras]` renderiza una pantalla con una lista capturada.

## Créditos y licencia

MIT. El protocolo es obra de [KonradIT/osmosis](https://github.com/KonradIT/osmosis) y de los proyectos en los que se apoya (dji-remote, osmo-download, DJI-Wifi-Connect, lib-osmo-ble, dji_protocol, reverse-engineering-dji, los DJI OGs). Las capturas de prueba en `Tests/OsmoticCoreTests/Fixtures` vienen de ese repositorio. El control de la cámara y la vista en vivo (pestaña Live) siguen a [Kaze for DJI](https://github.com/brianmerchant/Kaze-for-DJI) de Brian Merchant (MIT; partes adaptadas) y las notas de [OpenPocketCine](https://github.com/erik-sutton95/OpenPocketCine) (Apache-2.0; re-implementado a partir de su documentación, sin copiar código).

Proyecto independiente, **sin afiliación con DJI**. "DJI" y "Osmo" son marcas de sus dueños.
