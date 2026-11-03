# Swan Gallery Pick — iOS sample

A complete iOS app that hosts the Swan Gallery Pick flow: the web page in a
`WKWebView`, and the native controller that scans the photo library, matches
the shopper's face on the phone, ranks the photos and uploads the selected
ones. Open it, add your keys, run it on a device.

## Requirements

- Xcode 16 or later, iOS 17.6 or later on the device.
- CocoaPods (`sudo gem install cocoapods` if you do not have it).
- A physical iPhone. The simulator has no camera and no photo library worth
  scanning.
- Swan API keys for the environment the page is built against.

## Run it

1. In this folder: `pod install`. It fetches the MediaPipe framework the
   expression reader uses.
2. Open **`photoApp.xcworkspace`**, not the `.xcodeproj`. The pod is linked only
   through the workspace.
3. `photoApp/SwanEnvironment.swift` holds what differs between a sandbox and
   a production build: the Swan page URL, the session URL, the API key, and
   whether each scan's report is posted (sandbox only). The sandbox values are
   Swan's development environment, so the sample runs as it is; fill in the
   production values for your account. In a shipped app the session token
   comes from your own server and the key never ships; the sample mints it on
   the device to keep the setup short.
4. In `photoApp/ViewController.swift`, set `shopDomain` (a placeholder) to your
   shop's id, and `userGender` and `userHeightCm` for the shopper.
5. Under Signing & Capabilities, replace the development team and bundle
   identifier with your own, pick the `photoApp Sandbox` scheme and your device, run. The project carries Swan's
   team id and the bundle id `com.ios.swan`, which will not sign for you.

### Sandbox and production builds

The project has two build configurations and a scheme for each, so the same
code makes both TestFlight builds:

| Scheme | Environment | Scan report | Example build |
|---|---|---|---|
| `photoApp Sandbox` | sandbox | posted to Swan's scan ingest | 1.0 (32) |
| `photoApp Production` | production | off | 1.0 (33) |

Pick the scheme to run or archive; give each upload a new build number. Both
builds are optimised. A Production build shows a warning until the production
values in `SwanEnvironment.swift` are filled in.

## What is in here

| Path | What it is |
|---|---|
| `photoApp/ViewController.swift` | The controller: settings, hosts the page, answers its messages. `handleCallback` is where the flow's callbacks arrive. |
| `photoApp/GallerySettings.swift` | The scan's tuning values and the small rules that read them. |
| `photoApp/GalleryScan.swift` | Starts a scan: the reference selfie, photo access, the photo fetch. |
| `photoApp/LibraryScan.swift` | Runs the scan: each photo, the iCloud pass, the end-of-scan checks and the results sent to the page. |
| `photoApp/FaceVision.swift` | Loads photos, checks the selfie, matches faces, checks the body. |
| `photoApp/MuseScore.swift` | Scores how well a matched photo would serve the Muse. |
| `photoApp/GalleryPhotos.swift` | Serves photos to the page: thumbnails, originals, captures. |
| `photoApp/Helpers.swift` | Small shared helpers. |
| `photoApp/SwanEnvironment.swift` | The values that differ per build: page URL, session URL, key, scan report. |
| `photoApp/ScanReport.swift` | Posts a JSON report of each scan in sandbox builds; off in production. |
| `photoApp/FaceRecognition.swift` | Runs the face recognition model and compares faces. |
| `photoApp/FaceExpression.swift` | Reads expression from a face crop with MediaPipe. |
| `photoApp/FaceCover.swift` | Reads what covers a selfie's face, with MediaPipe. |
| `photoApp/BodyScore.swift` | Scores a front or side photo on the body. |
| `photoApp/BodyObjects.swift` | Finds bags, umbrellas, bicycles and furniture over the body, with MediaPipe. |
| `photoApp/ScanStore.swift` | Keeps what the scan learned about each photo between scans, on the phone only. |
| `photoApp/FaceModels/` | The four models: the face matcher (Core ML package), `face_landmarker.task`, `selfie_multiclass_256x256.tflite` and `efficientdet_lite0.tflite`. Keep the package folder intact. |
| `photoApp/PrivacyInfo.xcprivacy` | Privacy manifest for the system APIs used. |
| `photoApp/SwanSession.swift` | Sample sign-in: mints a session token from your keys. Replace with your own auth. |
| `Podfile` | `MediaPipeTasksVision 0.10.21`. Rename the target to yours when copying. |
| `docs/` | Integration guide, text keys, controller notes and the changelog. |

`AppDelegate.swift`, `SceneDelegate.swift`, the storyboards and `Info.plist`
are a plain single-view app. Nothing in them is Swan-specific.

## Taking it into your app

Copy the Swift files listed above (all but `SwanSession`, which you replace with
your own sign-in), the `FaceModels` folder and the privacy manifest into your
target, add the pod line to your Podfile, and present `ViewController` however
your app navigates. Every callback the flow reports arrives in
`handleCallback(_:_:)` in `ViewController.swift`; replace each case with your
own handling.

What the controller does, what it is built from, how each piece is licensed
and what leaves the phone: `docs/GALLERY_PICK_IOS_CONTROLLER.md`. The page's
props, events and text keys: `docs/GALLERY_PICK.md` and
`docs/GALLERY_PICK_TEXT_CONFIG.md`.
