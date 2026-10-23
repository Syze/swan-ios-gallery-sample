# Gallery Pick — iOS controller notes for 1.3.3

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
| `FaceExpression.swift` | Reads facial expression (smile, blink, brows, eyes) from a face crop. |
| `FaceModels/FaceRecognitionSFace.mlpackage` | The face recognition model, 9.3 MB, Core ML format. |
| `FaceModels/face_landmarker.task` | The expression model, 3.7 MB. |
| `PrivacyInfo.xcprivacy` | Apple's privacy manifest, listing the system APIs the code calls and why. |
| `Podfile` entry `pod 'MediaPipeTasksVision', '0.10.21'` | The framework that runs the expression model. |

## What is used, and its licence

| Component | Made by | Licence | Where it runs |
|---|---|---|---|
| SFace face recognition model, from the OpenCV Model Zoo, converted to Core ML | OpenCV | Apache 2.0, commercial use allowed | On the phone, Core ML, CPU and Neural Engine |
| MediaPipe Face Landmarker model (`face_landmarker.task`) | Google | Apache 2.0 | On the phone, CPU |
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
   photo itself. These are Apple Photos downloads of the user's own photos, on
   Wi-Fi or mobile data, Low Data Mode included, up to 200 on Wi-Fi and 100 on
   mobile data per scan. The scan waits 30 seconds after the local pass for
   downloads still in progress, and up to 90 seconds while a photo the small
   copy confirmed is still coming down (a library that is all in iCloud has
   nothing to match until then). Both are constants in the controller.
2. Faces are found with Apple Vision. Group photos, photos with other people,
   faces too small, and photos that are not head to toe or head to knee are
   dropped here.
3. Each remaining face is compared with the selfie by the SFace model. A
   distance under 0.60 is a match. Borderline matches are decided at the end
   of the scan.
4. Matches are scored for the Muse with Apple Vision (face quality, pose,
   light, sharpness, hats, sunglasses, hands, clothing) and the MediaPipe
   expression model (smile, blink, brows, eyes). Some are dropped, the rest
   ranked. Repeated shots are grouped with Apple's image fingerprint.
5. The page shows the ranked grid and pre-selects five.

All models load from the app bundle. No model, image, face measurement or
score is sent anywhere during steps 1 to 5. The iCloud downloads in step 1 go
from Apple's servers to the phone through the Photos framework; Swan is not
involved in them.

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
dropped. These exist only in memory during the scan.

## Debug switches, all off in the shared build

| Switch | Default | What it does when on |
|---|---|---|
| `verboseLogging` | off | One console line per photo scanned, on the developer's Mac only. Nothing is transmitted. |
| `evalMode` | off | Writes a CSV of the scan into the app's own Documents folder for the developer to pull by cable. Never uploaded. |
| `debugBridgeLogging` | off | Prints the messages between page and controller to the console. |
| `debugDumpCrops` | off | Writes face crops to the app's Documents folder. |

## Processing cost

Measured on an A16 iPhone over a library of 2,147 photos, 453 of them only in
iCloud: 88 to 102 seconds, 21 to 24 photos a second, with the expression model
adding 10 to 25 ms per matched photo. Peak memory for the app's own process was
230 to 295 MB; the web view runs in its own process. An iPhone 12 over 89
photos: 10 seconds, peak 244 MB. Each photo is released after its checks;
iCloud downloads are held compressed, about 1 MB each, until read. The two models add 13 MB to
the app; the MediaPipe frameworks added about 40 MB to a debug build, less
in a release build.

## Permissions

- Photo library: read access, limited or full. With limited access only the
  chosen photos are scanned.
- Camera: for the selfie, requested by the web page through WebKit.
- The privacy manifest declares the file timestamp, user defaults, system
  boot time and disk space APIs, with Apple's standard reasons.
