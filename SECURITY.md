# Seguridad

## Reportar un problema

Abrí un [issue](https://github.com/smithplus/Osmotic/issues) marcado **security**, o si preferís que no sea público, pedí un canal privado en ese mismo issue sin detalles. Se responde en lo posible dentro de una semana. Solo la última versión recibe arreglos.

## Qué hace la app con tu Mac y tus datos

- **Nada sale del Mac**: sin cuentas, sin analítica, sin servidores propios. La app habla con la cámara (Bluetooth y su red Wi-Fi `192.168.2.1`) y, una vez por día como máximo, pregunta a GitHub (`api.github.com`) por la última versión — sin mandar datos tuyos; se apaga en Ajustes › Updates.
- **Actualizaciones**: solo se instala un zip cuya firma Ed25519 coincide con la clave pública incluida en la app (`OsmoticUpdatePublicKey`); descargas solo desde GitHub por HTTPS; se verifica el bundle (identificador, versión, `codesign`) antes de reemplazar la app. La clave privada está en el Llavero de quien publica, nunca en el repo.
- **Permisos** y para qué: Bluetooth (encontrar la cámara), Red local (hablar con ella), Ubicación (macOS solo muestra el nombre de tu Wi-Fi con este permiso; se usa para volver a tu red), Descargas (guardar en `~/Downloads/DJI`), Cámara (pestaña Webcam, solo con una cámara USB enchufada), Notificaciones (aviso al terminar).
- **Cambia la red Wi-Fi** del Mac mientras está conectada (CoreWLAN y `/usr/sbin/networksetup`) y la restaura al terminar. Solo olvida la red de la cámara si la agregó ella.
- **Contraseña Wi-Fi de la cámara**: en el Llavero, solo si la escribiste a mano.
- **Sin App Sandbox**: unirse a una red Wi-Fi no es posible desde el sandbox. Se compensa con hardened runtime y validación de todo lo que llega de la cámara (nombres de archivo, tamaños, tramas).
- **Registro técnico** en `~/Library/Logs/Osmotic`: sin contraseñas; tus redes van abreviadas y las rutas sin tu usuario.

## Para quien toque el código

La cámara es un par de red **no confiable**: todo lo que manda (nombres, tamaños, tramas, HTTP) se valida. Ver `docs/STATUS.md` (revisión de seguridad) y los tests `PathSafetyTests`, `DownloaderTests`, `FuzzTests`.
