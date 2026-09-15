# Changelog

Formato [Keep a Changelog](https://keepachangelog.com/es-ES/1.1.0/); versiones [SemVer](https://semver.org/lang/es/). El número de build del `.app` es la cantidad de commits.

## [Unreleased] — rama `ui/te-style`

### Agregado
- Pestañas **Files · Live · Webcam**. Live: grabar/detener, foto, modos (Video, Foto, Cámara lenta, Poca luz) y vista en vivo por Wi-Fi (sin probar con hardware). Webcam: la cámara enchufada por USB en modo webcam.
- Interfaz en inglés con traducción al español; tema oscuro de equipo de audio (teclas de cassette, pantallas LCD, LEDs).
- Navegación de la grilla con flechas; VoiceOver en celdas, filtros, LEDs y etapas; Reducir movimiento.
- Binario universal (Apple silicon + Intel); licencias y créditos dentro de la app; scripts de firma Developer ID y notarización.

### Corregido
- **Seguridad**: un archivo de la cámara llamado `..` podía borrar la carpeta que contiene a la de descargas; un SSID falso podía borrar una red guardada del Mac; la contraseña Wi-Fi de la cámara quedaba en texto plano.
- "Try Again" no hacía nada; conexiones y restauraciones de Wi-Fi podían pisarse; descargas podían darse por completas con bytes de menos o una página HTML.
- La lista de la tarjeta podía llegar corta (un paquete de estado se "tragaba" fragmentos).
- Permiso de ubicación bajo hardened runtime (sin él no se leía el nombre de tu Wi-Fi).

## [0.1.0] — 2026-09-14

Primera versión: descarga desde una Osmo Pocket 3 por BLE + Wi-Fi, verificada con hardware real.
