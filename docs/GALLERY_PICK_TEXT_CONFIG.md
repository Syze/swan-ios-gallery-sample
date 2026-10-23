# GalleryPick — Text Configuration

**Status:** Implemented. Types check, package builds, resolver tested.
**Applies to:** the `GalleryPick` component only. Nothing else changes.

Defaults live in `src/components/galleryPick/galleryCopy.ts`; screens read them through
`useCopy()` in `GalleryCopyContext.tsx`.

---

## 1. The idea

Every page's text lives under that page's name. You change what you want, ignore the rest.

```js
config.content.galleryPick = {
  introPage: {
    headingTitle:    "Create your Acme twin.",
    subHeadingTitle: "Take a selfie and pick a few photos.",
    buttonText:      "Get started",
  },
  previewPage: {
    headingTitle: "Your twin is ready.",
  },
}
```

That's it. **77 names**: 69 across the 14 pages, plus 8 shared buttons and notes. Two of the 69 are optional overrides for generated headings (see §4).

**Every value is plain text.** No codes, no placeholders, no formatting rules.

---

## 2. The shape at a glance

```js
{
  content: {
    galleryPick: {

      common:             { …}   // buttons & notes that appear on many pages
      landingPage:        { …}   // the first screen: one button
      introPage:          { …}   // the drawer that introduces the flow
      genderPage:         { …}   // shown only when the host sends no gender
      heightPage:         { …}
      selfiePage:         { …}
      searchingPage:      { …}
      pickerPage:         { …}   // the main photo-picking screen
      capturePage:        { …}   // "take 5 photos" fallback
      topUpPage:          { …}   // take 1 photo for a missing angle
      buildingPage:       { …}
      previewPage:        { …}
      failedPage:         { …}
      libraryBlockedPage: { …}
      cameraBlockedPage:  { …}
    }
  }
}
```

**The names mean the same thing on every page**, so once you've learned one you've learned all:

| Name | What it is |
|---|---|
| `headingTitle` | The big heading at the top |
| `subHeadingTitle` | The smaller line under it |
| `bodyText` | A paragraph in the middle of the page |
| `buttonText` | The main button |
| `captionText` | Text over the camera preview |
| `footerText` | The small grey line at the bottom |

---

## 3. Quick start

### React

```tsx
<GalleryPick
  token={sessionToken}
  config={{
    content: {
      galleryPick: {
        introPage:  { headingTitle: "Create your Acme twin.", buttonText: "Get started" },
        pickerPage: { buttonText: "Build my twin" },
      },
    },
  }}
  onComplete={handleComplete}
/>
```

### Native app (iOS / Android / React Native)

Nothing new to wire up — it travels inside the `config` you already send:

```json
{
  "type": "RENDER_COMPONENT",
  "componentName": "GalleryPick",
  "props": {
    "config": {
      "content": {
        "galleryPick": {
          "introPage": { "headingTitle": "Create your Acme twin." },
          "pickerPage": { "buttonText": "Build my twin" }
        }
      }
    }
  }
}
```

**Three rules, and that's all of them:**

1. Send only what you're changing. Everything else keeps its current text.
2. Names are case-sensitive — `buttonText`, not `buttontext`.
3. `""` hides a line. Leaving a name out keeps the default.

---

## 4. Every page

---

### `common` — appears on many pages

Change once, changes everywhere.

| Name | Current text |
|---|---|
| `poweredBy` | Powered by Swan |
| `privacyNote` | Nothing leaves your phone until you approve it. |
| `notUploadedNote` | Your photos haven't been uploaded. |
| `keepAppOpenNote` | Keep the app open while this runs. |
| `tryAgainButton` | Try again |
| `retryButton` | Retry |
| `openSettingsButton` | Open Settings |
| `cameraStartingButton` | Starting camera… |
| `switchCameraText` | Switch camera |

---

### `landingPage`

The first screen: the Muse picture with one button over it. Tapping the
button slides the intro drawer up.

| Name | Current text |
|---|---|
| `buttonText` | Discover on you |

---

### `introPage`

The drawer that slides up over the landing screen.

```
┌───────────────────────────┐
│ ┌───────────────────────┐ │
│ │ Create your Muse.  ←──┼─┼── headingTitle
│ │ Take a selfie & ... ←─┼─┼── subHeadingTitle
│ │ [      Start      ] ←─┼─┼── buttonText
│ │ About a minute. ... ←─┼─┼── footerText
│ └───────────────────────┘ │
└───────────────────────────┘
```

| Name | Current text |
|---|---|
| `headingTitle` | Create your Muse. |
| `subHeadingTitle` | Take a selfie & pick a few photos. We measure you & build your twin. Then see anything, in your size, on you. |
| `buttonText` | Start |
| `footerText` | About a minute. Nothing leaves your phone until you approve it. |

---

### `genderPage`

Shown only when the host's `userDetails.gender` is missing or not `"male"` /
`"female"`. With a usable value the screen is skipped, the same way a height
inside the range skips the ruler. Continue stays disabled until one option is
chosen.

```
┌───────────────────────────┐
│ Where do you shop?     ←──┼── headingTitle
│ It sets the body we... ←──┼── subHeadingTitle
│ [     Womenswear     ] ←──┼── womensButton
│ [      Menswear      ] ←──┼── mensButton
│ [      Continue      ] ←──┼── buttonText
│ Nothing leaves your... ←──┼── common.privacyNote
└───────────────────────────┘
```

| Name | Current text |
|---|---|
| `headingTitle` | Where do you shop? |
| `subHeadingTitle` | It sets the body we build your Muse from. |
| `womensButton` | Womenswear |
| `mensButton` | Menswear |
| `buttonText` | Continue |

The two option labels are content, not fixed: a brand that words its
categories differently can change them. The value sent to the build is the
same either way.

---

### `heightPage`

```
┌───────────────────────────┐
│ How tall are you?      ←──┼── headingTitle
│ It anchors the meas... ←──┼── subHeadingTitle
│        172 cm             │
│   ▏▎▍▌▋▊▉█▉▊▋▌▍▎▏      │
│ [Centimetres][Feet & in]  │  (not editable — see §5)
│ [      Continue      ] ←──┼── buttonText
│ Nothing leaves your... ←──┼── common.privacyNote
└───────────────────────────┘
```

| Name | Current text |
|---|---|
| `headingTitle` | How tall are you? |
| `subHeadingTitle` | It anchors the measurements we take from your photos. |
| `buttonText` | Continue |

---

### `selfiePage`

```
┌───────────────────────────┐
│ First, a quick selfie. ←──┼── headingTitle
│ It stays on your phone.←──┼── subHeadingTitle
│ ┌───────────────────────┐ │
│ │ Move closer        ←──┼─┼── guide* (one at a time, over the oval)
│ │     ╭─────╮           │ │
│ │     │     │           │ │
│ │     ╰─────╯           │ │
│ │ Position your face ←──┼─┼── captionText (no guide)
│ └───────────────────────┘ │
│ [   Use this photo   ] ←──┼── buttonText
│ Your selfie is used... ←──┼── footerText
│ Next, your phone will..←──┼── permissionText
└───────────────────────────┘
```

The preview carries a face guide: an oval, dimmed outside, with one hint at a
time above it. The outline turns green and the button enables when the face sits
inside the oval. While the guide loads, `guidePreparingCaption` shows under the
preview; if it cannot start, `guideUnavailableCaption` shows instead and the
button enables anyway. `captionText` is the plain caption when the guide is off.

In a dark room the mask around the oval turns white to light the face, and
`guideLowLight` replaces the framing hints until the face fits.

When the host sends a selfie back — no face, more than one person, or not
looking at the camera — the user returns to this screen with the matching
`retake*` text as a notice.

| Name | Current text |
|---|---|
| `headingTitle` | First, a quick selfie. |
| `subHeadingTitle` | It stays on your phone. It only checks that the photos you pick are of you. |
| `buttonText` | Use this photo |
| `captionText` | Position your face in the frame |
| `footerText` | Your selfie is used only to find your photos. |
| `permissionText` | Next, your phone will ask about photo access. Allow Full Access so we can find your pictures — nothing leaves your phone until you approve it. |
| `guidePreparingCaption` | Preparing face guide… |
| `guideUnavailableCaption` | Position your face in the frame and look straight at the camera |
| `guidePosition` | Position your whole face inside the oval |
| `guideLowLight` | Not enough light. Turn towards a lamp or window. |
| `guideCloser` | Move closer |
| `guideFarther` | Move farther away |
| `guideCenter` | Move your face to the center |
| `guideFitWholeFace` | Fit your whole face inside the oval |
| `guidePerfect` | Perfect! Hold still |
| `retakeNoFace` | We couldn’t see a face in that photo. Try again in better light. |
| `retakeSeveralFaces` | Only you should be in the selfie. Try again on your own. |
| `retakeNotFrontal` | Look straight at the camera and try again. |
| `retakeBlurry` | That one came out blurred. Hold still and try again. |

---

### `searchingPage`

| Name | Current text |
|---|---|
| `headingTitle` | Finding your photos. |
| `subHeadingTitle` | We're looking for photos of you. This happens on your phone. |
| `progressPreText` | Looking through your photos… |
| `progressPostText` | (empty) |

The progress line reads `progressPreText 13 of 1567 progressPostText`. The count and
its `of` come from the scan and stay as they are; an empty piece leaves no extra space.

> The footer line comes from `common.keepAppOpenNote` — the picker shows the same line
> while a scan is still running, so it is shared rather than owned by this page.

---

### `pickerPage` — the main screen

```
┌───────────────────────────┐
│ Pick at least 5 photo..←──┼── headingTitle (optional)
│ Albums › People & Pets ←──┼── subHeadingTitle
│ ┌───────────────────────┐ │
│ │Selfie│Front 1/2│Side..│ │  (not editable — see §5)
│ └───────────────────────┘ │
│ ▣ ▣ ▣                     │
│ ▣ ▣ ▣  (your photos)      │
│ [  Load more photos   ]←──┼── loadMoreButtonText / loadingMoreButtonText
│ ───────────────────────── │
│ [   Build my Muse     ]←──┼── buttonText
│ Front and side must... ←──┼── (not editable — see §5)
└───────────────────────────┘
```

| Name | Current text |
|---|---|
| `subHeadingTitle` | Albums › People & Pets has all your photos of you in one place. |
| `buttonText` | Build my Muse |
| `takePhotoButtonText` | Take it now |
| `loadMoreButtonText` | Load more photos |
| `loadingMoreButtonText` | Looking… |
| `scanningHeadingTitle` | Finding your photos. |
| `scanningSubHeadingTitle` | Picking opens once the search is done. |
| `scanningStatusText` | Still looking for more photos of you… |
| `scanningStatusPostText` | (empty) |
| `limitReachedText` | That's as many photos as we can take. |
| `picksChoosingTitle` | Picking for you… |
| `picksTitle` | Picked for you |

`loadMoreButtonText` is one label for one idea, get me more photos: behind it
the flow either reopens the system picker or searches further back, and
`loadingMoreButtonText` replaces it while that runs. The two `picks*` titles sit
over the pre-selection row, which is switched off in the current build, so they
are accepted but not shown.

**One extra name, with no fixed default:**

| Name | Behaviour |
|---|---|
| `headingTitle` | Leave it out and the page keeps its current wording, `Pick at least 5 photos of you.`, with the number filled in from the real minimum. Set it and your sentence is shown exactly as written. |

**While the photo search is still running**, this page shows different text — the grid
fills in as matches are found, so the picker appears before the scan has finished. That
is what the three `scanning*` names above are for.

---

### `capturePage` — "take 5 photos" fallback

Shown when the photo search found nothing usable.

| Name | Current text |
|---|---|
| `headingTitle` | We need a few more photos. |
| `subHeadingTitle` | We couldn't find enough clear, full-length photos of you. Take the rest now. |
| `buttonText` | Take new photos |
| `countingButtonText` | Get into position… |
| `limitedHeadingTitle` | These don't match your selfie. |
| `limitedSubHeadingTitle` | Choose different photos of you, or take new ones now. |

The two `limited*` names are shown instead of the heading and subheading when the
user gave the app limited photo access. `buttonText` is also the button on the
**Take it now** screen.

---

### `topUpPage` — one photo for one missing angle

Reached from the picker's **Take it now** button.

| Name | Current text |
|---|---|
| `subHeadingTitle` | Prop your phone up and stand back so we can see your feet. |
| `subHeadingTitleSelfie` | Hold the phone up and look at the camera. |

**One extra name, with no fixed default:**

| Name | Behaviour |
|---|---|
| `headingTitle` | Leave it out and the page keeps its current wording, `One more — a side photo.`, naming the angle it needs. Set it and your sentence is shown exactly as written, for every angle. |

> Two subheadings because a selfie needs different instructions from a full-length shot.
> The heading is the same for both.

---

### `buildingPage`

| Name | Current text |
|---|---|
| `headingTitle` | Creating your Muse. |
| `subHeadingTitle` | A measurement-accurate twin of you, built from these photos. Keep the app open while your photos upload. |

---

### `previewPage`

```
┌───────────────────────────┐
│ ┌───────────────────────┐ │
│ │   (your Muse image)   │ │
│ │ ┌───────────────────┐ │ │
│ │ │Your Muse is ready.┼─┼─┼── headingTitle
│ │ │Discover what you..┼─┼─┼── subHeadingTitle
│ │ └───────────────────┘ │ │
│ └───────────────────────┘ │
│ [       Done        ]  ←──┼── buttonText
└───────────────────────────┘
```

| Name | Current text |
|---|---|
| `headingTitle` | Your Muse is ready. |
| `subHeadingTitle` | Discover what you love by adding from trending or pasting a product link |
| `buttonText` | Done |

---

### `failedPage`

Two different problems share this page.

| Name | Current text |
|---|---|
| `pausedHeadingTitle` | Paused. |
| `pausedSubHeadingTitle` | Upload interrupted. We'll pick up where it stopped. |
| `unusableText` | Some photos wouldn't load. Picking different ones usually helps. |
| `failedHeadingTitle` | We couldn't finish. |
| `failedSubHeadingTitle` | Something went wrong building your Muse. Your photos are safe. |

The first three cover **photos that wouldn't upload** — `pausedSubHeadingTitle` on the
first failure, `unusableText` after a retry has also failed.

The last two cover **a Muse build that failed**.

> ⚠️ **`failedSubHeadingTitle` almost never appears.** When a build fails, the backend's
> own error sentence is shown **verbatim** in its place, and every failure path in the
> code supplies one. Treat it as a safety net, not as copy worth tuning. The backend's
> sentence cannot be configured from here — see §5.

---

### `libraryBlockedPage`

Shown whenever someone refuses photo-library access.

| Name | Current text |
|---|---|
| `headingTitle` | We can't see your photos. |
| `subHeadingTitle` | Allow photo library access in your device settings, then try again. |
| `bodyText` | Swan needs access to your photo library to find pictures of you. Nothing is uploaded — the matching happens on your phone. |

---

### `cameraBlockedPage`

An overlay inside the camera frame. Which line shows depends on why the camera failed.

| Name | Current text |
|---|---|
| `deniedText` | Camera access is off for this app. |
| `busyText` | The camera is in use by another app. Close it, then try again. |
| `unknownText` | We couldn't open the camera. |

---

## 5. What stays in the code

The flow holds about 130 strings. 77 are configurable; the rest stay put, each for a
reason. Nothing here is an oversight — ask and any row can be opened up later.

| What stays | Example | Why |
|---|---|---|
| Structural labels & live values | `Centimetres` · `Front 1/2` · `Looking through your photos… 12 of 340` · the countdown `6` | Layout-sensitive or generated at runtime, not brand copy |
| Capture step labels & captions | `Front` · `Head to toe, facing the camera` | Tied to the shot keys the flow scores against |
| Wrong-shot notices | `That looks like a side. We need a front.` | Assembled from the capture step labels above |
| Screen-reader labels | `Photo 3` · `Go back` · `Camera preview` | Not visible text |
| The one-line notices | `Skipped that one. Try another one.` · `We couldn't see a face in that photo.` | 12 transient messages, out of scope for v1 — §7.8 decision 2 |
| Picker hint lines | `Checking that photo…` · `Front and side must be full length.` · `Pick 5 photos for your Muse.` | They explain **why a button is disabled** — wording that contradicts the rule it describes is worse than none |
| Height out-of-range line | `Muse works between 152 and 213 cm…` | Same reason: it states a hard limit |
| **The backend's failure message** | whatever the service returns | A runtime value shown verbatim. There is nothing to configure |
| Its four fallback sentences | `We couldn't build your Muse…` | Which one appears depends on backend behaviour, so wording you set would surface unpredictably or never |
| Upload-failed / photos-failed | `We couldn't send your photos…` | **Never rendered.** Handed to your `onError` callback — your app decides what to show |
| — | — | — |
| *(Not excluded, but special:)* `pickerPage.headingTitle` and `topUpPage.headingTitle` | `Pick at least 5 photos of you.` · `One more — a side photo.` | These two are **generated** — they name a count and an angle. Leave them out and that behaviour is untouched; set them and you get a fixed sentence. See §7.3 |
| Confirmed-selection screen | `Your photos are selected.` · `Edit selection` | **Unreachable.** `setPhase("complete")` is never called — §7.8 decision 3 |

---

## 6. Full starter config

Copy it, delete the lines you don't want to change, keep the rest.
Every value below is verified against the code as it stands today.

`pickerPage.headingTitle` and `topUpPage.headingTitle` are **deliberately not listed** —
they have no fixed default. Add either one only if you want to replace a generated
sentence with your own. See §4.

```json
{
  "content": {
    "galleryPick": {
      "common": {
        "poweredBy": "Powered by Swan",
        "privacyNote": "Nothing leaves your phone until you approve it.",
        "notUploadedNote": "Your photos haven't been uploaded.",
        "keepAppOpenNote": "Keep the app open while this runs.",
        "tryAgainButton": "Try again",
        "retryButton": "Retry",
        "openSettingsButton": "Open Settings",
        "cameraStartingButton": "Starting camera…",
        "switchCameraText": "Switch camera"
      },
      "landingPage": {
        "buttonText": "Discover on you"
      },
      "introPage": {
        "headingTitle": "Create your Muse.",
        "subHeadingTitle": "Take a selfie & pick a few photos. We measure you & build your twin. Then see anything, in your size, on you.",
        "buttonText": "Start",
        "footerText": "About a minute. Nothing leaves your phone until you approve it."
      },
      "genderPage": {
        "headingTitle": "Where do you shop?",
        "subHeadingTitle": "It sets the body we build your Muse from.",
        "womensButton": "Womenswear",
        "mensButton": "Menswear",
        "buttonText": "Continue"
      },
      "heightPage": {
        "headingTitle": "How tall are you?",
        "subHeadingTitle": "It anchors the measurements we take from your photos.",
        "buttonText": "Continue"
      },
      "selfiePage": {
        "headingTitle": "First, a quick selfie.",
        "subHeadingTitle": "It stays on your phone. It only checks that the photos you pick are of you.",
        "buttonText": "Use this photo",
        "captionText": "Position your face in the frame",
        "footerText": "Your selfie is used only to find your photos.",
        "permissionText": "Next, your phone will ask about photo access. Allow Full Access so we can find your pictures — nothing leaves your phone until you approve it.",
        "guidePreparingCaption": "Preparing face guide…",
        "guideUnavailableCaption": "Position your face in the frame and look straight at the camera",
        "guidePosition": "Position your whole face inside the oval",
        "guideLowLight": "Not enough light. Turn towards a lamp or window.",
        "guideCloser": "Move closer",
        "guideFarther": "Move farther away",
        "guideCenter": "Move your face to the center",
        "guideFitWholeFace": "Fit your whole face inside the oval",
        "guidePerfect": "Perfect! Hold still",
        "retakeNoFace": "We couldn’t see a face in that photo. Try again in better light.",
        "retakeSeveralFaces": "Only you should be in the selfie. Try again on your own.",
        "retakeNotFrontal": "Look straight at the camera and try again.",
        "retakeBlurry": "That one came out blurred. Hold still and try again."
      },
      "searchingPage": {
        "headingTitle": "Finding your photos.",
        "subHeadingTitle": "We're looking for photos of you. This happens on your phone.",
        "progressPreText": "Looking through your photos…",
        "progressPostText": ""
      },
      "pickerPage": {
        "subHeadingTitle": "Albums › People & Pets has all your photos of you in one place.",
        "buttonText": "Build my Muse",
        "takePhotoButtonText": "Take it now",
        "loadMoreButtonText": "Load more photos",
        "loadingMoreButtonText": "Looking…",
        "scanningHeadingTitle": "Finding your photos.",
        "scanningSubHeadingTitle": "Picking opens once the search is done.",
        "scanningStatusText": "Still looking for more photos of you…",
        "scanningStatusPostText": "",
        "limitReachedText": "That's as many photos as we can take.",
        "picksChoosingTitle": "Picking for you…",
        "picksTitle": "Picked for you"
      },
      "capturePage": {
        "headingTitle": "We need a few more photos.",
        "subHeadingTitle": "We couldn't find enough clear, full-length photos of you. Take the rest now.",
        "buttonText": "Take new photos",
        "countingButtonText": "Get into position…",
        "limitedHeadingTitle": "These don't match your selfie.",
        "limitedSubHeadingTitle": "Choose different photos of you, or take new ones now."
      },
      "topUpPage": {
        "subHeadingTitle": "Prop your phone up and stand back so we can see your feet.",
        "subHeadingTitleSelfie": "Hold the phone up and look at the camera."
      },
      "buildingPage": {
        "headingTitle": "Creating your Muse.",
        "subHeadingTitle": "A measurement-accurate twin of you, built from these photos. Keep the app open while your photos upload."
      },
      "previewPage": {
        "headingTitle": "Your Muse is ready.",
        "subHeadingTitle": "Discover what you love by adding from trending or pasting a product link",
        "buttonText": "Done"
      },
      "failedPage": {
        "pausedHeadingTitle": "Paused.",
        "pausedSubHeadingTitle": "Upload interrupted. We'll pick up where it stopped.",
        "unusableText": "Some photos wouldn't load. Picking different ones usually helps.",
        "failedHeadingTitle": "We couldn't finish.",
        "failedSubHeadingTitle": "Something went wrong building your Muse. Your photos are safe."
      },
      "libraryBlockedPage": {
        "headingTitle": "We can't see your photos.",
        "subHeadingTitle": "Allow photo library access in your device settings, then try again.",
        "bodyText": "Swan needs access to your photo library to find pictures of you. Nothing is uploaded — the matching happens on your phone."
      },
      "cameraBlockedPage": {
        "deniedText": "Camera access is off for this app.",
        "busyText": "The camera is in use by another app. Close it, then try again.",
        "unknownText": "We couldn't open the camera."
      }
    }
  }
}
```

---

## 7. Implementation notes (engineers)

### 7.1 Shape

```ts
export interface Config {
  style?: StyleConfig;               // unchanged
  logo?: string;                     // unchanged
  loader?: string;                   // unchanged
  language?: PreferredLanguageType;  // unchanged
  appName?: string;                  // unchanged
  content?: ContentConfig;           // NEW, optional
}

export interface ContentConfig {
  galleryPick?: GalleryCopyOverrides;   // later: onboarding?, faceScan?, …
}

export type GalleryCopy = typeof GALLERY_COPY_DEFAULTS;
export type GalleryCopyOverrides = {
  [P in keyof GalleryCopy]?: Partial<GalleryCopy[P]>;
};
```

Two levels deep, no deeper. Every top-level value is an object — there are no bare
strings at the root, which is what lets the resolver stay this small:

```ts
const resolveGalleryCopy = (o?: GalleryCopyOverrides): GalleryCopy =>
  Object.fromEntries(
    Object.entries(GALLERY_COPY_DEFAULTS).map(([page, keys]) => [
      page,
      { ...keys, ...(o?.[page] ?? {}) },
    ]),
  ) as GalleryCopy;
```

Sending `pickerPage: { buttonText: "…" }` keeps the other eight `pickerPage` values.

### 7.2 Where the text is today

| Source | In code | Becomes configurable |
|---|---|---|
| `COPY` in `galleryConstants.ts` | 64 keys / 87 refs / 15 files | **36** |
| Hardcoded in JSX | ~51 strings / 11 components | **20** |
| Inside `SHOT_TYPES` / `COVERAGE` | 9 strings | 0 — staying put, see §5 |

The 28 `COPY` keys left behind: 12 notices, 5 picker hints, 4 backend fallbacks,
3 never rendered (`cameraBlocked`, `captureRetake`, `previewBody`), 2 that only reach
`onError`, 1 height range, 1 unreachable (`selectionDone`).

`COPY` is imported only from inside `galleryPick/`, which is what keeps this contained.

### 7.3 The two headings with no fixed default

Every configurable value is a literal string, with two exceptions. These are **generated**
today and stay that way unless a host overrides them:

| Key | Generated by |
|---|---|
| `pickerPage.headingTitle` | `` `Pick at least ${MIN_SELECTION} photos of you.` `` |
| `topUpPage.headingTitle` | `` `One more — a ${label.toLowerCase()} photo.` `` |

They carry **no entry in `GALLERY_COPY_DEFAULTS`**. The call site keeps its existing
expression as the fallback:

```tsx
const heading = copy.pickerPage.headingTitle
  ?? `Pick at least ${minSelection} photos of you.`;
```

Two consequences worth stating:

- **No interpolation helper is needed anywhere.** Every value a host can write is literal,
  so there is no `fmt()`, no `{token}` syntax, and nothing for a config author to learn.
- **The count and the angle stay correct by default.** A host that says nothing keeps
  today's behaviour exactly; a host that sets a sentence accepts that it is fixed for
  every count and every angle. That is their choice to make, not a silent regression.

Type them as optional so the distinction is visible:

```ts
pickerPage: { headingTitle?: string; /* …the other eight are required */ }
```

### 7.4 Wiring, and one constraint worth knowing

```tsx
const copy = useMemo(() => resolveGalleryCopy(config?.content?.galleryPick), [config]);
const state = useGalleryPick({ copy, … });
return <GalleryCopyProvider value={copy}>…</GalleryCopyProvider>;
```

| Consumer | How it gets copy | Why |
|---|---|---|
| Screen components | `useCopy()` from context | — |
| `useGalleryPick.ts` | explicit `copy` option | `GalleryPick` renders the provider **and** calls this hook in the same component, so the provider isn't mounted when the hook runs. Context is not available; passing it explicitly is the only correct option |
| `museSocket.ts` | a `fallbackMessage` argument | Plain module, not React |

Only a handful of the hook's 24 `COPY` references are in scope (the notices stay in code),
so most of them keep importing `COPY` directly.

### 7.5 Phases

| Phase | What | Risk |
|---|---|---|
| 0 | `galleryCopy.ts` defaults + `resolveGalleryCopy` + `GalleryCopyContext` + `Config.content` type | None — nothing consumes it |
| 1 | Move 36 of the 64 `COPY` keys into their page groups; update those call sites | Low, mechanical, type-checked |
| 2 | Lift the 20 in-scope hardcoded JSX strings | Low |
| 3 | Dev warning for unknown names, JSON schema, ReadMe section | None |

Roughly **2.5 days**. Phases 0+1 are shippable alone.

Phase 1 is a bigger diff than a flat key map would be, because each call site gains a page
prefix (`copy.pickerPage.buttonText` rather than `copy.buildMuse`). That cost is accepted
deliberately: the config is read and edited far more often than the call sites are.

### 7.6 Why nothing else breaks

1. `content` is a **new optional field** — existing `Config` objects stay valid.
2. `COPY` is imported **only** inside `galleryPick/`.
3. `useLocalConfig` is extended, not restructured — the `style` merge is untouched.
4. No other component reads `config.content`.
5. With no `content` sent, every screen renders **byte-identical** text to today — the two
   generated headings included, because they keep their existing expressions (§7.3).

### 7.7 Test checklist

- [ ] No config → every screen byte-identical to today, with no exceptions
- [ ] One name inside a page → only that one changes; the page's others survive
- [ ] `""` → renders nothing, does not fall back
- [ ] Unknown page or name → ignored, warns in dev, silent in production
- [ ] A Muse build failure carrying a server message → the server's sentence shows, not `failedSubHeadingTitle`
- [ ] Refuse photo access → `libraryBlockedPage` overrides take effect
- [ ] Omit `pickerPage.headingTitle` → the count still tracks `MIN_SELECTION`; set it → the fixed sentence shows
- [ ] Omit `topUpPage.headingTitle` → the angle is still named; set it → the fixed sentence shows for every angle
- [ ] Same override works through the native `RENDER_COMPONENT` JSON
- [ ] `Onboarding`, `FaceScan`, `BodyScan`, `FocalLength`, `Educational` unchanged

### 7.8 Open decisions

| # | Question | Recommendation |
|---|---|---|
| 1 | The 12 one-line notices are excluded. Right call? | **Yes for v1**, but they are the most likely follow-up — they are ordinary sentences, not structural |
| 2 | The unreachable `complete` phase | **Separate cleanup ticket.** `setPhase("complete")` is never called, so the phase, its branch in `GalleryPick.tsx`, the `complete` prop on `GalleryPhotoPicker` and `actions.edit` are all dead |
| 3 | 3 `COPY` keys defined but never rendered | **Delete in phase 1** — don't leave dead names behind |
| 4 | Should `content` accept a remote URL? | **No** — fetch it yourself and pass the object |

---

## 8. FAQ

**Do I have to send everything?**
No. Send one page, one name — whatever you're changing.

**What if I get a name wrong?**
It's ignored and you see the default. TypeScript users get a compile error; everyone else
gets a dev-console warning, and a JSON schema will ship for CI validation.

**Can I hide a line?** Send `""`.

**Does this change colours or fonts?** No — that's `config.style`, unchanged.

**Does this translate the flow?**
No. Translations are the built-in dictionary (7 languages). This is about *what your brand
calls things*, in whatever language you write. When gallery strings are translated later,
your override still wins, and nothing you write today needs changing.

**Will this affect other components?** No — see §7.6.

**Different text per brand?**
One JSON file per brand in your repo, validated in CI, passed as
`config.content.galleryPick`. Copy changes ship without a package release.
