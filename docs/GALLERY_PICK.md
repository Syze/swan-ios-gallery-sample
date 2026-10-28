# GalleryPick — Integration Guide

**Why this exists:** a shopper builds their Muse from photos they already have.
No posed photoshoot, no standing against a wall in good light — they take one
selfie so we know who to look for, pick five pictures out of their own camera
roll, and the Muse is built from those.

It is the low-friction alternative to a guided body scan: most people can finish
it in under a minute, with photos they took months ago.

Mechanically: the component searches the photo library on the device, lets the
shopper pick the best matches, uploads only those, and builds the Muse.

Everything on screen is rendered by the Swan web component inside your WebView.
Your app supplies only what the browser cannot reach: the photo library, the
photo bytes, and the on-device analysis.

**Platform:** iOS 17+, inside a `WKWebView`. Matching is tuned on Vision's
FeaturePrint revision 2, which needs iOS 17.

---

## Contents

1. [What the user sees](#what-the-user-sees)
2. [Host app requirements](#host-app-requirements)
3. [What your app must implement](#what-your-app-must-implement)
4. [Rendering the component](#rendering-the-component)
5. [Component props](#component-props)
6. [Callbacks](#callbacks)
7. [When something fails](#when-something-fails)
8. [Message contract](#message-contract)
9. [Previewing a screen](#previewing-a-screen)
10. [Forcing a build result](#forcing-a-build-result)
11. [Theming](#theming)
12. [Customising the text](#customising-the-text)
13. [Sensitive content filtering](#sensitive-content-filtering)
14. [Known limitations](#known-limitations)
15. [Versions and release notes](#versions-and-release-notes)

---

## What the user sees

```
Intro ─> Gender* ─> Height** ─> Selfie ─> Searching ─┬─> Picker ─┬─> Building ─> Preview
                                                     │           │
                                                     │           └─> Take it now ─┘
                                                     └─> Camera (no matches at all)

 * skipped when userDetails.gender is supplied and is male or female
** skipped when userDetails.heightInCm is supplied and inside 152–213 cm (5'0"–7'0")
```

1. **Intro** — the "Create your Muse" screen: what the flow does, and Start.
2. **Gender** — which body the Muse is built from. **Skipped entirely** if you
   pass a usable `gender`. Worded as a shopping question rather than an identity
   one, because the value only selects a body model and a garment fit.
3. **Height** — collected in centimetres. **Skipped entirely** if you pass a
   usable `heightInCm` — see [Component props](#component-props).
4. **Selfie** — one photo, used only as the reference for matching. It never
   leaves the device. A face guide sits over the preview: an oval with one hint
   at a time ("Move closer", "Move your face to the center"), green when the
   face fits, and the button enables only then. Once green it stays green
   through small movements, so reaching for the button does not lose it. In a dark room the mask around
   the oval turns white to light the face, the hint asks for more light until
   the face fits, and the screen flashes white as the photo is taken. While the oval is green the screen also keeps two
   silent frames and sends them with the tapped one, so your app can match
   against the sharpest; the tapped frame is the selfie the user sees and
   uploads. If the guide cannot start, the plain
   camera is shown and the button enables anyway. Your app then checks the
   photo — one face, looking at the camera — and sends it back for a retake
   when it is not, with the reason shown on this screen.
5. **Searching** — your app scans the library. Matches stream in as they are
   found; the screen switches to the grid on the first one. The scan walks the
   whole window — see [Scanning the window](#scanning-the-window).
6. **Picker** — the grid fills as the scan runs. When it ends, the top-ranked
   photo of each type the Muse needs, **1 selfie, 2 front, 2 side**, is
   selected and moved to the front of the grid, ticked (fewer when the library
   is short of a type), chosen from the verdicts the host sent with the
   matches; the rest of the grid follows by the host's `score`, best first.
   That is the one moment tiles move. The user can change any of
   them; a coverage row tracks what the selection still needs. Front and side
   shots must be full length; a selfie is exempt. Nothing uploads until Build
   is tapped.

7. **Load more photos** — shown only when the user granted **limited** photo
   access. It reopens the iOS picker so they can share more; the host reports
   what was added and the scan runs again, merging into the grid they already
   have.
8. **Take it now** — when the selection cannot reach coverage from the library
   alone, the primary button becomes *Take it now* and asks for the one missing
   angle. The photo is handed to your app **in memory only** — it is never
   written to the photo library — and comes back as an ordinary grid tile,
   already selected. Capped at 12 per run.
9. **Camera fallback** — only when the scan matched **nothing at all**, the user
   photographs themselves three times (front, side, selfie). Those skip matching.
10. **Building** — the photos upload, the Muse is requested, and a websocket
   reports progress until the build settles.
11. **Preview** — the finished Muse's rendered views, in a carousel.

---

## Host app requirements

### Info.plist

| Key | Why |
|---|---|
| `NSPhotoLibraryUsageDescription` | **Required.** The scan reads the library. |
| `NSCameraUsageDescription` | **Required.** The selfie and camera fallback. |

Missing either and iOS terminates the app on first access.

### Capabilities

| Capability | Required | Why |
|---|---|---|
| *Sensitive Content Analysis* | No | Filters explicit photos out of the results. Without it nothing is filtered — see [Sensitive content filtering](#sensitive-content-filtering). |

### WKWebView configuration

```swift
configuration.allowsInlineMediaPlayback = true
configuration.mediaTypesRequiringUserActionForPlayback = []
```

Without these the camera opens fullscreen and audio guidance is muted.

Your `WKUIDelegate` must grant media capture, or the selfie camera never opens:

```swift
func webView(_ webView: WKWebView,
             requestMediaCapturePermissionFor origin: WKSecurityOrigin,
             initiatedByFrame frame: WKFrameInfo,
             type: WKMediaCaptureType,
             decisionHandler: @escaping (WKPermissionDecision) -> Void) {
    decisionHandler(.grant)
}
```

### Bridge

The message handler **must** be registered under the name `swanBridge`:

```swift
contentController.add(BridgeProxy(target: self), name: "swanBridge")
```

Register it under any other name and no message from the web layer is ever
received — with no error on either side.

> Use a weak proxy, not `self`. `WKUserContentController` retains its handler
> strongly, which otherwise leaks the view controller, the WebView and a content
> process on every presentation.

### Serving

The SDK must be served over **https**. `getUserMedia` requires a secure context,
so the selfie screen cannot open the camera from an insecure origin.

### Photo delivery

Photos reach the page one of two ways. Both are supported; the page detects
which works and uses it.

- **Custom scheme** (`swan-photo://thumb?id=…`) — register a
  `WKURLSchemeHandler`. Works for `<img>` display only.
- **Base64 over the bridge** — the fallback, used automatically when the scheme
  is blocked.

> `fetch("swan-photo://…")` is refused by WebKit before your handler is called.
> Custom schemes are not reachable from JavaScript, which is why photos for
> upload always travel over the bridge.

---

## What your app must implement

**Read this before estimating.** The component renders every screen, but it has
no access to the photo library, the photo bytes, or any on-device vision. All of
that is native work in your app. The web layer cannot do any of it and will
simply wait if it is missing.

`native-samples/ios/ViewController.swift` is a complete, working implementation
of everything below — roughly 1,900 lines. **The intended path is to lift it and
adapt it**, not to rewrite it from this specification. It is the same code the
component was developed and tested against.

### Frameworks

| Framework | Used for |
|---|---|
| `Photos` / `PhotosUI` | Enumerating the library, fetching image data, the limited-access picker |
| `Vision` | Face detection, face feature prints, body-pose joints |
| `SensitiveContentAnalysis` | Filtering explicit photos (iOS 17+, optional) |
| `WebKit` | The WebView, the bridge, the custom photo scheme |

### The work, per message

| You receive | What your app has to do |
|---|---|
| `GALLERY_SCAN_START` | Request library authorisation. Enumerate assets in the window. For each: load the image, detect faces, reject anything without exactly one face of sufficient size, compute a feature print, compare it against the selfie's, check lower-body joints via body pose, optionally screen for sensitive content — then stream each match as `onGalleryMatchFound` and finish with `onGalleryScanComplete`. See [Scanning the window](#scanning-the-window). |
| `GALLERY_ANALYSE_PHOTO` | Classify one photo as `front`, `side` or `selfie`, and decide whether it is full length. This drives the coverage row — see [`onGalleryPhotoAnalysis`](#ongalleryphotoanalysis--read-this-one-carefully). |
| `GALLERY_THUMBNAILS` | Return a small JPEG data URI for one id. |
| `GALLERY_FULL_IMAGE` | Return one photo for upload — **its original file**, never a re-encode. See [Sending the original file](#sending-the-original-file). |
| `GALLERY_CAPTURE_PHOTO` | Hold a captured photo in memory, analyse it, and serve it by id afterwards. |
| `GALLERY_PICK_MORE` | Present `presentLimitedLibraryPicker`. |
| `GALLERY_RESET` / `GALLERY_CLEAR_CAPTURES` | Drop per-run state and held captures. |
| `OPEN_SETTINGS` | Open your app's settings page. |

### Things that are easy to get wrong

- **Stream matches as you find them.** The grid fills during the scan. Batching
  everything into `onGalleryScanComplete` leaves the user on the searching screen
  for the whole scan.
- **Scan off the main thread.** A few hundred assets through Vision will freeze
  the UI otherwise.
- **Never download the library to scan it,** or the scan stalls on network
  fetches. The one exception is bounded: iCloud-only photos whose thumbnail
  looks like a selfie, a capped number per scan, over Wi-Fi only.
- **Serve captured photos by id exactly like a `PHAsset`.** After
  `GALLERY_CAPTURE_PHOTO`, the same id comes back through `GALLERY_THUMBNAILS`
  and `GALLERY_FULL_IMAGE`, and the page does not know or care which kind it is.
- **Always reply.** Every request expects a response, including failures —
  `{ id, error }` is a valid answer and keeps the flow moving. Silence is the one
  thing that hangs it.

### Matching quality is yours to own

The reference implementation matches identity with
`VNGenerateImageFeaturePrint`, a general image-similarity descriptor. It works,
but it is not a face-identity model — see
[Known limitations](#known-limitations). If match precision matters to you, this
is the part to replace, and it is cleanly isolated in `matchPerson(in:asset:)`.

---

## Rendering the component

You do not write React. The page hosts every Swan component and renders whichever
one you name, with the props you send.

**1. Wait for `WEB_READY`.** The page sends it once it has mounted. Sending
`RENDER_COMPONENT` before this arrives does nothing.

**2. Reply with `RENDER_COMPONENT`.** Props go in as a dictionary:

```swift
sendToWeb([
    "type": "RENDER_COMPONENT",
    "componentName": "GalleryPick",
    "props": [
        "userDetails": [
            "email": session.email,
            "shopDomain": shopDomain,
            "gender": userGender,
            "heightInCm": userHeightCm,   // omit the key entirely if unknown
        ],
        "token": session.token,
        "monthsBack": 12,
        "config": theme,
    ],
])
```

`token` is a session token from `POST /auth/session`, minted by your backend
for the signed-in user. The reference host ships with `SwanSession.swift`, a
sign-in screen that obtains one itself on first launch and, while it is still
valid, offers that email with a Continue button and a way to sign in as someone
else. The page loads behind that screen and is rendered only once there is a
token. A shipped app replaces that screen with its own session.

> Omit `heightInCm` rather than sending `null` if you do not know it. The flow
> reads a missing key as "no height" and shows the ruler; a null it has to
> interpret is one more thing to get wrong.

**3. Receive every callback as `COMPONENT_CALLBACK`.** They do **not** arrive as
separate message types — all eight come through one envelope:

```json
{
  "type": "COMPONENT_CALLBACK",
  "callbackName": "onMuseEnd",
  "payload": { "status": "ready", "museId": "…", "data": "{…}" }
}
```

```swift
case "COMPONENT_CALLBACK":
    let name = payload["callbackName"] as? String ?? ""
    let result = payload["payload"] as? [String: Any] ?? [:]
    switch name {
    case "onComplete":  …
    case "onMuseEnd":   …
    default: break
    }
```

`callbackName` is exactly the prop name — `onComplete`, `onCaptureComplete`,
`onRetry`, `onImageSelect`, `onLoadMore`, `onUploadStart`, `onUploadEnd`,
`onMuseStart`, `onMuseEnd`, `onError`.

> The payload of a callback is **not** sensitive-free. `onComplete` carries
> presigned URLs and the user's email; `onMuseEnd` carries the whole build frame.
> Gate any logging of it — the reference host does, behind `debugBridgeLogging`.

---

## Component props

| Prop | Type | Default | Notes |
|---|---|---|---|
| `config` | `Config` | — | Theme **and** text. See [Customising the text](#customising-the-text). |
| `monthsBack` | `number` | `12` | How far back the scan reaches, in months. **Minimum 1, maximum 36.** See below. |
| `token` | `string` | — | Session token from `POST /auth/session`. **Required for the flow.** Without it nothing uploads, and Build my Muse shows an error naming what is missing (`onError` with `stage: "config"`). Not needed for `previewPhase`, `isSuccess` or `isError`. |
| `userDetails` | `GalleryUserDetails` | — | **Required for the flow.** Not needed for `previewPhase`, `isSuccess` or `isError`. See below. |

### `monthsBack`

Accepted range is **1 to 36 months**. Anything outside it is clamped rather than
rejected, and anything that is not a usable number falls back to 12:

| You pass | Scan uses |
|---|---|
| absent, `12` | 12 |
| `0`, `-3` | 1 |
| `600` | 36 |
| `6.4`, `"6"` | 6 |
| `null`, `""`, `"abc"` | 12 |

`0` is raised to 1 rather than honoured: a cutoff of "now" can never match
anything, so it is never a useful request.

> **The value you receive in `GALLERY_SCAN_START` is already clamped.** Do not add
> your own defaulting on top — if your host silently substitutes a different
> number, the scan and the analytics disagree about what was searched. Clamp
> defensively against a bad value if you like, but do not replace a valid one.

### `userDetails`

| Field | Required | Notes |
|---|---|---|
| `email` | **Yes** | The build-progress socket subscribes by address. Without it the build cannot be reported as finished. |
| `shopDomain` | **Yes** | Sent as `customerStoreUrl` on the build, and prefixes every analytics event. |
| `gender` | No | `male` or `female`. **Supply a usable one and the gender screen is skipped**; anything else, or absent, shows the screen and **the user's answer wins** — so the `gender` on `onComplete` is the authoritative one and may differ from what you passed. Matched case-insensitively and trimmed. Required by `POST /muse/build`, so if you omit it the user is always asked. |
| `heightInCm` | No | A height you already know. **Inside 152–213 cm (about 5'0"–7'0") the ruler screen is skipped** and this is what the Muse is built from. Outside it, or absent, the ruler is shown and **the user's answer wins** — so the `heightInCm` on `onComplete` is the authoritative one and may differ from what you passed. A string is tolerated. |

---

## Callbacks

All optional. Height is always centimetres.

| Callback | Fires when |
|---|---|
| `onImageSelect` | One photo selected or deselected in the picker. Fires for the user's taps and for the photos the flow selects itself (the starting selection after a scan, a photo just taken), which carry `auto: true`. |
| `onLoadMore` | The user asked for more photos than the scan found. |
| `onUploadStart` | The chosen photos begin uploading. |
| `onUploadEnd` | One **file** finished uploading — per file, not per set, and for failures too. |
| `onMuseStart` | The Muse build is requested. |
| `onMuseEnd` | The build socket answers — **success or failure**. |
| `onComplete` | The run finished successfully. |
| `onCaptureComplete` | The camera fallback finished (fires **instead of** `onComplete`). |
| `onRetry` | The user acted on the failure screen. |
| `onError` | Upload or build failed. |

```ts
onComplete({
  source: "library" | "camera",
  assetIds: string[],      // PHAsset.localIdentifier values you can resolve
  photoIds: string[],      // server ids from the upload — what POST /muse/build took
  heightInCm: number,
  gender?: "male" | "female",  // what it was built from — the user's answer wins
  email?: string,
  museId?: string,
  museStatus?: string,     // "ready", "skipped", or why it did not settle
  museImages?: string,     // JSON array of rendered view URLs — a string, see below
})
```

```ts
onMuseEnd({
  source: "library" | "camera",
  status: "ready" | "failed",
  phase?: string,          // muse_completed | validation_failed | muse_failed
  message?: string,        // the service's own words
  data: string,            // the whole settling frame, as JSON
  museId?: string,
  heightInCm: number,
  gender?: "male" | "female",
  email?: string,
})
```

> **`onMuseEnd` is the only callback that fires for a failed build.** `onComplete`
> does not run when a build fails, so without this you see a Muse start and then
> silence. `data` is also the only place `missingRoles` and `rejectedPhotos` are
> readable.

```ts
onImageSelect({ assetId: string, selected: boolean, count: number, email?: string, auto?: true })
onLoadMore({ path: "shared_library" | "older_photos", shown: number, selected: number, email? })
onUploadStart({ source, photoCount: number, photoIds: [], background?: boolean, heightInCm, gender?, email? })
onUploadEnd({ source, assetId, kind: "image" | "video", photoId?, uploaded: boolean, error?, original: boolean, background?, email? })
onMuseStart({ source, photoCount: number, photoIds: string[], heightInCm, gender?, email? })
onRetry({ kind, escalated: boolean, failedCount: number, email? })
onError({ stage: "photos" | "upload" | "muse" | "config", source, message: string, failedCount: number, email? })
onCaptureComplete({ photoIds: string[], heightInCm: number, gender?, email?: string })
```

`onCaptureComplete`'s `photoIds` are **generated ids, not PHAsset identifiers** —
those photos never entered the library.

**`onUploadEnd` fires more often than you may expect.** Photos go up one at a
time, so it is raised once per file rather than once per run — and a Live Photo
is two files, so a set of five can raise it seven or eight times. `kind` tells
the still from the paired video, `original` is false only for a photo taken in
the flow, and `uploaded: false` carries the reason a file did not make it.
Because the run stops at the first failure, you hear about every file that
worked before you hear about the one that did not.

> `museImages` and `data` are JSON **strings**, not arrays or objects. Every
> payload is serialised crossing the native bridge anyway, so handing you one
> value to parse beats a structure that has to survive two conversions.

### Callback order

A normal library run fires:

```
onImageSelect × n  ─>  onUploadStart  ─>  onUploadEnd × n  ─>  onMuseStart  ─>  onMuseEnd(ready)  ─>  onComplete
```

A failed build stops at `onMuseEnd(failed)`, followed by `onError`. **`onComplete`
never fires.** If you treat `onComplete` as "the run ended", a failed build looks
like the user vanished mid-flow.

`onUploadStart` can also fire early with `background: true` — the flow starts
uploading while the user is still picking, so the photos are already up by the
time Build is pressed. That one never leads to a build on its own.

---

## When something fails

There is one failure screen, used for two different situations. The user is not
returned to your app — the flow handles it and keeps going.

| Situation | What the user sees | Button | Result |
|---|---|---|---|
| Some photos would not upload | "Paused." | *Try again* | Re-attempts **only** the failed photos. `onRetry` with `escalated: false`. |
| The same photos failed twice | "Paused." | *Try again* | Back to the picker. `onRetry` with `escalated: true`. |
| The build failed or was refused | "We couldn't finish." plus **the service's own message** | *Retry* | Back to the picker. `onRetry` with `escalated: true`. |
| A capture-fallback run failed | as above | *Retry* | Back to the five-shot camera, old shots cleared. |
| One photo is held by a build that has not finished | **No failure screen.** The user stays on the picker, that one tile is marked, and a message explains it | — | Register can answer `409 PHOTO_IN_USE` naming a single photo. The set is fine and the picker is full of alternatives, so that photo is dropped and the run continues. Rare — it needs an earlier build still in progress. The reference selfie is the exception: it is not a tile, so it takes the ordinary failure path. |

`escalated` is the field that matters: `false` means the same photos are being
re-attempted, `true` means the user has been moved somewhere else.

### After a failed build

The user lands back on the picker with their photos still there. What changes:

- **Photos the service rejected are deselected.** If the build frame carried
  `rejectedPhotos`, those ids are unselected and marked, and the user is told why
  on tapping one. **The mark is advice, not a lock** — tapping shows the reason
  and then selects the photo anyway. The service can be wrong, and a user left
  with nothing selectable has no way forward.
- **Photos claiming a role the build said was missing are deselected too.** If the
  frame carried `missingRoles`, every selected photo covering one of those roles
  is unselected and the coverage row empties with it, so the row cannot show a
  satisfied *Side* while the message says the set has no side photo. These are not
  marked — the service named a gap in the set and pointed at no photo — and can be
  picked straight back.
- **Successfully uploaded photos are not re-uploaded.** Their server ids are kept,
  so a second Build only uploads what is new. Photos never leave your app twice.
- **Nothing is cleared.** The selfie, the captures and the selection survive, so
  the user can adjust and retry rather than start over.

Everything above is cleared **only on a successful build** — the selection, the
selfie, the captured photos, the upload ids, the rejections. Your app is told to
clear too, via `GALLERY_RESET` and `GALLERY_CLEAR_CAPTURES`.

### What you should do

- Read `onMuseEnd`. It is the only signal that a build ended badly.
- `message` is written by the service and is already shown to the user — you do
  not need to display it again.
- `data` is the whole frame. Parse it if you want `rejectedPhotos` or
  `missingRoles`; ignore it otherwise.
- Do not tear down the WebView on `onError`. The user is still in the flow and can
  recover.

---

## Message contract

Both directions are JSON. Web to native goes through `swanBridge`; native to web
through `window.postMessage`.

> Send native to web with `callAsyncJavaScript` and an arguments dictionary, not
> a spliced string. U+2028 and U+2029 are legal in JSON but terminate a line in
> JavaScript source, so a spliced payload can throw a syntax error and vanish
> with no trace.

### Web sends

| Message | Payload | Your app must |
|---|---|---|
| `WEB_READY` | — | Reply `RENDER_COMPONENT` |
| `GALLERY_SCAN_START` | `{ referenceImage, referenceImages?, monthsBack, email? }` | Scan the window and stream results. `referenceImages` is the tapped frame plus up to two taken silently while the face fitted the oval, oldest first; pick the sharpest as the matching reference and ignore the rest. Absent from pages before 1.3.0 — use `referenceImage`. |
| `GALLERY_ANALYSE_PHOTO` | `{ assetId }` | Reply `onGalleryPhotoAnalysis` |
| `GALLERY_FULL_IMAGE` | `{ assetId }` | Reply `onGalleryFullImage`. One file per request — the page fetches, uploads and releases one at a time. An `assetId` ending `.mov` asks for a Live Photo's paired video |
| `GALLERY_THUMBNAILS` | `{ assetId }` | Reply `onGalleryThumbnails` |
| `GALLERY_CAPTURE_PHOTO` | `{ id, dataURI, shot }` | Hold in memory, reply `onGalleryPhotoAnalysis` with `captured: true` |
| `GALLERY_CLEAR_CAPTURES` | — | Drop every photo taken in this run |
| `GALLERY_PICK_MORE` | — | `presentLimitedLibraryPicker`, reply `onGalleryPickedMore` |
| `GALLERY_RESET` | — | Drop all per-run state |
| `OPEN_SETTINGS` | — | `UIApplication.open(settings URL)` |
| `SCHEME_TEST_RESULT` | `{ ok }` | Log only |
| `WEB_LOG` | `{ text }` | Print — the only console on device |

`referenceImage` is the selfie as a JPEG data URI. It is the match reference and
must not be stored or transmitted.

### `GALLERY_CAPTURE_PHOTO` — required for the "Take it now" flow

Sent when the user photographs a missing angle from the picker.

```json
{ "id": "cap_1", "dataURI": "data:image/jpeg;base64,…", "shot": "side" }
```

Your app must:

1. Hold the bytes **in memory only**. Do not write to the photo library — the
   user did not ask for these in their camera roll, and the reference host keeps
   them in a lock-guarded in-memory store capped at 12.
2. Analyse the image as you would a library photo.
3. Reply `onGalleryPhotoAnalysis` with the same `id` as `assetId`, plus
   **`captured: true`**.
4. Serve it afterwards from `GALLERY_THUMBNAILS` and `GALLERY_FULL_IMAGE` by that
   id, exactly like a `PHAsset`.

`shot` is what the user was asked for. It is **advisory** — your analysis decides
what the photo actually counts as, and the page will discard it if the two
disagree.

`GALLERY_CLEAR_CAPTURES` is separate from `GALLERY_RESET` on purpose: `RESET` is
also sent at the start of every scan, and a user who takes a photo and then asks
iOS for more library photos has to keep it.

### Your app sends

| Message | Payload |
|---|---|
| `RENDER_COMPONENT` | `{ componentName: "GalleryPick", props: { … } }` — see [Rendering the component](#rendering-the-component) |
| `onGalleryMatchFound` | `{ assetId, type, isFullBody, distance?, score?, scoreParts?, scorePenalties?, scoreFilter?, dupGroup?, done, total }` — `distance` is the host's match distance, lower is closer; `score` is the host's ranking of the photo for the Muse, higher is better, with clean faces at 0.5 and above and demoted ones below; `dupGroup` is shared by photos that repeat one shot. The picker pre-selects the top-ranked photo of each type, one per `dupGroup` unless every photo of a new shot scores under 0.5: by `score` when sent, else the closest by `distance`, else the newest. Analytics only, sent with `score`: `scoreParts` is each signal 0–1 (`quality`, `pose`, `light`, `size`, `mouth`, `eyes`, `brow`, `sharp`), `scorePenalties` lists what pulled the score down (`cap`, `tilted`, `closed smile`, `open smile`, `wide-eyed`, `mouth open`, `exposure`, `dressy`, `busy`; empty when none), and `scoreFilter` is what set it to 0 (for example `sunglasses`). The page adds them to the selection events. |
| `onGalleryScanProgress` | `{ done, total }` |
| `onGalleryScanComplete` | `{ assetIds, dropped?, limited?, denied?, error?, skipped?, summary? }` — `dropped` names matches the host withdrew once the whole pass was scored; the page removes those tiles if it ever showed them. A host holds borderline matches back rather than streaming them, so in practice `assetIds` only adds tiles, appended after the streamed ones, and `dropped` names ids the page never saw. Absent from hosts that predate it. `skipped` is `{ inCloud, cloudSelfies, cloudFullLength, cloudDownloaded, cloudLeft, noImage }`, counts of what the scan could not look at (photos only in iCloud, how many of those looked like a selfie or a full-length photo from their thumbnail, how many were downloaded in full after a small copy confirmed one person, how many were left by the cap or still downloading when the wait after the local scan ran out). `summary` is the scan's whole tally as numbers: photos examined, each gate's count (no face, group, other people, face too small, not full body, no match, sensitive, unusable face, too large), the matcher's name and cut-off, the closest rejected distance and near misses, matches by type, the selfie frames chosen from, and timings. Counts only, no ids. Both are reported to analytics only; nothing is shown to the user. |
| `onGalleryPhotoAnalysis` | `{ assetId, type, isFullBody, captured? }` |
| `onGalleryFullImage` | `{ id, dataURI, original, hasVideo? }` or `{ id, error }` |
| `onGalleryThumbnails` | `{ thumbs: [{ id, dataURI }] }` |
| `onGalleryPickedMore` | `{ added }` — only when the user actually shared more |

### `onGalleryPhotoAnalysis` — read this one carefully

Sent in reply to `GALLERY_ANALYSE_PHOTO` (user tapped a photo) and to
`GALLERY_CAPTURE_PHOTO` (user took one). It drives the coverage row and the Build
button.

```json
{ "assetId": "…/L0/001", "type": "front", "isFullBody": true }
```

| Field | Values | Effect |
|---|---|---|
| `type` | `"front"` \| `"side"` \| `"selfie"` \| `"unknown"` | Fills that coverage slot |

> **Send the same `type` and `isFullBody` on `onGalleryMatchFound`.** Your scan
> has already worked them out to decide the photo matched, and sending them lets
> the picker choose a starting selection without asking about every photo. Omit
> them and the flow still works — it falls back to asking on tap.
| `isFullBody` | `boolean` | **Required** for `front` and `side`. A selfie is exempt. |
| `captured` | `boolean` | `true` only in reply to `GALLERY_CAPTURE_PHOTO` |
| `otherPeople` | `boolean` | Optional. `true` when anyone besides the user is in the photo — **rejected**, whatever the other fields say. Absent means no |

A photo fills **exactly one** slot. The selection needs **1 selfie, 2 front and
2 side** before Build enables.

A reply of `type: "unknown"`, or `{ assetId, error }`, or `otherPeople: true`, or a
`front`/`side` without `isFullBody: true`, **deselects the photo** and tells the user why.

> Omitting `type` has the same effect as `"unknown"`. A host that replies only
> `{ assetId, isFullBody: true }` will have every photo rejected and the Build
> button will never enable.

> There is no `full_length` slot. Front and side shots must be full length
> already, so a separate marker would fill on the first pick and never mean
> anything. It is still sent to the server as a role.

### Scanning the window

A scan walks the **whole window** in one pass — every photo inside `monthsBack`,
newest first — and streams each match as it finds it. There is no cursor, no
early stop and no cap.

Streaming is what makes the wait bearable: the grid fills from the first match
rather than at the end, so the user starts choosing while the scan is still
running. Report progress with `onGalleryScanProgress` so the screen can show it.

**Under limited access, ignore the date window entirely.** PhotoKit only returns
the subset the user hand-picked, so the set is already bounded by their own
choice and a date range bounds nothing on top of it — all it does is discard
photos they went out of their way to share. Someone who shares forty shots, half
of them from a holiday two years ago, would otherwise have the scan look at the
recent handful, match nobody, and be sent to the camera with the rest never
opened.

**Send the analysis with the match.** `onGalleryMatchFound` takes `type`,
`isFullBody` and `distance` alongside the id, and the scan has already worked
all three out — the face-to-frame ratio, the yaw and the joint count come from
the match gates, the distance from the matcher. Sending them means the picker
knows what every photo is before anything is tapped, can pre-select the closest
photo of each type the moment the scan ends, and a tap never has to wait for
`GALLERY_ANALYSE_PHOTO` to answer. A match sent only in the final `assetIds`
has no verdict, so it is shown but never pre-selected.

**Caching pays for itself here.** The scan already computes everything
`GALLERY_ANALYSE_PHOTO` needs — the face observations, the face-to-frame ratio
and the joint count are all produced by the match gates. Storing the verdict per
asset id turns the later tap into a dictionary lookup instead of a second photo
load and two more Vision passes, and guarantees a photo counted as `side` while
deciding when to stop cannot come back `front` when the user taps it.

### Sending the original file

**Send the camera's own file — and nothing else.** The build service reads depth
and detail out of an original and gets neither from a re-encode. The loss is the
*decode*, not the scale: `PHImageManager` hands back a decoded bitmap, with the
file container, its EXIF and any depth auxiliary data already gone, so asking it
for original dimensions does not help. **There is no rendered fallback**: a photo
goes as its original or not at all.

`PHAssetResource` is the only route to the bytes:

```swift
PHAssetResource.assetResources(for: asset)          // .photo, and .pairedVideo for a Live Photo
PHAssetResourceManager.default().requestData(for:)  // streams the file
```

**Cap what you will carry, and abort mid-stream.** `requestData` delivers chunks;
keep a running total and cancel the read the moment it crosses your limit. A 75MB
ProRAW then costs the cap rather than the file. The reference host uses **10MB per
file**, measured separately for the still and its paired video.

> **What it costs in the page.** The cap is on *file* bytes; what crosses the
> bridge is base64, so a 10MB file is 13.3MB as a string, plus a ~10MB Blob while
> that string is still alive. The page fetches and releases **one photo at a
> time**, which is what keeps that peak to a single photo.

**Hide what cannot be sent, during the scan.** No public API gives a file's size
without reading it, so the reference host counts a matched photo's original as it
streams, keeping none of it, before the match reaches the grid:

- **On the phone:** counted from the local file. Over 10MB is hidden.
- **Only in iCloud:** downloaded just far enough to size it, with a 10s limit.
  That is the matched photos only, never the library.
- **Low Data Mode on** (`NWPath.isConstrained`): sized the same way; the
  `sizeOriginalsInLowDataMode` switch in the controller turns that off, which
  hides the photo instead.
- **Unreadable, or not downloaded in time:** hidden. With no fallback it could
  not be uploaded.

iOS may keep a downloaded original in the Photos library, as it does for any app
that opens one. It is not stored in your app, iOS clears it when it needs the
space, and the upload reads it again without a second download.

**Give the upload read a deadline.** The picked photos are read again with the
network allowed. The reference host waits 20s — inside the page's own 30s deadline —
then replies `{ id, error }`, and the page counts the photo as failed.

**Declare the real content type.** An original HEIC is `image/heic`, not
`image/jpeg`; the presigned PUT signs for whatever you say, so a wrong type fails
the upload. Set `original: true` on the reply. Only a photo taken inside the flow
is a JPEG with `original: false`.

### Live Photos — the paired video

**A Live Photo is two files.** iOS stores a HEIC still and a MOV video, and the
Photos framework hands them over as separate resources, so they upload as two
objects.

**Say so on the still's reply.** When the asset is a Live Photo, add
`hasVideo: true`. The page then asks for the second half in its own
`GALLERY_FULL_IMAGE` request, under the still's id plus `.mov`:

```
AD022AEB-AEF9-483C-B627-AAD7317C6B38/L0/001        ← the still
AD022AEB-AEF9-483C-B627-AAD7317C6B38/L0/001.mov    ← the paired video
```

**Strip the suffix to know which half is wanted.** A `PHAsset.localIdentifier` is
a UUID plus `/L0/001` — hyphens and slashes, never a dot — so a trailing `.mov`
is unambiguous. Read the `.pairedVideo` resource and reply with a
`data:video/quicktime;base64,…` URI.

**Two separate requests, on purpose.** A 3MB still and a 5MB video in one reply
would be 8MB alive at once, which is exactly what fetching one photo at a time
exists to avoid.

**The video is best-effort.** It is fetched and uploaded *after* every still is
safely up, it is never added to the build's `photoIds`, and a failure costs the
motion rather than the Muse. A video over the 10MB cap — rare, since they run
about 3 seconds and 2–5MB — is skipped and the still goes alone. The scan does not
size videos.

> **Worth saying out loud in your UI.** A Live Photo records 1.5 seconds either
> side of the shutter, **with audio**. That is materially more than "a photo", and
> a user who has been told nothing leaves the photo library has not agreed to it.

### `onGalleryScanComplete` error values

| Field | Meaning | User lands on |
|---|---|---|
| `error: "no-face-in-selfie"` | No face in the reference | Selfie screen, retake |
| `error: "several-faces-in-selfie"` | Another person in the selfie, at least a quarter the size of the main face | Selfie screen, retake |
| `error: "selfie-not-frontal"` | Head turned more than 20° or tilted more than 15° (25° before 1.3.4) | Selfie screen, retake |
| `error: "no-reference"` | Reference could not be decoded | Selfie screen |
| `denied: true` | Photo library access refused | A screen of its own, with *Open Settings* |
| `limited: true` | Only selected photos shared | Picker, with an *Add more photos* button that sends `GALLERY_PICK_MORE` |
| `assetIds: []` | Scan ran, found nothing | Camera fallback |

`candidates` is the set of photos that were eligible but did not match. Send it
if you have it; it is not required.

---

## Previewing a screen

Sometimes you want to *look* at a screen — a design review, a demo, a screenshot
— without a photo library, a token or a real scan.

```swift
"props": ["isSuccess": true]          // the finished-Muse screen
"props": ["isError": true]            // the failure screen
"props": ["previewPhase": "height"]   // any one screen

// the camera-blocked overlay, on whichever camera screen you preview
"props": ["previewPhase": "cameraBlocked", "previewCameraBlocked": "busy"]
```

The same two flags BodyScan and FaceScan take, so a host that knows one knows all
three. `previewPhase` reaches the screens those two cannot, and wins if both are
given:

`intro` · `gender` · `height` · `libraryBlocked` · `cameraBlocked` · `results` ·
`building` · `failed` · `preview`

This is a shorter list than the flow's own screens, on purpose — **nothing in it
opens a camera, reaches your app, or needs data of its own.** `selfie`, `capture`
and `topup` are left out because they start a live stream, and `topup` renders
nothing anyway since nothing tells it which shot to ask for; `searching` is a
progress bar with no progress behind it; and `complete` draws the same picker as
`results`.

While any of them is set:

- **No message reaches your app** — nothing asks you to scan a library for a
  screenshot.
- **No analytics are recorded**, including the page view. A review does not enter
  the funnel.
- **`userDetails` and `token` are not needed.**
- Buttons that would navigate to a screen built from data a preview does not have
  — *Done* on the preview, *Retry* on the failure screen — fire your callback and
  leave the screen where it is. Everything else behaves: the ruler drags.

`isSuccess` with no Muse shows the carousel's placeholder slides, which is the
screen as a shopper sees it mid-load.

### The camera-blocked screen

`cameraBlocked` is the one entry that is not a phase of the flow — in a real run
the overlay sits *over* the camera screen rather than replacing it. Asked for
here it draws that screen with the overlay forced and **no camera opened**.

`previewCameraBlocked` picks which of the three messages in `cameraBlockedPage`
to show, and defaults to `"denied"`:

```swift
"props": ["previewPhase": "cameraBlocked"]                              // denied
"props": ["previewPhase": "cameraBlocked", "previewCameraBlocked": "busy"]
"props": ["previewPhase": "cameraBlocked", "previewCameraBlocked": "unknown"]
```

`building` and `failed` draw placeholder cards when there are no photos behind
them, so both render on their own.

---

## Forcing a build result

The build service can be asked for a named answer instead of the one your photos
would really produce:

```swift
"props": ["mockScenario": "reject_all"]
```

| Value | What the build answers |
|---|---|
| `success` | A finished Muse |
| `fail_final` | The build failed |
| `reject_all` | Every photo refused, with a reason each |
| `missing_side` | The set is short a side shot |

**Omit the field** and the service uses its own default: it reads the roles the
photos registered with and answers `missing_side` when none claims `side`,
`success` otherwise. That is the only correct setting for a shipped build.

Unlike the preview props, this **runs the real flow** — a real scan, real photos,
a real upload. Only the build's answer is faked. That is the only way to reach
the failure screens, which are otherwise unreachable on demand.

> **Not for production.** Left set, every Muse your users build returns a canned
> result. Omit it and the field is left off the request entirely, which is the
> only correct setting for a shipped build.

`missing_side` deliberately shows a **generic** failure. The service names a gap
in the set rather than a photo, so there is nothing to mark on screen — the user
sees the service's own message. Not a bug.

---

## Theming

`config` carries both the look and the wording. Everything in it is optional —
anything you leave out keeps the gallery's own styling.

```json
{
  "style": {
    "base": {
      "backgroundColor": "#FFF8F0",
      "baseTextColor": "#101828",
      "baseFontFamily": "Georgia, serif",
      "baseFontSize": "17px",
      "brandColor": "#E5006D",
      "primaryColor": "#00A37A",
      "secondaryColor": "#E3D5C8"
    },
    "heading":    { "headingColor": "#101828", "headingFontFamily": "…", "headingFontSize": "26px", "headingFontWeight": "700" },
    "subheading": { "subheadingColor": "#475467", "subheadingFontFamily": "…", "subheadingFontSize": "13px", "subheadingFontWeight": "500" },
    "button":     { "buttonBackground": "#101828", "buttonTextColor": "#FFFFFF", "buttonFontSize": "15px",
                    "buttonFontFamily": "…", "buttonBorderRadius": "14px",
                    "buttonDisabledBackground": "#B0A6C4", "buttonDisabledTextColor": "#FFF3F8" }
  },
  "logo": "https://…/logo.svg",
  "appName": "H&M",
  "content": { "galleryPick": { … } }
}
```

| Key | Effect |
|---|---|
| `style.base` | Page background, body text, the base font, and the three brand colours |
| `style.heading` / `style.subheading` | The two text levels on every screen |
| `style.button` | Primary buttons, including their **disabled** state — the Build button spends most of its life disabled, so set those two |
| `logo` | Shown in the flow's header |
| `appName` | Used in the camera-permission instructions: *Settings › {appName} › Camera*. Defaults to "this app" |
| `content` | Wording — see below |

Values are CSS strings, passed through as-is. `"16px"` works; `16` does not.

The same `style` object is understood by the other Swan components, so one theme
covers the whole SDK.

---

## Customising the text

Every user-visible string can be replaced through `config.content.galleryPick`,
grouped by the screen it appears on. Send one group, one name, or nothing —
anything you leave out keeps its default, so a partial override is always safe.

```json
{
  "content": {
    "galleryPick": {
      "introPage":   { "headingTitle": "Create your Muse.", "buttonText": "Start" },
      "pickerPage":  { "buttonText": "Build my Muse", "takePhotoButtonText": "Take it now" }
    }
  }
}
```

The groups, in the order the user meets them:

| Group | Screen |
|---|---|
| `common` | Buttons and notes shared across screens |
| `introPage` | The "Create your Muse" screen that opens the flow |
| `genderPage` | Which body to build |
| `heightPage` | The ruler |
| `selfiePage` | The reference selfie |
| `searchingPage` | Shown while your app scans |
| `pickerPage` | The photo grid |
| `capturePage` | The five-shot camera fallback |
| `topUpPage` | The single "Take it now" shot |
| `buildingPage` | Shown while the Muse builds |
| `previewPage` | The finished carousel |
| `failedPage` | Upload interrupted, and build failed |
| `libraryBlockedPage` | Photo access refused |
| `cameraBlockedPage` | Camera unavailable |

A misspelled group or name is **ignored silently** — the default renders and
nothing indicates why. The component logs
`[GalleryPick] Unknown content name "…" — ignored.` to the web console for
exactly this case, which on device reaches you through `WEB_LOG`.

Structural labels (the coverage chips, height units), live counters and anything
the backend writes are not overridable.

---

## Sensitive content filtering

Matched photos are screened on-device with Apple's
[SensitiveContentAnalysis](https://developer.apple.com/documentation/sensitivecontentanalysis)
framework before their ids are sent to the web layer. A photo the classifier
flags is never streamed, never appears in the grid, and is not included in the
completion message.

This is implemented in the reference host — see `isSensitiveContent(_:)` in
`ViewController.swift`. **You must add the entitlement below for it to do
anything.**

**This is best-effort and cannot be relied upon.** It runs only when *all* of the
following hold:

1. **iOS 17.0 or later.** Older devices are not filtered.
2. **The `com.apple.developer.sensitivecontentanalysis.client` entitlement**
   (Xcode capability: *Sensitive Content Analysis*) is on your app. The Swan SDK
   cannot add this for you.
3. **The user has Sensitive Content Warning enabled** in
   Settings › Privacy & Security. This is **off by default** on adult accounts,
   and there is no API to request it or prompt for it.

When any of these is missing, `SCSensitivityAnalyzer().analysisPolicy` returns
`.disabled` and **no photo is filtered** — silently, with no error anywhere.

The reference host prints the policy at the start of every scan so you can tell
a clean library from an inactive filter. On the first run, look for one of:

```
🚫 sensitivity filter: on (simpleInterventions)
🚫 sensitivity filter: OFF — no entitlement, or Sensitive Content Warning is off in Settings
🚫 sensitivity filter: OFF (needs iOS 17)
```

The scan summary then reports how many photos it removed:

```
no match    41
sensitive   2   (matched, then filtered)
MATCHED     9
```

Read those two together. `sensitive 0` with the filter `on` means a clean
library; `sensitive 0` with the filter `OFF` means nothing was checked.

### Behaviour

| Analyser result | Photo |
|---|---|
| Sensitive | **Skipped** |
| Not sensitive | Shown |
| Threw an error | Shown |
| Unavailable (see above) | Shown |

Only an explicit positive removes a photo. Everything else — an analysis that
failed, an unentitled app, an older device, a user who never turned the setting
on — lets the photo through. The rule is deliberately fail-open: the check is
best-effort, and a filter that empties the grid whenever it cannot run is worse
than no filter at all. The cost is that a photo whose analysis errors is shown
unfiltered.

The check runs **after** a photo has matched, not before — a handful of
classifier passes per scan rather than one for every asset in the library. A
rejected photo is also kept out of the `candidates` list on
`onGalleryScanComplete`, so it cannot return through that route.

The user is not told a photo was removed. There is no message and no placeholder
tile; the photo simply is not there.

If filtering must be guaranteed rather than best-effort, it has to happen
somewhere you control — server-side during the Muse build, or with a bundled
model.

---

## Known limitations

**Matching accuracy.** Identity matching uses `VNGenerateImageFeaturePrint`,
which is a general image-similarity descriptor rather than a face-identity
embedding. It partly encodes lighting, hair and background, so photos of other
people can appear in the results. Measured AUC on a labelled set was 0.64
(0.50 is chance). The eligibility gates — one face, minimum face size, lower body
visible — do most of the filtering; the distance threshold does comparatively
little. The selfie guide and the host's own selfie checks (one face, frontal)
keep the reference sharp, which moves every score in the right direction. A
bundled CoreML face-identity model is the fix, and is not yet included.

**iCloud-only photos.** The scan does not download the library. For a photo whose
full version is only in iCloud, the phone keeps a 120px thumbnail; when that
thumbnail shows one face filling the frame, or one person standing tall in the
frame, the photo is a candidate. A 30KB copy is fetched first to confirm one
person; then the photo itself, 1536px for a selfie or 2560px for a standing
shot, and it is scanned like any other photo. Downloads run during the local
pass, six at a time, up to 200 per scan on Wi-Fi or 100 on mobile data, Low
Data Mode included; the scan waits 30s after the local pass for the rest, and up
to 90s while a photo the small copy confirmed is still coming down. Every other
iCloud-only photo is skipped. All of it is counted and logged.

**Limited photo access.** If the user shares only selected photos, only those are
scanned. A small result count is expected, not a fault.

**Camera fallback photos stay in the page.** The five photos from the *no
matches* fallback are never sent to the host, and `onCaptureComplete` carries
generated ids only. This is **not** true of "Take it now" photos, which do cross
to the host via `GALLERY_CAPTURE_PHOTO` — in memory, never to the library.

**Captured photos do not survive the app.** The in-memory store is cleared on
`GALLERY_CLEAR_CAPTURES` and on deallocation. A backgrounded app whose web
content process is killed loses them, and the user has to retake.

**Orphaned uploads.** Photos uploaded for a build that then fails are not
deleted server-side; there is no delete endpoint yet.

---

## Versions and release notes

Every release has its own address, for example
`https://swan-mobile-web-component.swan.so/v1.1.0/index.html`.

- **A published version never changes.** An app pointed at `/v1.1.0/index.html`
  keeps getting exactly that release until you point it at a newer one.
- **`https://swan-mobile-web-component.swan.so/` always serves the latest
  release.**
- **To pin a version, set `sdkURL` in `ViewController.swift`:**

  ```swift
  let sdkURL = URL(string: "https://swan-mobile-web-component.swan.so/v1.1.0/index.html")!
  ```

- **The page reports its version** in the `WEB_READY` message (`version`), and the
  reference host logs it.
- **Each release says whether `ViewController.swift` needs updating.**

### 1.3.6 — 28 October 2026

**Controller:** no update needed. Page fixes only.

**Flow**

- Pre-selection still takes one photo per shot, but when every photo of a new
  shot for a slot scores under 0.5, the best photo left fills it even if it
  repeats a shot already picked (`PRESELECT_REPEAT_BELOW`).
- Fixed: the matches the controller holds back until the end of the scan are
  now ranked with the rest and considered for the picks. They used to sit at
  the bottom of the grid unsorted and were never pre-selected.

### 1.3.5 — 28 October 2026

**Controller:** update recommended. Older controllers keep working; without
the update, a second scan takes as long as the first, iCloud downloads on
mobile data keep the 20 s limit, and the score breakdown is not sent. The
full list is in `CHANGELOG.md`.

**Flow**

- Each grid tile shows the host's score (0–1) in its corner, the number the
  grid order and the pre-selection follow, so the ranking can be reviewed on
  the phone. Behind `SHOW_SCORE_BADGE` in `galleryConstants.ts`, on in this
  release.
- The controller keeps what it learned about each photo between scans, on the
  phone only (new file `ScanStore.swift`): a second scan for the same account
  counts the known photos without loading them, compares the new selfie with
  the stored face vectors, and loads only a possible match. Same results, a
  fraction of the time, and an iCloud photo is downloaded once in its life.
  The file is private to the app, excluded from backups and deleted when
  another account signs in. Details in `GALLERY_PICK_IOS_CONTROLLER.md`.
- Each iCloud download is given 30 s on mobile data; 20 s on Wi-Fi as before.

**Setup**

- `summary` gains `storeDecided` (photos counted from an earlier scan without
  loading), `storeCloudSkipped` (iCloud photos skipped on an earlier verdict),
  `storeWritten` and `storeRecords` (records written this scan, and held);
  absent when the store is off.
- `onGalleryMatchFound` gains `scoreParts`, `scorePenalties` and
  `scoreFilter`, the breakdown behind `score` (see the message table).
- `photo_selected` and `photo_deselected` gain `type`, `distance`, `score` and
  `rank`; `photo_deselected` also `auto`. `selection_confirmed` gains
  `photos`, one entry per chosen photo with the same fields and `auto`. The
  score breakdown is added to the same events. A field is left out when the
  controller did not send it.

### 1.3.4 — 27 October 2026

**Controller:** update recommended. Older controllers keep working; without
the update, iCloud photos with a small face are matched on too small a copy,
the flat-face ranking does not apply, and the new fields are not sent. The
full list is in `CHANGELOG.md`.

**Flow**

- Library selfies with the head pitched more than 15° or turned more than 20°
  rank below every level selfie; never hidden. Fronts and sides unchanged.
- The camera selfie is sent back (`selfie-not-frontal`) from 15° of tilt,
  was 25°.
- iCloud photos are fetched at the scan's own size, a bigger copy only when
  the face would be too small; three downloads at a time on mobile data, six
  on Wi-Fi, each given 20 s. A matched iCloud photo whose original is too
  slow to size is shown when its pixel count rules out the 10MB cap.

**Setup**

- `summary`, and `scan_complete` as separate properties, gain
  `cloudFirstDownloadedDate`, `cloudLastDownloadedDate` (capture dates,
  `yyyy-MM-dd`), `cloudFirstDownloadedAtMs`, `cloudLastDownloadedAtMs` (ms from
  the start of the scan), and `matchedFirstDate`, `matchedLastDate` (newest and
  oldest match).
- `summary` gains `tilted`, `sizedByPixels`, `cloudParallel`, and
  `cloudFailures` (iCloud download failures by reason: `diskFull`,
  `timedOut`, `other`; absent when none failed).

### 1.3.3 — 23 October 2026

**Controller:** update recommended. The 1.3.2 `ViewController.swift` still
works; without the update, photos saved from other apps or taken with Live
Photos off are not scanned, and the wider iCloud pass does not apply. The full
list is in `CHANGELOG.md`.

**Flow**

- Every photo in the window is scanned except real screenshots. The 1.3.2
  controller dropped every photo without a Live, HDR or depth flag.
- iCloud: up to 200 photos on Wi-Fi, 100 on mobile data, Low Data Mode
  included; the wait after the local pass runs to 90 seconds while confirmed
  photos are still coming down; each download gets 20 seconds.
- No match: the camera takes five photos (two front, two side, one selfie), the
  same set as the picker, instead of three. The text depends on photo access.

**Setup**

- `summary` gains `cloudWaitMs`. New text keys `capturePage.limitedHeadingTitle`
  and `capturePage.limitedSubHeadingTitle`.

### 1.3.2 — 22 October 2026

**Controller:** update recommended. The 1.3.0 and 1.3.1 `ViewController.swift`
still work; without the update, photos that are only in iCloud are not searched
and the sign-in screen does not wait for the page. The full list is in
`CHANGELOG.md`.

**Flow**

- Photos that are only in iCloud are searched: a small copy confirms one person,
  then the photo is fetched and matched like a local one, within a cap and a
  30 second wait after the local pass.
- The selfie guide runs on the CPU (wasm): no first-run shader compile.

**Setup**

- `onGalleryScanComplete` `skipped` gains `cloudFullLength`; `summary` gains
  `cloudPreviewOut`, `cloudLargerDownloads`, `cloudOnMobile`, `frameQualities`,
  `blendSpread`, `blendShift`, `memoryPeakMB`.

### 1.3.1 — 22 October 2026

**Controller:** no update needed.

**Flow**

- The three photos taken in the flow, and "Take it now", get a front/rear camera
  switch. Muse builds wait up to 10 minutes.

**Setup**

- New text keys: `searchingPage.progressPreText`, `progressPostText`,
  `pickerPage.scanningStatusPostText` — see `GALLERY_PICK_TEXT_CONFIG.md`.

### 1.3.0 — 22 October 2026

**Controller:** update recommended. The 1.2.0 `ViewController.swift` still works;
without the update the selfie checks, the face matching and the ranking below do
not run. The full list, and the files to add, are in `CHANGELOG.md`.

**Flow**

- The selfie screen guides the shot: an oval over the preview with one hint at a
  time, green when the face fits, and the button enables only then. In a dark
  room the screen flashes white as the photo is taken. If the guide cannot
  start, the plain camera is shown and the button enables anyway.
- After the shot, the controller sends the selfie back for a retake when it is
  not one face looking at the camera, or too blurred to match from, with the
  reason shown on the selfie screen.
- Photos are matched on the face with a model on the phone, scored for the
  Muse, and the best of each type is pre-selected when the scan ends. Repeated
  shots are pre-selected once. Photos with sunglasses, a hand over the face or
  closed eyes are left out; caps, smiles, wide eyes and open mouths rank lower.
- Results keep the order they were found in, newest first; nothing moves when
  the scan finishes.
- Three selfie frames reach the controller — two taken silently while the face
  fitted the oval, plus the tapped one — and it matches against the sharpest.
  New `GALLERY_SCAN_START` field `referenceImages`.

**Setup**

- New `selfiePage` text keys for the guide hints and the retake reasons — see
  `GALLERY_PICK_TEXT_CONFIG.md`.
- New `onGalleryScanComplete` errors: `several-faces-in-selfie`,
  `selfie-not-frontal`, `selfie-too-blurry`.
- `onGalleryMatchFound` gains `distance`, `score` and `dupGroup`;
  `onGalleryScanComplete` gains `dropped` and `summary`.

### 1.2.0 — 7 October 2026

**Controller:** no update needed. The 1.1.0 `ViewController.swift` works as it
is; to pin this release, point `sdkURL` at `/v1.2.0/index.html`.

**Flow**

- Gallery Pick opens on the "Create your Muse" screen, with Start leading into
  the flow.

### 1.1.0 — 7 October 2026

**Controller:** update to the 1.1.0 `ViewController.swift` to send original
photos and Live Photos. The 1.0.0 controller also works with this release.

**Photos**

- **Original files.** Photos are uploaded as the original files from the
  library, not re-encoded copies. A photo whose original is over 10MB is not
  shown in the results.
- **Live Photos.** The motion is sent alongside the photo. Until our servers
  accept the video format, the photo uploads on its own and the Muse builds as
  normal.
- **One photo at a time.** Each photo uploads on its own, and `onUploadEnd`
  fires after every file, including failures.

**Matching (controller)**

- Photos with anyone else in them are left out. People far in the background
  don't count.
- A selfie is judged the same way whether the phone was held upright or
  sideways.
- Full-length photos must show the whole body, head to toe.
- Front and side photos are told apart by body position, so a side-on body with
  the face turned to the camera counts as a side photo.
- Photos stored only in iCloud are searched when their thumbnail looks like a
  selfie: a small copy is downloaded over Wi-Fi, at most 40 per scan, and put
  through the same checks. Full-length photos only in iCloud are not searched.
  Not in Low Data Mode.
- **Requires iOS 17 or later.**

**Setup**

- **`token` and `userDetails` are required.** `userDetails` must include `email`
  and `shopDomain`. Without them nothing uploads, and Build reports an `onError`
  with stage `config`.

### 1.0.0

The release live before versioning began.

---

## Support

| | |
|---|---|
| Reference host | `native-samples/ios/ViewController.swift` — a complete, working implementation of every message in this document |
| Full list of text keys | `GALLERY_PICK_TEXT_CONFIG.md` |

The reference host is the answer to most questions here. If a payload shape in
this document is ambiguous, that file is what the component was tested against.
