# Changelog

Formato [Keep a Changelog](https://keepachangelog.com/es-ES/1.1.0/); versiones [SemVer](https://semver.org/lang/es/). El número de build del `.app` es la cantidad de commits.

## [Unreleased]

## [0.2.0] — 2026-09-15

Probada con una Osmo Pocket 3: conexión, lista, descargas, vista en vivo, grabar/detener y cambio de modo.

### Agregado
- Pestañas **Files · Live · Webcam**. Live: grabar/detener, foto, modos (Video, Foto, Cámara lenta, Poca luz) y vista en vivo por Wi-Fi. Webcam: la cámara enchufada por USB en modo webcam.
- Instalador `.dmg` (arrastrar a Aplicaciones) en cada release, con una nota para el primer arranque de una build sin notarizar.
- README nuevo en inglés y español, con capturas.
- Interfaz en inglés con traducción al español; tema oscuro de equipo de audio (teclas de cassette, pantallas LCD, LEDs).
- Navegación de la grilla con flechas; VoiceOver en celdas, filtros, LEDs y etapas; Reducir movimiento.
- Binario universal (Apple silicon + Intel); licencias y créditos dentro de la app; scripts de firma Developer ID y notarización.

### Actualizaciones y créditos
- Actualización automática desde GitHub Releases (Ajustes › Updates, menú Check for Updates…): descarga, verifica la firma Ed25519 y el bundle, reemplaza la app y la reabre. `scripts/release.sh` arma y firma la release; publica solo con `--publish`.
- Ajustes › Credits: quienes hicieron posible la app (Osmosis, Kaze for DJI, OpenPocketCine, la investigación del protocolo y los testers de Osmosis).

### Rendimiento
- En reposo la app ya casi no consume: los LEDs parpadean en dos pasos (no animación continua) y todo lo animado, el escaneo Bluetooth y la webcam se pausan con la ventana oculta (pantalla de cámaras: 13 % → ~0 % de CPU).
- Miniaturas reducidas a 560 px al recibirlas (~40 KB en vez de ~460 KB) y en una caché con límite; ordenar y agrupar una tarjeta grande ya no congela la ventana; el progreso de descarga no redibuja toda la grilla.
- Descargas largas con la ventana atrás: sin App Nap mientras hay conexión y sin reposo mientras se descarga.

### Corregido
- Clips de más de 4 GB: la lista de la cámara da el tamaño en 32 bits, así que la barra llegaba a 100 % con 00:00 restante mientras seguía bajando. Ahora se usa el tamaño real (se le pregunta a la cámara) en la barra, el tiempo restante y la grilla.
- El registro técnico podía incluir el nombre de tu red Wi-Fi dentro de un error de `networksetup`.
- En español, el tamaño de cada clip se cortaba ("69,8…") por el formato de hora "p. m.": ahora se acorta primero la resolución.
- **Seguridad**: un archivo de la cámara llamado `..` podía borrar la carpeta que contiene a la de descargas; un SSID falso podía borrar una red guardada del Mac; la contraseña Wi-Fi de la cámara quedaba en texto plano.
- "Try Again" no hacía nada; conexiones y restauraciones de Wi-Fi podían pisarse; descargas podían darse por completas con bytes de menos o una página HTML.
- La lista de la tarjeta podía llegar corta (un paquete de estado se "tragaba" fragmentos).
- Permiso de ubicación bajo hardened runtime (sin él no se leía el nombre de tu Wi-Fi).

## [0.1.0] — 2026-09-14

Primera versión: descarga desde una Osmo Pocket 3 por BLE + Wi-Fi, verificada con hardware real.
