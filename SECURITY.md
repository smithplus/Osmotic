# Security

## Reporting a problem

Open an [issue](https://github.com/smithplus/Osmotic/issues) labeled **security**, or, if you'd rather keep it private, ask for a private channel in that same issue without details. We aim to respond within a week. Only the latest version receives fixes.

## What the app does with your Mac and your data

- **Nothing leaves your Mac**: no accounts, no analytics, no servers of our own. The app talks to the camera (Bluetooth and its Wi-Fi network `192.168.2.1`) and, at most once a day, asks GitHub (`api.github.com`) for the latest version, without sending any of your data; it can be turned off in Settings › Updates.
- **Updates**: only a zip whose Ed25519 signature matches the public key included in the app (`OsmoticUpdatePublicKey`) is installed; downloads come only from GitHub over HTTPS; the bundle is verified (identifier, version, `codesign`) before the app is replaced. The private key is in the publisher's Keychain, never in the repo.
- **Permissions** and what they are for: Bluetooth (find the camera), Local Network (talk to it), Location (macOS only shows your Wi-Fi name with this permission; used to return to your network), Downloads (save to `~/Downloads/DJI`), Camera (Webcam tab, only with a USB camera plugged in), Notifications (alert when finished).
- **Changes the Mac's Wi-Fi network** while connected (CoreWLAN and `/usr/sbin/networksetup`) and restores it when done. It only forgets the camera's network if the app added it.
- **Camera Wi-Fi password**: in the Keychain, only if you typed it in manually.
- **No App Sandbox**: joining a Wi-Fi network is not possible from the sandbox. This is offset by the hardened runtime and validation of everything that comes from the camera (file names, sizes, frames).
- **Technical Log** in `~/Library/Logs/Osmotic`: no passwords; your networks are abbreviated and paths omit your username.

## For people working on the code

The camera is an **untrusted** network peer: everything it sends (names, sizes, frames, HTTP) is validated. See `docs/STATUS.md` (security review) and the `PathSafetyTests`, `DownloaderTests`, `FuzzTests` tests.
