# Osmotic guide

Everything the app does, in the order you meet it. Short version: turn the camera on, click Connect, click Download New.

- [Install](#install)
- [Connect](#connect)
- [Files: download from the card](#files-download-from-the-card)
- [From the card, over USB](#from-the-card-over-usb)
- [Live: control the camera](#live-control-the-camera)
- [Webcam](#webcam)
- [Settings](#settings)
- [Keyboard](#keyboard)
- [Updates](#updates)
- [When something goes wrong](#when-something-goes-wrong)

## Install

1. Download the `.dmg` from the [latest release](https://github.com/smithplus/Osmotic/releases/latest), open it and drag **Osmotic** onto **Applications**.
2. Open it from Applications. The first time, macOS says it can't verify the app, because this build isn't notarized by Apple yet. Go to **System Settings › Privacy & Security**, scroll to the notice about Osmotic and click **Open Anyway**. Once.
3. A new camera has to be activated once in DJI's own app, as DJI requires. After that Osmotic doesn't need your phone.

Requirements: macOS 15 or later, Apple silicon or Intel, Bluetooth and Wi-Fi.

## Connect

Turn the camera on and click **Connect** next to it. Five lights track the steps:

| Light | What is happening |
|---|---|
| Bluetooth | The Mac finds the camera and pairs with it. The first time, approve the request on the camera's screen. |
| Pair | The camera accepts the Mac. |
| Wi-Fi | The camera hands over the name and password of its own network and the Mac joins it. |
| Link | The app opens its link to the camera and puts it in playback mode. |
| Library | The card's files arrive. |

While connected, your Mac is on the camera's Wi-Fi, so it has **no Internet over Wi-Fi**. Ethernet, or an iPhone sharing its connection over a cable, keeps you online. **Disconnect** hands the camera back and returns the Mac to your network. Quitting the app does the same thing first.

Cameras you have used before appear under "Connected before", so a second trip is one click. "Forget cameras" in Settings clears that list.

## Files: download from the card

- **Download New** (⇧⌘D) takes everything that isn't on your Mac yet. **Download Selection** (⌘D) takes what you picked. Each day also has its own **Download Day** key.
- Click a thumbnail to select it, ⌘-click to add or remove, ⇧-click for a range, or use the checkbox on each thumbnail. The arrow keys move through the grid and ⇧ extends the selection.
- The filters show **All**, **Videos**, **Photos**, **Starred** or **New**. "New" means not on your Mac yet.
- Space bar (or a double click) opens a preview. It streams the camera's small `.LRF` proxy, not the full 4K file, so it opens fast. ← and → move to the next file.
- Files land in `~/Downloads/DJI`, one folder per day, and each file gets the moment it was shot as its creation date, so Finder and your editor sort it correctly.
- A clip already on your Mac is skipped, never overwritten. An interrupted download resumes from where it stopped, even past 4 GB. If the link drops, the app waits for the camera and carries on.
- The transfer bar shows the file, the speed and the time left. **Cancel** stops after the current file and keeps what arrived.

## From the card, over USB

Plug the camera into the Mac with USB-C and choose **USB storage** (or **Data**) on the camera. Its card mounts as a disk, and Osmotic lists it on the cameras screen under **Plugged in**, with how fast the cable negotiated.

- **Open** shows the card's files in the same grid, with the same keys: Download New, Download Selection, Download Day, the filters and the day headers. Files already on your Mac are skipped.
- Nothing wireless happens: no Bluetooth, no pairing, and your Mac keeps its own Wi-Fi and its Internet.
- Sizes come from the card, so the bar and the time left are right from the first second, whatever the clip's length.
- **Eject** unmounts the card so the cable can come out. Pulling the cable mid-copy is safe too: what already arrived is saved, and the file being copied is discarded rather than left half written.
- The card's row shows what it **measured**, not just what the bus promises: Osmotic reads a stretch of the biggest clip and reports the rate and roughly how long the whole card would take. A slow cable is worth swapping before the copy, not after.
- About speed: the readout shows **USB 2.0** or **USB 3**. A cable that only carries USB 2 (most charging cables) tops out around 40 MB/s, which is roughly what Wi-Fi gives you. A USB 3 cable, straight into the Mac rather than through a hub, is the one worth using for a full card.

## Live: control the camera

The **Live** tab takes the camera out of playback and into capture, so Files and Live are never busy at the same time (downloads have to finish first).

- **Record** starts and stops; the elapsed time comes from the camera.
- **Photo** takes a picture in Photo mode.
- **Mode** switches Video, Photo, Slow-mo and Low Light.
- The picture is the camera's live preview over Wi-Fi, at preview quality. For full quality use the Webcam tab (over the cable).

Going back to **Files** returns the camera to playback and relists the card, so what you just shot is there.

## Webcam

Plug the camera into the Mac with USB-C and choose **Webcam** on the camera. The picture shows up in the Webcam tab, and the camera is a standard USB webcam for Zoom, Meet, FaceTime or OBS even with Osmotic closed. Over the cable the picture is full quality and the camera charges.

This tab isn't tested on hardware yet.

## Settings

⌘, opens Settings.

- **General**: the download folder, subfolders by date, the RAW `.DNG` and backup `.WAV` sidecars, the sound and notification when a download finishes, going back to your Wi-Fi on disconnect, and disconnecting automatically when downloads finish.
- **Updates**: check at startup (once a day), or check now.
- **Credits**: the people whose work the app is built on.
- **Maintenance**: forget saved cameras, open the log folder.

## Keyboard

| Keys | Action |
|---|---|
| ⌘D | Download Selection |
| ⇧⌘D | Download New |
| Space | Preview the selection |
| ← → | Previous or next file in the preview |
| Arrows, ⇧ arrows | Move or extend the selection in the grid |
| ⇧⌘O | Open the downloads folder |
| ⌥⌘L | Technical log |
| ⌘, | Settings |

## Updates

Osmotic checks GitHub Releases once a day, and from **Osmotic › Check for Updates…** whenever you ask. A new version installs only if its signature matches the key inside the app; then Osmotic quits, swaps itself and reopens. Because this build is signed ad-hoc, macOS asks for its permissions again after an update.

## When something goes wrong

The technical log is the thing that makes a camera problem solvable: **Window › Technical Log** (⌥⌘L), or Settings › Maintenance › Open Folder. It records the whole session and leaves out your Wi-Fi password and network name.

| Symptom | What to try |
|---|---|
| The camera never appears | Turn Bluetooth on, keep the camera within a few metres, and check Osmotic has Bluetooth permission in System Settings › Privacy & Security. |
| It pairs, then stops at Wi-Fi | Approve the pairing on the camera's screen, and give the app Location permission: macOS only tells apps the name of a Wi-Fi network if they have it. |
| Downloads are slow | Keep the camera close, and avoid crowded 2.4 GHz channels. About 33 MB/s is what a Pocket 3 gives on a good link. |
| The Mac stayed on the camera's network | Pick your network from the menu bar. The app also retries on its own and says so in the log. |
| A download failed | Run it again: it resumes. If it keeps failing, the log line starting with `transfer:` says why. |
| macOS won't open the app | System Settings › Privacy & Security › Open Anyway (see [Install](#install)). |

Anything else: [open an issue](https://github.com/smithplus/Osmotic/issues) with the log attached. The forms ask for the camera, the Mac and the version.
