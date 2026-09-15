# Launch kit (Product Hunt)

Research done 2026-09-15 from public pages (sources at the end). Prices and stats are as those pages stated them that day; anything unverified says so. A Product Hunt draft was filled in on 2026-09-15 with the copy below (tagline 1, the description, the maker's comment in its 864-character version, topics Mac, Open Source, Photography, pricing Free); it is launched or scheduled only by the owner.

## Positioning

**The gap:** DJI's own export guide says wireless transfer from an Osmo goes **to a phone only** (DJI Mimo); to a computer it's a cable or a card reader. GoPro removed Quik for desktop from the Mac App Store (see the GoPro and TechRadar sources). Pro offload tools (OffShoot, ShotPut Pro) cost $169+ and assume a card reader. So wireless Osmo → Mac is Osmotic's unique claim; the webcam tab is a bonus (the Pocket 3 is a plain UVC webcam, and Camo already covers phones-as-webcams).

Three angles:
1. **The missing wireless path to the Mac:** closes the gap DJI's own docs describe.
2. **Offload for creators, not film crews:** free, three steps to install, understands the camera's files (proxies, `.WAV`/`.DNG` sidecars, "Download New", day folders dated when shot).
3. **Private and open:** no account, no analytics, MIT, lineage from Osmosis.

## Competitors (checked 2026-09-15)

| Product | Price / platform | Gap Osmotic uses |
|---|---|---|
| DJI Mimo (official) | Free; iOS/Android (also listed for Apple-silicon Macs) | Wireless transfer to a phone only, per DJI; whether the Mac build downloads from the camera is unverified |
| Sync for DJI Osmo | Free + IAP $1.99–14.99; iPhone/iPad | No Mac; added an account sign-in; doesn't name the Pocket 3 |
| OffShoot (ex-Hedge) | $169 / Pro $249 / $49 per 30 days; Mac/Windows | Built for DITs with card readers; no Osmo awareness |
| ShotPut Pro | $169 or $60 rental; Mac/Windows | Pro cinema cameras; dense page |
| Camera Import (Mac App Store) | ~¥300 JP (US price unverified) | Needs a card or drive |
| GoPro Quik for desktop | Sunset (removed from the Mac App Store) | Even GoPro left desktop import |
| Insta360 Studio | Free | Insta360 only, over a cable |
| Camo (on PH, launched 2020 and 2023) | Free / Pro (current price unverified) | Webcam only; generic about action cams |

What their pages do well, worth copying: a short concrete hero (Camo), social proof with real numbers (OffShoot: 50,000+ users; Camo: 10M users, tweets), logos of the apps it works with, a comparison FAQ (Camo vs Continuity Camera), trials.

## Product Hunt rules that matter

- **Name:** just "Osmotic". **Tagline:** ≤ 60 characters, no hype. **Description:** keep ≤ 260 characters (the Help Center's limit).
- **Gallery:** ≥ 2 images, 1270×760; the first one is the social preview. **Thumbnail:** 240×240, < 3 MB (a GIF animates on hover). **Video:** YouTube URL, takes the first slot (about half of Product of the Day winners since 2021 had one).
- **Maker's first comment:** most winners had one. Cover who it's for, the problem, the story, pricing, and end with a question.
- **Timing:** a 24-hour day starting 12:01 AM Pacific; can be scheduled up to a month ahead. Up to 3 topics.
- Since ~Aug 2025 there are no "Coming Soon" pages (collect interest on the landing page). PH links are `rel="ugc"`: traffic, not SEO.

## Copy

**Taglines** (character counts in parentheses):
1. Download your DJI Osmo footage to your Mac over Wi-Fi (53) ← recommended
2. Your Osmo camera, on your Mac. Wireless, no phone app. (54)
3. Wireless offload for Osmo cameras. Free and open source. (56)
4. Offload your Osmo over Wi-Fi. Nothing leaves your Mac. (54)
5. Open-source Mac app for Osmo: offload, control, webcam (54)

**Description** (235 characters):
> Free, open-source Mac app for DJI Osmo cameras. Pairs over Bluetooth, joins the camera's Wi-Fi and downloads clips into day folders, dated when shot and resumable. Plus remote record, live view and USB webcam. No phone app, no account.

**Maker's first comment** (edit before posting; keep it honest):
> Hi Product Hunt! I shoot on an Osmo Pocket 3 and got tired of the routine: cable or card reader on the Mac, or DJI Mimo on the phone and then AirDrop. Osmotic lets the Mac talk to the camera directly. It pairs over Bluetooth, joins the camera's Wi-Fi and pulls only what's new into a folder per day, dated when shot, resuming if the link drops.
>
> It stands on the shoulders of Osmosis, Konrad Iturbe's open-source Android app that reverse-engineered the protocol; Osmotic is a native macOS port. Remote control and live view follow Kaze for DJI.
>
> Honest status: tested on a real Pocket 3 (downloads, recording, live view); the webcam tab and other Osmo models aren't tested yet. Free, MIT, no analytics, no account.
>
> Which Osmo do you shoot with, and what would make offloading painless for you?

**Topics:** Mac, Open Source, Photography (alternates: Video, Webcam, GitHub).

## Assets

`swift scripts/make_icon.swift . && swift scripts/make_launch_assets.swift .` renders the gallery and thumbnail into `build/launch/` (1270×760 at 2x, from the README screenshots; slides 3 and 5 crop the raw renders of `make_shots.swift` and `make_demo_video.swift`, so run those first): hero, how it works, connect, Live, Webcam, comparison, open and private. The gallery that went into the Product Hunt draft (2026-09-15) is slides 1 to 6 as JPEG, kept on the `launch-assets` branch. For the video slot: `docs/images/demo.mp4` and `live.mp4` joined at 1080p (`build/launch/producthunt/osmotic-demo-1080p.mp4`), to upload to YouTube. Still to make by hand: the Finder slide (needs real downloads).

The full list, for reference:

Gallery (1270×760):
1. Hero: the app window with tagline 1.
2. Files tab grouped by day, "Download New".
3. The result in Finder: day folders, capture dates, `.WAV`/`.DNG` sidecars.
4. How it works in 3 steps: Bluetooth → camera Wi-Fi → download → back on your network.
5. Live tab.
6. Webcam in Zoom/OBS.
7. The comparison table.
8. Open source and privacy, with credits.

Plus the 240×240 thumbnail (the icon; `build/icon-1024.png` from `scripts/make_icon.swift`) and a 30–60 s YouTube demo (Connect → thumbnails → Download New → Finder).

## Before launch day (owner's decisions)

1. **Notarize.** Step 2 of the install ("Open Anyway") will lose many first-time visitors. `scripts/notarize.sh` is ready; it needs an Apple Developer account ($99/year).
2. Test Webcam and a photo in Photo mode on hardware; ideally one more camera model.
3. Record the demo video with a real camera (the screenshots use demo data).
4. Ask Konrad Iturbe (Osmosis) whether he's happy to be mentioned in the launch; a friendly heads-up keeps the relationship good.
5. Verify the FAQ claim about activation (a new camera is activated once in DJI Mimo, per DJI's FAQ).

## Sources

- Product Hunt: https://www.producthunt.com/launch/preparing-for-launch · https://help.producthunt.com/en/articles/479557-how-to-post-a-product · https://www.producthunt.com/products/camo · https://www.producthunt.com/products/screen-awesome-record-annotate · https://www.producthunt.com/topics/mac · https://www.producthunt.com/topics/open-source · https://www.producthunt.com/topics/photography
- Launch practice: https://submitator.com/blog/product-hunt-launch-assets · https://submitator.com/blog/product-hunt-launch-advice-thats-now-wrong
- DJI: https://support.dji.com/help/content?customId=en-us03400006849&spaceId=34&re=US&lang=en · https://www.dji.com/osmo-pocket-3/faq · https://apps.apple.com/us/app/dji-mimo/id1431720653 · https://www.dji.com/downloads/softwares/dji-studio
- Others: https://apps.apple.com/us/app/sync-for-dji-osmo-download-4k/id1483079930 · https://hedge.co/products/offshoot · https://www.imagineproducts.com/product/shotput-pro/mac · https://apps.apple.com/jp/app/id6451119588 · https://gopro.com/en/us/news/gopro-sunsetting-quik-desktop-app · https://www.techradar.com/cameras/action-cameras/gopro-pulls-the-plug-on-its-desktop-quik-editing-app-less-than-a-year-after-bringing-it-back · https://www.insta360.com/blog/news/insta360-studio-experience-update.html · https://camo.com/studio · https://9to5mac.com/2020/07/16/hands-on-reincubate-camo-use-iphone-as-mac-webcam/ · https://camerabits.freshdesk.com/support/solutions/articles/48001252734-photo-mechanic-pricing-and-information · https://github.com/KonradIT/osmosis
