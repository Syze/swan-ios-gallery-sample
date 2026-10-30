# Gallery Pick — iOS controller notes for 1.3.8

What the native code does on the phone, what it is built from, how each part
is licensed, and what leaves the device. Companion to `CHANGELOG.md` and
`GALLERY_PICK.md`.

## Files

All of them are in `native-samples/`. The Podfile names the sample target
`photoApp`; change that to your app's target.

| File | Role |
|---|---|
| `ViewController.swift` | Hosts the web page, scans the photo library, matches faces, scores and filters photos, uploads the selected ones. |
| `FaceRecognition.swift` | Runs the face recognition model and compares faces. |
| `FaceExpression.swift` | Reads facial expression (smile, blink, brows, eyes, iris size) from a face crop. |
| `FaceCover.swift` | Reads what covers a selfie's face (hairline band, jaw band, face oval) from a face crop. |
| `BodyScore.swift` | Scores a front or side photo on the body: how well the clothes show the shape of the torso, legs and arms, the pose, the sharpness, and the outfit colour. |
| `BodyObjects.swift` | Finds bags, umbrellas, bicycles and furniture that may cover the body. |
| `ScanStore.swift` | Keeps what the scan learned about each photo between scans, on the phone only. |
| `FaceModels/FaceRecognitionSFace.mlpackage` | The face recognition model, 9.3 MB, Core ML format. |
| `FaceModels/face_landmarker.task` | The expression model, 3.7 MB. |
| `FaceModels/selfie_multiclass_256x256.tflite` | The face cover model, 16.4 MB. Must be a member of the app target. |
| `FaceModels/efficientdet_lite0.tflite` | The object model, 4.6 MB. Must be a member of the app target. |
| `PrivacyInfo.xcprivacy` | Apple's privacy manifest, listing the system APIs the code calls and why. |
| `Podfile` entry `pod 'MediaPipeTasksVision', '0.10.21'` | The framework that runs the expression, face cover and object models. |

## What is used, and its licence

| Component | Made by | Licence | Where it runs |
|---|---|---|---|
| SFace face recognition model, from the OpenCV Model Zoo, converted to Core ML | OpenCV | Apache 2.0, commercial use allowed | On the phone, Core ML, CPU and Neural Engine |
| MediaPipe Face Landmarker model (`face_landmarker.task`) | Google | Apache 2.0 | On the phone, CPU |
| MediaPipe Multiclass Selfie Segmenter model (`selfie_multiclass_256x256.tflite`) | Google | Apache 2.0 | On the phone, CPU |
| MediaPipe EfficientDet-Lite0 object detector, int8 (`efficientdet_lite0.tflite`) | Google | Apache 2.0 | On the phone, CPU |
| MediaPipe Tasks Vision framework 0.10.21, with its TensorFlow Lite runtime | Google | Apache 2.0, licence text ships in the pod | On the phone |
| Vision, Core ML, Photos, WebKit, SensitiveContentAnalysis, Network | Apple | Part of iOS | On the phone |

Nothing else is added. No third-party analytics SDK and no third-party
network library are in the controller. The licence texts for the MediaPipe
frameworks are in the pod folders; keep the OpenCV Model Zoo's Apache 2.0
notice with the SFace package when the app ships.

Not used, on purpose: InsightFace models, which are licensed for
non-commercial use only.

## What runs on the phone

Every step of finding and filtering photos is on the device:

1. The library is read with the Photos framework, newest first, within the
   months-back window. A photo that is only in iCloud is judged from the
   thumbnail the phone keeps; if it looks like a selfie or one standing person,
   the phone asks iCloud for a 30 KB copy to confirm one person, then for the
   photo itself at the scan's own size (1536 px, about 0.5 MB), or a larger
   copy when the face would otherwise be too small to compare. These are Apple
   Photos downloads of the user's own photos, on Wi-Fi or mobile data, Low
   Data Mode included, up to 200 on Wi-Fi and 100 on mobile data per scan, six
   at a time on Wi-Fi and three on mobile data, each given 20 seconds on Wi-Fi
   and 30 on mobile data. The scan waits 30 seconds after
   the local pass for
   downloads still in progress, and up to 90 seconds while a photo the small
   copy confirmed is still coming down (a library that is all in iCloud has
   nothing to match until then). Both are constants in the controller.
   Downloads still queued when that wait ends are cancelled; nothing is
   fetched once the scan is over.
2. Faces are found with Apple Vision. Group photos, photos with other people,
   faces too small, and photos that are not head to toe are dropped here (a
   head-to-knee photo counts as not head to toe: the knee rule is off, behind
   `kneeLengthEnabled`). Each remaining photo is sorted by shape: a selfie is
   a face with no knee or ankle in frame and eye spacing of 60 px or more in
   the original (from the Vision eye landmarks); a full-length photo is
   front, three-quarter (turned 30° to 45°, by the shoulders) or side (45°
   and over).
3. Each remaining face is compared with the selfie by the SFace model. A
   distance under 0.60 is a match. Borderline matches are decided at the end
   of the scan.
4. Matches are scored for the Muse with Apple Vision (face quality, pose,
   head angle, light, sharpness, hats, sunglasses, hands, clothing) and the
   MediaPipe expression model (smile, blink, brows, eyes, iris size, the
   head's angle to the camera; eye direction is logged but not used). Some
   are dropped, the rest ranked. A selfie also meets the v2 gates and is
   dropped when the head is pitched over 15° (MediaPipe's reading) or turned
   over 20°, the mouth is open, teeth show without a
   smile, the face is very dark or blown out or touches the frame's edge,
   the camera was under 25 cm away, or the original carries no camera data.
   The distance comes from the iris size and the focal length in the
   original's metadata, read from the phone's copy of the file; a photo
   without metadata is read as a phone's front camera. A smile showing teeth
   ranks low. A selfie none of those gates dropped is also dropped when a
   cap or hat is on, or when the MediaPipe multiclass selfie segmenter, run
   on the head crop at 256 px, finds clothes or an accessory over the
   hairline band or the jaw band, or anything but skin and hair inside the
   face oval (a hood, scarf, mask or object; eyeglasses pass). A match of
   any type is dropped when Vision's classifier reads it as a document (an
   ID card, passport or page with the face on it), or when its document
   detector finds a page with the face inside it and the classifier half
   agrees. Repeated shots are grouped with Apple's image fingerprint.
   A selfie that passed every gate is then scored the v2 way: six groups
   (head pose, a camera held below the face and camera distance from the
   iris size, light, gaze, expression,
   how much of the face is visible, detail), each the lowest of its
   readings, combined by a weighted geometric mean into T from 0 to 1; T at
   0.70 or more is Tier A, and a selfie whose eyes are under 90 px apart in
   the original is Tier B whatever its T. A front, three-quarter or side is
   scored on the body instead of the face: Vision's person segmentation and
   the pose joints give how close the outline sits to the torso, legs and
   arms, the contrast and light on each, and the pose (sitting, leaning,
   crossed arms); Vision's whole-photo labels cap a region a garment hides
   (a suit, sherwani, gown or sari); the MediaPipe object detector finds a
   bag, umbrella, bicycle or chair over the body. These combine into T from
   0 to 1: Tier A at 0.70, usable down to 0.45. A body under 400 px tall,
   blurred, or a quarter or more under objects is not usable. The face
   filters do not apply to these photos. The mean colour of the top and the
   trousers is sent with each, so the page can tell two outfits apart. Each
   match also gets an order for the grid: Tier A above
   Tier B, and within Tier A the score with how recent the photo is and, for
   a selfie, whether the user marked it a favourite, edited it or kept it
   from a burst (flags on the library record, no image work). A borderline
   match the gap rule would withdraw is kept when its face sits under 0.48
   from one of the user's sure matches, since photos of one person sit
   closer to each other than to a quick selfie.
5. The page shows the grid in that order and pre-selects five: the top Tier
   A selfie (a wide-eyed one only when no other is left), and two fronts and
   two sides, each usable (0.45 and over), with the second of each from a
   different session, at least an hour from the first, or from the same
   session in a clearly different outfit. Selfies follow the picks, then the
   fronts and sides. The pre-selected fronts and sides stay selected; the
   selfie can be swapped.

All models load from the app bundle. No model, image, face measurement or
score is sent anywhere during steps 1 to 5. The iCloud downloads in step 1 go
from Apple's servers to the phone through the Photos framework; Swan is not
involved in them.

Between scans the controller keeps one record per photo it has judged, in the
app's private Application Support folder: either a verdict that does not
depend on the selfie (no face, a group, face too small, not head to toe, only
in iCloud and not worth a download, and so on) or, for a photo that could
match somebody, the face vectors of its faces (128 numbers per face, up to
three faces). The next scan for the same account counts the known photos
without loading them and compares the new selfie with the stored vectors;
only a possible match is loaded and goes through steps 2 to 4 in full, so
every rule that decides a match runs on the real photo. An iCloud photo is
therefore downloaded once in its life, and after that only when it matches.
A record is dropped when the photo is edited or when the rules change. The
file is under iOS data protection, excluded from iCloud and computer backups,
never sent anywhere, and deleted when a different account signs in. About
0.6 KB per photo. `ScanStore.enabled` in `ScanStore.swift` turns it off, and
the scan is then exactly what it was.

## What leaves the phone, and when

Only when the user taps Build, and only to Swan's servers:

- The photos the user has selected, as the original files, plus the paired
  video of a Live Photo.
- The selfie taken in the flow.
- The user's email and the brand token, to register the uploads.
- With each photo, its role (selfie, front, side, full length), which the
  phone worked out.

Analytics events carry counts, timings and the scan summary (how many photos
fell to each rule). They never carry images, face data, scores per photo or
photo identifiers.

Never sent: face embeddings, expression readings, the library scan results
for photos the user did not select, or anything from photos that were
dropped. Verdicts and face embeddings stay on the phone between scans, in the
app's private folder described above; everything else exists only in memory
during the scan.

## Debug switches, all off in the shared build

| Switch | Default | What it does when on |
|---|---|---|
| `verboseLogging` | off | One console line per photo scanned, on the developer's Mac only. Nothing is transmitted. |
| `evalMode` | off | Writes a CSV of the scan into the app's own Documents folder for the developer to pull by cable. Never uploaded. |
| `debugBridgeLogging` | off | Prints the messages between page and controller to the console. |
| `debugDumpCrops` | off | Writes face crops to the app's Documents folder. |
| `ownPhotoLogEnabled` | on in the review build | With `verboseLogging`, prints each borderline face's distance to the user's sure matches and the capture date of every photo the gap rule touches. Console only. |
| `fullLengthLabelLog` | on in the review build | With `verboseLogging`, prints Vision's whole-photo labels over 0.2 on each front and side. Console only. |

The page has review switches of its own in `galleryConstants.ts`:
`SHOW_SCORE_BADGE` and `SHOW_ID_BADGE` put the score and the first 8
characters of the photo id on each tile, and `SHOW_TIER_BADGE` (off) adds
the tier. They are compiled into the page, so turning them off is a
release.

## Processing cost

Measured on an A16 iPhone over a library of 2,147 photos, 453 of them only in
iCloud: 88 to 102 seconds, 21 to 24 photos a second, with the expression model
adding 10 to 25 ms per matched photo. Peak memory for the app's own process was
230 to 295 MB; the web view runs in its own process. An iPhone 12 over 89
photos: 10 seconds, peak 244 MB. With the results kept from an earlier scan,
a second scan of a 3,533-photo library (741 only in iCloud) took 76 seconds
against 201 for the first, 58 of them waiting for iCloud on mobile data; the
local pass itself was about 18 seconds, with face detection and embedding
under a second, and peak memory 244 MB against 280. The iPhone 12 over 123
photos: 8 seconds against 12. The face cover read costs about 170 ms per
selfie it runs on, 2.5 seconds over 15 selfies on the iPhone 12, and raises
peak memory by 70 to 100 MB while it runs (322 MB on the iPhone 12 over 124
photos). Each photo is released after its checks;
iCloud downloads are held compressed, about 1 MB each, until read. The body
score adds about 8 seconds and the object read about 2 seconds over a
3,039-photo library, 25 to 30 ms per matched front or side for the
objects; that first scan took about 150 seconds and a rescan with
the results kept 31. The four models add 34 MB to the app; the MediaPipe
frameworks added about 40 MB to a debug build, less in a release build. A
debug build of the sample app is 73 MB.

## Permissions

- Photo library: read access, limited or full. With limited access only the
  chosen photos are scanned.
- Camera: for the selfie, requested by the web page through WebKit.
- The privacy manifest declares the file timestamp, user defaults, system
  boot time and disk space APIs, with Apple's standard reasons.
