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
3. `photoApp/SwanSession.swift` ships with Swan's development keys in
   `SwanSessionConfig`, so the sample runs as it is against the development
   environment. Replace them with your own keys for your environment. In a
   shipped app the session token comes from your own server and the keys
   never ship; the sample mints it on the device to keep the setup short.
4. In `photoApp/ViewController.swift`, check `sdkURL` points at the Swan page
   for your environment, and set `shopDomain`, `userGender` and
   `userHeightCm` for the shopper.
5. Under Signing & Capabilities, replace the development team and bundle
   identifier with your own, pick your device, run. The project carries Swan's
   team id and the bundle id `com.ios.swan`, which will not sign for you.

## What is in here

| Path | What it is |
|---|---|
| `photoApp/ViewController.swift` | The controller: hosts the page, scans, matches, ranks, uploads. The part to copy into your app. |
| `photoApp/FaceRecognition.swift` | Runs the face recognition model and compares faces. |
| `photoApp/FaceExpression.swift` | Reads expression from a face crop with MediaPipe. |
| `photoApp/FaceModels/` | The two models: the face matcher (Core ML package) and `face_landmarker.task`. Keep the package folder intact. |
| `photoApp/PrivacyInfo.xcprivacy` | Privacy manifest for the system APIs used. |
| `photoApp/SwanSession.swift` | Sample sign-in: mints a session token from your keys. Replace with your own auth. |
| `Podfile` | `MediaPipeTasksVision 0.10.21`. Rename the target to yours when copying. |
| `docs/` | Integration guide, text keys, controller notes and the changelog. |

`AppDelegate.swift`, `SceneDelegate.swift`, the storyboards and `Info.plist`
are a plain single-view app. Nothing in them is Swan-specific.

## Taking it into your app

Copy the four Swift files, the `FaceModels` folder and the privacy manifest
into your target, add the pod line to your Podfile, and present
`ViewController` however your app navigates. Every callback the flow reports
arrives in `COMPONENT_CALLBACK` in the controller; the handlers there print,
replace them with your own handling.

What the controller does, what it is built from, how each piece is licensed
and what leaves the phone: `docs/GALLERY_PICK_IOS_CONTROLLER.md`. The page's
props, events and text keys: `docs/GALLERY_PICK.md` and
`docs/GALLERY_PICK_TEXT_CONFIG.md`.
