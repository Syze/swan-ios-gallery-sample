# Changelog

All notable changes to the Swan web components, newest first: the npm package
`@swan-admin/swan-web-component` and the mobile bundle that iOS apps load.

**npm:** `npm install @swan-admin/swan-web-component@<version>`.

**Mobile:** every release has its own fixed address, for example
`https://swan-mobile-web-component.swan.so/v1.2.0/index.html`, and
`https://swan-mobile-web-component.swan.so` always serves the latest. To stay on
a release, set `sdkURL` in `ViewController.swift` to its address. The page
reports its version in the `WEB_READY` message, a version that was never
published loads the latest instead, and each entry says whether
`ViewController.swift` needs updating.

**For H&M:** the iOS app loads the mobile page only, so the mobile entries are
the ones to follow. The page is built from the same source as the npm package,
and every npm fix and option listed further down is already in it from 1.1.0
onwards; those entries are kept for reference and need nothing on your side.

---

## [1.3.4] — 2026-10-26

**Mobile iOS only.** The npm package is unchanged. **Controller: update
recommended** for the new fields; older controllers keep working and simply do
not send them.

```
https://swan-mobile-web-component.swan.so/v1.3.4/index.html
```

### Added

- **Photo dates in the scan summary.** `summary` and the `scan_complete` event
  gain, each as its own property:
  - `cloudFirstDownloadedDate` / `cloudLastDownloadedDate` — capture date of the
    first and last photo downloaded from iCloud, and `cloudFirstDownloadedAtMs`
    / `cloudLastDownloadedAtMs` — when each landed, in ms from the start of the
    scan.
  - `matchedFirstDate` / `matchedLastDate` — capture date of the newest and
    oldest matched photo (the scan runs newest first).

  Dates are `yyyy-MM-dd`, in the phone's time zone. A field is left out when
  there is nothing to report — no iCloud downloads, or no matches. The date a
  photo was added to the library is not available from iOS.

---

## [1.3.3] — 2026-10-23

**Mobile iOS only.** The npm package is unchanged. **Controller: update
recommended.** The 1.3.2 controller keeps working with this page; without the
update, the fix and the controller changes below do not apply.

```
https://swan-mobile-web-component.swan.so/v1.3.3/index.html
```

### Controller

- **Fixed: photos without a Live, HDR or depth flag were never scanned.** The
  screenshot filter asked Photos for "images whose screenshot bit is not set",
  and Photos answered with "images that have no subtype bits at all". Every
  photo saved from another app (Slack, WhatsApp, Files), AirDropped, or taken
  with Live Photos off was dropped before the scan began and counted in the
  log as a skipped screenshot. On one test library that was 24 of 113 photos;
  on another, 2,746 of 14,989. Screenshots are now filtered in code from each
  photo's own flag; nothing else is skipped. The log's "screenshots skipped"
  count is now real screenshots only. A first scan after the update covers
  more photos and takes longer.
- **iCloud photos: more of them, and a longer wait when they are all there is.**
  Up to 200 on Wi-Fi and 100 on mobile data, Low Data Mode included (1.3.2:
  100, 50, none). The scan still waits 30 seconds after the local pass, and
  longer, up to 90 seconds, only while a photo the small copy confirmed is
  still coming down; a library that is all in iCloud has nothing to match
  until those arrive. Each download gets 20 seconds instead of 10: on one
  Wi-Fi library full-length downloads took 7 to 9.7 seconds and six were cut
  off at 10. Originals are sized for upload in Low Data Mode too. `summary`
  gains `cloudWaitMs`, how long the scan waited after the local pass.
- **`memoryPeakMB`** is now reported by the shipped controller. It was listed
  under 1.3.2 but missing from that file.

### Changed

- **No match: five photos instead of three.** When the search finds nothing,
  the camera now takes two front, two side and one selfie — the same set the
  picker asks for — in that order, each uploaded as its type. The row above the
  camera lists the types in the picker's order and counts them ("Selfie ·
  Front 1/2 · Side 0/2"), and the second front and side say "One more from the
  front" / "side".
- **No-match text by photo access.** Full access: "We need a few more
  photos." / "We couldn't find enough clear, full-length photos of you. Take
  the rest now." Limited access: "These don't match your selfie." / "Choose
  different photos of you, or take new ones now." — new keys
  `capturePage.limitedHeadingTitle` and `limitedSubHeadingTitle`. The camera
  button (`capturePage.buttonText`) is "Take new photos", on the no-match
  screen and on Take it now. `capture_fallback_shown` gains `limited`.
  **If your `ViewController.swift` sends its own `capturePage` text** — the
  earlier sample did, asking for three photos "taken automatically after a
  countdown" — remove that block: it overrides the new text and no longer
  describes the screen. The current sample sends none.
- **The photo screens no longer promise a countdown.** The default
  `capturePage` and `topUpPage` subtitles drop "takes itself after a
  countdown": on the rear camera the photo is taken at once.

---

## [1.3.2] — 2026-10-22

**Mobile iOS only.** The npm package is unchanged. **Controller: update
recommended.** The 1.3.0 and 1.3.1 controllers keep working with this page;
without the update, the four controller points below do not apply.

```
https://swan-mobile-web-component.swan.so/v1.3.2/index.html
```

### Controller

- **Photos that are only in iCloud are searched too.** During the scan, iCloud
  photos whose thumbnail looks like a selfie or one standing person are
  fetched: a 30 KB copy first to confirm one person, then the photo itself
  (1536 px for a selfie, 2560 px for a standing shot). Up to 100 on Wi-Fi, 50
  on mobile data, none in Low Data Mode. The scan waits at most 30 seconds
  after the local pass for downloads still in progress. Downloads are held
  compressed until the scan reads them. `onGalleryScanComplete` `skipped` and
  `summary` gain `cloudFullLength`, `cloudPreviewOut`, `cloudLargerDownloads`
  and `cloudOnMobile`.
- **The sign-in screen waits for the page.** The web view is created after
  Continue and the sign-in screen stays up, with a spinner, until the page
  reports ready. If the page fails or takes more than 30 seconds, the screen
  shows the reason and a Try again that reloads the page only.
- **Selfie frames are reported.** `summary` gains `frameQualities`,
  `blendSpread` and `blendShift`, so a reference built from the wrong frames
  can be seen in analytics.
- **Scan memory is reported** as `memoryPeakMB` in `summary`.

### Changed

- **The selfie guide runs on the CPU (wasm) instead of WebGL.** The first run
  on a new phone no longer compiles shaders, which took 14 to 20 seconds on
  test phones; the guide is ready in under 100 ms and each check is faster.

---

## [1.3.1] — 2026-10-22

**Mobile iOS only.** The npm package is unchanged. **Controller: no update
needed.**

```
https://swan-mobile-web-component.swan.so/v1.3.1/index.html
```

### Changed

- **Building a Muse waits up to 10 minutes,** up from 6, before reporting "The
  build is taking longer than expected." Builds that take longer than six
  minutes now finish on screen instead of failing.

### Added

- **Text around the photo count.** The search progress line, "Looking through
  your photos… 13 of 1567", takes `searchingPage.progressPreText` before the
  count and `progressPostText` after it. On the picker, `scanningStatusText`
  stays the text before the count and `scanningStatusPostText` is added after
  it. Defaults keep today's wording.
- **Rear camera for the photos taken in the flow.** The three photos taken
  when no match is found, and "Take it now" for a missing selfie, front or side
  photo, get a switch between the front and rear camera. The front camera stays
  the default; on the rear one the photo is taken at once, with no countdown,
  since someone else is holding the phone. The first selfie, the one photos are
  matched against, stays on the front camera. The switch shows only on phones
  with two cameras; `common.switchCameraText` labels it. `camera_opened` now
  says which camera opened.

### Fixed

- **Photos taken in the flow were cut to a square.** The camera was asked for a
  square picture, so a full-length front or side photo lost the head or the
  feet. These photos now keep the camera's upright shape. The first selfie,
  used only for its face, is unchanged. Each photo taken is reported as
  `camera_capture`, with its size, the camera and the shot.

---

## [1.3.0] — 2026-10-22

**Mobile iOS only.** The npm package is unchanged.

**Controller: update needed for the new matching and ranking.** Add to the
app target, next to `ViewController.swift`:

- `FaceRecognition.swift` and `FaceExpression.swift`
- the `FaceModels` folder (face matcher package and `face_landmarker.task`)
- `PrivacyInfo.xcprivacy` (TestFlight requires it anyway)
- the pod `MediaPipeTasksVision 0.10.21` via CocoaPods, then open the
  `.xcworkspace`. Swift Package Manager is not an option for this framework;
  App Store Connect rejects it.

The 1.2.0 controller keeps working with this page, without the changes below.

```
https://swan-mobile-web-component.swan.so/v1.3.0/index.html
```

### Finding the shopper's photos

- Photos are matched on the face, with a face recognition model that runs on
  the phone. Lighting, clothes and framing no longer sway the result.
- Knee-length photos count, not only head to toe. Seated photos do not.
- Mirror photos count when everyone in the frame is the shopper.
- Borderline matches are decided at the end of the scan, so a tile never
  disappears once shown. `onGalleryScanComplete` gains `dropped`.
- Scanning carries on when the app is in the background.

### Choosing the best ones

- Left out: sunglasses, a hand over the face, eyes closed or a wink, the face
  cut by the frame, heavy blur.
- Ranked lower, below every clean photo: caps, smiles (closed lips lower,
  teeth or laughing lower still), wide eyes, an open mouth, a black or blown
  exposure. `score` is 0.5 or more for a clean face, under 0.5 otherwise.
- Ranked a little lower: suits, jackets, ties, sarees, gowns, and busy prints
  or drape. Plain clothes win.
- Repeated shots are pre-selected once. They share a `dupGroup` on
  `onGalleryMatchFound`; all stay in the grid.
- When the scan ends, the best photo of each type the Muse needs (1 selfie, 2
  front, 2 side) is pre-selected and moved to the front, and the rest of the
  grid follows by rank. The user can change any of it. `onImageSelect` fires
  with `auto: true`; `onGalleryMatchFound` gains `distance` and `score`.
- A side photo is one turned 45 degrees or more from the camera.

### Selfie

- A guide oval over the camera: one hint at a time, green when the face fits,
  and the button enables only then. Green holds through small movements. In
  a dark room the screen lights the face and flashes white on capture.
- A selfie with another person in it, looking away, or too blurred to match
  from is sent back for a retake with the reason shown. New
  `onGalleryScanComplete` errors: `several-faces-in-selfie`,
  `selfie-not-frontal`, `selfie-too-blurry`.
- Two silent frames are taken while the face fits, and the three are combined
  into one steady reference for matching. The tapped one stays the selfie the
  user sees. New `GALLERY_SCAN_START` field `referenceImages`.
- New text keys under `selfiePage` for the hints and retake reasons.

### Other

- Upload starts when Build is tapped, not in the background.
- Muse builds get six minutes before the page gives up, up from three.
- `onGalleryScanComplete` carries `summary`, the scan's counts and timings,
  for analytics.

---

## [1.2.0] — 2026-10-07

**Controller: update to the 1.2.0 `ViewController.swift`** to send original
photos and Live Photos. The previous controller keeps working with this
release, uploading re-encoded copies as before.

```
https://swan-mobile-web-component.swan.so/v1.2.0/index.html
```

Published the same day as 1.1.0, which has everything below except the first
screen. Both folders stay available.

### Added

- **Original files.** Photos are uploaded as the original files from the
  library, not re-encoded copies. A photo whose original is over 10MB is not
  shown in the results.
- **Live Photos.** The motion is sent alongside the photo. Until our servers
  accept the video format, the photo uploads on its own and the Muse builds as
  normal.
- **One photo at a time.** Each photo uploads on its own, and `onUploadEnd`
  fires after every file, including failures.
- **Selfies stored only in iCloud are searched.** When a thumbnail looks like a
  selfie, a small copy is downloaded over Wi-Fi, at most 40 per scan, and put
  through the same checks. Not in Low Data Mode.
- **A months-back setting** at the top of `ViewController.swift`, next to the
  email, token and height: how far back the library search reaches, 12 by
  default.

### Changed

- **Gallery Pick opens on the "Create your Muse" screen.** It explains the flow,
  and Start leads into it.
- **Photos with anyone else in them are left out.** People far in the
  background don't count.
- **Full-length photos must show the whole body,** head to toe.
- **Front and side photos are told apart by body position,** so a side-on body
  with the face turned to the camera counts as a side photo.
- **A selfie is judged the same way** whether the phone was held upright or
  sideways.
- **`token` and `userDetails` are required.** `userDetails` must include `email`
  and `shopDomain`. Without them nothing uploads, and Build reports an `onError`
  with stage `config`.
- **Requires iOS 17 or later.**

---

---

## [1.0.130] — 2026-09-04

Bug fixes. No changes needed on your side.

```bash
npm install @swan-admin/swan-web-component@1.0.130
```

### Fixed

- **Height in feet returned `cm: 0`.** Onboarding emitted
  `{ cm: 0, ft: 6, inch: 3 }` because feet were never converted. It now returns
  the converted value, e.g. `{ cm: 191, ft: 6, inch: 3 }`. `ft` and `inch` are
  unchanged, so existing parsing keeps working.

- **Endless loading screen after an out-of-range height.** BodyScan reported the
  error but left the spinner running. It now shows an error screen with a retry,
  and keeps showing it while the height is still invalid.

- **Face scan cut prompts short.** A stage could advance twice in quick
  succession, restarting the voiceover and skipping ahead. Each prompt now plays
  through and each stage advances once.

---

## [1.0.129] — 2026-09-02

### Fixed

- **The educational flow no longer renders a blank screen when `startStep` is
  outside 1-3.** Passing `0` in particular left the screen empty with no way to
  continue and no `onComplete`; out-of-range values now start at the first screen.

---

## [1.0.128] — 2026-08-25

Adds two display options. No breaking changes — both default to the previous
behaviour, so nothing changes unless you opt in.

```bash
npm install @swan-admin/swan-web-component@1.0.128
```

### Added

- **Hide the onboarding progress bar.**

  ```jsx
  <Onboarding steps={steps} showProgressBar={false} />
  ```

- **Hide or customise the heading on the phone-model screen.**

  ```jsx
  <FocalLength showTitle={false} />              // hide it
  <FocalLength title="Select your phone" />      // custom text
  ```

---

## [1.0.127] — 2026-08-25

Drop-in patch release. No breaking changes — nothing in your integration needs
to change.

```bash
npm install @swan-admin/swan-web-component@1.0.127
```

### Fixed

- **Camera-blocked message now tells users how to fix it.** Denying camera access
  previously showed "camera already in use — try closing your browser", which
  didn't apply. It now shows where to re-enable permissions.

- **The camera dialog uses your branding.** Fonts and colours from your `config`
  are applied — it previously fell back to the SDK's defaults.

- **Progress screen no longer flips back to the live camera.** The "measurements
  are being taken" screen now stays up until results return, instead of resetting
  mid-wait and looking like a failed scan.

- **Drawers stay put.** The scan drawer could be pushed off-screen once the
  camera started, or render invisible on iOS Safari. Both fixed, including in
  embedded hosts like Shopify Remix.


- **Scans work without WebGL.** Devices with no usable WebGL now fall back to CPU
  instead of failing to start. Slower frame rate, but the scan completes.


