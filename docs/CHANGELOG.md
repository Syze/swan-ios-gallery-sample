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

## [1.3.7] — 2026-10-29

**Mobile iOS only.** **Controller: update recommended.** Older controllers
keep working with this page; without the update, photos are sorted by the
1.3.x rules (no three-quarter, no knee-up flag) and `scoreInputs` is left
out. The page must be on this release or later for a controller with the
new sort: an older page rejects the `three-quarter` type. The update adds
`FaceCover.swift` and a 16.4 MB model file to the target.

### Added

- **Photos sorted the v2 way (plan item 1).** Behind `typeSortV2` in the
  controller, on. A selfie is a face with no knee or ankle joint in frame
  and eye spacing of 60 px or more in the original (`selfieEyeSpacingPixels`,
  `selfieEyeFloorEnabled`); a knee-up photo is never a selfie, whatever the
  face size. A full-length photo turned 30° to 45° is a `three-quarter`
  (`threeQuarterDegrees`), which the page puts in a side slot; from 45° it is
  a `side` as before. `onGalleryMatchFound` and `onGalleryPhotoAnalysis`
  gain `kneeUp`, true for a head-to-knee photo, which the page pre-selects
  only when no head-to-toe photo is left for the slot; with the knee rule
  off (see Changed) the controller sends it as false. `summary` gains `matchedThreeQuarter` and
  `selfieSmallEyes`; the console MATCH line shows the eye spacing. The
  results store's rules version is 2, so the first scan after the update is
  a full one. Measured on two libraries (123 and 2,875 photos): no selfie
  under the eye floor, three-quarters at 32° to 44°, sides unchanged.

- **Selfie gates the v2 way (plan item 2, the part that needs no new
  model).** Behind `selfieGatesV2` in the controller, on. A photo sorted as a
  selfie is now out (score 0, hidden) where 1.3.x ranked it lower or let it
  through: head pitched over 15° or turned over 20°, mouth open, teeth
  showing on a face that is not smiling, a black or blown exposure, the face
  contour at the frame's edge, the camera under 25 cm
  (`tooCloseGateEnabled`), and no camera data in the original
  (`noCameraDataGateEnabled`). A smile showing teeth stays in and ranks low
  (`smileKeepsTeeth`), as before. The camera distance comes from the iris
  size the expression model already reports and the focal length in the
  original's metadata, read from the phone's copy of the file; a photo with
  no metadata is read as a phone's front camera (30 mm equivalent, counted
  as `focalAssumed`), and a camera photo without a 35 mm equivalent gets no
  distance. At the end of the scan a selfie whose more closed eye is under
  40 percent of the shopper's median openness is withdrawn through `dropped`
  (`relativeEyeGateEnabled`; on three libraries the fixed closed-eye gate
  caught every such face first). `onGalleryMatchFound.scoreInputs` gains
  `cameraCm`, `irisPx`, `eyeSpacingPx`, `focal35`, `focalAssumed` and
  `cameraData`; `scoreFilter` gains `head pitched`, `head turned`, `mouth
  open`, `teeth showing`, `exposure`, `too close` and `no camera data`.
  `summary` gains `unusableGates` (a count per filter), `eyeDropped`,
  `eyeBaseline`, `coverHints` (matched selfies the classifier labelled with
  a scarf, mask, hood, earmuffs, headphones or tiara; logged, not filtered)
  and `focalAssumed`. The results store's rules version is 4. Measured on
  three libraries (124, 124 and 2,944 photos): on the large one the new
  gates removed 12 turned heads, 6 pitched, 2 cut by the frame and 1 with no
  camera data from 87 matches, none for distance (clean selfies sat at 27 to
  45 cm), and the metadata read cost 0.7 s over 95 originals.

- **Covered faces gated (plan item 2, the rest).** Behind `coverGatesEnabled`
  in the controller, on. A photo sorted as a selfie is out when a cap or hat
  is on (Vision's hat labels at 0.5 or more; was a ×0.6 demotion), when
  clothes or an accessory cover 30 percent or more of the hairline band
  (`coverHairlineLimit`) or 40 percent or more of the jaw band
  (`coverJawLimit`), or when 15 percent or more of the face oval is neither
  skin nor hair (`coverFaceLimit`): a hood, a scarf, a mask, an object. The
  bands come from the MediaPipe multiclass selfie segmenter
  (`FaceModels/selfie_multiclass_256x256.tflite`, 16.4 MB, Apache 2.0, run
  by the new `FaceCover.swift`) on the head crop at 256 px. It reads only a
  selfie that no other gate has dropped (`coverReadEnabled`), about 170 ms a
  read. Eyeglasses are untouched: they read 0.03 to 0.06 on the face oval
  against 0.26 to 0.34 for sunglasses. `scoreFilter` gains `cap or hat`,
  `hairline covered`, `jaw covered` and `face covered`; `scoreInputs` gains
  `coverHairline`, `coverJaw` and `coverFace` when the segmenter read the
  photo; `summary` gains `coverRead` and `coverFacts` (how many read selfies
  sat over each limit). The results store's rules version is 6. Measured on
  three libraries: the 124-photo one lost its three capped selfies to the
  hat gate (two more had already gone for sunglasses) and nothing else; the
  2,944-photo one lost one hooded head (hairline 0.82, no hat label from
  Vision) and no selfie with eyeglasses; a bare jaw with the chin lowered
  onto a dark polo collar read 0.33, which put the jaw limit at 0.4. The
  read cost 2.5 s over 15 selfies on an iPhone 12.

- **The raw readings behind the score.** `onGalleryMatchFound` gains
  `scoreInputs`, what each part of `scoreParts` was worked out from: head
  `yaw`, `pitch`, `roll` (degrees), `faceWidth` (pixels), `quality`,
  `brightness`, `clipped`, `backlight`, `blur`, `smile`, `jawOpen`, `blink`,
  `browUp`, `squint`, `eyeWide`, `teeth`, `sunglasses`, `cap`, `handOnFace`
  (1 or 0), `dressy`, `busy`. Expression readings are left out when the
  expression reader did not run, light readings when the face could not be
  read.

- **Score details in `onImageSelect`.** The callback gains `type`, `distance`,
  `score`, `rank`, `scoreParts`, `scorePenalties`, `scoreFilter` and
  `scoreInputs`. Each is left out when the controller did not send it.

- **What is collected.** The score details of the photos a user selects are
  sent to Swan's analytics. No photo ids, no images.

### Changed

- **Head-to-knee photos are not shown.** Behind `kneeLengthEnabled` in the
  controller, off. Muses built from head-to-knee photos were not good
  enough, so only head to toe counts as full length and a head-to-knee photo
  is "not head to toe". `kneeUp` stays in the messages and is false; the
  page's knee-up handling is unchanged for a controller that turns the rule
  back on. On the 2,944-photo library 14 of 81 matches had come in on the
  knee rule.

### Fixed

- **iCloud downloads stopped at the end of the scan.** The downloads still
  queued when the iCloud pass reached its deadline, or when a new scan
  replaced the running one, used to carry on in the background and their
  results were thrown away. They are cancelled now; the few already in
  flight finish within their timeout. Seen on a 3,544-photo library on
  mobile data, where 22 downloads were left at the deadline.

---

## [1.3.6] — 2026-10-28

**Mobile iOS only.** The npm package is unchanged. **Controller: no update
needed.** Page fixes only.

```
https://swan-mobile-web-component.swan.so/v1.3.6/index.html
```

### Changed

- **A repeat of a good shot beats a weak photo in the pre-selection.** The
  picks still take one photo per shot (`dupGroup`), but when every photo of a
  new shot for a slot scores under 0.5, the best photo left fills it even if
  it repeats a shot already picked. A scan had picked a 0.09 side view over
  the 0.70 second frame of the side already picked. `PRESELECT_REPEAT_BELOW`
  in `galleryConstants.ts`.

### Fixed

- **The last matches of a scan were left unsorted and out of the
  pre-selection.** The controller streams the matches it held back for the
  gap rule one moment before the scan-complete message; the page ranked the
  grid and chose the picks from a copy of the scores that had not yet taken
  them in. Those photos sat at the bottom of the grid in arrival order, and a
  better side or front among them was never considered. Present since the
  ranking at scan end in 1.3.0.

---

## [1.3.5] — 2026-10-28

**Mobile iOS only.** The npm package is unchanged. **Controller: update
recommended.** Older controllers keep working; without the update, a second
scan takes as long as the first, iCloud downloads on mobile data keep the 20 s
limit, and the score breakdown is left out.

```
https://swan-mobile-web-component.swan.so/v1.3.5/index.html
```

### Added

- **Scan results kept between scans.** The controller now remembers, on the
  phone, what it learned about each photo: a verdict that does not depend on
  the selfie (no face, a group, face too small, not head to toe, and so on)
  or, for a photo that could match somebody, the face vectors of its faces.
  The next scan for the same account counts the known photos without loading
  them and compares the new selfie with the stored vectors; only a possible
  match is loaded and goes through every rule as before, so the result is the
  same. An iCloud photo is downloaded once in its life, and after that only
  when it matches. On a 3,533-photo library with 741 photos in iCloud the
  second scan took 76 s against 201 s, 58 s of that waiting for iCloud on
  mobile data; on a 123-photo library 8 s against 12 s. A record is dropped
  when the photo is edited or the rules change. The file (`ScanStore.swift`,
  new, add it to your target) lives in the app's private Application Support
  folder under iOS data protection, is excluded from iCloud and computer
  backups, is never sent anywhere, and is deleted when a different account
  signs in. `ScanStore.enabled` turns it off. `summary` gains `storeDecided`,
  `storeCloudSkipped`, `storeWritten` and `storeRecords`; absent when the
  store is off. The console summary gains a `store` line.

- **Why a photo scored what it did.** `onGalleryMatchFound` gains
  `scoreParts` (each signal 0–1: `quality`, `pose`, `light`, `size`, `mouth`,
  `eyes`, `brow`, `sharp`), `scorePenalties` (what pulled the score down, for
  example `["closed smile", "cap"]`) and `scoreFilter` (what set it to 0, for
  example `sunglasses`). The page sends them, with each selected photo's
  `type`, `distance`, `score` and grid position, to Swan's analytics. No photo
  ids, no images.

- **Score badge on the grid.** Each tile shows the host's `score` (0–1, two
  decimals) in its bottom-left corner, the number that sets the grid's order
  and the pre-selection, so the ranking can be reviewed on the phone. Behind
  `SHOW_SCORE_BADGE` in `galleryConstants.ts`, on in this release; it is
  compiled into the page, so removing it is a release with the switch off.
  Tiles from hosts that send no score show nothing.

### Changed

- **Each iCloud download gets 30 s on mobile data** (20 s on Wi-Fi, as
  before): a 0.5 MB copy measured 8 to 17 s on mobile data and a matched photo
  was lost at 20 s. Sizing an original keeps its 20 s.

---

## [1.3.4] — 2026-10-27

**Mobile iOS only.** The npm package is unchanged. **Controller: update
recommended.** Older controllers keep working; without the update, iCloud
photos with a small face are matched on too small a copy (see Fixed), the
flat-face ranking does not apply, and the new fields are not sent.

```
https://swan-mobile-web-component.swan.so/v1.3.4/index.html
```

### Added

- **Photo dates in the scan summary.** `summary` gains:
  - `cloudFirstDownloadedDate` / `cloudLastDownloadedDate` — capture date of the
    first and last photo downloaded from iCloud, and `cloudFirstDownloadedAtMs`
    / `cloudLastDownloadedAtMs` — when each landed, in ms from the start of the
    scan.
  - `matchedFirstDate` / `matchedLastDate` — capture date of the newest and
    oldest matched photo (the scan runs newest first).

  Dates are `yyyy-MM-dd`, in the phone's time zone. A field is left out when
  there is nothing to report — no iCloud downloads, or no matches. The date a
  photo was added to the library is not available from iOS.

- **Flat face first.** A selfie from the library whose head is pitched more
  than 15° up or down, or turned more than 20°, is ranked below every level
  selfie: it keeps 0.6 of its Muse score, in the lower band, like a cap. Never
  hidden. Fronts and sides are not affected — a side view has the head turned
  by definition. Every match line in the console shows `head yaw N° pitch N°`;
  `summary.tilted` counts the lowered matches.

- **Camera selfie held to the same angles.** `selfie-not-frontal` is now sent
  for a head tilted more than 15° (was 25°); the 20° turn limit is unchanged.
  The two limits are one pair of constants in the controller.

- **More in `summary`:** `tilted` (above), `sizedByPixels` (matches shown on
  pixel count because the original was too slow to size, see Changed),
  `cloudParallel` (downloads in flight at once on this scan: 3 on mobile data,
  6 on Wi-Fi) and `cloudFailures`, why iCloud downloads failed, as counts by
  reason: `diskFull` (Photos refuses every download when the phone is nearly
  out of space, iOS error "Disk space is very low"; freeing space is the only
  fix), `timedOut`, `other`. Left out when nothing failed. The console summary
  line shows the same breakdown after "failed". The expression reader also logs where the eyes point (`gaze up /
  down / side` on the match line, three eval CSV columns); information only,
  no rule uses it.

### Changed

- **iCloud downloads are the scan's own size.** A full-length candidate is
  fetched at 1536 px, as a local photo is loaded, about 0.5 MB instead of
  2560 px and about 1.2 MB. A bigger copy is fetched only when the small copy
  says the face will be under the 120 px floor, or after a match for the body
  check. On a slow line three downloads run at once on mobile data (six on
  Wi-Fi): on a 250 KB/s connection six at once each took over 12 s and most
  timed out.

- **Sizing an iCloud original gets 20 s** (was 10), and a matched photo whose
  original still cannot be sized in time is shown on its pixel count when the
  original cannot be over the 10 MB cap (30 megapixels or under; a phone's
  24 MP default is 24.5 MP). 48 MP and ProRAW photos are hidden as before.

### Fixed

- **The bigger copy for a small face was never fetched for an iCloud photo.**
  The fetch reset the flag that said the photo came from iCloud, so a face
  under the floor was matched on the 1536 px copy, or skipped as too small,
  instead of on a larger one. Present since the iCloud pass in 1.3.2.

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
  screen and on Take it now.
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
  with two cameras; `common.switchCameraText` labels it.

### Fixed

- **Photos taken in the flow were cut to a square.** The camera was asked for a
  square picture, so a full-length front or side photo lost the head or the
  feet. These photos now keep the camera's upright shape. The first selfie,
  used only for its face, is unchanged.

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


