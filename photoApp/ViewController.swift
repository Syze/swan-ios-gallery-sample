

// Swan Gallery Pick host — pairs with Swan mobile 1.3.8. Release notes and
// whether this file needs updating: CHANGELOG.md.

import UIKit
import WebKit
import Photos
import PhotosUI
import Vision
import Network
import SensitiveContentAnalysis

final class ViewController: UIViewController {

    /// Where the SDK bundle is served from. Must be **https** — getUserMedia needs
    /// a secure context, so an http or file:// URL gives no camera.
    let sdkURL = URL(string: "https://swan-mobile-web-component.swan.so/v1.3.8/index.html")!

    static let bridgeName = "swanBridge"

    // ---- Fill these in before running ----------------------------------------
    // Email and token come from `SwanSession.swift`; put your API keys in `SwanSessionConfig`.

    /// Who the flow is running for. `gender` is optional: "male" or "female" skips
    /// the flow's own gender screen; anything else, or nil, shows it.
    static let shopDomain = "hm_ie"
    static let userGender = ""        // "male" | "female"

    /// Optional height in cm (a string works too). Inside 152–213 the ruler screen is
    /// skipped; otherwise the ruler is shown and `onComplete` carries the user's answer.
    static let userHeightCm: Any? = nil

    /// How far back the library search reaches, in months (1–36, clamped). Older
    /// photos are reached only through "Load more". 12 is the flow's default.
    static let monthsBack = 12

    /// Brand styling and wording, passed through as `config`: `style` becomes CSS
    /// variables, `content` replaces text. Every value is optional and unvalidated.
    /// Headline, body, button, and footer map to `headingTitle`, `subHeadingTitle`,
    /// `buttonText`, and `footerText`. The review screen is `pickerPage`.
    static let theme: [String: Any] = [
        "content": [
            "galleryPick": [
                "introPage": [
                    "headingTitle": "Create your Muse.",
                    "subHeadingTitle": "Take a selfie and we’ll find photos of you to measure from. Then see anything on you, in your size.",
                    "buttonText": "Start",
                    "footerText": "About a minute. Nothing leaves your phone until you approve it.",
                ],
                "selfiePage": [
                    "headingTitle": "First, a quick selfie.",
                    "subHeadingTitle": "We use it to find photos of you on this phone. It stays on your phone.",
                    "buttonText": "Use this photo",
                    "footerText": "Next, your phone will ask for photo access. Choose Allow Full Access so we can search your library. The search runs on your phone.",
                    // Second footnote under the button. Cleared so it does not repeat the line above.
                    "permissionText": "",
                ],
                "searchingPage": [
                    "headingTitle": "Finding photos of you.",
                    "subHeadingTitle": "We're looking for a selfie and clear, full-length photos from the front and side.",
                    // Around the "13 of 1567" count: text before it, and after it.
                    "progressPreText": "Looking through your photos…",
                    "progressPostText": "",
                ],
                "pickerPage": [
                    "scanningHeadingTitle": "Finding photos of you.",
                    "scanningSubHeadingTitle": "We're looking for a selfie and clear, full-length photos from the front and side.",
                    // Around the "13 of 1567" count while the scan runs: before it, and after it.
                    "scanningStatusText": "Found",
                    "scanningStatusPostText": "",
                    "headingTitle": "Here's what we picked.",
                    "subHeadingTitle": "We'll measure you from these. Swap any you'd rather not use.",
                    "buttonText": "Build my Muse",
                ],
                "heightPage": [
                    "subHeadingTitle": "",
                ],
                "genderPage": [
                    "subHeadingTitle": "",
                ],
                "common": [
                    // Footer on the searching screen, and again while the grid is still filling.
                    "keepAppOpenNote": "",
                    "poweredBy": "",
                    "notUploadedNote": "Keep the app open. Nothing has been uploaded."
                ],
            ] as [String: Any],
        ] as [String: Any],
    ]

    // Example values for both halves, with every text key, are in
    // GALLERY_PICK.md and GALLERY_PICK_TEXT_CONFIG.md.

    /// Custom scheme for serving photos straight into <img src>. Must not collide
    /// with a scheme WebKit already handles — registering "http" or "https" throws.
    static let photoScheme = "swan-photo"

    /// Held strongly here; the configuration's reference alone is not something to
    /// rely on for an object we also want to keep alive across navigations.
    let photoSchemeHandler = PhotoSchemeHandler()

    var webView: WKWebView!

    /// Who is signed in. Set before the page loads, so `WEB_READY` always has a
    /// token to hand over — see `SwanSession.swift`.
    var session: SwanSession?
    var webReadyWatchdog: DispatchWorkItem?
    var isLimitedAccess = false
    /// The selfie's identity vector — what every library face is measured against.
    var referenceEmbedding: [Float]?

    /// The other selfie frames' vectors, only under `matchAgainstAllFrames`.
    var extraReferenceEmbeddings: [[Float]] = []

    /// Which frame became the reference and why, for the scan summary.
    var lastReferenceNote = ""
    var lastReferenceFrames = 1
    var lastReferenceIndex = 0
    var lastReferenceQuality: Float?

    /// Face measurements from the last photo `matchPerson` looked at, for `ScanEval`.
    /// Only filled in eval mode, since the quality number costs an extra Vision pass.
    /// How many selfie frames went into the reference — see `blendReferenceFrames`.
    var lastReferenceBlended = 1
    /// Every frame's capture quality, the widest distance from the chosen frame to
    /// another blended frame, and how far the blend moved from the chosen frame.
    var lastReferenceQualities: [Float?] = []
    var lastReferenceSpread: Float?
    var lastReferenceShift: Float?

    /// Face measurements from the last photo `matchPerson` looked at, for
    /// `ScanEval`. Only filled in eval mode — the quality number costs an extra
    /// Vision pass per photo.
    var lastFaceMetrics: FaceMetrics?

    /// Whether the last photo `matchPerson` scored had its face re-cropped from a
    /// larger render. Read by `ScanEval`, so a run shows whether it actually kicked in.
    var lastCropFullRes = false

    /// Whether the last photo `loadPhoto` returned had to be turned upright. Read by
    /// `ScanEval`, since the photo it is handed no longer shows it.
    var lastLoadRotated = false

    /// Whether the last photo `loadPhoto` returned was the phone's smaller copy of a
    /// photo whose full version is only in iCloud. Counted by the scan.
    var lastLoadLocalCopy = false
    var lastLoadFromCloud = false
    /// Bigger copies fetched from iCloud for a small face, for the summary.
    var cloudLargerDownloads = 0

    /// Why the last `loadPhoto` came back empty, for the verbose log: whether iOS
    /// said the photo was in iCloud, and how large a copy the phone offered.
    var lastLoadNote = ""

    /// What the second head-to-toe check found, when `matchPerson` ran one — see
    /// the full-body gate there. Nil when no retry happened. Read by the scan log.
    /// Where a scan's time goes, in milliseconds per stage: load, detect, group,
    /// pose, embed, score. Reset per scan, printed in the summary. Scan queue only.
    var stageMs: [String: Double] = [:]
    func timed<T>(_ stage: String, _ work: () -> T) -> T {
        let started = Date()
        defer { stageMs[stage, default: 0] += Date().timeIntervalSince(started) * 1000 }
        return work()
    }

    /// The last `matchPerson` decided "no match" from the face alone, before body
    /// pose — see `matchBeforePose`. Counted by the scan.
    var lastEarlyNoMatch = false

    /// A photo's capture date as `yyyy-MM-dd`, in the phone's time zone, for the
    /// scan summary. Nil when the photo has no date.
    static func captureDay(_ date: Date?) -> String? {
        guard let date else { return nil }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter.string(from: date)
    }

    /// This process's resident memory in MB, for the scan summary. The web view's
    /// content process is separate and not counted here; Xcode's memory gauge
    /// shows both.
    static func residentMB() -> Int {
        var info = mach_task_basic_info()
        var count = mach_msg_type_number_t(MemoryLayout<mach_task_basic_info>.size) / 4
        let result = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                task_info(mach_task_self_, task_flavor_t(MACH_TASK_BASIC_INFO), $0, &count)
            }
        }
        return result == KERN_SUCCESS ? Int(info.resident_size / 1_048_576) : 0
    }

    /// What the second head-to-toe check found, when `matchPerson` ran one — see
    /// the full-body gate there. Nil when no retry happened. Read by the scan log.
    var lastBodyRetry: (note: String, rescued: Bool)?
    /// The pose observation the last `bodyCheck` kept, for `BodyScore`.
    var lastBodyObservation: VNHumanBodyPoseObservation?
    /// Pupil-to-pupil distance of the widest face in the photo just examined,
    /// in the scan's pixels. Nil without landmarks. For the v2 selfie rule and
    /// the `selfieSmallEyes` count.
    var lastEyeSpacing: CGFloat?

    /// How many faces in the last photo examined were the shopper's. Above 1 it was
    /// a mirror shot — see `sameShopperFacesMax`. Read by the scan log and summary.
    var lastShopperFaces = 1

    /// Results kept between scans — see `ScanStore`. Opened per scan for the
    /// signed-in account; nil when the store is off.
    var scanStore: ScanStore?
    /// Face vectors of the faces `matchPerson` last embedded, largest first, one
    /// per face it kept. Empty when any face could not be embedded. Written to
    /// the store beside the verdict, so the next scan compares a new selfie with
    /// them instead of loading the photo.
    var lastEmbeddings: [[Float]] = []

    /// The smallest local copy worth scanning, on its longer side. Under this only a
    /// thumbnail is held, too blurred to read a face, so the photo is "no image".
    static let minLocalCopyPixels = 800

    /// How long `loadPhoto` waits for the phone's copy of an iCloud photo: a ceiling
    /// against a stalled callback, not a download allowance.
    static let localCopyWait: DispatchTimeInterval = .seconds(2)

    /// The copy iOS offered when the full photo was in iCloud, however small. The
    /// scan reads it only to ask one question: does this look like a selfie?
    var lastLoadThumbnail: UIImage?

    // ---- iCloud selfies ------------------------------------------------------
    // A 120px iCloud thumbnail shows whether one face fills the frame; those alone are downloaded small.

    /// Longest side of a downloaded copy: the scan's own render size, so it is
    /// matched on the same pixels as a local photo.
    static let cloudPixels: CGFloat = loadPixels
    /// Downloads per scan, newest first; one cap on Wi-Fi, a lower one on mobile data.
    /// The mobile cap is a placeholder until a scan on mobile data has been measured.
    static let cloudDownloadCapWifi = 200
    static let cloudDownloadCapMobile = 100
    /// Download slots held for full-length candidates, so recent selfies cannot crowd them out.
    static let cloudFullLengthReserve = 20
    /// Downloads start during the local pass; the scan waits at most `cloudTail` after
    /// the local pass for the rest, which are counted as left.
    static let cloudTail: TimeInterval = 30
    /// Past `cloudTail`, the wait goes on only while a photo the small copy
    /// confirmed is still downloading in full, and never past this. A library
    /// that is all in iCloud has nothing to match until those arrive.
    static let cloudTailMax: TimeInterval = 90
    /// Per-photo limit. Full-length downloads on Wi-Fi measured 7 to 9.7 s on one
    /// library and six photos timed out at 10 s; the wait after the local pass
    /// (`cloudTail`/`cloudTailMax`) bounds the scan, so this can be generous.
    static let cloudTimeout: DispatchTimeInterval = .seconds(20)
    /// On mobile data, where a 0.5MB copy measured 8 to 17 s and a matched
    /// photo timed out at 20 s on a 3,500-photo library (28 Oct 2026).
    static let cloudTimeoutMobile: DispatchTimeInterval = .seconds(30)
    /// The per-photo limit for the current connection.
    static var cloudTimeoutNow: DispatchTimeInterval { cloudOnMobile ? cloudTimeoutMobile : cloudTimeout }
    /// Downloads in flight at once. Fewer on mobile data: on a 250KB/s line six
    /// 0.5MB copies shared it, each took 12 s or more, and 21 of 32 hit
    /// `cloudTimeout`. At three each finishes in half the time and the total is
    /// the same, since the line is the limit either way.
    static let cloudParallel = 6
    static let cloudParallelMobile = 3
    /// A small copy fetched first, about 30KB: faces and people are counted on it
    /// and only a lone person goes on to the full download. Group photos read as
    /// one tall person on a 120px thumbnail.
    static let cloudPreviewPixels: CGFloat = 320
    /// A full-length candidate is fetched at the scan's own size, as a local photo
    /// is loaded, about 0.5MB. A bigger copy is fetched only when its face is under
    /// the 120px floor (see `cloudFloorDeferred`) or, after a match, for the body
    /// check. Measured on one library at 2560px: 18 of 20 full downloads were
    /// other people, so the bigger copy was wasted on most. Selfies stay at `cloudPixels`.
    static let cloudFullLengthPixels: CGFloat = loadPixels
    /// A downloaded photo whose face is under the floor: `true` matches the small
    /// face first and fetches the bigger copy only after a match (a stranger costs
    /// nothing more, but a small face can miss); `false` fetches the bigger copy
    /// before deciding, as for a local photo, so the decision is always made at
    /// 120px or more.
    static let cloudFloorDeferred = false
    /// The small copy's face box overstates the face at 1536 by about 25% (32
    /// photos measured); a predicted face under floor × this margin fetches the
    /// bigger copy straight away rather than landing just under the floor.
    static let cloudFaceEstimateMargin: CGFloat = 1.25
    /// A single person spanning this much of a thumbnail's height is a full-length candidate.
    /// Measured on 120px thumbnails: 124 of 134 full-length photos pass, 2 of 22 others.
    static let cloudPersonHeight: CGFloat = 0.6

    /// Online. Mobile data is allowed under `cloudDownloadCapMobile`; Low Data Mode
    /// does not stop the pass, the caps bound what it costs.
    static var cloudDownloadsAllowed: Bool {
        let path = pathMonitor.currentPath
        return path.status == .satisfied
    }
    static var cloudOnMobile: Bool { pathMonitor.currentPath.isExpensive }
    static var cloudDownloadCap: Int { cloudOnMobile ? cloudDownloadCapMobile : cloudDownloadCapWifi }

    /// Bumped on every reset. A scan loop stops when the value changes, so a block
    /// that outlives a page reload cannot reply into the next scan.
    var scanGeneration = 0

    /// Reload attempts after a WebContent process crash, and the ceiling on them.
    var processReloads = 0
    static let maxProcessReloads = 3

    /// One console line per photo scanned. Useful on a small library, a flood on
    /// a real one — a 10k-photo scan prints 10k lines.
    static let verboseLogging = false

    /// Review aid: when a scan ends, the controller posts one JSON report to
    /// this address — every photo in the scan's final results with everything
    /// the page was sent for it (type, score, tier, scoreParts, scoreInputs, ...),
    /// the page's pre-selection, the withdrawn ids and the scan summary — so a
    /// scan on a tester's phone can be read without its console. Ids are cut to
    /// the 8 characters of the page's id badge. For test builds only; nil turns
    /// it off.
    static let scanReportURL: URL? = URL(string: "https://webhook.site/01f24d43-ec40-4da5-b081-062d59a39673")
    /// The matches sent to the page in the current pass, by asset id, for the
    /// report — see `scanReportURL`.
    var scanReportMatches: [String: [String: Any]] = [:]
    /// The page pre-selects after it hears the scan is complete and reports each
    /// pick through `onImageSelect` with `auto`; the report waits this long to
    /// collect them, then goes with `picked`.
    static let scanReportPickWait: TimeInterval = 4
    var scanReportPicks: [String] = []

    /// Measures matching against a hand-labelled album and prints the result after
    /// each scan. **Debug only, keep off in any build a brand sees.** See `ScanEval`.
    static let evalMode = false

    /// The album whoever runs the measurement fills with every photo that *should* reach the grid:
    /// them, alone, head to toe — or a selfie of them. Read as the answer key.
    static let evalAlbumTitle = "Swan-Eval"

    /// How much of the grid "precision at the top" looks at. A measuring window,
    /// not a number of photos the grid has to show.
    static let evalTopN = 20

    /// Replace the saved eval selfie with this run's. Set true for one run, then
    /// back. See `evalReferenceSelfie`.
    static let evalResaveSelfie = false

    /// Echoes the SDK's API trace and callback bodies to the console. **Keep off in
    /// a shipped app:** they carry presigned URLs, the user's email and render links.
    /// Echoes the SDK's own API and socket trace, and the bodies of its callbacks,
    /// into the Xcode console.
    ///
    /// **Turn this off before you ship.** Those lines carry presigned S3 URLs with
    /// their signature and security token, the user's email address, and 24-hour
    /// links to their finished renders. On a device you are holding that is
    /// exactly what you want to see; inside a shipped app it is all of that going
    /// wherever your logs go.
    ///
    /// The flow is unaffected either way — this only decides whether the host
    /// prints what crosses the bridge.
    static let debugBridgeLogging = false
    /// Diagnostic: writes the selfie frames the page sent, as received, to the
    /// app's Documents folder (Files app → On My iPhone → photoApp → selfie-frames),
    /// so a frame from a tester's phone can be run through the Mac matcher. Each
    /// scan overwrites the previous set. Off in any shared copy. Needs
    /// `UIFileSharingEnabled` and `LSSupportsOpeningDocumentsInPlace` in Info.plist
    /// for the folder to show in the Files app.
    static let saveReferenceFrames = false

    /// Writes the selfie and candidate face crops to Documents. Biometric data
    /// on disk — keep false outside local debugging.
    var debugDumpCrops = false
    var debugCropsSaved = 0
    static let debugCropLimit = 12

    // MARK: - Lifecycle

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .systemBackground
        // Started now rather than at the first scan: a monitor's first reading takes
        // a moment, and the scan reads it the moment a photo matches.
        _ = Self.pathMonitor
        // The web view is created after Continue. Building it here blocks the main
        // thread through launch and freezes the email field while the bundle loads.
    }

    /// Decided once the view is on screen: presenting from `viewDidLoad` is refused
    /// because the view is not in the window yet.
    private var started = false

    /// Still on screen while the gallery page loads. Nil once that page is shown.
    private weak var signInController: SwanSessionViewController?

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        guard !started else { return }
        started = true
        presentSignIn(existing: SwanSession.restoreIfAlive())
    }

    /// The page has said WEB_READY and is waiting for RENDER_COMPONENT.
    private var webReady = false

    /// Signed in. The form stays up until the page is ready, so a slow load is a
    /// spinner instead of a white screen over a dead email field.
    func openGallery(with session: SwanSession) {
        self.session = session
        let until = session.validUntil.map { DateFormatter.localizedString(from: $0, dateStyle: .medium, timeStyle: .short) } ?? "unknown"
        if Self.debugBridgeLogging { print("👤 Signed in as \(session.email) — token valid until \(until)") }
        signInController?.beginOpeningGallery()
        // One turn so the spinner paints before WebKit takes the main thread.
        DispatchQueue.main.async { [weak self] in
            self?.loadGalleryPage()
        }
    }

    /// Creates the web view on first use and loads the bundle. Renders immediately
    /// when a reload has already reported WEB_READY.
    private func loadGalleryPage() {
        if webView == nil { setupWebView() }
        if webReady {
            revealGallery()
            return
        }
        startWebReadyWatchdog()
        webView.load(URLRequest(url: sdkURL))
    }

    /// RENDER_COMPONENT has a session and a ready page. The sign-in screen can go.
    private func revealGallery() {
        renderGallery()
        guard let signIn = signInController else { return }
        signInController = nil
        signIn.dismiss(animated: true)
    }

    /// The sign-in screen is still up and the page will not become ready.
    private func pageDidFail(_ message: String) {
        guard signInController != nil else { return }
        webReadyWatchdog?.cancel()
        webReady = false
        signInController?.showPageError(message)
    }

    /// Loads the face matcher, the expression reader and the hand detector now,
    /// while the user reads the intro and frames the selfie, so none of it is
    /// paid between the tap and the first scanned photo. Idempotent: each load
    /// happens once, and the post-selfie calls then return at once.
    private static var modelsWarmed = false
    func warmUpModels() {
        guard !Self.modelsWarmed else { return }
        Self.modelsWarmed = true
        DispatchQueue.global(qos: .utility).async {
            let started = Date()
            _ = Self.faceRecognizer
            FaceExpression.warmUp()
            if Self.coverReadEnabled { FaceCover.warmUp() }
            if Self.fullLengthScoreV2 && Self.objectReadEnabled { BodyObjects.warmUp() }
            let hands = VNDetectHumanHandPoseRequest()
            if let ctx = CGContext(data: nil, width: 64, height: 64, bitsPerComponent: 8, bytesPerRow: 0,
                                   space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue),
               let blank = ctx.makeImage() {
                try? VNImageRequestHandler(cgImage: blank, orientation: .up, options: [:]).perform([hands])
            }
            print("🔥 Models warmed in \(Int(Date().timeIntervalSince(started) * 1000))ms, before the selfie")
        }
    }

    /// RENDER_COMPONENT for GalleryPick, with the signed-in session. Never sent
    /// without one: the page cannot upload without a token.
    func renderGallery() {
        guard let session = session else { return }
        if Self.debugBridgeLogging { print("▶️ Rendering GalleryPick for \(session.email)") }
        warmUpModels()
        sendToWeb([
            "type": "RENDER_COMPONENT",
            "componentName": "GalleryPick",
            "props": [
                "userDetails": [
                    "email": session.email,
                    "shopDomain": Self.shopDomain,
                    "gender": Self.userGender,
                    // Omitted entirely when nil, so the flow sees no height at
                    // all rather than a null it has to interpret.
                    "heightInCm": Self.userHeightCm as Any,
                ].compactMapValues { $0 },
                "token": session.token,
                "config": Self.theme,
                "monthsBack": Self.monthsBack,
            ]
        ])
    }

    /// The sign-in screen: stays up until the gallery page is ready, cannot be dismissed
    /// without a token, and with a live session offers that email and Continue.
    func presentSignIn(existing: SwanSession? = nil) {
        let signIn = SwanSessionViewController(existing: existing)
        signIn.modalPresentationStyle = .fullScreen
        signIn.onSignedIn = { [weak self] session in
            self?.openGallery(with: session)
        }
        signIn.onRetryPage = { [weak self] in
            DispatchQueue.main.async { self?.loadGalleryPage() }
        }
        signInController = signIn
        present(signIn, animated: false)
    }

    deinit {
        webView?.configuration.userContentController
            .removeScriptMessageHandler(forName: Self.bridgeName)
        webReadyWatchdog?.cancel()
        print("♻️ ViewController deinit")
    }

    // MARK: - Setup

    func setupWebView() {
        guard webView == nil else { return }
        let contentController = WKUserContentController()

        // Retained strongly, so passing `self` leaks the VC, the web view and a
        // content process on every presentation. The proxy points back weakly.
        contentController.add(BridgeProxy(target: self), name: Self.bridgeName)

        let configuration = WKWebViewConfiguration()
        configuration.userContentController = contentController
        // Without these the scan camera opens fullscreen and the voice-over
        // guidance is silently muted.
        configuration.allowsInlineMediaPlayback = true
        configuration.mediaTypesRequiringUserActionForPlayback = []

        // Lets React write <img src="swan-photo://…"> instead of moving bytes
        // through the JSON bridge. The base64 path is the fallback if it is blocked.
        configuration.setURLSchemeHandler(photoSchemeHandler, forURLScheme: Self.photoScheme)

        webView = WKWebView(frame: .zero, configuration: configuration)
        // ngrok's free tier answers any browser-looking request, scripts included,
        // with a "visit site" page, which the sign-in screen now hides. A user agent
        // that does not start with "Mozilla" is passed through; the page's own
        // iPhone checks still match. Only for ngrok hosts; the CDN sees the default.
        if sdkURL.host?.contains("ngrok") == true {
            webView.customUserAgent = "SwanHost/1 (iPhone; CPU iPhone OS 18_0 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Mobile/15E148"
        }
        webView.uiDelegate = self
        webView.navigationDelegate = self
        webView.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(webView)

        NSLayoutConstraint.activate([
            webView.topAnchor.constraint(equalTo: view.topAnchor),
            webView.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            webView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            webView.trailingAnchor.constraint(equalTo: view.trailingAnchor)
        ])
    }

    /// A reload that superseded this one. Not a failure of the page the user is waiting on.
    private static func cancelled(_ error: Error) -> Bool {
        let error = error as NSError
        return error.domain == NSURLErrorDomain && error.code == NSURLErrorCancelled
    }

    /// How long the sign-in screen waits for WEB_READY before offering Try again. A first
    /// load on a slow connection fetches the bundle and the face-guide model, so it is generous.
    static let webReadyTimeout: TimeInterval = 30

    /// A JS error in the bundle gives a successful navigation and a blank page, the
    /// same white screen as a network failure. This log tells them apart.
    func startWebReadyWatchdog() {
        webReadyWatchdog?.cancel()
        let work = DispatchWorkItem { [weak self] in
            print("⏰ No WEB_READY within \(Int(Self.webReadyTimeout))s — the bundle probably threw. Check Web Inspector.")
            self?.pageDidFail("The gallery didn't open. Check your connection and try again.")
        }
        webReadyWatchdog = work
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.webReadyTimeout, execute: work)
    }

    // MARK: - Sending to web

    /// `callAsyncJavaScript` with an arguments dictionary, not a spliced string:
    /// U+2028/U+2029 are legal in JSON but break JS source.
    func sendToWeb(_ payload: [String: Any]) {
        if Self.scanReportURL != nil { collectForScanReport(payload) }
        webView.callAsyncJavaScript(
            "window.postMessage(payload, window.location.origin);",
            arguments: ["payload": payload],
            in: nil,
            in: .page
        ) { result in
            if case .failure(let error) = result {
                print("❌ sendToWeb failed: \(error)")
            }
        }
    }

    /// Keeps each match sent to the page and, on the pass's scan-complete
    /// message, posts the report — see `scanReportURL`. On the main queue, as
    /// every `sendToWeb` is.
    private func collectForScanReport(_ message: [String: Any]) {
        guard let url = Self.scanReportURL, let type = message["type"] as? String,
              let payload = message["payload"] as? [String: Any] else { return }
        if type == "onGalleryMatchFound", let id = payload["assetId"] as? String {
            scanReportMatches[id] = payload
            return
        }
        guard type == "onGalleryScanComplete" else { return }
        let short = { (id: String) in String(id.prefix(8)) }
        let ids = payload["assetIds"] as? [String] ?? []
        let photos: [[String: Any]] = ids.enumerated().map { index, id in
            var photo = scanReportMatches[id] ?? [:]
            for key in ["assetId", "done", "total"] { photo.removeValue(forKey: key) }
            photo["id"] = short(id)
            photo["position"] = index + 1
            return photo
        }
        var report: [String: Any] = [
            "at": ISO8601DateFormatter().string(from: Date()),
            "device": UIDevice.current.model + " iOS " + UIDevice.current.systemVersion,
            "page": sdkURL.absoluteString,
            "shown": photos.count,
            "dropped": (payload["dropped"] as? [String] ?? []).map(short),
            "photos": photos,
        ]
        for key in ["error", "denied", "limited", "skipped", "summary"] { report[key] = payload[key] }
        scanReportMatches = [:]
        scanReportPicks = []
        // Sent after the page's pre-selection has come back — see `scanReportPickWait`.
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.scanReportPickWait) { [weak self] in
            guard let self else { return }
            let picks = self.scanReportPicks.filter { ids.contains($0) }
            report["picked"] = picks.map(short)
            report["photos"] = photos.map { photo -> [String: Any] in
                var photo = photo
                photo["picked"] = picks.contains { short($0) == photo["id"] as? String }
                return photo
            }
            self.postScanReport(report, to: url)
        }
    }

    /// One POST of the report as JSON — see `scanReportURL`.
    private func postScanReport(_ report: [String: Any], to url: URL) {
        let photos = report["photos"] as? [[String: Any]] ?? []
        guard JSONSerialization.isValidJSONObject(report),
              let body = try? JSONSerialization.data(withJSONObject: report, options: [.sortedKeys]) else {
            print("📤 scan report not sent — not valid JSON")
            return
        }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = body
        URLSession.shared.dataTask(with: request) { _, response, error in
            let status = (response as? HTTPURLResponse)?.statusCode
            print("📤 scan report — \(photos.count) photos, \(body.count / 1024)KB: \(error.map { "failed, \($0.localizedDescription)" } ?? "HTTP \(status ?? 0)")")
        }.resume()
    }
}

/// Which way the person in a photo is facing. String-backed so the raw value
/// crosses the bridge as-is; the web side stores the payload without decoding it.
enum PhotoType: String {
    case front
    case side
    /// A full-length photo turned between `threeQuarterDegrees` and
    /// `sideTurnDegrees`. The page puts it in a side slot. Only sent when
    /// `typeSortV2` is on.
    case threeQuarter = "three-quarter"
    case selfie
    /// No face was found. Usually a back view, sometimes an unusable photo — read
    /// alongside `isFullBody` to tell those apart.
    case unknown
}

/// One reference print, built from a face crop degraded to `sourceWidth`.
// MARK: - Receiving from web

extension ViewController: WKScriptMessageHandler {

    func userContentController(
        _ userContentController: WKUserContentController,
        didReceive message: WKScriptMessage
    ) {
        // Accept both a JSON string and a dictionary — silently dropping anything
        // that isn't a String is how messages disappear without trace.
        let body: [String: Any]?
        switch message.body {
        case let string as String:
            body = (try? JSONSerialization.jsonObject(with: Data(string.utf8))) as? [String: Any]
        case let dictionary as [String: Any]:
            body = dictionary
        default:
            print("⚠️ Bridge got unsupported body: \(type(of: message.body))")
            return
        }

        guard let payload = body, let type = payload["type"] as? String else {
            // Only under the debug flag: an undecodable body is by definition
            // unbounded and could hold a token, an email or photo bytes.
            if Self.debugBridgeLogging { print("⚠️ Bridge got undecodable message: \(message.body)") }
            return
        }

        switch type {
        case "WEB_READY":
            webReadyWatchdog?.cancel()
            // First load, or a reload after the content process died: the web side
            // has no state, so nothing held here, captures included, is still valid.
            if CaptureStore.count > 0 { print("🧹 dropping \(CaptureStore.count) capture(s) — the page reloaded") }
            CaptureStore.removeAll()
            resetScanState()
            // Pages from before versioning send no version, so the line just omits it.
            let webVersion = (payload["version"] as? String).map { " v\($0)" } ?? ""
            print("✅ WEB_READY\(webVersion)")
            webReady = true
            if session != nil { revealGallery() } else { print("⏳ Page ready — rendering after sign-in") }

        case "GALLERY_SCAN_START":
            let filters = payload["payload"] as? [String: Any] ?? [:]

            // Redact the reference image before logging: a base64 selfie floods the console.
            var loggable = filters
            if let reference = loggable["referenceImage"] as? String {
                loggable["referenceImage"] = "<base64, \(reference.count) chars>"
            }
            if let frames = loggable["referenceImages"] as? [String] {
                loggable["referenceImages"] = "<\(frames.count) frames, \(frames.reduce(0) { $0 + $1.count }) chars>"
            }
            if Self.debugBridgeLogging { print("🔍 GALLERY_SCAN_START \(loggable)") }
            startGalleryScan(monthsBack: filters["monthsBack"] as? Int ?? 12,
                             referenceImage: filters["referenceImage"] as? String,
                             referenceImages: filters["referenceImages"] as? [String])

        case "GALLERY_THUMBNAILS":
            // Fallback: one photo the custom scheme could not load, asked for per tile.
            let thumbId = (payload["payload"] as? [String: Any])?["assetId"] as? String ?? ""
            sendThumbnail(for: thumbId)

        case "GALLERY_FULL_IMAGE":
            // One photo per request: fetch() cannot reach the custom scheme, and a
            // whole selection in one message would be megabytes of base64.
            let assetId = (payload["payload"] as? [String: Any])?["assetId"] as? String ?? ""
            sendFullImage(id: assetId)

        case "OPEN_SETTINGS":
            // A web page cannot navigate to the settings URL scheme, so the only way
            // to offer "Open Settings" from inside the WebView is to ask the host.
            if let url = URL(string: UIApplication.openSettingsURLString) {
                UIApplication.shared.open(url)
            }

        case "GALLERY_PICK_MORE":
            // Reopens iOS's limited-library picker so the user can add to what they
            // shared. The completion handler triggers the rescan.
            PHPhotoLibrary.shared().presentLimitedLibraryPicker(from: self) { [weak self] added in
                print("\u{1f5bc} limited picker closed — \(added.count) photo(s) added")
                guard let self = self, !added.isEmpty else { return }
                // The selfie is still held web-side, so re-entering the scan is enough.
                self.sendToWeb(["type": "onGalleryPickedMore", "payload": ["added": added.count]])
            }

        case "WEB_LOG":
            // console.log in a WKWebView only reaches Safari's Web Inspector, so the
            // SDK mirrors its trace here. Request bodies and all, hence the flag.
            if Self.debugBridgeLogging {
                print((payload["payload"] as? [String: Any])?["text"] as? String ?? "")
            }

        case "GALLERY_RESET":
            // The web layer starts a scan, or abandons the flow. Either way nothing
            // from the previous run should survive into the next one.
            resetScanState()

        case "GALLERY_ANALYSE_PHOTO":
            // Sent when the user selects a photo. See analysePhoto(id:).
            let photoId = (payload["payload"] as? [String: Any])?["assetId"] as? String ?? ""
            analysePhoto(id: photoId)

        case "GALLERY_CAPTURE_PHOTO":
            // A photo taken inside the flow. Held in memory, analysed like any other,
            // never written to the photo library. See storeCapture(id:dataURI:).
            let capture = payload["payload"] as? [String: Any] ?? [:]
            let captureId = capture["id"] as? String ?? ""
            let captureURI = capture["dataURI"] as? String ?? ""
            print("📥 GALLERY_CAPTURE_PHOTO \(captureId) — \(captureURI.count / 1024)KB base64, shot \(capture["shot"] ?? "?")")
            storeCapture(id: captureId, dataURI: captureURI)

        case "GALLERY_CLEAR_CAPTURES":
            // Its own message, not part of GALLERY_RESET: a capture must survive a
            // rescan for more library photos.
            print("🧹 clearing \(CaptureStore.count) held capture(s)")
            CaptureStore.removeAll()

        case "SCHEME_TEST_RESULT":
            // React reporting whether <img src="swan-photo://..."> worked.
            let ok = (payload["payload"] as? [String: Any])?["ok"] as? Bool ?? false
            // Only ever reports on <img>. fetch() against a custom scheme is
            // refused by WebKit outright, so "works" means displays, not readable.
            print(ok
                  ? "\n🧪 <img> loads from the custom scheme (display only; fetch() is still blocked).\n"
                  : "\n🧪 Custom scheme blocked for <img> too — falling back to base64 thumbnails.\n")

        case "COMPONENT_CALLBACK":
            // Everything the flow reports comes through here. Replace each print
            // with your own handling.
            let name = payload["callbackName"] as? String ?? "?"
            let result = payload["payload"] as? [String: Any] ?? [:]

            // The page's pre-selection, for the scan report — see `scanReportURL`.
            if Self.scanReportURL != nil, name == "onImageSelect", result["auto"] as? Bool == true,
               result["selected"] as? Bool == true, let id = result["assetId"] as? String {
                scanReportPicks.append(id)
            }

            // Replace these prints with your own handling. Some echo signed URLs and
            // the user's email — see `debugBridgeLogging`.
            guard Self.debugBridgeLogging else { break }

            switch name {
            case "onUploadStart":
                // Photos are going up. `background` means the user is still picking
                // and this started on its own — no Muse is being built yet.
                let background = (result["background"] as? Bool ?? false) ? " (background)" : ""
                print("\u{1f4e4} upload started\(background) — \(result["photoCount"] ?? 0) photo(s)")

            case "onUploadEnd":
                // One file is up, or failed — per file, so a Live Photo's paired video
                // reports separately under the still's id plus `.mov`.
                let ok = result["uploaded"] as? Bool ?? false
                print("\u{2b06}\u{fe0f} \(result["kind"] ?? "?") \(ok ? "uploaded" : "FAILED") \(result["assetId"] ?? "?") — original \(result["original"] ?? false)\((result["background"] as? Bool ?? false) ? " (background)" : "")\(ok ? "" : " — \(result["error"] ?? "")")")

            case "onComplete":
                // The end of the flow. `photoIds` are the server's — this is what
                // POST /muse/build takes. `assetIds` are local and it does not.
                let muse = result["museId"] as? String ?? "none"
                let status = result["museStatus"] as? String ?? "not attempted"
                print("\u{2705} complete — museId \(muse), build \(status)")
                print("   photoIds \(result["photoIds"] ?? []) height \(result["heightInCm"] ?? 0)")
                // The finished Muse's rendered views, as a JSON array of URLs —
                // what the preview carousel is showing. Decode it to use them.
                print("   museImages \(result["museImages"] as? String ?? "none")")

            case "onCaptureComplete":
                // The camera fallback finished. Upload follows; onComplete closes out.
                print("\u{1f4f8} captured \(result["photoIds"] ?? [])")

            case "onImageSelect":
                // One photo tapped in the picker. `selected` false is a deselect.
                let picked = (result["selected"] as? Bool ?? false) ? "picked" : "dropped"
                print("\u{1f5b1} \(picked) \(result["assetId"] ?? "?") — \(result["count"] ?? 0) selected")

            case "onLoadMore":
                // The scan came up short and the user asked for more. `path` is
                // "shared_library" (OS picker reopened) or "older_photos".
                print("\u{1f50e} load more — \(result["path"] ?? "?"), \(result["shown"] ?? 0) shown, \(result["selected"] ?? 0) selected")

            case "onMuseStart":
                print("\u{1f3a8} muse requested — \(result["photoIds"] ?? [])")

            case "onMuseEnd":
                // The build socket settled. onComplete never runs on failure, so this
                // is the only callback that reports a Muse that did not arrive.
                print("\u{1f3c1} muse \(result["status"] ?? "?") — phase \(result["phase"] ?? "none"), museId \(result["museId"] ?? "none")")
                print("   \(result["message"] ?? "")")
                // The websocket frame as JSON; `missingRoles` and `rejectedPhotos` are
                // in here and nowhere else.
                print("   frame \(result["data"] as? String ?? "none")")

            case "onError":
                // `stage` is photos | upload | muse. The web layer already shows the
                // user a failure screen; this is for your logging and alerting.
                print("\u{274c} \(result["stage"] ?? "?") failed — \(result["message"] ?? "") (\(result["failedCount"] ?? 0) photo(s))")

            case "onRetry":
                // User pushed on the failure screen. `escalated` false = same photos
                // again, true = they gave up on that set and went back.
                print("\u{1f501} retry — \(result["kind"] ?? "?") escalated=\(result["escalated"] ?? false)")

            default:
                print("\u{1f4e9} \(name) \(result)")
            }

        default:
            print("⚠️ Unhandled message type: \(type)")
        }
    }
}

// MARK: - Camera

extension ViewController: WKUIDelegate {

    /// Required on iOS 15+ — without it the scan camera never opens.
    func webView(
        _ webView: WKWebView,
        requestMediaCapturePermissionFor origin: WKSecurityOrigin,
        initiatedByFrame frame: WKFrameInfo,
        type: WKMediaCaptureType,
        decisionHandler: @escaping (WKPermissionDecision) -> Void
    ) {
        // Only the camera, and only from the page we loaded. A blanket grant hands
        // any origin the web view reaches a live capture device.
        guard type == .camera, origin.host == sdkURL.host else {
            decisionHandler(.deny)
            return
        }
        decisionHandler(.grant)
    }
}

// MARK: - Load failures

extension ViewController: WKNavigationDelegate {

    /// The WebContent process was killed, usually memory pressure. Reloaded, with a
    /// cap so a page that exhausts memory does not crash forever.
    func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
        // Capped: if the page is what exhausts memory, reloading reproduces the
        // crash forever.
        guard processReloads < Self.maxProcessReloads else {
            print("\u{1f480} Web content process terminated again — giving up after \(processReloads) reloads")
            pageDidFail("The gallery didn't open. Try again.")
            return
        }

        processReloads += 1
        print("\u{1f480} Web content process terminated — reloading (\(processReloads)/\(Self.maxProcessReloads))")
        startWebReadyWatchdog()
        webView.reload()
    }

    // Without these a page that cannot be reached is a blank screen with an
    // empty console.
    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        if Self.cancelled(error) { return }
        webReadyWatchdog?.cancel()
        print("❌ Could not reach \(sdkURL): \(error.localizedDescription)")
        pageDidFail("Could not reach the gallery. Check your connection and try again.")
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        if Self.cancelled(error) { return }
        webReadyWatchdog?.cancel()
        print("❌ Navigation failed: \(error.localizedDescription)")
        pageDidFail("Could not open the gallery. Try again.")
    }

    /// A version folder that was never published is sent on to the latest release;
    /// any other missing path is a 404 and the flow never starts.
    func webView(_ webView: WKWebView, decidePolicyFor navigationResponse: WKNavigationResponse,
                 decisionHandler: @escaping (WKNavigationResponsePolicy) -> Void) {
        if navigationResponse.isForMainFrame,
           let response = navigationResponse.response as? HTTPURLResponse,
           response.statusCode >= 400 {
            print("❌ \(response.statusCode) for \(response.url?.absoluteString ?? "?") — check sdkURL")
            pageDidFail("The gallery didn't open (\(response.statusCode)). Try again.")
        }
        decisionHandler(.allow)
    }

    /// A pinned version that was never published: the latest release loaded instead.
    /// Only checked when `sdkURL` names a version.
    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        guard sdkURL.path.hasPrefix("/v"), let landed = webView.url, landed.path != sdkURL.path else { return }
        print("⚠️ Asked for \(sdkURL.path), got \(landed.path) — that version is not published; the latest release loaded instead")
    }
}

// MARK: - Gallery scan

extension ViewController {

    /// The face-recognition model — see `FaceModel`. The matching package in
    /// `FaceModels/` must be a member of the target.
    static let faceModel: FaceModel = .sface

    /// Loaded once, at the first scan. Nil only when the model is missing from the
    /// bundle, which the scan reports and stops on rather than matching nothing.
    static let faceRecognizer = FaceRecognizer(faceModel)

    /// Match cutoff for a full-length photo — fronts, and sides not in profile. Lower
    /// distance = more similar. See `FaceModel.matchThreshold`.
    static let matchThreshold: Float = faceModel.matchThreshold

    /// Cutoff for a full-profile side (shoulders side-on, face past `profileYaw`).
    /// The same as `matchThreshold`; a fully side-on head is not scored.
    static let profileMatchThreshold: Float = faceModel.matchThreshold

    /// The gap rule: once every photo is scored, the cut-off is lowered into the gap
    /// between the shopper's photos and a lookalike's. Borderline matches are held back and shown at the end.
    static let gapCutEnabled = true

    /// A match whose face the Muse cannot use (see `MuseScore.filter`) is kept out of
    /// the grid; off, it is shown and ranks last. Everything else only ranks lower.
    static let unusableFaceDrops = true

    /// Feature-print distance under which two matches repeat one shot (repeats ~0.2,
    /// unrelated ~0.8). Both stay in the grid; the page pre-selects one per group.
    /// Match the face before running body pose. Pose is the most expensive request
    /// in the scan and most photos with a face are not the shopper, so a face that
    /// is clearly not a match (at or past `gapCutCeiling`, where the gap rule
    /// stops looking) returns before pose runs. A near miss still takes the body
    /// gates, so the gap rule and the eval see exactly what they saw before. A
    /// small face, which the final score re-crops from a larger render, is only
    /// decided early past `earlyNoMatchSmallFace`, since the re-crop can move it.
    static let matchBeforePose = true
    static let earlyNoMatchSmallFace: Float = 0.75

    /// Decode the next photo while Vision works on this one. The scan is one
    /// serial pipeline otherwise; with this the decode of photo N+1 overlaps the
    /// detection of photo N. One extra render in memory, about 16MB.
    static let decodeAhead = true

    /// The hand detector runs on a crop around the padded face box (`handsCropScale`
    /// times it) instead of the whole render. Only points inside that box count, so
    /// nothing a hand elsewhere could add is lost.
    static let handsOnHeadCrop = true

    /// Read the expression on a second thread while the Vision requests run: the
    /// expression reader is CPU work and Vision mostly Neural Engine, so the two
    /// overlap. Off, the steps run one after another as before.
    static let scoreInParallel = true
    static let handsCropScale: CGFloat = 1.8

    /// Skip a photo from its library record alone, before loading it: too small to
    /// scan (longer side under `minLocalCopyPixels`) or a panorama (flagged, or
    /// wider than this ratio). Nothing is read from the file.
    static let panoramaAspect = 3.0
    static func shapeReject(_ asset: PHAsset) -> String? {
        let w = asset.pixelWidth, h = asset.pixelHeight
        guard w > 0, h > 0 else { return nil }
        if max(w, h) < minLocalCopyPixels { return "only \(max(w, h))px" }
        if asset.mediaSubtypes.contains(.photoPanorama) || Double(max(w, h)) / Double(min(w, h)) > panoramaAspect { return "panorama \(w)x\(h)" }
        return nil
    }

    /// Two matches whose Vision feature prints are closer than this repeat one
    /// shot: the same pose seconds apart. Measured 19 Oct 2026 on a test
    /// library: repeats 0.17–0.25, the same pose with a different expression
    /// 0.19, unrelated photos around 0.8. Both stay in the grid; the page
    /// pre-selects only one of a group.
    static let duplicateDistance: Float = 0.2

    static func featurePrint(of image: UIImage) -> VNFeaturePrintObservation? {
        guard let cgImage = image.cgImage else { return nil }
        let request = VNGenerateImageFeaturePrintRequest()
        try? VNImageRequestHandler(cgImage: cgImage, orientation: Self.cgOrientation(image.imageOrientation), options: [:]).perform([request])
        return request.results?.first
    }

    /// Distances considered when looking for the gap — just past the cut-off, so
    /// the first stranger is in the picture.
    static let gapCutCeiling: Float = 0.65

    /// The cut never goes below this, so a library of two or three photos is
    /// not cut by a spurious gap inside the shopper's own cluster.
    static let gapCutFloor: Float = 0.45

    /// A gap smaller than this is not a gap: a shopper's own photos spread with
    /// gaps under 0.05 between them, strangers sit 0.10 or more away.
    static let gapCutMinGap: Float = 0.08

    /// The lowered cut-off, or nil to keep `matchThreshold`: the midpoint of the
    /// largest gap under the ceiling, clamped to the floor.
    /// Weak-reference fallback. When the gap rule finds no gap and the matches run
    /// up to the cut-off anyway, the reference is usually a poor selfie (three
    /// middling frames put one shopper's borderline photos and the strangers in
    /// one band, and ten strangers were shown). The cut then tightens to this for
    /// that scan: a few of the shopper's own borderline photos go with the
    /// strangers, which beats showing the strangers. Off, the cut-off stands.
    static let weakReferenceCutEnabled = true
    static let weakReferenceCut: Float = 0.50
    /// The fallback applies only when a match sits at or above this, i.e. the
    /// matches really do reach the cut-off; a clean library stays untouched.
    static let weakReferenceReach: Float = 0.55

    /// Own-photo check, logged only (30 Oct 2026). The gap rule and the
    /// weak-reference cut follow the selfie: with a selfie of quality 0.35 the
    /// cut fell to 0.50 and withdrew five of the shopper's own photos (four
    /// fronts with the head turned about 50°, at 0.50–0.59, from a shoot whose
    /// level fronts matched at 0.36–0.40). Photos of one person sit closer to
    /// each other than to a quick selfie, so a second opinion can come from the
    /// shopper's sure matches: those under `ownPhotoCore`. With this on, every
    /// face from `gapCutFloor` to `gapCutCeiling` (matches held for the gap rule
    /// and near-miss strangers alike) is logged with its nearest distance to
    /// those sure matches, to pick a limit from. Nothing is decided by it.
    static let ownPhotoLogEnabled = true
    static let ownPhotoCore: Float = 0.40

    /// Own-photo keep (30 Oct 2026). On, a match the gap rule or the
    /// weak-reference cut would withdraw stays when its face is under
    /// `ownPhotoKeepLimit` from the nearest sure match (see
    /// `ownPhotoLogEnabled`). Measured on three libraries: the shopper's own
    /// borderline photos sat 0.15–0.47 from their sure matches, other people
    /// 0.50 and over (a stranger read exactly 0.500 on one library, so the
    /// limit sits under it). Off, the gap rule withdraws as before.
    static let ownPhotoKeepEnabled = true
    static let ownPhotoKeepLimit: Float = 0.48

    /// The sharpest selfie frame must reach this Vision capture quality, else the
    /// page asks for a retake (`selfie-too-blurry`). The number is relative to the
    /// phone and the light: one phone's good frames read 0.46–0.54, another's
    /// steady frames read under 0.40 and a floor there locked that user on the
    /// selfie screen. Set to catch only a truly blurred tap (0.06–0.11); the weak-
    /// reference fallback handles a merely middling selfie.
    static let selfieMinQuality: Float = 0.25

    /// The lowered cut-off for this run's distances, or nil to keep
    /// `matchThreshold`: the midpoint of the largest gap under the ceiling,
    /// clamped to the floor.
    static func gapCut(distances: [Float]) -> Float? {
        guard gapCutEnabled else { return nil }
        let sorted = distances.filter { $0 < gapCutCeiling }.sorted()
        guard sorted.count >= 2 else { return nil }
        var best: (gap: Float, lo: Float, hi: Float) = (0, 0, 0)
        for i in 0..<(sorted.count - 1) where sorted[i + 1] - sorted[i] > best.gap {
            best = (sorted[i + 1] - sorted[i], sorted[i], sorted[i + 1])
        }
        guard best.gap >= gapCutMinGap else { return nil }
        let cut = max(gapCutFloor, min(matchThreshold, (best.lo + best.hi) / 2))
        return cut < matchThreshold ? cut : nil
    }

    /// How far the head must be turned, in Vision's yaw radians (about 46°), for a
    /// side's face to count as in profile.
    static let profileYaw = 0.8

    /// The cutoff for a selfie. The same as `matchThreshold`: own close-up face
    /// frames and strangers' fell on either side of the one cutoff.
    static let selfieMatchThreshold: Float = faceModel.matchThreshold

    /// Only consider photos with exactly one face. The minimum distance over N faces
    /// is a best-of-N draw, so this is a precision fix as much as a speed one.
    static let requireSingleFace = true

    /// Mirror shots: up to this many faces are checked and the photo is one person
    /// only if every face matches the shopper. 1 turns the check off.
    static let sameShopperFacesMax = 3

    /// How large a second face or body must be, against the largest, to count as
    /// someone else rather than a passer-by, poster or reflection.
    static let bystanderRatio: CGFloat = 0.25

    /// How far the selfie's head may be turned before a retake is asked for. The
    /// same limits as the library's flat-face rule (`MuseScore.tiltedYawDegrees` /
    /// `tiltedPitchDegrees`), so the shopper's own selfie is never one the scan
    /// would rank as tilted. Pitch was 25 until 1.3.4: a chin a little down passes
    /// at 15, a look down at the phone does not.
    static let selfieMaxYawDegrees: Double = Double(MuseScore.tiltedYawDegrees)
    static let selfieMaxPitchDegrees: Double = Double(MuseScore.tiltedPitchDegrees)

    /// Match against every selfie frame, not only the sharpest: a photo then scores
    /// its second-smallest distance, so the best two frames must agree. Off by default.
    static let matchAgainstAllFrames = false

    /// A face narrower than this, in the best copy the phone holds, is skipped.
    /// Permissive, since a full-body photo has a small face by construction.
    static let minFacePixels: CGFloat = 120

    /// Require the lower body to be visible: a headshot and a full-length photo match
    /// a face matcher equally well, only body pose separates them.
    static let requireFullBody = true

    /// Face width, as a fraction of the frame's shorter side, for a photo with no
    /// lower body to count as a selfie (cropped shots 15–25%, real selfies 37%+).
    static let selfieFaceRatio: CGFloat = 0.30

    /// The v2 type sort — GALLERY_PICK_V2_PLAN.md, item 1. On: a selfie is a
    /// face with no knee or ankle joint in frame (hips may show) and, once
    /// `selfieEyeFloorEnabled` is on, eye spacing of `selfieEyeSpacingPixels`
    /// or more; a knee-up photo is never a selfie; a full-length photo turned
    /// between `threeQuarterDegrees` and `sideTurnDegrees` is a three-quarter,
    /// which the page puts in a side slot. Off: the 1.3.x rules — a face 30% of
    /// the frame is a selfie, full-length photos are front or side only.
    static let typeSortV2 = true
    /// Pupil to pupil, in the original photo's pixels (the face texture comes
    /// from the original, as the 120 px face floor is measured), under which a
    /// face is too small for the Muse. The spec's 60 px gate; the 120 px face
    /// floor is about 48 px of eye spacing, so this removes faces up to about
    /// 145 px wide. Counted on two test libraries first (0 selfies under it on
    /// both, 29 Oct 2026), then switched on. `selfieSmallEyes` in the summary
    /// keeps the count.
    static let selfieEyeSpacingPixels: CGFloat = 60
    static let selfieEyeFloorEnabled = true

    /// The v2 selfie gates — GALLERY_PICK_V2_PLAN.md, item 2, the part that
    /// needs no new model. On, for photos sorted as selfies: the head pitched
    /// past `gatePitchDegrees` or turned past `gateYawDegrees`, the mouth open
    /// or teeth showing, a black or blown exposure, the face contour at the
    /// frame's edge and the camera under `tooCloseCm` each rule the photo out
    /// (score 0, hidden) where 1.3.x ranked it lower or let it through. Off: the
    /// 1.3.x rules. The covered-face gates (hood, scarf, mask, object) wait for
    /// the segmenter; see `coverLabels` for what is logged meanwhile.
    static let selfieGatesV2 = true
    /// Pitch at the spec's 15°. Yaw at 20°, not the spec's starting 15°: on a
    /// 2,944-photo library 5 of the 12 faces gated at 15° were turned 17° to
    /// 24°, near-frontal by eye, and Vision's yaw is a rough reading; the
    /// clear turns sat at 36° and over (29 Oct 2026).
    static let gatePitchDegrees: Float = 15
    static let gateYawDegrees: Float = 20
    /// Camera to face, from the iris (11.7 mm in everyone) or, without iris
    /// points, the eye spacing (63 mm on average) and the focal length. A photo
    /// with no camera data at all is read as taken on a phone's front camera,
    /// `assumedFocal35mm`: the iPhone 12, 13 Pro and 15 Pro front cameras all
    /// write 30 mm equivalent (three test libraries, 29 Oct 2026). The summary
    /// counts how often that assumption was used. Clean selfies on two
    /// libraries measured 27 to 45 cm; nothing real sat under 25.
    static let tooCloseGateEnabled = true
    static let tooCloseCm: Float = 25
    static let irisMm: Float = 11.7
    static let eyeSpacingMm: Float = 63
    static let assumedFocal35mm: Float = 30
    /// The spec's "no camera data" gate: a selfie whose original carries no
    /// camera make, model or focal length (saved from an app, exported and
    /// re-imported) is out. A photo whose metadata cannot be read in time (only
    /// in iCloud) is not judged on it. Counted in the summary as `noCameraData`.
    static let noCameraDataGateEnabled = true
    /// Either eye under `relativeOpenness` of the shopper's usual openness: the
    /// median over the scan's clean selfies, once `relativeBaselineMin` of them
    /// are in; decided at the end of the scan and withdrawn through `dropped`.
    /// The fixed closed-eye and wink gates still apply as the photo streams.
    static let relativeEyeGateEnabled = true
    static let relativeOpenness: Float = 0.4
    static let relativeBaselineMin = 3

    /// The v2 selfie score — GALLERY_PICK_V2_PLAN.md, item 3. On, a selfie
    /// that passed the gates scores T, 0 to 1: six groups, each the lowest of
    /// its signals, combined by a weighted geometric mean (pose 0.30, light
    /// 0.20, gaze 0.15, expression 0.15, visibility 0.10, detail 0.10). Each
    /// signal is a straight line from 1 at its tolerance to 0 at its limit.
    /// T at `tierALine` or above is Tier A; the page pre-selects selfies from
    /// Tier A only and sends `tier` with the match. It replaces, for selfies,
    /// the eight-part average, Apple's capture quality, the multipliers and
    /// the two score bands. Fronts and sides keep the 1.3.x score until item
    /// 5. Off: the 1.3.x score for every photo.
    ///
    /// Angles are Vision's, the same readings the gates use, so a selfie the
    /// gates let through is never zeroed by a second reading of its angle.
    /// Gaze and camera height score 1 until they are measured (plan, item 3
    /// decisions). Measured 30 Oct 2026 for the expression limits: clearly
    /// pursed lips read 0.87–1.00; relaxed lips, checked by eye on a library,
    /// read up to 0.45, and light deliberate puckers that look near-normal
    /// 0.29–0.37; a frown read 0.31, neutral brows 0.15 or less.
    static let selfieScoreV2 = true
    static let tierALine: Float = 0.70

    /// The v2 order — GALLERY_PICK_V2_PLAN.md, item 4. On, each match carries
    /// `order` for the grid and the pre-selection, and `takenAt` (capture time,
    /// ms) for the page's one-session rule; `score` stays T for the badge.
    /// Within Tier A, a selfie's R = 0.45 T + 0.40 P + 0.15 recency, with P =
    /// 0.7 × 0.5 (no aesthetic score yet) + 0.3 × the person's choices
    /// (favourite 0.5, edited 0.25, their pick from a burst 0.25, capped at 1);
    /// a full-length photo's R = 0.8 T + 0.2 recency. Fronts and sides have no
    /// tier until item 5, so the 1.3.x bands stand in: a clean photo is Tier
    /// A, a demoted one Tier B. Tier A sends 1 + R; Tier B sends T, so it keeps
    /// its order, after every Tier A photo. Off: no `order`, the page ranks by
    /// `score`.
    static let orderV2Enabled = true
    /// Recency, in months: 1 up to the first, 0 from the second.
    static let selfieRecency: (good: Double, bad: Double) = (12, 36)
    static let fullLengthRecency: (good: Double, bad: Double) = (6, 24)

    /// `order` and `takenAt` for one match — see `orderV2Enabled`.
    static func orderFields(asset: PHAsset, type: PhotoType, score: MuseScore?) -> [String: Any] {
        guard orderV2Enabled, let score else { return [:] }
        var fields: [String: Any] = [:]
        var recency: Double = 0
        if let taken = asset.creationDate {
            fields["takenAt"] = Int(taken.timeIntervalSince1970 * 1000)
            let months = Date().timeIntervalSince(taken) / (30.44 * 24 * 3600)
            let curve = type == .selfie ? selfieRecency : fullLengthRecency
            recency = min(max((curve.bad - months) / (curve.bad - curve.good), 0), 1)
        }
        let t = Double(score.value)
        // A body-scored photo with no tier sits under the usable floor: never Tier A.
        let tierA = score.tier.map { $0 == "A" } ?? (score.body == nil && !score.demoted)
        guard tierA else { fields["order"] = t; return fields }
        let r: Double
        if type == .selfie {
            var choices: Double = 0
            if asset.isFavorite { choices += 0.5 }
            if asset.hasAdjustments { choices += 0.25 }
            if asset.burstSelectionTypes.contains(.userPick) { choices += 0.25 }
            let p = 0.7 * 0.5 + 0.3 * min(choices, 1)
            r = 0.45 * t + 0.40 * p + 0.15 * recency
        } else {
            r = 0.8 * t + 0.2 * recency
        }
        fields["order"] = 1 + r
        return fields
    }
    static let scoreWeightsV2: [(name: String, weight: Float)] = [
        ("pose", 0.30), ("light", 0.20), ("gaze", 0.15), ("expression", 0.15), ("visibility", 0.10), ("detail", 0.10),
    ]
    /// Pose, in degrees: tolerance then limit. Yaw ends at the yaw gate (20°,
    /// agreed 30 Oct 2026) rather than the spec's 15°, so a selfie the gate
    /// lets through never scores a zero pose.
    static let posePitch: (good: Float, bad: Float) = (3, 15)
    static let poseYaw: (good: Float, bad: Float) = (5, 20)
    static let poseRoll: (good: Float, bad: Float) = (5, 20)
    /// Camera to face, in centimetres. Full marks from 40 cm, not the spec's
    /// 45 (agreed 30 Oct 2026): clean selfies on every library measured 27 to
    /// 45 cm, and at 45 an arm's-length selfie at 30–35 cm lost Tier A on
    /// distance alone. Zero stays at 25 cm, the too-close gate.
    static let poseDistance: (good: Float, bad: Float) = (40, 25)
    /// Light: the brighter half of the face over the darker half; the face
    /// over the whole frame (backlight); the share of blown-out face pixels.
    /// Bright only (30 Oct 2026): the face box takes in hair, beard and a
    /// night background, and counting black pixels zeroed well-lit selfies.
    static let lightEvenness: (good: Float, bad: Float) = (1.3, 2.0)
    static let lightBacklight: (good: Float, bad: Float) = (0.8, 0.4)
    static let lightClipped: (good: Float, bad: Float) = (0.01, 0.05)
    /// Expression: each of these caps the group. A closed smile, eyes held
    /// wide or raised brows, a pucker and a frown at 0.5; an open smile (kept
    /// by `MuseScore.smileKeepsTeeth`) at 0.4, so it sits behind a closed one.
    static let expressionCapped: Float = 0.5
    static let expressionOpenSmile: Float = 0.4
    /// Raised from 0.25 to 0.6 on 30 Oct 2026: two relaxed-lip selfies read
    /// 0.29 and 0.30 and dropped to Tier B.
    static let puckerLimit: Float = 0.6
    static let frownLimit: Float = 0.25
    /// Eyes held wide or raised brows cap expression and send `wideEyes`: the
    /// page pre-selects such a selfie only when no other Tier A selfie is
    /// left (agreed 30 Oct 2026). The eyes-wide reading counts from this line, lower than the 1.3.x
    /// `MuseScore.eyeWideFilter`: a staring selfie read 0.08, everyday
    /// selfies 0.00–0.03.
    static let wideEyesLine: Float = 0.05
    /// Visibility: the share of the face oval that is skin or hair, from
    /// `FaceCover`. Clear glasses cap it at `glassesCap`.
    static let visibilityShare: (good: Float, bad: Float) = (0.95, 0.85)
    static let glassesCap: Float = 0.85
    static let glassesConfidence: Float = 0.5
    /// Detail: eye spacing in the original's pixels; sharpness keeps its 1.3.x
    /// reading.
    static let detailEyeSpacing: (good: Float, bad: Float) = (120, 60)
    /// A selfie whose eyes are under this many pixels apart (in the original)
    /// is Tier B whatever its T (agreed 30 Oct 2026): detail is a tenth of the
    /// score, so a face shot from metres away with a zoom lens still reached
    /// Tier A at 80 px, and a face that small is a poor reference for the Muse.
    /// It stays in the grid. Hand-held selfies read 300 to 550 px.
    static let tierAEyeSpacingMin: Float = 90

    /// The v2 full-length score — GALLERY_PICK_V2_PLAN.md, item 5, part a. On,
    /// a matched front, three-quarter or side is scored by `BodyScore`: how
    /// clearly the body shows under the clothes, from Vision's person
    /// segmentation and the pose joints, with openness and image quality. The
    /// face no longer decides anything for these photos: sunglasses, a hand
    /// over the face, closed eyes and a smile neither filter nor lower them
    /// (the document gate still applies). Tier A at `fullLengthTierALine`,
    /// usable down to `fullLengthUsableFloor`; the page pre-selects Tier A
    /// first and fills a shortfall from Tier B. Off: the 1.3.x face score.
    static let fullLengthScoreV2 = true
    static let fullLengthTierALine: Float = 0.70
    static let fullLengthUsableFloor: Float = 0.45
    /// The outfit multipliers of the 1.3.x score (`MuseScore.outfitMultiplier`)
    /// also apply on top of the body score: a busy torso always, and tailoring
    /// or formal wear from the whole-photo labels only while `garmentCapsEnabled`
    /// is off, since the caps cover the same labels. The tier is the body's own;
    /// only the value and the order move. Off, the body score stands alone.
    static let fullLengthOutfitMultiplier = true
    /// Item 5b, garment caps. A garment the whole-photo classifier names at or
    /// over its line caps the body regions it covers (`BodyScore.Caps`): the
    /// region can read no higher than the cap, whatever the fit and outline
    /// say. Measured 30 Oct 2026 on the 121 test photos: suits fell from
    /// 0.72–0.96 to 0.46–0.61, puffers and winter jackets to 0.41–0.78, hoodies
    /// lost about 0.1; dresses already read legs 0 under the hem. `jacket`
    /// also names fitted denim, so its cap is 0.5, not a coat's. Coats,
    /// cardigans and fleeces have no reliable label and are left to the fit.
    static let garmentCapsEnabled = true
    /// Item 5b, objects. On, MediaPipe's object detector (`BodyObjects`) runs
    /// on every matched front or side — about 80 ms — and each body region is
    /// lowered by the share of it a bag, umbrella, bicycle or chair covers;
    /// objects over a quarter of the body make the photo unusable
    /// (`BodyScore.objectBodyGate`). Off: no detector, no model load.
    static let objectReadEnabled = true
    /// Item 6, early stop — GALLERY_PICK_V2_PLAN.md. On, the local pass stops
    /// once `earlyStopTierA` distinct Tier A shots of each kind are in hand
    /// (held matches and repeats of a shot do not count), but never before
    /// `earlyStopMinExamined` photos, so the gap rule still sees enough
    /// distances; the iCloud pass is then skipped and the summary says how
    /// many photos were not examined. Photos not examined have no store
    /// record and are read next time if the recent ones fall short. Every
    /// progress and match message carries the Tier A counts so far as
    /// `tierA`, which the page counts against the five slots.
    static let earlyStopEnabled = false
    static let earlyStopMinExamined = 500
    /// Item 6, excluded tiles. On, a match the face or body gates drop is still
    /// sent to the page with `tier: "x"` and `gate` (why), no score, and goes
    /// last in the completion list, so a review build can show it greyed at
    /// the bottom of the grid with the gate's name, as the client's test
    /// sheets do. The page shows them only with its own switch on. Off for a
    /// release to shoppers: nothing excluded is sent.
    static let sendExcludedMatches = false
    static let earlyStopTierA: [String: Int] = ["selfie": 10, "front": 6, "side": 6]
    /// The page's slot for a type: a three-quarter photo fills a side slot.
    static func slot(of type: PhotoType) -> String {
        switch type { case .selfie: return "selfie"; case .front: return "front"; default: return "side" }
    }
    /// Indian formal wear, read 30 Oct 2026 on a tester's photos: a sherwani
    /// is `lab_coat` 0.33–0.49 (never seen on the 121 test photos) or `suit`
    /// 0.49–0.50; a bandhgala only `suit` 0.24–0.36. So `suit` has two lines:
    /// a sure suit from 0.4 takes the full cap, a likely one from 0.22 (plain
    /// clothes never read over 0.21 on the test photos) takes a jacket's.
    static let garmentCaps: [(labels: Set<String>, line: Float, torso: Float, legs: Float, arms: Float)] = [
        (["suit", "tuxedo"], 0.4, 0.2, 1, 0.2),
        (["lab_coat"], 0.3, 0.2, 1, 0.2),
        (["suit", "tuxedo"], 0.22, 0.5, 1, 0.5),
        (["gown", "sari", "kimono", "wedding_dress"], 0.3, 1, 0.2, 1),
        (["hoodie"], 0.5, 0.5, 1, 1),
        (["jacket"], 0.6, 0.5, 1, 0.5),
    ]
    /// Prints every whole-photo label at `fullLengthLabelFloor` or over on a
    /// body-scored photo, to learn what the classifier calls Indian formal
    /// wear before the 5b cap list is written.
    static let fullLengthLabelLog = true
    static let fullLengthLabelFloor: Float = 0.2
    /// Part 2 of the selfie gates: what covers the face, read by `FaceCover`
    /// from the MediaPipe selfie segmenter on a matched selfie that no other
    /// gate has dropped. With `coverGatesEnabled` a selfie is out when the
    /// hairline band, the jaw band or the face oval is covered past the
    /// limits below, or when Vision's classifier names a cap or hat
    /// (`MuseScore.hatLabels`, which only lowered the score before). With
    /// the gates off every matched selfie is read: its MATCH line carries the
    /// readings and the summary counts them against the limits, so the
    /// gates' reach can be seen before they are turned on.
    static let coverReadEnabled = true
    static let coverGatesEnabled = true
    /// From three libraries (29 Oct 2026): caps read hairline 0.37–0.52 and a
    /// hood 0.82 against 0.00–0.12 bare; bare jaws read 0.00–0.09, except
    /// 0.33 with the chin lowered onto a dark polo collar, so the jaw limit
    /// sits above that; eyeglasses read face 0.03–0.06 and sunglasses
    /// 0.26–0.34, so the face limit sits above glasses.
    static let coverHairlineLimit: Float = 0.3
    static let coverJawLimit: Float = 0.4
    static let coverFaceLimit: Float = 0.15
    /// Documents (30 Oct 2026): a photographed passport, ID card or printed
    /// page matches the face printed on it and passes every gate above, and
    /// must never reach the Muse or an upload. With `documentGateEnabled` a
    /// match of any type is out ("document") when the whole-image
    /// classifier's document-like labels (`documentLabels`) sum to
    /// `documentLabelSumLimit` or more, or ("handwriting") when handwriting
    /// alone reads `handwritingLimit` or more. Measured: passport photo 1.05
    /// and 1.73, Aadhaar 0.78, voter ID 0.77, PAN card 0.72; clean matches on
    /// two libraries 0.16 at most, one selfie with paper behind it 0.37.
    /// Handwriting: clean 0.06 at most, a passport page 0.42; ID cards read
    /// 0.00 to 0.11, so the label sum is what catches them.
    ///
    /// Second rule, for a document the labels only half see: out ("document")
    /// when the labels sum to `documentPageLabelLimit` or more and Vision's
    /// document segmentation finds a page at `documentConfidenceLog` or more,
    /// with the matched face inside it, covering less than
    /// `documentPageAreaLimit` of the frame. Measured: two documents read
    /// labels 0.40 and 0.42 with a page at 0.98–0.99 over 28% and 39% of the
    /// frame; the selfie at 0.37 had its "page" over 99% of the frame (the
    /// whole picture), and a full-length front with a page at 0.99 read labels
    /// 0.03. Clean matches never reached 0.3.
    ///
    /// Logged with every match, not part of the gate: Vision's text detector
    /// (one false box can cover a third of a clean selfie), and its document
    /// segmentation on its own (fires on doors and frames behind a
    /// full-length photo).
    static let documentReadEnabled = true
    static let documentGateEnabled = true
    static let documentLabels: Set<String> = ["document", "printed_page", "screenshot", "passport", "handwriting",
                                              "ticket", "receipt", "text", "id_card", "signature", "paper"]
    static let documentLabelSumLimit: Float = 0.5
    static let handwritingLimit: Float = 0.3
    static let documentPageLabelLimit: Float = 0.3
    static let documentPageAreaLimit: Float = 0.9
    static let documentTextShareLog: Float = 0.10
    /// Vision's document segmentation, counted at this confidence when the
    /// matched face sits inside the document it found.
    static let documentConfidenceLog: Float = 0.8

    /// A face's width against the frame's shorter side — the one number every
    /// selfie decision reads, so the scan and a tap cannot disagree about it.
    static func faceRatio(boxWidth: CGFloat, in cgImage: CGImage) -> CGFloat {
        boxWidth * CGFloat(cgImage.width) / CGFloat(min(cgImage.width, cgImage.height))
    }

    /// Pupil to pupil in the image's pixels, from the eye landmarks of one face —
    /// the v2 selfie floor's measure. Nil when the face has no landmarks.
    static func eyeSpacing(of face: VNFaceObservation?, in cgImage: CGImage, handler: VNImageRequestHandler? = nil) -> CGFloat? {
        guard var face else { return nil }
        // The scan detects faces as rectangles; the landmarks are fetched here
        // for the one face that needs them, on the handler that already holds
        // the image — a few ms.
        if face.landmarks == nil, let handler {
            let request = VNDetectFaceLandmarksRequest()
            request.inputFaceObservations = [face]
            try? handler.perform([request])
            guard let withLandmarks = request.results?.first else { return nil }
            face = withLandmarks
        }
        guard let points = FaceRecognizer.fivePoints(face, width: cgImage.width, height: cgImage.height) else { return nil }
        return hypot(points[1].x - points[0].x, points[1].y - points[0].y)
    }

    /// Head turn, in Vision's yaw radians, for a full-length photo to count as a
    /// side: fronts come in at 0.02–0.07 and sides at 0.35 and up.
    static let sideYawThreshold = 0.25

    /// How sure Vision must be of a joint before it counts as seen.
    static let bodyJointConfidence: Float = 0.3

    /// Ankles a head-to-toe photo must show. One, since a side photo routinely hides
    /// the far ankle.
    static let minAnkles = 1

    /// How much of the image height, eyes to lowest ankle, the person must span. The
    /// bar with one ankle found; with both, `minBodySpanBothAnkles` applies.
    static let minBodySpan: CGFloat = 0.55
    static let minBodySpanBothAnkles: CGFloat = 0.40

    /// Room below the lowest ankle, as a fraction of the span, so the feet are in
    /// frame (toes cut off ~0.05, good full-length ~0.14+).
    static let minFootRoom: CGFloat = 0.10

    /// The knee rule: a photo that fails the ankle rule above still passes with
    /// the head and at least `minKnees` knees, the figure tall enough in the
    /// frame, and the knees well below the hips. Off since 29 Oct 2026: the
    /// Muses built from head-to-knee photos were not good enough, so only head
    /// to toe counts as full length and a knee-length photo is "not head to
    /// toe". The rule was removed once before because strangers reached the
    /// grid through it under FeaturePrint, which matched the whole picture;
    /// that reason is gone (SFace matches the face), this one is the Muse.
    static let kneeLengthEnabled = false
    static let minKnees = 1

    /// Head to lowest knee as a fraction of the image height: the ankle spans
    /// scaled by three quarters, with a little margin.
    static let minKneeSpan: CGFloat = 0.38
    static let minKneeSpanBothKnees: CGFloat = 0.28

    /// How far the lowest knee sits below the hips, against the torso (standing
    /// 0.8–1.0, sitting under 0.3). Keeps seated photos out; 0 turns it off.
    static let minKneeDrop: CGFloat = 0.5

    /// Body turn, in degrees, for a full-length photo to be a side. Estimated from
    /// the shoulder spread against the torso, accurate to about ±10°.
    static let sideTurnDegrees: Double = 45
    static let frontShoulderSpread: CGFloat = 0.60

    /// Shoulder spread below which a full-length photo is a side — `sideTurnDegrees`
    /// as a spread.
    static let sideShoulderSpread: CGFloat = frontShoulderSpread * CGFloat(cos(sideTurnDegrees * .pi / 180))

    /// Turn from the camera, in degrees, from which a full-length photo is a
    /// three-quarter rather than a front — the spec's "about 30°". Up to
    /// `sideTurnDegrees` it is a three-quarter, past that a side; both fill
    /// side slots on the page. Only with `typeSortV2`.
    static let threeQuarterDegrees: Double = 30
    static let threeQuarterShoulderSpread: CGFloat = frontShoulderSpread * CGFloat(cos(threeQuarterDegrees * .pi / 180))

    /// The body's turn from the camera that a shoulder spread implies, in degrees.
    static func turnDegrees(spread: CGFloat) -> Double {
        acos(Double(min(1, max(0, spread / frontShoulderSpread)))) * 180 / .pi
    }

    /// Joint confidence for the spread, lower than `bodyJointConfidence` because a
    /// side view half hides the far shoulder.
    static let spreadJointConfidence: Float = 0.1

    /// One photo's type, from values the caller already has. Shared by the scan and
    /// `classifyPhotoType` so the two cannot disagree.
    static func photoType(faceRatio: CGFloat, eyeSpacing: CGFloat? = nil, yaw: Double?, body: BodyCheck) -> PhotoType {
        if typeSortV2 {
            // A selfie is a face with no lower-body joint in frame. Until the eye
            // floor is switched on, the 1.3.x face ratio stands in beside it, so
            // the count of selfies the floor would drop can be read first.
            let bigEnough = selfieEyeFloorEnabled
                ? (eyeSpacing ?? 0) >= selfieEyeSpacingPixels
                : faceRatio >= selfieFaceRatio || (eyeSpacing ?? 0) >= selfieEyeSpacingPixels
            if body.lowerJoints == 0 && bigEnough { return .selfie }
            // Not a selfie and not head to toe (or knee): neither.
            if !body.isHeadToToe { return .unknown }
            // The body's own turn: side past `sideTurnDegrees`, three-quarter from
            // `threeQuarterDegrees`, front below. The head only without shoulders.
            if let spread = body.shoulderSpread {
                if spread < sideShoulderSpread { return .side }
                return spread < threeQuarterShoulderSpread ? .threeQuarter : .front
            }
            guard let yaw else { return .unknown }
            return headType(yaw: yaw)
        }
        // Not head to toe. A big face is a face photo; a small one is someone cut
        // off or too far away, which the full-body gate exists to reject.
        if !body.isHeadToToe {
            return faceRatio >= selfieFaceRatio ? .selfie : .unknown
        }
        // The body's own turn decides — see `sideShoulderSpread`. The head's turn only
        // when the shoulders could not be measured.
        if let facing = body.bodyFacing { return facing }
        guard let yaw else { return .unknown }
        return headType(yaw: yaw)
    }

    /// Front or side by the head's turn alone: the fallback above, and logged beside the
    /// body's answer so the two can be compared.
    static func headType(yaw: Double) -> PhotoType {
        abs(yaw) > sideYawThreshold ? .side : .front
    }

    /// Builds the reference face print off the main thread, then asks for photo
    /// access. Of `referenceImages` the sharpest becomes the reference.
    func startGalleryScan(monthsBack: Int, referenceImage: String?, referenceImages: [String]? = nil) {
        // Fail fast: without a usable reference the scan would report a confident zero.
        guard let reference = referenceImage else {
            print("🚫 No reference image in payload")
            sendToWeb(["type": "onGalleryScanComplete",
                       "payload": ["assetIds": [], "error": "no-reference"]])
            return
        }

        // Whatever the web side did or did not send, a scan always begins clean.
        resetScanState()

        // A first-time user sees the photo-access prompt now, while the reference
        // is built behind it, instead of after a pause with nothing on screen.
        // `requestAccessAndScan` asks again once the reference is ready; by then
        // the answer is known and it returns at once.
        if PHPhotoLibrary.authorizationStatus(for: .readWrite) == .notDetermined {
            PHPhotoLibrary.requestAuthorization(for: .readWrite) { _ in }
        }

        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self = self else { return }

            // Eval mode only: every run is matched against one saved selfie, so a
            // change in the scores comes from the code, not from a new selfie.
            let referenceURI = Self.evalReferenceSelfie(reference)
            let pinned = referenceURI != reference

            // The frames to choose from: the page's set, or the one frame an older
            // page sends. Under a pinned eval selfie there is nothing to choose.
            let sent = referenceImages ?? []
            let frameURIs = pinned ? [referenceURI] : Array((sent.isEmpty ? [reference] : sent).prefix(3))
            let frames = frameURIs.compactMap { Self.image(fromDataURI: $0) }
            if Self.saveReferenceFrames { Self.saveFrames(frames) }
            if pinned, sent.count > 1 {
                print("🧪 eval selfie pinned — \(sent.count) frames from the page ignored")
            }

            guard !frames.isEmpty else {
                print("🚫 Reference image could not be decoded")
                DispatchQueue.main.async {
                    self.sendToWeb(["type": "onGalleryScanComplete",
                                    "payload": ["assetIds": [], "error": "no-reference"]])
                }
                return
            }

            let chosen = self.chooseReference(frames)
            let selfie = chosen.image
            self.lastReferenceNote = chosen.note
            self.lastReferenceFrames = frames.count
            self.lastReferenceIndex = chosen.index
            self.lastReferenceQuality = chosen.quality
            self.lastReferenceQualities = chosen.qualities
            self.lastReferenceSpread = nil
            self.lastReferenceShift = nil
            if frames.count > 1 { print("🤳 Reference: \(chosen.note)") }

            // One face, looking at the camera (see `selfieMaxYawDegrees`). The page
            // returns to the selfie screen with the reason; nothing below runs.
            // Too blurred to be the reference — see `selfieMinQuality`. Only when a
            // quality was measured: a single frame from an older page has none.
            if let quality = chosen.quality, quality < Self.selfieMinQuality {
                print("🤳 Selfie rejected — sharpest frame quality \(String(format: "%.2f", quality)), under \(Self.selfieMinQuality)")
                DispatchQueue.main.async {
                    self.sendToWeb(["type": "onGalleryScanComplete",
                                    "payload": ["assetIds": [], "error": "selfie-too-blurry"]])
                }
                return
            }

            // One face, looking at the camera — see `selfieMaxYawDegrees`. The
            // page returns to the selfie screen with the reason, as it does for
            // no face, and the rejected frame is dropped on both sides: nothing
            // below runs, so no reference is kept from it.
            if let rejection = self.selfieRejection(in: selfie) {
                print("🤳 Selfie rejected — \(rejection.note)")
                DispatchQueue.main.async {
                    self.sendToWeb(["type": "onGalleryScanComplete",
                                    "payload": ["assetIds": [], "error": rejection.error]])
                }
                return
            }

            guard let recognizer = Self.faceRecognizer else {
                DispatchQueue.main.async {
                    self.sendToWeb(["type": "onGalleryScanComplete",
                                    "payload": ["assetIds": [], "error": "matcher-unavailable"]])
                }
                return
            }

            // The selfie is the reference: its face aligned and embedded exactly
            // like every library face, by `FaceRecognizer`.
            guard let selfieCG = selfie.cgImage,
                  let embedding = recognizer.embedding(in: selfieCG) else {
                print("🚫 No face found in the selfie")
                DispatchQueue.main.async {
                    self.sendToWeb(["type": "onGalleryScanComplete",
                                    "payload": ["assetIds": [], "error": "no-face-in-selfie"]])
                }
                return
            }
            self.referenceEmbedding = embedding

            // Case A, off by default: every other frame with a face becomes a
            // reference too — see `matchAgainstAllFrames`.
            self.lastReferenceBlended = 1

            // The other usable frames join the reference — see `blendReferenceFrames`.
            if Self.blendReferenceFrames, frames.count > 1 {
                var blended = embedding
                var used = [chosen.index]
                var spread: Float = 0
                for (index, frame) in frames.enumerated() where index != chosen.index {
                    guard let quality = chosen.qualities[index], quality >= Self.blendQualityFloor,
                          let cg = frame.cgImage, let other = recognizer.embedding(in: cg) else { continue }
                    spread = max(spread, FaceRecognizer.distance(embedding, other))
                    blended = zip(blended, other).map { $0 + $1 }
                    used.append(index)
                }
                if used.count > 1 {
                    let norm = blended.reduce(0) { $0 + $1 * $1 }.squareRoot()
                    let reference = blended.map { $0 / norm }
                    self.referenceEmbedding = reference
                    self.lastReferenceSpread = spread
                    self.lastReferenceShift = FaceRecognizer.distance(embedding, reference)
                    let names = used.sorted().map { String($0 + 1) }.joined(separator: ", ")
                    self.lastReferenceNote += " · blended frames \(names)"
                    print("🤳 Reference blended from frames \(names) (quality \(Self.blendQualityFloor) and up) — frames up to \(String(format: "%.3f", spread)) apart, blend \(String(format: "%.3f", self.lastReferenceShift ?? 0)) from the tapped frame")
                }
                self.lastReferenceBlended = used.count
            }

            // Case A, off by default: every other frame with a face becomes a
            // reference too — see `matchAgainstAllFrames`.
            if Self.matchAgainstAllFrames {
                self.extraReferenceEmbeddings = frames.enumerated()
                    .filter { $0.offset != chosen.index }
                    .compactMap { $0.element.cgImage.flatMap { recognizer.embedding(in: $0) } }
                if !self.extraReferenceEmbeddings.isEmpty {
                    print("🤳 Matching against \(1 + self.extraReferenceEmbeddings.count) frames — best two must agree")
                }
            }

            let selfiePx = "\(selfieCG.width)x\(selfieCG.height)"
            print("🤳 Reference face ready — selfie \(selfiePx), model \(Self.faceModel.rawValue), cutoff \(String(format: "%.2f", Self.matchThreshold))")

            // The expression reader and hand detector load on first use; paid here
            // rather than on the first match. Nothing is kept from either pass.
            FaceExpression.warmUp()
            if Self.coverReadEnabled { FaceCover.warmUp() }
            if Self.fullLengthScoreV2 && Self.objectReadEnabled { BodyObjects.warmUp() }
            if Self.evalMode, let crop = self.crop(selfieCG, to: CGRect(x: 0.25, y: 0.25, width: 0.5, height: 0.5)) {
                recognizer.benchmark(on: crop)
            }
            let warmHands = VNDetectHumanHandPoseRequest()
            try? VNImageRequestHandler(cgImage: selfieCG, orientation: .up, options: [:]).perform([warmHands])

            self.saveDebugImage(selfie, name: "00-selfie")
            if let croppedSelfie = self.croppedFace(from: selfie) {
                self.saveDebugImage(croppedSelfie, name: "00-reference-crop")
            }

            DispatchQueue.main.async { self.requestAccessAndScan(monthsBack: monthsBack) }
        }
    }

    private func requestAccessAndScan(monthsBack: Int) {
        // .readWrite despite never writing: PHAccessLevel offers only .addOnly
        // (write-only) and .readWrite, so this is the only level that grants reads.
        PHPhotoLibrary.requestAuthorization(for: .readWrite) { [weak self] status in
            DispatchQueue.main.async {
                guard let self = self else { return }
                switch status {
                case .authorized:
                    self.isLimitedAccess = false
                    self.scanAssets(monthsBack: monthsBack)
                case .limited:
                    // The user shared only a hand-picked subset, so the fetch below
                    // sees just those. A small result count is expected, not a bug.
                    print("⚠️ Limited photo access — scanning only the shared subset")
                    self.isLimitedAccess = true
                    self.scanAssets(monthsBack: monthsBack)
                default:
                    print("🚫 Photo access denied")
                    self.sendToWeb(["type": "onGalleryScanComplete",
                                    "payload": ["assetIds": [], "denied": true]])
                }
            }
        }
    }

    /// Watches the network for the scan's iCloud sizing. Started once and kept for
    /// the life of the app.
    static let pathMonitor: NWPathMonitor = {
        let monitor = NWPathMonitor()
        monitor.start(queue: DispatchQueue(label: "co.getswan.gallery.network"))
        return monitor
    }()

    /// The shopper has asked the phone to save data — Low Data Mode on mobile data
    /// or on this Wi-Fi network. The scan then downloads nothing to size a photo.
    static var lowDataMode: Bool { pathMonitor.currentPath.isConstrained }
    /// Whether a matched photo's original is still sized over the network in Low
    /// Data Mode. On, like the iCloud pass: a match the scan paid to fetch should
    /// not vanish at the upload check. Off hides such photos as "low data".
    static let sizeOriginalsInLowDataMode = true

    /// What sizing a matched photo's original found.
    enum OriginalCheck {
        case fits(bytes: Int, downloaded: Bool)
        case tooLarge(downloaded: Bool)
        case unavailable(Original.Unavailable)
        /// Only in iCloud, and not downloaded because Low Data Mode is on.
        case lowData
    }

    /// Sizes a matched photo's original so the grid shows only sendable photos. An
    /// iCloud-only original is downloaded just far enough to size it.
    func checkOriginal(_ asset: PHAsset) -> OriginalCheck {
        switch Original.size(for: asset, allowNetwork: false) {
        case .success(let bytes): return .fits(bytes: bytes, downloaded: false)
        case .failure(.tooLarge): return .tooLarge(downloaded: false)
        case .failure:
            guard Self.sizeOriginalsInLowDataMode || !Self.lowDataMode else { return .lowData }
            switch Original.size(for: asset, allowNetwork: true) {
            case .success(let bytes): return .fits(bytes: bytes, downloaded: true)
            case .failure(.tooLarge): return .tooLarge(downloaded: true)
            case .failure(let reason): return .unavailable(reason)
            }
        }
    }

    /// How far back the search may look. Clamped here too, since a host may call in
    /// with anything.
    static let monthsBackRange = 1...36

    /// Scans the whole window in one pass. Every photo inside `monthsBack` is
    /// examined and matches stream to the web layer as found; no early stop.
    private func scanAssets(monthsBack: Int) {
        let months = min(max(monthsBack, Self.monthsBackRange.lowerBound), Self.monthsBackRange.upperBound)
        if months != monthsBack {
            print("\u{26a0}\u{fe0f} monthsBack \(monthsBack) is out of range — using \(months)")
        }

        let options = PHFetchOptions()

        // No date filter under limited access: the user hand-picked the set, so a
        // date range would only discard photos they chose to share.
        if !isLimitedAccess {
            // Not force-unwrapped: `date(byAdding:)` answers nil outside the calendar's
            // range, and a crash is worse than a scan that does not run.
            guard let from = Calendar.current.date(byAdding: .month, value: -months, to: Date()) else {
                print("\u{1f6ab} Could not build the scan window")
                sendToWeb(["type": "onGalleryScanComplete",
                           "payload": ["assetIds": [], "limited": isLimitedAccess]])
                return
            }
            options.predicate = NSPredicate(format: "creationDate >= %@", from as NSDate)
        }
        options.sortDescriptors = [NSSortDescriptor(key: "creationDate", ascending: false)]

        // The shopper's own library only — not shared albums, which are other
        // people's photos — and no screenshots: a screenshot of a model passes every
        // other check. Screenshots are filtered in code, not in the fetch predicate:
        // PhotoKit evaluates "(mediaSubtypes & screenshot) == 0" as "no subtype bits
        // at all", which dropped every photo without a Live/HDR/depth flag — photos
        // saved from other apps, AirDropped, or taken with Live Photos off. Measured on
        // one library: 24 of 113 photos removed, all with subtypes 0, none a screenshot.
        options.includeAssetSourceTypes = [.typeUserLibrary]
        var assets: [PHAsset] = []
        var screenshots = 0
        PHAsset.fetchAssets(with: .image, options: options).enumerateObjects { asset, _, _ in
            if asset.mediaSubtypes.contains(.photoScreenshot) { screenshots += 1 } else { assets.append(asset) }
        }
        let total = assets.count

        // Visible-to-us count with no date filter. If this is 0 the problem is
        // access; if it is large while `total` is 0 the problem is the date range.
        let visible = PHAsset.fetchAssets(with: .image, options: nil).count
        let window = isLimitedAccess ? "everything you shared" : "the last \(months) months"
        print("\u{1f4f8} \(total) photos in \(window) (\(visible) visible in total\(isLimitedAccess ? ", limited access" : ""), \(screenshots) screenshots skipped)")
        logSensitivityPolicy()

        guard total > 0 else {
            sendToWeb(["type": "onGalleryScanComplete",
                       "payload": ["assetIds": [], "limited": isLimitedAccess]])
            return
        }

        let startedAt = Date()

        // Captured once. Anything that resets the flow — a reload, a new scan,
        // starting over — moves scanGeneration past this and ends the loop below.
        let generation = scanGeneration

        // A no-op unless eval mode is on and the answer-key album exists.
        let evalLabels = loadEvalLabels()

        // What earlier scans learned about this account's photos — see `ScanStore`.
        scanStore = ScanStore.open(for: session?.email ?? "")
        // Captured for this scan: a scan started on top of this one opens its own,
        // and the two never share a dictionary.
        let store = scanStore
        if let store { print("\u{1f4be} Scan store: \(store.count) photo(s) remembered from earlier scans") }

        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            var matchedIds: [String] = []
            // Score and type per match, for the eval report and the retry logs.
            var matchScores: [String: (distance: Float, type: PhotoType, score: Float?, breakdown: [String: Any]?)] = [:]
            // Every distance scored this run, match or not — the gap rule reads
            // the whole distribution once the scan is over. See `gapCutEnabled`.
            var scoredDistances: [Float] = []
            // Matches between `gapCutFloor` and the cut-off: held back until the gap
            // is known, then appended so nothing on screen moves.
            var heldIds: [String] = []
            // Faces under `gapCutCeiling` with their vectors, for the own-photo
            // check — see `ownPhotoLogEnabled`. `matched` is false for a no-match.
            var nearFaces: [(n: Int, id: String, distance: Float, type: String, matched: Bool, vector: [Float])] = []
            // Near-duplicates among the matches — see `duplicateDistance`. Each
            // match gets a group: its own id, or the id of the earlier match it
            // repeats. The page keeps one pick per group; all are still shown.
            var featurePrints: [(id: String, print: VNFeaturePrintObservation)] = []
            var dupGroups: [String: String] = [:]
            var duplicates = 0
            var eval = ScanEval(labels: evalLabels)
            var lastReport = Date.distantPast

            // Per-gate tallies — which stage a disappointing result came from.
            var noImage = 0
            // Near-duplicates (see `duplicateDistance`): each match gets a group id,
            // its own or the earlier match it repeats. The page picks one per group.
            // Scanned from the phone's smaller copy, the full photo being in iCloud.
            var localCopies = 0
            var noFace = 0
            var noMatch = 0
            // How close the rejected faces came: the smallest no-match distance and
            // how many fell within 0.1 of the cut-off.
            var closestNoMatch: Float?
            var nearMisses = 0
            var groupSkipped = 0
            var tooSmall = 0
            var notFullBody = 0
            var otherPeople = 0
            var sensitiveSkipped = 0
            // Originals sized after a match — see `checkOriginal`.
            var tooLargeSkipped = 0
            var noOriginal = 0
            var sizedByPixels = 0
            // Matches lowered by `MuseScore.tiltMultiplier` (head pitched or turned).
            var tiltedMatches = 0
            var lowDataSkipped = 0
            var sized = 0
            var downloadedToSize = 0
            var sizingSeconds = 0.0

            // What the matches cover, for the summary only; the web layer derives
            // coverage from the selection.
            var found: [PhotoType: Int] = [:]
            var examined = 0
            // Distinct Tier A shots per slot, shown and final — see `earlyStopEnabled`.
            var tierA: [String: Int] = ["selfie": 0, "front": 0, "side": 0]
            var stoppedEarly = false
            // Gated matches sent for the review grid — see `sendExcludedMatches`.
            var excludedIds: [String] = []
            func tierAReached() -> Bool {
                Self.earlyStopEnabled && examined >= Self.earlyStopMinExamined
                    && Self.earlyStopTierA.allSatisfy { tierA[$0.key, default: 0] >= $0.value }
            }

            // iCloud-only photos whose thumbnail looks like a selfie, examined after
            // the local pass — see `cloudDownloadCap`.
            var cloudCandidates: [(asset: PHAsset, n: Int)] = []
            // Downloads started during the local pass. Each job's result lands in its box
            // on the download queue; the scan reads them after the local pass, in order.
            final class CloudGauge { private let lock = NSLock(); private var n = 0
                func add(_ d: Int) { lock.lock(); n += d; lock.unlock() }
                var value: Int { lock.lock(); defer { lock.unlock() }; return n } }
            let cloudFullInFlight = CloudGauge()
            final class CloudJob { let asset: PHAsset; let n: Int; let kind: String; let group = DispatchGroup(); let box = LoadBox(); var seconds = 0.0; var previewRejected = false; var previewNote = ""; var data: Data?
                init(asset: PHAsset, n: Int, kind: String) { self.asset = asset; self.n = n; self.kind = kind } }
            var cloudJobs: [CloudJob] = []
            var cloudSelfieCandidates = 0, cloudFullCandidates = 0
            var cloudStartedSelfie = 0, cloudStartedFull = 0
            var cloudLeft = 0
            let cloudAllowed = Self.cloudDownloadsAllowed
            let cloudCap = Self.cloudDownloadCap
            // At the scan's own priority: the scan waits on these at the end, and a
            // lower class there is a priority inversion. The queue caps what runs
            // at once, so no thread is parked on a semaphore.
            let cloudQueue = OperationQueue()
            cloudQueue.name = "co.getswan.gallery.cloud"
            cloudQueue.qualityOfService = .userInitiated
            cloudQueue.maxConcurrentOperationCount = Self.cloudOnMobile ? Self.cloudParallelMobile : Self.cloudParallel
            var cloudPreviewOut = 0
            self?.cloudLargerDownloads = 0
            var cloudOnly = 0
            // Second head-to-toe checks at the larger render — see `lastBodyRetry`.
            var bodyRetried = 0
            var bodyRescued = 0
            // Mirror shots: more than one face, all the shopper's — see `sameShopperFacesMax`.
            var sameShopper = 0
            // Matches in on the knee rule alone — see `minKnees`.
            var kneeLength = 0
            // Matched selfies under the v2 eye-spacing floor — see `selfieEyeFloorEnabled`.
            var selfieSmallEyes = 0
            // Matches kept out for a face the Muse cannot use — see `unusableFaceDrops`.
            var unusableFace = 0
            // The same, per filter — the v2 selfie gates' counts.
            var unusableGates: [String: Int] = [:]
            // Matched selfies the classifier marked with a head covering or an
            // object over the face — see `MuseScore.coverLabels`.
            var coverHints = 0
            // Matched selfies whose focal length was assumed — see `assumedFocal35mm`.
            var focalAssumed = 0
            // Eye openness of each clean matched selfie, for the relative gate.
            var selfieOpenness: [String: Float] = [:]
            // Matched selfies the segmenter read, and how many sat over each
            // cover limit — see `coverReadEnabled`.
            var coverRead = 0
            var coverFacts: [String: Int] = [:]
            // Matches the document reader saw, and how many had text over the
            // logging share — see `documentReadEnabled`.
            var documentRead = 0
            var textHeavy = 0
            var faceOnDocument = 0
            var documentLabelled = 0
            var handwritten = 0
            var faceOnPage = 0
            // Skipped from the library record alone — see `shapeReject`.
            var skippedShape = 0
            // No-matches decided before body pose — see `matchBeforePose`.
            var earlyNoMatch = 0
            self?.stageMs = [:]
            let memoryAtStart = Self.residentMB()
            var memoryPeak = memoryAtStart
            FaceRecognizer.timing = { stage, ms in self?.stageMs[stage, default: 0] += ms }

            // One loaded photo through every gate. Shared by the local pass and the
            // iCloud pass, so a downloaded photo faces exactly the same checks.
            // The store — see `ScanStore`. `remember` writes a photo's verdict once
            // examined; `decideFromStore` counts a photo the store already knows
            // without loading it, and says so. Candidates are compared with the
            // selfie here, and only a possible match goes on to be loaded.
            var storeDecided = 0
            var storeCloudSkipped = 0
            // The widest cut-off any type gets: under it the real rules might
            // still match the photo, so it is examined in full.
            let storeCutoff = max(Self.matchThreshold, Self.selfieMatchThreshold, Self.profileMatchThreshold)
            func remember(_ asset: PHAsset, _ verdict: ScanStore.Verdict, note: String? = nil) {
                guard let store else { return }
                if verdict == .candidate {
                    guard let faces = self?.lastEmbeddings, !faces.isEmpty else { return }
                    store.remember(asset, .candidate, faces: faces)
                } else {
                    store.remember(asset, verdict, note: note)
                }
            }
            func decideFromStore(_ asset: PHAsset, n: Int) -> Bool {
                guard let store, let record = store.record(for: asset) else { return false }
                func decided(_ gate: EvalGate, _ line: String) -> Bool {
                    storeDecided += 1
                    eval.note(asset, image: nil, gate: gate, fromStore: true)
                    if Self.verboseLogging { print("  \u{1f4be} [\(n)] \(line) — from the last scan") }
                    return true
                }
                switch record.verdict {
                case .noFace: noFace += 1; return decided(.noFace, "no face")
                case .group: groupSkipped += 1; return decided(.group, "group")
                case .faceTooSmall: tooSmall += 1; return decided(.faceTooSmall, "face too small")
                case .otherPeople: otherPeople += 1; return decided(.otherPeople, "someone else in the photo")
                case .notFullBody: notFullBody += 1; return decided(.notFullBody, "not head to toe")
                case .unusableFace: unusableFace += 1; return decided(.unusableFace, "unusable face")
                case .tooLarge: tooLargeSkipped += 1; return decided(.tooLarge, "original over the cap")
                case .sensitive: sensitiveSkipped += 1; return decided(.sensitive, "sensitive content")
                case .cloudThumbnail, .cloudSmallCopy:
                    // Only while the photo still has no copy on the phone: decided
                    // in the iCloud branch, once the load has failed.
                    return false
                case .candidate:
                    guard let reference = self?.referenceEmbedding else { return false }
                    let distances = store.distances(record, to: reference, extra: self?.extraReferenceEmbeddings ?? [],
                                                    allFrames: Self.matchAgainstAllFrames)
                    guard let best = distances.min() else { return false }
                    // Several faces: every one must be the shopper, as in `matchPerson`.
                    if distances.count > 1, distances.contains(where: { $0 >= Self.matchThreshold }) {
                        groupSkipped += 1
                        return decided(.group, "group (\(distances.count) faces, d=\(String(format: "%.3f", best)))")
                    }
                    guard best >= storeCutoff else { return false }
                    noMatch += 1
                    scoredDistances.append(best)
                    if Self.ownPhotoLogEnabled || Self.ownPhotoKeepEnabled, best < Self.gapCutCeiling,
                       let index = distances.firstIndex(of: best), index < record.vectors.count {
                        nearFaces.append((n, asset.localIdentifier, best, "?", false, record.vectors[index]))
                    }
                    if let closest = closestNoMatch, closest <= best {} else { closestNoMatch = best }
                    if best - Self.matchThreshold <= 0.1 { nearMisses += 1 }
                    storeDecided += 1
                    eval.note(asset, image: nil, gate: .noMatch, distance: best, fromStore: true)
                    if Self.verboseLogging { print("  \u{1f4be} [\(n)] no match  d=\(String(format: "%.3f", best)) — from the last scan's face vector") }
                    return true
                }
            }

            func examine(_ asset: PHAsset, _ image: UIImage, n: Int) {
                    // Read before anything else loads: the photo is already upright.
                    let wasRotated = self?.lastLoadRotated ?? false
                    if self?.lastLoadLocalCopy == true { localCopies += 1 }

                    // Delivered dimensions, not the requested targetSize — PHImageManager
                    // treats that as a hint.
                    let px = image.cgImage.map { "\($0.width)x\($0.height)" } ?? "?"
                    let orient = Self.orientationName(image.imageOrientation)

                    guard let outcome = self?.matchPerson(in: image, asset: asset) else { return }
                    let metrics = self?.lastFaceMetrics
                    if let copies = self?.lastShopperFaces, copies > 1 {
                        sameShopper += 1
                        if Self.verboseLogging { print("  🪞 [\(n)] \(copies) faces, all the shopper — one person, not a group") }
                    }
                    if let retry = self?.lastBodyRetry {
                        bodyRetried += 1
                        if retry.rescued { bodyRescued += 1 }
                        if Self.verboseLogging { print("  🦶 [\(n)] \(retry.note) — \(retry.rescued ? "rescued" : "still not head to toe")") }
                    }
                    // Set by the size check when a match's original fits.
                    var originalBytes: Int?

                    switch outcome {
                    case .noFace:
                        noFace += 1
                        remember(asset, .noFace)
                        eval.note(asset, image: image, rotated: wasRotated, gate: .noFace)
                        if Self.verboseLogging { print("  ○  [\(n)] no face             \(px) \(orient)") }

                    case .group(let faceCount):
                        groupSkipped += 1
                        // Four or more faces, or a face that could not be embedded,
                        // is a group whoever the shopper is; two or three faces are
                        // a group only against this selfie, so their vectors are kept.
                        remember(asset, faceCount > Self.sameShopperFacesMax || (self?.lastEmbeddings.isEmpty ?? true) ? .group : .candidate)
                        eval.note(asset, image: image, rotated: wasRotated, gate: .group)
                        if Self.verboseLogging { print("  \u{1f465} [\(n)] group (\(faceCount) faces) — skipped   \(px) \(orient)") }

                    case .faceTooSmall(let pixels):
                        tooSmall += 1
                        remember(asset, .faceTooSmall)
                        eval.note(asset, image: image, rotated: wasRotated, gate: .faceTooSmall, metrics: metrics)
                        if Self.verboseLogging { print("  \u{1f50e} [\(n)] face too small (\(pixels)px)   \(px) \(orient)") }

                    case .otherPeople(let body):
                        otherPeople += 1
                        // One face: someone else is in the photo whoever the shopper
                        // is. Several faces all the shopper's: only against this selfie.
                        remember(asset, (self?.lastShopperFaces ?? 1) == 1 ? .otherPeople : .candidate)
                        eval.note(asset, image: image, rotated: wasRotated, gate: .otherPeople, body: body, metrics: metrics)
                        if Self.verboseLogging { print("  \u{1f465} [\(n)] \(body.people) people — skipped   \(px) \(orient)") }

                    case .notFullBody(let body):
                        notFullBody += 1
                        // Final once the larger render was tried, or when nothing
                        // could trigger that retry. Otherwise a match by a later
                        // selfie could still rescue it, so the vectors are kept.
                        remember(asset, self?.lastBodyRetry != nil || !body.headSeen || body.lowerJoints < 1 ? .notFullBody : .candidate)
                        eval.note(asset, image: image, rotated: wasRotated, gate: .notFullBody, body: body, metrics: metrics)
                        if Self.verboseLogging { print("  \u{1f9cd} [\(n)] not head to toe (head \(body.headSeen), ankles \(body.ankles), span \(String(format: "%.2f", body.span)), feet room \(String(format: "%.3f", body.footRoom)); knees \(body.knees), knee span \(String(format: "%.2f", body.kneeSpan)), knee drop \(body.kneeDrop.map { String(format: "%.2f", $0) } ?? "–"))   \(px) \(orient)") }

                    case .scored(let distances, let facePixels, let body, let type, let profile, let museScore):
                        // A list, not a value, so turning off the single-face gate
                        // does not silently change what is logged.
                        let scores = distances.sorted()
                            .map { String(format: "%.3f", $0) }
                            .joined(separator: " ")
                        let distance = distances.min()!
                        // Its vectors, whatever happens next: match or not, the
                        // next selfie decides afresh. The branches below that are
                        // final for the photo itself overwrite this.
                        remember(asset, .candidate)
                        // The gap rule sees clean faces only: covered or strained faces
                        // land between the shopper's photos and strangers.
                        let unusable = Self.unusableFaceDrops ? museScore?.filter : nil
                        if unusable == nil && museScore?.demoted != true { scoredDistances.append(distance) }

                        // A face in profile against a front-facing selfie gets more room; a
                        // selfie, whose own matches score low, gets less.
                        let cutoff = profile ? Self.profileMatchThreshold
                            : type == .selfie ? Self.selfieMatchThreshold
                            : Self.matchThreshold
                        // The vector of the closest face, for the own-photo check.
                        // Clean faces only, as for the gap rule; a match the size
                        // check hides is told apart at the end by `matchScores`.
                        if Self.ownPhotoLogEnabled || Self.ownPhotoKeepEnabled, unusable == nil, museScore?.demoted != true, distance < Self.gapCutCeiling,
                           let vectors = self?.lastEmbeddings, vectors.count == distances.count,
                           let index = distances.firstIndex(of: distance) {
                            nearFaces.append((n, asset.localIdentifier, distance, type.rawValue, distance < cutoff, vectors[index]))
                        }
                        // Facts for the gates still to come, on every match.
                        if distance < cutoff, let doc = museScore?.document {
                            documentRead += 1
                            if doc.textArea >= Self.documentTextShareLog { textHeavy += 1 }
                            if doc.docConfidence >= Self.documentConfidenceLog && doc.faceInDoc { faceOnDocument += 1 }
                            if doc.labelSum >= Self.documentLabelSumLimit { documentLabelled += 1 }
                            if doc.handwriting >= Self.handwritingLimit { handwritten += 1 }
                            if doc.faceOnPage && doc.labelSum < Self.documentLabelSumLimit
                                && doc.handwriting < Self.handwritingLimit { faceOnPage += 1 }
                        }
                        if distance < cutoff, type == .selfie, let museScore {
                            if museScore.coverHint { coverHints += 1 }
                            if museScore.focalAssumed { focalAssumed += 1 }
                            if let cover = museScore.cover {
                                coverRead += 1
                                if cover.hairline >= Self.coverHairlineLimit { coverFacts["hairline", default: 0] += 1 }
                                if cover.jaw >= Self.coverJawLimit { coverFacts["jaw", default: 0] += 1 }
                                if cover.face >= Self.coverFaceLimit { coverFacts["face", default: 0] += 1 }
                            }
                        }

                        if distance >= cutoff {
                            noMatch += 1
                            if self?.lastEarlyNoMatch == true { earlyNoMatch += 1 }
                            if let closest = closestNoMatch, closest <= distance {} else { closestNoMatch = distance }
                            if distance - cutoff <= 0.1 { nearMisses += 1 }
                            eval.note(asset, image: image, rotated: wasRotated, gate: .noMatch, distance: distance,
                                      type: type, body: body, metrics: metrics,
                                      fullRes: self?.lastCropFullRes)
                            if Self.verboseLogging { print("  ·  [\(n)] no match  d=\(String(format: "%.3f", distance)) cut=\(String(format: "%.2f", cutoff))  \(px) \(orient)  face=\(facePixels)px joints=\(body.lowerJoints)  [\(scores)]") }
                        } else if self?.isSensitiveContent(image) == true {
                            sensitiveSkipped += 1
                            remember(asset, .sensitive)
                            eval.note(asset, image: image, rotated: wasRotated, gate: .sensitive, distance: distance,
                                      type: type, body: body, metrics: metrics,
                                      fullRes: self?.lastCropFullRes)
                            if Self.verboseLogging { print("  \u{1f6ab} [\(n)] sensitive content — skipped   \(px) \(orient)") }
                        } else if let why = unusable {
                            // Before sizing: nothing is fetched for a photo that
                            // will not be shown.
                            unusableFace += 1
                            unusableGates[why, default: 0] += 1
                            remember(asset, .unusableFace)
                            eval.note(asset, image: image, rotated: wasRotated, gate: .unusableFace, distance: distance,
                                      type: type, body: body, metrics: metrics,
                                      fullRes: self?.lastCropFullRes, score: museScore)
                            if Self.verboseLogging { print("  \u{1f648} [\(n)] id=\(asset.localIdentifier.prefix(8)) unusable face — \(why)  d=\(String(format: "%.3f", distance)) type=\(type.rawValue)  \(px) \(orient)  \(museScore?.note ?? "")") }
                            if Self.sendExcludedMatches {
                                excludedIds.append(asset.localIdentifier)
                                let excludedPayload: [String: Any] = ["assetId": asset.localIdentifier, "type": type.rawValue,
                                                                      "isFullBody": body.isHeadToToe, "kneeUp": body.byKnees,
                                                                      "distance": distance, "dupGroup": asset.localIdentifier,
                                                                      "tier": "x", "gate": why, "usable": false,
                                                                      "done": n, "total": total, "tierA": tierA]  // sent only under `sendExcludedMatches`
                                DispatchQueue.main.async {
                                    self?.sendToWeb(["type": "onGalleryMatchFound", "payload": excludedPayload])
                                }
                            }
                        } else if let hidden = { () -> (gate: EvalGate, why: String)? in
                            // Sized before the grid sees it: a photo whose original
                            // cannot be sent as it is never reaches the shopper.
                            let sizingStarted = Date()
                            let check = self?.checkOriginal(asset) ?? .unavailable(.unreadable)
                            sizingSeconds += Date().timeIntervalSince(sizingStarted)
                            sized += 1
                            switch check {
                            case .fits(let bytes, let downloaded):
                                if downloaded { downloadedToSize += 1 }
                                originalBytes = bytes
                                return nil
                            case .tooLarge(let downloaded):
                                if downloaded { downloadedToSize += 1 }
                                tooLargeSkipped += 1
                                remember(asset, .tooLarge)
                                return (.tooLarge, "original over \(Original.byteCap / 1_048_576)MB")
                            case .unavailable(let reason):
                                downloadedToSize += 1
                                let megapixels = Double(asset.pixelWidth * asset.pixelHeight) / 1_000_000
                                if reason == .tooSlow, Original.sizeByPixelsWhenSlow, megapixels <= Original.sizeByPixelsMaxMegapixels {
                                    sizedByPixels += 1
                                    if Self.verboseLogging { print("  \u{1f4cf} [\(n)] original too slow to size — \(String(format: "%.1f", megapixels))MP, assumed under the cap, shown") }
                                    return nil
                                }
                                noOriginal += 1
                                return (.noOriginal, "original \(reason.rawValue), \(String(format: "%.1f", megapixels))MP")
                            case .lowData:
                                lowDataSkipped += 1
                                return (.noOriginal, "only in iCloud, Low Data Mode")
                            }
                        }() {
                            eval.note(asset, image: image, rotated: wasRotated, gate: hidden.gate, distance: distance,
                                      type: type, body: body, metrics: metrics,
                                      fullRes: self?.lastCropFullRes)
                            if Self.verboseLogging { print("  \u{1f4cf} [\(n)] hidden — \(hidden.why)  d=\(String(format: "%.3f", distance)) type=\(type.rawValue)  \(px) \(orient)") }
                        } else {
                            matchedIds.append(asset.localIdentifier)
                            let orderFields = Self.orderFields(asset: asset, type: type, score: museScore)
                            matchScores[asset.localIdentifier] = (distance, type, museScore?.value,
                                                                  museScore.map { $0.breakdown.merging(orderFields) { _, new in new } })
                            if museScore?.tilted == true { tiltedMatches += 1 }
                            var dupGroup = asset.localIdentifier
                            if let fingerprint = Self.featurePrint(of: image) {
                                var nearest: (id: String, distance: Float)?
                                for other in featurePrints {
                                    var d: Float = 1
                                    guard (try? other.print.computeDistance(&d, to: fingerprint)) != nil else { continue }
                                    if nearest == nil || d < nearest!.distance { nearest = (other.id, d) }
                                }
                                if let nearest, nearest.distance < Self.duplicateDistance {
                                    dupGroup = dupGroups[nearest.id] ?? nearest.id
                                    duplicates += 1
                                    if Self.verboseLogging { print("  \u{1f46f} [\(n)] near-duplicate of an earlier match (\(String(format: "%.3f", nearest.distance)))") }
                                }
                                featurePrints.append((asset.localIdentifier, fingerprint))
                            }
                            dupGroups[asset.localIdentifier] = dupGroup
                            eval.note(asset, image: image, rotated: wasRotated, gate: .grid, distance: distance,
                                      type: type, body: body, metrics: metrics,
                                      fullRes: self?.lastCropFullRes, originalBytes: originalBytes, score: museScore)

                            // Kept so the tap that follows does not reload the photo
                            // and re-run pose detection for answers already in hand.
                            ScanAnalysisStore.store(ScanAnalysis(type: type, body: body),
                                                    id: asset.localIdentifier)
                            found[type, default: 0] += 1
                            if body.byKnees { kneeLength += 1 }
                            if museScore?.tier == "A", dupGroup == asset.localIdentifier, !(Self.gapCutEnabled && distance >= Self.gapCutFloor) {
                                tierA[Self.slot(of: type), default: 0] += 1
                            }
                            // The more closed eye, for the relative gate at the end.
                            if Self.relativeEyeGateEnabled, type == .selfie, let e = museScore?.expression {
                                selfieOpenness[asset.localIdentifier] = 1 - e.blinkMax
                            }
                            // Selfies the v2 eye floor would drop once it is on.
                            if type == .selfie, (self?.lastEyeSpacing ?? Self.selfieEyeSpacingPixels) < Self.selfieEyeSpacingPixels { selfieSmallEyes += 1 }

                            // Streamed as found so the grid fills during the scan.
                            // Only the id travels; the page fetches its own pixels.
                            let matchedId = asset.localIdentifier
                            // The verdict rides along with the match, so the picker can
                            // choose one of each type without tapping every photo.
                            let matchedType = type.rawValue
                            let matchedFullBody = body.isHeadToToe
                            // A match the gap rule could still withdraw is held back:
                            // a tile that vanishes is worse than one that arrives late.
                            let held = Self.gapCutEnabled && distance >= Self.gapCutFloor
                            if held {
                                heldIds.append(matchedId)
                            } else {
                                var matchPayload: [String: Any] = ["assetId": matchedId,
                                                                   "type": matchedType,
                                                                   "isFullBody": matchedFullBody,
                                                                   // Head to knee, not to toe: the page
                                                                   // pre-selects it only when no head-to-toe
                                                                   // photo is left for the slot.
                                                                   "kneeUp": body.byKnees,
                                                                   // Lower is closer; the page falls back to
                                                                   // it when no score is sent.
                                                                   "distance": distance,
                                                                   // Same for every photo that repeats one shot;
                                                                   // the page pre-selects one per group.
                                                                   "dupGroup": dupGroup,
                                                                   "done": n,
                                                                   "total": total]
                                // The Tier A counts ride along only while the early
                                // stop is on — see `earlyStopEnabled`.
                                if Self.earlyStopEnabled { matchPayload["tierA"] = tierA }
                                // Higher is better. The page pre-selects the top of each type by it.
                                if let museScore {
                                    matchPayload["score"] = museScore.value
                                    matchPayload.merge(museScore.breakdown) { _, new in new }
                                }
                                matchPayload.merge(orderFields) { _, new in new }
                                DispatchQueue.main.async {
                                    self?.sendToWeb(["type": "onGalleryMatchFound", "payload": matchPayload])
                                }
                            }
                            if Self.verboseLogging { print("  ✅ [\(n)] id=\(asset.localIdentifier.prefix(8)) MATCH\(held ? " (held)" : "")     d=\(String(format: "%.3f", distance)) cut=\(String(format: "%.2f", cutoff))  \(px) \(orient)  face=\(facePixels)px eyes=\(self?.lastEyeSpacing.map { String(format: "%.0f", $0) } ?? "?")px joints=\(body.lowerJoints)\(body.byKnees ? " knee-length" : "") type=\(type.rawValue) shoulders=\(body.shoulderSpread.map { String(format: "%.2f (~%.0f°)", $0, Self.turnDegrees(spread: $0)) } ?? "–") original=\((originalBytes ?? 0) / 1024)KB  [\(scores)]  \((orderFields["order"] as? Double).map { String(format: "order=%.3f  ", $0) } ?? "")\(museScore?.note ?? "")") }
                        }
                    }

            }

            let prefetchQueue = DispatchQueue(label: "co.getswan.gallery.prefetch", qos: .userInitiated)
            var ahead: (index: Int, group: DispatchGroup, box: LoadBox)?
            for index in 0..<total {
                // Abandons the scan outright: a superseded scan that still reported
                // would overwrite the live one.
                guard self?.scanGeneration == generation else {
                    print("\u{1f6d1} Scan superseded — stopping at \(index) of \(total)")
                    return
                }

                autoreleasepool {
                    let asset = assets[index]
                    let n = index + 1

                    examined += 1

                    if let why = Self.shapeReject(asset) {
                        skippedShape += 1
                        eval.note(asset, image: nil, gate: .noImage)
                        if Self.verboseLogging { print("  ⃠  [\(n)] skipped — \(why)") }
                        return
                    }

                    // Known from an earlier scan — see `ScanStore`: counted without
                    // a load. A decode already started for it finishes unused.
                    if decideFromStore(asset, n: n) {
                        ahead = nil
                        // The page's progress still moves while known photos fly by.
                        if Date().timeIntervalSince(lastReport) > 0.25 || n == total {
                            lastReport = Date()
                            let tierANow: [String: Int]? = Self.earlyStopEnabled ? tierA : nil
                            DispatchQueue.main.async {
                                var payload: [String: Any] = ["done": n, "total": total]
                                if let tierANow { payload["tierA"] = tierANow }
                                self?.sendToWeb(["type": "onGalleryScanProgress", "payload": payload])
                            }
                        }
                        return
                    }

                    // The photo decoded ahead of time, if `decodeAhead` started it
                    // during the previous photo; else loaded now. Either way the next
                    // one starts decoding before this one is examined.
                    let loaded: ViewController.LoadResult? = self?.timed("load") {
                        if let ahead, ahead.index == index {
                            ahead.group.wait()
                            return ahead.box.result
                        }
                        return self?.loadPhotoResult(asset: asset)
                    } ?? nil
                    ahead = nil
                    if Self.decodeAhead, index + 1 < total {
                        let nextAsset = assets[index + 1]
                        // No decode for a photo the store will most likely decide
                        // without one; a candidate that turns out to match loads then.
                        let known = store?.record(for: nextAsset).map { $0.verdict != .cloudThumbnail && $0.verdict != .cloudSmallCopy } ?? false
                        if Self.shapeReject(nextAsset) == nil, !known {
                            let group = DispatchGroup(), box = LoadBox()
                            group.enter()
                            prefetchQueue.async { box.result = self?.loadPhotoResult(asset: nextAsset); group.leave() }
                            ahead = (index + 1, group, box)
                        }
                    }
                    self?.applyLoad(loaded)

                    guard let image = loaded?.image else {
                        let note = self?.lastLoadNote ?? ""
                        if note.hasPrefix("in iCloud") { cloudOnly += 1 }
                        // Judged on its thumbnail or small copy by an earlier scan and
                        // still only in iCloud — see `ScanStore`: no test, no download.
                        if let store, let record = store.record(for: asset),
                           record.verdict == .cloudThumbnail || record.verdict == .cloudSmallCopy {
                            storeCloudSkipped += 1
                            noImage += 1
                            eval.note(asset, image: nil, gate: .noImage, fromStore: true)
                            if Self.verboseLogging { print("  \u{1f4be} [\(n)] in iCloud — \(record.verdict == .cloudSmallCopy ? "small copy: \(record.note ?? "dropped")" : "not a candidate") in an earlier scan, skipped") }
                            return
                        }
                        // A thumbnail shaped like a selfie or a lone standing person is worth a
                        // download, started now within the caps and the ceiling. Anything else is skipped.
                        if let thumb = self?.lastLoadThumbnail,
                           let kind: String = (self?.isSelfieShaped(thumb) == true ? "selfie" : (self?.isFullLengthShaped(thumb) == true ? "full-length" : nil)) {
                            cloudCandidates.append((asset, n))
                            if kind == "selfie" { cloudSelfieCandidates += 1 } else { cloudFullCandidates += 1 }
                            let started = cloudStartedSelfie + cloudStartedFull
                            let selfieRoom = cloudCap - max(0, Self.cloudFullLengthReserve - cloudStartedFull)
                            let fits = kind == "full-length" ? started < cloudCap : cloudStartedSelfie < selfieRoom && started < cloudCap
                            if cloudAllowed, fits {
                                if kind == "selfie" { cloudStartedSelfie += 1 } else { cloudStartedFull += 1 }
                                let job = CloudJob(asset: asset, n: n, kind: kind)
                                cloudJobs.append(job)
                                job.group.enter()
                                cloudQueue.addOperation {
                                    let began = Date()
                                    // Small copy first; the full one only for a lone person.
                                    let preview = self?.loadFromCloudResult(asset: asset, pixels: Self.cloudPreviewPixels, timeout: Self.cloudTimeoutNow)
                                    let check: (passes: Bool, note: String, faceRatio: CGFloat)? = preview?.image.map { self?.cloudPreviewPasses($0, kind: kind) ?? (passes: false, note: "", faceRatio: 0) }
                                    if let check, check.passes {
                                        cloudFullInFlight.add(1)
                                        // The small copy's face box says how big the face will be at the
                                        // scan's size. Under the floor, fetch the bigger copy straight away
                                        // (the size the scan would ask for anyway) instead of two downloads.
                                        var pixels = kind == "selfie" ? Self.cloudPixels : Self.cloudFullLengthPixels
                                        if check.faceRatio > 0, check.faceRatio * pixels < Self.minFacePixels * Self.cloudFaceEstimateMargin {
                                            pixels = min(Self.fullResPixels, max(pixels, (Self.minFacePixels / check.faceRatio * 1.25).rounded(.up)))
                                            if Self.verboseLogging { print("  ☁️  [\(n)] \(kind) — small copy face \(Int(check.faceRatio * Self.cloudFullLengthPixels))px at \(Int(Self.cloudFullLengthPixels)), under \(Int(Self.minFacePixels * Self.cloudFaceEstimateMargin)) with margin: fetching \(Int(pixels))px") }
                                        } else if Self.verboseLogging {
                                            print("  ☁️  [\(n)] \(kind) — small copy face \(Int(check.faceRatio * pixels))px at \(Int(pixels)): fetching \(Int(pixels))px")
                                        }
                                        var full = self?.loadFromCloudResult(asset: asset, pixels: pixels, timeout: Self.cloudTimeoutNow)
                                        // Held as JPEG until the scan reads it: a decoded 1536px image is
                                        // about 7MB, and dozens may wait for the local pass to end.
                                        job.data = full?.image?.jpegData(compressionQuality: 0.92)
                                        full?.image = nil
                                        job.box.result = full
                                        cloudFullInFlight.add(-1)
                                    } else if let check {
                                        job.previewRejected = true
                                        job.previewNote = check.note
                                    } else {
                                        job.box.result = preview
                                    }
                                    job.seconds = Date().timeIntervalSince(began)
                                    job.group.leave()
                                }
                                if Self.verboseLogging { print("  ☁️  [\(n)] in iCloud — looks like a \(kind), downloading") }
                            } else {
                                cloudLeft += 1
                                noImage += 1
                                eval.note(asset, image: nil, gate: .noImage)
                                if Self.verboseLogging { print("  ☁️  [\(n)] in iCloud — looks like a \(kind), left (\(!cloudAllowed ? "no suitable connection" : "cap"))") }
                            }
                            return
                        }
                        noImage += 1
                        // A thumbnail that failed the shape test fails it next time
                        // too; a photo with no thumbnail at all is tried again.
                        if note.hasPrefix("in iCloud"), self?.lastLoadThumbnail != nil { remember(asset, .cloudThumbnail) }
                        eval.note(asset, image: nil, gate: .noImage)
                        if Self.verboseLogging { print("  ⃠  [\(n)] no local image — \(note)") }
                        return
                    }
                    examine(asset, image, n: n)
                    if n % 25 == 0 { memoryPeak = max(memoryPeak, Self.residentMB()) }
                    store?.saveIfDue()

                    // Throttled by time, not photo count: per-photo cost varies too
                    // much for "every Nth" to give a predictable update rate.
                    if Date().timeIntervalSince(lastReport) > 0.25 || n == total {
                        lastReport = Date()
                        let tierANow: [String: Int]? = Self.earlyStopEnabled ? tierA : nil
                        DispatchQueue.main.async {
                            var payload: [String: Any] = ["done": n, "total": total]
                            if let tierANow { payload["tierA"] = tierANow }
                            self?.sendToWeb(["type": "onGalleryScanProgress", "payload": payload])
                        }
                    }
                    if tierAReached() { stoppedEarly = true }
                }
                if stoppedEarly {
                    print("⏹ early stop at \(examined) of \(total) — Tier A selfie \(tierA["selfie"] ?? 0), front \(tierA["front"] ?? 0), side \(tierA["side"] ?? 0); \(total - examined) photo(s) not examined, iCloud pass skipped")
                    break
                }
            }

            // ---- iCloud pass -------------------------------------------------
            // The downloads started during the local pass, examined like any other photo in
            // `cloudTail` past the local pass, longer (to `cloudTailMax`) only while
            // a confirmed photo is still downloading; the rest count as left.
            var cloudDownloaded = 0
            // The first and last iCloud download: the photo's capture date, and when
            // it landed, in ms from the start of the scan. For the scan summary.
            var cloudFirstDownloaded: (day: String?, atMs: Int)?
            var cloudLastDownloaded: (day: String?, atMs: Int)?
            var cloudFailed = 0
            // Failures by reason (`LoadResult.cloudFailure`): diskFull, timedOut, other.
            var cloudFailures: [String: Int] = [:]
            var cloudSeconds = 0.0
            let cloudPassStarted = Date()
            if !cloudCandidates.isEmpty && !cloudAllowed {
                print("☁️  \(cloudCandidates.count) iCloud candidate(s) not downloaded — offline")
            }
            let deadline = cloudPassStarted.addingTimeInterval(Self.cloudTail)
            let hardDeadline = cloudPassStarted.addingTimeInterval(Self.cloudTailMax)
            var cloudExtended = false
            // Stopped early: the slots are full, so the downloads are dropped — see
            // `earlyStopEnabled`. The jobs count as left for the summary.
            if stoppedEarly { cloudLeft += cloudJobs.count }
            for job in (stoppedEarly ? [] : cloudJobs) {
                guard self?.scanGeneration == generation else {
                    cloudQueue.cancelAllOperations()
                    print("\u{1f6d1} Scan superseded — stopping in the iCloud pass")
                    return
                }
                let wait = max(0, deadline.timeIntervalSinceNow)
                var arrived = job.group.wait(timeout: .now() + wait) == .success
                // Past the base wait: keep going in short steps while a confirmed
                // photo is still coming down, up to `cloudTailMax`. Each step pings
                // the page so its stall timer stays quiet.
                while !arrived, hardDeadline.timeIntervalSinceNow > 0, cloudFullInFlight.value > 0 {
                    if !cloudExtended {
                        cloudExtended = true
                        print("☁️  \(Int(Self.cloudTail))s up — \(cloudFullInFlight.value) confirmed photo(s) still downloading, waiting up to \(Int(Self.cloudTailMax))s")
                    }
                    DispatchQueue.main.async {
                        self?.sendToWeb(["type": "onGalleryScanProgress",
                                         "payload": ["done": total, "total": total]])
                    }
                    let step = min(2, max(0, hardDeadline.timeIntervalSinceNow))
                    arrived = job.group.wait(timeout: .now() + step) == .success
                }
                guard arrived else {
                    cloudLeft += 1
                    noImage += 1
                    eval.note(job.asset, image: nil, gate: .noImage)
                    if Self.verboseLogging { print("  ☁️  [\(job.n)] \(job.kind) still downloading at the deadline — left") }
                    continue
                }
                cloudSeconds += job.seconds
                if job.previewRejected {
                    cloudPreviewOut += 1
                    remember(job.asset, .cloudSmallCopy, note: job.previewNote)
                    if Self.verboseLogging { print("  ☁️  [\(job.n)] \(job.kind) — small copy: \(job.previewNote), full download skipped") }
                    continue
                }
                autoreleasepool {
                    if let data = job.data { job.box.result?.image = UIImage(data: data); job.data = nil }
                    self?.applyLoad(job.box.result)
                    guard let image = job.box.result?.image else {
                        cloudFailed += 1
                        cloudFailures[job.box.result?.cloudFailure ?? "other", default: 0] += 1
                        noImage += 1
                        eval.note(job.asset, image: nil, gate: .noImage)
                        if Self.verboseLogging { print("  ☁️  [\(job.n)] \(job.box.result?.note ?? "iCloud download failed")") }
                        return
                    }
                    cloudDownloaded += 1
                    let landed = (day: Self.captureDay(job.asset.creationDate), atMs: Int(Date().timeIntervalSince(startedAt) * 1000))
                    if cloudFirstDownloaded == nil { cloudFirstDownloaded = landed }
                    cloudLastDownloaded = landed
                    if Self.verboseLogging, let cg = image.cgImage { print("  ☁️  [\(job.n)] \(job.kind) downloaded \(cg.width)x\(cg.height) in \(String(format: "%.1f", job.seconds))s") }
                    examine(job.asset, image, n: job.n)
                    memoryPeak = max(memoryPeak, Self.residentMB())
                    // Keeps the page's stall timer quiet while this pass runs.
                    DispatchQueue.main.async {
                        self?.sendToWeb(["type": "onGalleryScanProgress",
                                         "payload": ["done": total, "total": total]])
                    }
                }
            }
            // Nothing reads a download that lands after the deadline: the jobs
            // still queued are dropped here instead of running on in the
            // background. The few already in flight finish within their timeout.
            cloudQueue.cancelAllOperations()

            // Not for a scan another one has replaced: its records are already
            // in the newer store, and two writers on one file help nobody.
            if self?.scanGeneration == generation { store?.save() }

            let cloudWaited = Date().timeIntervalSince(cloudPassStarted)
            let elapsed = Date().timeIntervalSince(startedAt)
            let rate = Double(examined) / max(elapsed, 0.001)

            // The relative eye gate — see `relativeEyeGateEnabled`: with every
            // selfie in, the shopper's usual openness is the median over the clean
            // ones, and a selfie whose more closed eye is under `relativeOpenness`
            // of it is withdrawn, through `dropped` like the gap rule below.
            var eyeDropped: [String] = []
            var eyeBaseline: Float?
            if Self.relativeEyeGateEnabled, selfieOpenness.count >= Self.relativeBaselineMin {
                let sorted = selfieOpenness.values.sorted()
                let median = sorted.count % 2 == 1 ? sorted[sorted.count / 2] : (sorted[sorted.count / 2 - 1] + sorted[sorted.count / 2]) / 2
                eyeBaseline = median
                eyeDropped = matchedIds.filter { selfieOpenness[$0].map { $0 < Self.relativeOpenness * median } ?? false }
                if !eyeDropped.isEmpty {
                    let droppedSet = Set(eyeDropped)
                    matchedIds.removeAll { droppedSet.contains($0) }
                    heldIds.removeAll { droppedSet.contains($0) }
                    for id in eyeDropped { if let score = matchScores[id] { found[score.type, default: 0] -= 1 } }
                    unusableFace += eyeDropped.count
                    unusableGates["eyes under usual", default: 0] += eyeDropped.count
                    eval.regate(droppedSet, to: .unusableFace)
                }
                if Self.verboseLogging {
                    let withdrawn = eyeDropped.compactMap { selfieOpenness[$0] }.sorted().map { String(format: "%.2f", $0) }.joined(separator: " ")
                    print("  \u{1f441}  usual eye openness \(String(format: "%.2f", median)) over \(selfieOpenness.count) selfie(s) — withdrew \(eyeDropped.count) under \(Int(Self.relativeOpenness * 100))% of it\(withdrawn.isEmpty ? "" : "  [\(withdrawn)]")")
                }
            }

            // The gap rule, decided with every distance in: matches above the gap
            // are withdrawn from the final list and named in `dropped`.
            var gapCut: Float?
            var gapDropped: [String] = []
            var weakCut = false
            var decidedCut = Self.gapCut(distances: scoredDistances)
            if decidedCut == nil, Self.weakReferenceCutEnabled,
               let farthest = matchedIds.compactMap({ matchScores[$0]?.distance }).max(), farthest >= Self.weakReferenceReach {
                decidedCut = Self.weakReferenceCut
                weakCut = true
                if Self.verboseLogging { print("  ✂️  no gap and matches reach \(String(format: "%.3f", farthest)) — weak reference, cut tightened to \(String(format: "%.2f", Self.weakReferenceCut))") }
            }
            // Capture date and time for the console lines below, so a photo that
            // is not in the grid (withdrawn, or no match) can be found in Photos.
            let takenFormat = DateFormatter()
            takenFormat.dateFormat = "d MMM yyyy HH:mm"
            func taken(_ id: String) -> String {
                guard let date = PHAsset.fetchAssets(withLocalIdentifiers: [id], options: nil).firstObject?.creationDate else { return "taken ?" }
                return "taken " + takenFormat.string(from: date)
            }
            // The own-photo keep — see `ownPhotoKeepEnabled`. A face's nearest
            // distance to the sure matches, nil when it has none to compare.
            let sureMatches = nearFaces.filter { $0.distance < Self.ownPhotoCore && matchedIds.contains($0.id) }
            func nearestOwn(_ id: String) -> Float? {
                guard let face = nearFaces.first(where: { $0.id == id }) else { return nil }
                return sureMatches.filter { $0.id != id }.map { FaceRecognizer.distance(face.vector, $0.vector) }.min()
            }
            var ownKept: [String] = []
            if let cut = decidedCut {
                gapCut = cut
                gapDropped = matchedIds.filter { (matchScores[$0]?.distance ?? 0) >= cut }
                if Self.ownPhotoKeepEnabled {
                    ownKept = gapDropped.filter { (nearestOwn($0) ?? .infinity) < Self.ownPhotoKeepLimit }
                    let keptSet = Set(ownKept)
                    gapDropped.removeAll { keptSet.contains($0) }
                    if Self.verboseLogging, !ownKept.isEmpty {
                        let kept = ownKept.map { String(format: "%@ %.3f %@", String($0.prefix(8)), nearestOwn($0) ?? 0, taken($0)) }.joined(separator: ", ")
                        print("  \u{1f9ed} own-photo keep — \(ownKept.count) match(es) above the cut stay, under \(String(format: "%.2f", Self.ownPhotoKeepLimit)) from a sure match  [\(kept)]")
                    }
                }
                let droppedSet = Set(gapDropped)
                matchedIds.removeAll { droppedSet.contains($0) }
                for id in gapDropped {
                    if let score = matchScores[id] { found[score.type, default: 0] -= 1 }
                    if ScanAnalysisStore.analysis(for: id)?.body.byKnees == true { kneeLength -= 1 }
                }
                eval.regate(droppedSet, to: .gapCut)
                if Self.verboseLogging {
                    let scores = gapDropped.compactMap { id in matchScores[id].map { (id, $0.distance) } }.sorted { $0.1 < $1.1 }
                        .map { String(format: "id=%@ %.3f %@", String($0.0.prefix(8)), $0.1, taken($0.0)) }.joined(separator: ", ")
                    print("  ✂️  gap cut \(String(format: "%.3f", cut)) — withdrew \(gapDropped.count) match(es) scored above the gap  [\(scores)]")
                }
            }

            // The own-photo check — see `ownPhotoLogEnabled`. Logged only: each
            // face from the gap floor to the ceiling, with its nearest distance to
            // the sure matches (shown, under `ownPhotoCore` to the selfie).
            var ownCheckLine = "off"
            if Self.ownPhotoLogEnabled {
                let shown = Set(matchedIds)
                let gapSet = Set(gapDropped)
                let core = nearFaces.filter { $0.distance < Self.ownPhotoCore && shown.contains($0.id) }
                var withdrawnNearest: [Float] = []
                var keptNearest: [Float] = []
                var strangerNearest: [Float] = []
                for face in nearFaces.filter({ $0.distance >= Self.gapCutFloor }).sorted(by: { $0.distance < $1.distance }) {
                    let others = core.filter { $0.id != face.id }
                        .map { (id: $0.id, d: FaceRecognizer.distance(face.vector, $0.vector)) }
                        .sorted { $0.d < $1.d }
                    let status: String
                    if !face.matched { status = "no match" }
                    else if gapSet.contains(face.id) { status = "withdrawn by the gap rule" }
                    else if ownKept.contains(face.id) { status = "kept by the own-photo keep" }
                    else if shown.contains(face.id) { status = "kept" }
                    else { status = "matched, hidden for another reason" }
                    if let nearest = others.first {
                        if !face.matched { strangerNearest.append(nearest.d) }
                        else if gapSet.contains(face.id) { withdrawnNearest.append(nearest.d) }
                        else if shown.contains(face.id) { keptNearest.append(nearest.d) }
                    }
                    if Self.verboseLogging {
                        let near = others.prefix(3).map { String(format: "%.3f id=%@", $0.d, String($0.id.prefix(8))) }.joined(separator: ", ")
                        let within = others.filter { $0.d < Self.ownPhotoCore }.count
                        print("  \u{1f9ed} [\(face.n)] id=\(face.id.prefix(8)) d=\(String(format: "%.3f", face.distance)) \(face.type) \(status), \(taken(face.id)) — own photos: \(near.isEmpty ? "none to compare" : near); \(within) of \(others.count) under \(String(format: "%.2f", Self.ownPhotoCore))")
                    }
                }
                func span(_ values: [Float]) -> String {
                    guard let lo = values.min(), let hi = values.max() else { return "none" }
                    return String(format: "%d, nearest %.3f–%.3f", values.count, lo, hi)
                }
                ownCheckLine = "\(core.count) sure match(es) under \(String(format: "%.2f", Self.ownPhotoCore)); nearest own photo for withdrawn \(span(withdrawnNearest)) · kept \(span(keptNearest)) · no match under \(String(format: "%.2f", Self.gapCutCeiling)) \(span(strangerNearest))"
            }

            // The finished list is the streamed order: newest first, iCloud selfies
            // after the local pass. Nothing moves when the scan ends — the page keeps
            // the tiles where the tester watched them arrive, and the matches held
            // back for the gap rule go after them, so they only ever appear.
            let heldSet = Set(heldIds)
            let ordered = matchedIds.filter { !heldSet.contains($0) } + matchedIds.filter { heldSet.contains($0) }
                // Excluded matches last, after everything shown — see `sendExcludedMatches`.
                + excludedIds

            // Capture dates of the final matches, for the scan summary. The scan runs
            // newest first, so "first" is the newest match and "last" the oldest.
            var matchedDates: [Date] = []
            PHAsset.fetchAssets(withLocalIdentifiers: matchedIds, options: nil).enumerateObjects { asset, _, _ in
                if let date = asset.creationDate { matchedDates.append(date) }
            }
            let matchedFirstDate = Self.captureDay(matchedDates.max())
            let matchedLastDate = Self.captureDay(matchedDates.min())

            // Selfies by tier, among the final matches — see `selfieScoreV2`.
            let tiers = matchedIds.compactMap { matchScores[$0]?.breakdown?["tier"] as? String }
            let selfieTiers = matchedIds.filter { matchScores[$0]?.type == .selfie }.compactMap { matchScores[$0]?.breakdown?["tier"] as? String }
            let bodyIds = matchedIds.filter { matchScores[$0]?.type != .selfie }
            let bodyTiers = bodyIds.compactMap { matchScores[$0]?.breakdown?["tier"] as? String }
            var tierALine = selfieTiers.isEmpty ? "" : "\n                selfie tier A \(selfieTiers.filter { $0 == "A" }.count), B \(selfieTiers.filter { $0 == "B" }.count)   (v2 score T, Tier A at \(String(format: "%.2f", Self.tierALine)) and over; only Tier A selfies are pre-selected)"
            if Self.fullLengthScoreV2, !bodyIds.isEmpty {
                tierALine += "\n                full-length tier A \(bodyTiers.filter { $0 == "A" }.count), B \(bodyTiers.filter { $0 == "B" }.count), under the floor \(bodyIds.count - bodyTiers.count)   (v2 body score, Tier A at \(String(format: "%.2f", Self.fullLengthTierALine)), usable from \(String(format: "%.2f", Self.fullLengthUsableFloor)); Tier B fills a shortfall)"
            }
            _ = tiers

            // Built here, off the main thread. The grid is passed in the order the
            // web will show it, because that order is what "the top" means.
            let evalReport = eval.finish(grid: ordered)

            DispatchQueue.main.async {
                guard self?.scanGeneration == generation else { return }

                print("""

                ==============================
                SCAN COMPLETE
                ==============================
                examined    \(examined) of \(total) in window\(stoppedEarly ? "   (stopped early: Tier A selfie \(tierA["selfie"] ?? 0), front \(tierA["front"] ?? 0), side \(tierA["side"] ?? 0) reached \(Self.earlyStopTierA["selfie"] ?? 0)/\(Self.earlyStopTierA["front"] ?? 0)/\(Self.earlyStopTierA["side"] ?? 0) after at least \(Self.earlyStopMinExamined) photos; \(total - examined) not examined, iCloud pass skipped)" : "")
                reference   \(self?.lastReferenceNote ?? "")
                no image    \(noImage)   (in iCloud with no usable copy on the phone, or unreadable)
                skipped     \(skippedShape)   (from the library record alone: too small to scan, or a panorama)
                local copy  \(localCopies)   (in iCloud, scanned from the phone's smaller copy)
                iCloud      \(cloudOnly) only in iCloud; \(cloudSelfieCandidates) looked like selfies, \(cloudFullCandidates) like a full-length photo; \(cloudDownloaded) downloaded (\(String(format: "%.1f", cloudSeconds))s of download time), \(cloudPreviewOut) dropped on the small copy, \(cloudFailed) failed\(cloudFailures.isEmpty ? "" : " (" + cloudFailures.sorted { $0.key < $1.key }.map { "\($0.key) \($0.value)" }.joined(separator: ", ") + ")"), \(cloudLeft) left (cap \(cloudCap)\(Self.cloudOnMobile ? " on mobile data, \(Self.cloudParallelMobile)" : " on Wi-Fi, \(Self.cloudParallel)") at a time, waited \(Int(cloudWaited))s after the local pass\(cloudExtended ? " (extended past \(Int(Self.cloudTail))s for confirmed photos)" : "")\(cloudAllowed ? "" : " — no suitable connection"))
                no face     \(noFace)
                group       \(groupSkipped)   (skipped: more than one face; \(sameShopper) more had several faces all the shopper's and went on)
                others      \(otherPeople)   (skipped: someone else in the photo)
                face small  \(tooSmall)   (under \(Int(Self.minFacePixels))px, even in the original)
                not full body \(notFullBody)   (not head to toe: head, \(Self.minAnkles)+ ankle, \(Int(Self.minBodySpan * 100))% span or \(Int(Self.minBodySpanBothAnkles * 100))% with both ankles, feet in frame\(Self.kneeLengthEnabled ? " — nor head to knee: \(Self.minKnees)+ knee, \(Int(Self.minKneeSpan * 100))% span or \(Int(Self.minKneeSpanBothKnees * 100))% with both knees, knees \(String(format: "%.1f", Self.minKneeDrop)) torso below the hips" : "; the knee rule is off, so a head-to-knee photo counts here"))
                body retry  \(bodyRetried) re-checked at \(Int(Self.fullResPixels))px after a face match, \(bodyRescued) rescued
                no match    \(noMatch)   (\(earlyNoMatch) decided from the face alone, before body pose)
                gap cut     \(gapCut.map { String(format: "%.3f", $0) } ?? "none")\(weakCut ? " (weak reference fallback)" : "")   (\(gapDropped.count) withdrawn: matched under \(String(format: "%.2f", Self.matchThreshold)) but above the gap between the shopper's photos and the rest; \(heldIds.count) held back until the end, \(heldIds.count - gapDropped.count) of them shown; \(Self.ownPhotoKeepEnabled ? "\(ownKept.count) kept as under \(String(format: "%.2f", Self.ownPhotoKeepLimit)) from a sure match" : "own-photo keep off"))
                own check   \(ownCheckLine)   (logged only)
                sensitive   \(sensitiveSkipped)   (matched, then filtered)
                unusable    \(unusableFace)   (matched, but the face is no use for the Muse: sunglasses, hand over it, eyes closed or a wink, cut by the frame, blurred\(Self.selfieGatesV2 ? "; v2 selfie gates: head pitched or turned, mouth open, teeth, exposure, too close, no camera data, eyes under usual" : ""))
                gates       \(unusableGates.isEmpty ? "none" : unusableGates.sorted { $0.value > $1.value }.map { "\($0.key) \($0.value)" }.joined(separator: ", "))\(eyeBaseline.map { String(format: "; usual eye openness %.2f", $0) } ?? "")
                2b facts    \(coverHints) matched selfie(s) with a scarf, mask, hood, earmuffs, headphones or tiara label (not filtered yet); focal length assumed on \(focalAssumed); segmenter read on \(coverRead) selfie(s): over the cover limits hairline \(coverFacts["hairline", default: 0]) (≥ \(Self.coverHairlineLimit)), jaw \(coverFacts["jaw", default: 0]) (≥ \(Self.coverJawLimit)), face \(coverFacts["face", default: 0]) (≥ \(Self.coverFaceLimit))\(Self.coverGatesEnabled ? "" : " — gates off, counted only")
                documents   of \(documentRead) matched photo(s) read: document labels sum ≥ \(Self.documentLabelSumLimit) on \(documentLabelled), handwriting ≥ \(Self.handwritingLimit) on \(handwritten), labels ≥ \(Self.documentPageLabelLimit) with the face on a page under \(Int(Self.documentPageAreaLimit * 100))% of the frame on \(faceOnPage) more\(Self.documentGateEnabled ? " (all gated)" : " (gate off, counted only)"); logged only: face on a detected document (≥ \(Self.documentConfidenceLog)) on \(faceOnDocument), text over \(Int(Self.documentTextShareLog * 100))% of the frame on \(textHeavy)
                too large   \(tooLargeSkipped)   (original over \(Original.byteCap / 1_048_576)MB — hidden, nothing is sent compressed)
                no original \(noOriginal)   (original unreadable or not downloaded in time; \(sizedByPixels) too slow to size but shown on pixel count)
                low data    \(lowDataSkipped)   (only in iCloud, not downloaded — Low Data Mode is on)
                sized       \(sized) original(s), \(downloadedToSize) from iCloud, \(String(format: "%.1f", sizingSeconds))s
                store       \(store == nil ? "off" : "\(storeDecided) decided without loading, \(storeCloudSkipped) iCloud skipped, \(store?.written ?? 0) written, \(store?.count ?? 0) remembered")
                duplicates  \(duplicates)   (matches that repeat an earlier one; shown, but only one of each is pre-selected)
                MATCHED     \(matchedIds.count)   (selfie \(found[.selfie, default: 0]), front \(found[.front, default: 0]), three-quarter \(found[.threeQuarter, default: 0]), side \(found[.side, default: 0]); \(kneeLength) in on the knee rule; \(selfieSmallEyes) selfie(s) under \(Int(Self.selfieEyeSpacingPixels))px eye spacing\(Self.selfieEyeFloorEnabled ? "" : " — floor off, counted only"))\(tierALine)
                elapsed     \(String(format: "%.1f", elapsed))s  (\(String(format: "%.0f", rate))/s)
                memory      \(memoryAtStart)MB at start, peak \(max(memoryPeak, Self.residentMB()))MB during the scan (this process; the web view's process is separate)
                stages      \((self?.stageMs ?? [:]).sorted { $0.key < $1.key }.map { "\($0.key) \(String(format: "%.1f", $0.value / 1000))s" }.joined(separator: " · "))
                ==============================

                """)
                if let evalReport { print(evalReport) }

                // The console summary as numbers, for analytics. Counts only: no ids,
                // no images. Built up front because the literal is too large inline.
                var summary: [String: Any] = [:]
                summary["examined"] = examined
                summary["total"] = total
                summary["monthsBack"] = monthsBack
                summary["limited"] = self?.isLimitedAccess ?? false
                summary["noImage"] = noImage
                summary["skippedShape"] = skippedShape
                summary["earlyNoMatch"] = earlyNoMatch
                summary["stageMs"] = (self?.stageMs ?? [:]).mapValues { Int($0) }
                summary["localCopies"] = localCopies
                summary["noFace"] = noFace
                summary["group"] = groupSkipped
                summary["sameShopper"] = sameShopper
                summary["otherPeople"] = otherPeople
                summary["faceTooSmall"] = tooSmall
                summary["notFullBody"] = notFullBody
                summary["bodyRetried"] = bodyRetried
                summary["bodyRescued"] = bodyRescued
                summary["noMatch"] = noMatch
                summary["closestNoMatch"] = closestNoMatch
                summary["nearMisses"] = nearMisses
                summary["gapCut"] = gapCut
                summary["weakCut"] = weakCut
                summary["gapDropped"] = gapDropped.count
                summary["ownKept"] = ownKept.count
                summary["gapHeld"] = heldIds.count
                summary["sensitive"] = sensitiveSkipped
                summary["unusableFace"] = unusableFace
                // Per filter — the v2 selfie gates' counts; the relative eye gate's
                // baseline and withdrawals; the facts logged for the covered-face
                // gates and the focal-length assumption. See `selfieGatesV2`.
                if !unusableGates.isEmpty { summary["unusableGates"] = unusableGates }
                summary["eyeDropped"] = eyeDropped.count
                summary["eyeBaseline"] = eyeBaseline
                summary["coverHints"] = coverHints
                summary["focalAssumed"] = focalAssumed
                summary["coverRead"] = coverRead
                if !coverFacts.isEmpty { summary["coverFacts"] = coverFacts }
                summary["duplicates"] = duplicates
                summary["tooLarge"] = tooLargeSkipped
                summary["noOriginal"] = noOriginal
                summary["lowData"] = lowDataSkipped
                summary["matched"] = matchedIds.count
                summary["matchedSelfie"] = found[.selfie, default: 0]
                summary["matchedFront"] = found[.front, default: 0]
                summary["matchedSide"] = found[.side, default: 0]
                summary["matchedThreeQuarter"] = found[.threeQuarter, default: 0]
                summary["kneeLength"] = kneeLength
                // Selfies under the v2 eye-spacing floor; dropped once the floor is on.
                summary["selfieSmallEyes"] = selfieSmallEyes
                // Matches lowered for a pitched or turned head; shown on pixel count
                // because the original was too slow to size; downloads in flight at
                // once (3 on mobile data, 6 on Wi-Fi).
                summary["tilted"] = tiltedMatches
                summary["sizedByPixels"] = sizedByPixels
                summary["cloudParallel"] = Self.cloudOnMobile ? Self.cloudParallelMobile : Self.cloudParallel
                summary["model"] = Self.faceModel.rawValue
                summary["cutoff"] = Self.matchThreshold
                summary["frames"] = self?.lastReferenceFrames ?? 1
                summary["chosenFrame"] = (self?.lastReferenceIndex ?? 0) + 1
                summary["referenceQuality"] = self?.lastReferenceQuality
                summary["blendedFrames"] = self?.lastReferenceBlended ?? 1
                // Per-frame quality (-1 when none was measured), and how the blend sat.
                summary["frameQualities"] = (self?.lastReferenceQualities ?? []).map { $0 ?? -1 }
                summary["blendSpread"] = self?.lastReferenceSpread
                summary["blendShift"] = self?.lastReferenceShift
                summary["elapsedMs"] = Int(elapsed * 1000)
                summary["memoryPeakMB"] = max(memoryPeak, Self.residentMB())
                summary["photosPerSecond"] = Int(rate)
                summary["inCloud"] = cloudOnly
                summary["cloudSelfies"] = cloudSelfieCandidates
                summary["cloudFullLength"] = cloudFullCandidates
                summary["cloudOnMobile"] = Self.cloudOnMobile
                summary["cloudPreviewOut"] = cloudPreviewOut
                summary["cloudLargerDownloads"] = self?.cloudLargerDownloads ?? 0
                summary["cloudDownloaded"] = cloudDownloaded
                summary["cloudFailed"] = cloudFailed
                // Why they failed: diskFull (Photos refuses to download on a nearly
                // full phone), timedOut, other. Left out when nothing failed.
                if !cloudFailures.isEmpty { summary["cloudFailures"] = cloudFailures }
                summary["cloudLeft"] = cloudLeft
                summary["cloudWaitMs"] = Int(cloudWaited * 1000)
                // The store — see `ScanStore`: photos counted without a load,
                // iCloud candidates skipped, records written, records held.
                if let store {
                    summary["storeDecided"] = storeDecided
                    summary["storeCloudSkipped"] = storeCloudSkipped
                    summary["storeWritten"] = store.written
                    summary["storeRecords"] = store.count
                }
                summary["cloudFirstDownloadedDate"] = cloudFirstDownloaded?.day
                summary["cloudFirstDownloadedAtMs"] = cloudFirstDownloaded?.atMs
                summary["cloudLastDownloadedDate"] = cloudLastDownloaded?.day
                summary["cloudLastDownloadedAtMs"] = cloudLastDownloaded?.atMs
                summary["matchedFirstDate"] = matchedFirstDate
                summary["matchedLastDate"] = matchedLastDate

                // The held-back matches, streamed now that the cut is known, so the
                // page learns their type and distance for pre-selection.
                for id in ordered where heldSet.contains(id) {
                    guard let score = matchScores[id] else { continue }
                    var heldPayload: [String: Any] = ["assetId": id,
                                                      "type": score.type.rawValue,
                                                      "isFullBody": ScanAnalysisStore.analysis(for: id)?.body.isHeadToToe ?? true,
                                                      "kneeUp": ScanAnalysisStore.analysis(for: id)?.body.byKnees ?? false,
                                                      "distance": score.distance,
                                                      "dupGroup": dupGroups[id] ?? id,
                                                      "done": total,
                                                      "total": total]
                    if let value = score.score { heldPayload["score"] = value }
                    if let breakdown = score.breakdown { heldPayload.merge(breakdown) { _, new in new } }
                    self?.sendToWeb(["type": "onGalleryMatchFound", "payload": heldPayload])
                }

                self?.sendToWeb(["type": "onGalleryScanComplete",
                                 "payload": ["assetIds": ordered,
                                             // Matches the page may already show that the
                                             // gap rule or the relative eye gate withdrew —
                                             // see `gapCutEnabled`, `relativeEyeGateEnabled`.
                                             "dropped": gapDropped + eyeDropped,
                                             "limited": self?.isLimitedAccess ?? false,
                                             // What the scan could not look at, for
                                             // analytics — the page shows none of it.
                                             "skipped": ["inCloud": cloudOnly,
                                                         "cloudSelfies": cloudSelfieCandidates,
                                                         "cloudFullLength": cloudFullCandidates,
                                                         "cloudDownloaded": cloudDownloaded,
                                                         "cloudLeft": cloudLeft,
                                                         "noImage": noImage],
                                             "summary": summary]])
            }
        }
    }

    /// The selfie to match against: in eval mode the one saved on the first run, so
    /// runs are comparable; otherwise the one just taken.
    static func evalReferenceSelfie(_ fresh: String) -> String {
        guard evalMode,
              let dir = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first
        else { return fresh }
        let url = dir.appendingPathComponent("swan-eval-selfie.jpg")

        if !evalResaveSelfie, let saved = try? Data(contentsOf: url) {
            let when = (try? FileManager.default.attributesOfItem(atPath: url.path)[.modificationDate]) as? Date
            let stamp = DateFormatter()
            stamp.dateFormat = "d MMM HH:mm"
            print("\u{1f9ea} matching against the saved eval selfie (from \(when.map(stamp.string) ?? "?"))")
            return "data:image/jpeg;base64," + saved.base64EncodedString()
        }

        guard let comma = fresh.firstIndex(of: ","),
              let data = Data(base64Encoded: String(fresh[fresh.index(after: comma)...])) else { return fresh }
        do {
            try data.write(to: url, options: .completeFileProtection)
            print("\u{1f9ea} saved this selfie as the eval reference — later runs will match against it")
        } catch {
            print("\u{1f9ea} could not save the eval selfie: \(error) — matching against this run's only")
        }
        return fresh
    }

    func loadEvalLabels() -> Set<String>? {
        guard Self.evalMode else { return nil }

        let options = PHFetchOptions()
        options.predicate = NSPredicate(format: "title == %@", Self.evalAlbumTitle)
        guard let album = PHAssetCollection.fetchAssetCollections(with: .album, subtype: .any,
                                                                 options: options).firstObject else {
            print("\u{1f9ea} eval mode is on, but there is no album named \"\(Self.evalAlbumTitle)\" — nothing will be measured")
            return nil
        }

        var ids = Set<String>()
        PHAsset.fetchAssets(in: album, options: nil).enumerateObjects { asset, _, _ in
            ids.insert(asset.localIdentifier)
        }
        print("\u{1f9ea} eval mode: \(ids.count) labelled photo(s) in \"\(Self.evalAlbumTitle)\"")
        // Limited access hides most of the library — the album included — so the
        // numbers would describe only what the person happened to share.
        if isLimitedAccess { print("\u{1f9ea} limited photo access — grant Full Access, or these numbers mean little") }
        return ids
    }
}

// MARK: - Matching evaluation (debug only)
// Scores each scan against a labelled album. Changes nothing on screen; nothing leaves the phone.

/// Face numbers that no gate uses yet, recorded so the next gate can be chosen
/// from data rather than guessed.
struct FaceMetrics {
    /// Face width as a fraction of the frame's width — the raw Vision box, not the
    /// shorter-side ratio the selfie gate reads.
    let ratio: CGFloat
    let yaw: Double?
    /// Nil when Vision cannot tell.
    let pitch: Double?
    /// Vision's 0–1 capture quality. Apple positions it for comparing captures of
    /// the *same* person, so read it as a ranking hint, not an absolute bar.
    let quality: Float?

    /// One extra Vision pass — the quality request — on a handler that already
    /// holds the image, so the photo is not decoded a second time.
    init(_ face: VNFaceObservation, handler: VNImageRequestHandler) {
        let request = VNDetectFaceCaptureQualityRequest()
        request.inputFaceObservations = [face]
        try? handler.perform([request])

        ratio = face.boundingBox.width
        yaw = face.yaw?.doubleValue
        pitch = face.pitch?.doubleValue
        quality = request.results?.first?.faceCaptureQuality
    }
}

/// How well a matched photo would serve the Muse: neutral, straight to the camera,
/// eyes open, well lit, sharp. 0–1, 0 when a hard filter rules it out. Sent as `score`.
struct MuseScore {
    let value: Float
    /// Each signal 0–1, in `weights` order.
    let parts: [(name: String, value: Float)]
    /// The hard filter that zeroed the score, if one did.
    let filter: String?
    /// What the expression reader saw, when it ran — see `FaceExpression`.
    let expression: FaceExpression?
    /// Vision's classifier on the head crop, the labels the score reads.
    let labels: [String: Float]
    /// A hand over the face, from Vision's hand detector.
    let handOnFace: Bool
    /// A cap or hat: ranked lower, never filtered — see `capMultiplier`.
    let capped: Bool
    /// A selfie whose head is not level with the camera: ranked lower, never
    /// filtered — see `tiltMultiplier`. The angles, in degrees, for the console note.
    let tilted: Bool
    let headDegrees: (yaw: Float, pitch: Float)
    /// A smile stays in and ranks lower: closed lips by `closedSmileMultiplier`,
    /// teeth or open mouth by `openSmileMultiplier`.
    enum Smile: String { case none = "", closed, open }
    let smile: Smile
    /// A stare or eyes held wide open: ranked low, not filtered — see
    /// `wideEyedMultiplier`.
    let wideEyed: Bool
    /// Other reasons the photo ranks low, each worth `loweredMultiplier`: an open
    /// mouth without a smile, a black or blown exposure.
    let lowered: [String]
    /// Any of cap, smile, wide-eyed or `lowered`: the photo sits in the lower
    /// score band, and its distance is left out of the gap rule.
    let demoted: Bool
    /// Under `ViewController.selfieScoreV2`, a selfie's tier, "A" or "B", and
    /// what held each of its groups under 1, for the console. Nil and empty
    /// for every other photo, and for a selfie a gate ruled out.
    let tier: String?
    let reasons: [String]
    /// Under `ViewController.selfieScoreV2`, eyes held wide or raised brows —
    /// see `ViewController.wideEyesLine`. Sent as `wideEyes`.
    let wideEyesV2: Bool
    /// Under `ViewController.fullLengthScoreV2`, the body score of a front,
    /// three-quarter or side; it supplies the value, parts and tier, and the
    /// face filters stand down. Nil for selfies and with the switch off.
    let body: BodyScore?
    /// What the shopper wears — see `outfitMultiplier`.
    struct Outfit {
        /// The strongest of `dressyLabels` over the whole photo, if any.
        let label: String?
        let dressy: Float
        /// Edge density of the clothing below the face, 0–1.
        let busy: Float
        /// Every whole-photo label at `ViewController.fullLengthLabelFloor` or
        /// over, strongest first — see `fullLengthLabelLog`. Empty when off.
        var labels: [(label: String, confidence: Float)] = []
        /// The whole-photo labels `ViewController.garmentCaps` knows, at any
        /// confidence over 0.1, strongest first.
        var garments: [(label: String, confidence: Float)] = []
    }
    let outfit: Outfit
    let dressy: Bool
    let busy: Bool
    /// What says "document" about the whole photo — see
    /// `ViewController.documentReadEnabled`; the gate is
    /// `ViewController.documentGateEnabled`.
    struct DocumentRead {
        /// The classifier's strongest labels over the whole photo, best first.
        let scene: [(label: String, confidence: Float)]
        /// Text boxes Vision found, and the share of the frame they cover, 0–1.
        let textBoxes: Int
        let textArea: Float
        /// Vision's document segmentation: how sure it is that a flat document
        /// (a page, card or print) is in the photo, the share of the frame it
        /// covers, and whether the matched face sits inside it. A passport page
        /// read 0.94, 0.39 of the frame, face inside; two selfies read 0.00.
        let docConfidence: Float
        let docArea: Float
        let faceInDoc: Bool
        /// The document-like labels at 0.01 or more, best first, their sum and
        /// the handwriting score — see `ViewController.documentLabels`.
        let docLabels: [(label: String, confidence: Float)]
        var labelSum: Float { docLabels.reduce(0) { $0 + $1.confidence } }
        var handwriting: Float { docLabels.first { $0.label == "handwriting" }?.confidence ?? 0 }
        /// The second document rule — see `ViewController.documentPageLabelLimit`:
        /// some document labels, and a page that holds the face without being
        /// the whole picture.
        var faceOnPage: Bool {
            labelSum >= ViewController.documentPageLabelLimit
                && docConfidence >= ViewController.documentConfidenceLog && faceInDoc
                && docArea < ViewController.documentPageAreaLimit
        }
        var note: String {
            let labels = scene.map { String(format: "%@ %.2f", $0.label, $0.confidence) }.joined(separator: " ")
            let docs = docLabels.map { String(format: "%@ %.2f", $0.label, $0.confidence) }.joined(separator: " ")
            return String(format: "scene %@; doc labels sum %.2f (%@), handwriting %.2f; text %d box(es) %.2f of frame; document %.2f, %.2f of frame, face %@",
                          labels.isEmpty ? "none" : labels, labelSum, docs.isEmpty ? "none" : docs, handwriting,
                          textBoxes, textArea, docConfidence, docArea, faceInDoc ? "inside" : "outside")
        }
    }
    let document: DocumentRead?
    /// The raw readings the parts were worked out from: angles in degrees, face
    /// width in pixels, the rest as the detectors report them. Sent in
    /// `breakdown` as `scoreInputs`.
    let readings: [String: Double]
    /// Camera to face in centimetres and what it was read from (`iris` or
    /// `eyes`), when the v2 selfie gates ran; whether the focal length was
    /// assumed — see `ViewController.assumedFocal35mm`.
    let cameraCm: Float?
    let cameraFrom: String?
    let focalAssumed: Bool
    /// What the metadata read saw, for the console — see `Original.Camera`.
    let cameraDetail: String?
    /// What covers the face, when it was read — see `FaceCover` and
    /// `ViewController.coverGatesEnabled`. Nil when a cheaper gate fired first.
    let cover: FaceCover?
    /// A head covering or an object over the face by the classifier's labels —
    /// see `coverLabels`. Logged, not filtered.
    var coverHint: Bool { labels.contains { Self.coverLabels.contains($0.key) && $0.value >= Self.coverConfidence } }

    /// Apple's capture quality carries the most; the three expression terms together
    /// carry 0.35, which puts a neutral face above a smile, stare or wink. A selfie
    /// looking up or down at the camera is handled by `tiltMultiplier`, not by
    /// these weights, so the order among level faces stays as it was.
    static let weights: [(name: String, weight: Float)] = [
        ("quality", 0.25), ("pose", 0.15), ("light", 0.10), ("size", 0.10),
        ("mouth", 0.15), ("eyes", 0.10), ("brow", 0.10), ("sharp", 0.05),
    ]

    /// Classifier confidence for sunglasses (filtered) and caps (ranked lower). Clear
    /// glasses read as eyeglasses, not sunglasses.
    static let sunglassesConfidence: Float = 0.4
    static let hatConfidence: Float = 0.5
    static let hatLabels: Set<String> = ["hat", "baseball_hat", "sunhat", "cowboy_hat", "beanie", "helmet", "hardhat"]
    /// Head coverings and objects over the face that the covered-face gates
    /// will read from the segmenter (plan item 2b). Until then Vision's
    /// classifier names them on the head crop; a selfie with one at
    /// `coverConfidence` or more is logged and counted (`coverHints` in the
    /// summary), so the gates' reach is known before they ship. Nothing is
    /// filtered on them yet; `hatLabels` stay the cap demotion.
    static let coverLabels: Set<String> = ["scarf", "mask", "gas_mask", "hoodie", "earmuffs", "headphones", "tiara"]
    static let coverConfidence: Float = 0.3

    /// What the v2 selfie gates read beyond the face — see
    /// `ViewController.selfieGatesV2`. Passed for photos sorted as selfies only.
    struct SelfieGates {
        /// Pupil to pupil in the original's pixels; nil when not measured.
        let eyeSpacingOriginal: Float?
        /// One pixel of the scan's render in the original's pixels.
        let originalScale: Float
        /// The original's long side in pixels, for the focal length in pixels.
        let originalLongSide: Float
        /// Nil when the metadata could not be read (original only in iCloud).
        let camera: Original.Camera?
    }
    /// A capped photo keeps this much of its score: behind a bare-headed one of
    /// the same quality, ahead of a poor one. A product call, not a measurement.
    static let capMultiplier: Float = 0.6
    /// Hand points Vision must place inside the padded face box for a hand over the
    /// face (21 per hand; a hand on the face places 20–21).
    static let handPointsOnFace = 10
    /// Expression reader: both eyes shut above this blink value (closed eyes
    /// read 0.64–0.80, open 0.04–0.35, smiling squints 0.19–0.26).
    static let closedBlink: Float = 0.5
    /// Expression cuts, set so a relaxed neutral face is rarely caught. A slight
    /// smile (0.3) stays in.
    static let smileFilter: Float = 0.5
    /// Under the v2 selfie gates, a smile at this level or more keeps a photo
    /// in with the teeth showing: it ranks low, as in 1.3.x
    /// (`openSmileMultiplier`), rather than falling out. The "teeth showing"
    /// gate applies to a face that is not smiling; the "mouth open" gate
    /// (`mouthOpenFilter`) applies to every face, so a laugh is still out. A
    /// product call of 29 Oct 2026, checked on a library where the grins to
    /// keep read jaw 0.02–0.07 and the laughs to drop 0.40–0.45; the spec's
    /// text gates every smile showing teeth, so the client is told.
    static let smileKeepsTeeth: Float = 0.3
    /// Lips parted: the jaw open this much or teeth showing (`FaceExpression.teeth`,
    /// closed lips ≤ 0.11).
    static let lipsPartedJaw: Float = 0.15
    static let teethShowing: Float = 0.2
    /// What a smile keeps of its score: closed lips behind neutral faces, an open
    /// mouth or laugh behind the closed-lip ones.
    static let closedSmileMultiplier: Float = 0.6
    static let openSmileMultiplier: Float = 0.4
    /// A smile with the brows up or the eyes held open counts as wide-eyed as
    /// well, so it ranks lower still.
    static let smileBrowUp: Float = 0.25
    static let smileEyeWide: Float = 0.05

    /// The outfit: formal wear (`dressyLabels`) and a busy torso (edge density below
    /// the face) each pull the score down by `outfitMultiplier`. Never a filter.
    static let dressyLabels: Set<String> = ["suit", "tuxedo", "necktie", "bowtie", "jacket", "sari", "gown", "wedding_dress", "kimono", "costume"]
    static let dressyConfidence: Float = 0.3
    static let busyTorso: Float = 0.11
    static let outfitMultiplier: Float = 0.8

    /// Mean gradient magnitude over a 64px copy, 0–1: how much is going on in
    /// a crop. A plain tee measures 0.01–0.05, a floral shirt 0.2–0.3.
    static func busyness(of crop: CGImage) -> Float {
        let n = 64
        guard let ctx = CGContext(data: nil, width: n, height: n, bitsPerComponent: 8, bytesPerRow: n * 4,
                                  space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else { return 0 }
        ctx.interpolationQuality = .high
        ctx.draw(crop, in: CGRect(x: 0, y: 0, width: n, height: n))
        guard let data = ctx.data else { return 0 }
        let p = data.bindMemory(to: UInt8.self, capacity: n * n * 4)
        var grey = [Float](repeating: 0, count: n * n)
        for i in 0..<(n * n) { grey[i] = 0.299 * Float(p[i * 4]) + 0.587 * Float(p[i * 4 + 1]) + 0.114 * Float(p[i * 4 + 2]) }
        var sum: Float = 0
        for y in 1..<(n - 1) {
            for x in 1..<(n - 1) {
                let gx = grey[y * n + x + 1] - grey[y * n + x - 1]
                let gy = grey[(y + 1) * n + x] - grey[(y - 1) * n + x]
                sum += (gx * gx + gy * gy).squareRoot()
            }
        }
        return sum / Float((n - 2) * (n - 2)) / 255
    }
    static let mouthOpenFilter: Float = 0.3
    static let winkBlink: Float = 0.5
    static let staringBrow: Float = 0.6
    static let staringSquintBelow: Float = 0.25
    static let wideEyedBrow: Float = 0.25
    static let wideEyedSquintBelow: Float = 0.10
    /// Eye-wide blendshape from which the lids count as held open, catching wide
    /// eyes with the brows at rest. Relaxed faces read 0.00–0.02.
    static let eyeWideFilter: Float = 0.08
    /// What a wide-eyed photo keeps of its score: shown, behind the neutral
    /// and closed-lip-smile faces, beside the open-mouth smiles.
    static let wideEyedMultiplier: Float = 0.4
    static let loweredMultiplier: Float = 0.4

    /// Head turn, in degrees, at which the pose term reaches 0.
    static let poseLimitDegrees: Float = 30
    /// Past these a selfie's head is clearly not level with the camera and it
    /// keeps `tiltMultiplier` of its score, like a cap: behind every level face,
    /// never hidden. Selfies only: a side view has the head turned by definition,
    /// and a front's face is read through the pose term as before. Pitch (looking
    /// up or down) gets less room than yaw because that is the angle a Muse
    /// suffers from most; Vision's pitch from a flat photo is a rougher reading
    /// than its yaw, so it is not set tighter than this.
    static let tiltedPitchDegrees: Float = 15
    static let tiltedYawDegrees: Float = 20
    static let tiltMultiplier: Float = 0.6
    /// Face width, in pixels of the scan's render, that scores a full size term.
    static let fullSizePixels: Float = 400
    /// Eye height over width: about this and above reads as open, half of it
    /// as closed. Vision's six-point eye outline.
    static let eyeOpenRatio: Float = 0.30
    static let eyeClosedRatio: Float = 0.10
    /// Inner-lip height over mouth width above which the mouth is open.
    static let mouthOpenRatio: Float = 0.08
    /// Lip-corner lift over mouth width for a smile and for a full smile. Used only
    /// when the expression reader is unavailable.
    static let smileLift: Float = 0.03
    static let smileRamp: Float = 0.07
    /// Laplacian variance of the 64px face below which the photo is blurred:
    /// sharp faces 0.013–0.036, a soft one 0.004, a heavily upscaled one 0.001.
    static let blurVariance: Float = 5e-4

    init(face: VNFaceObservation, in image: CGImage, handler: VNImageRequestHandler, faceWidth: CGFloat,
         expression: FaceExpression? = nil, labels: [String: Float] = [:], handOnFace: Bool = false,
         outfit: Outfit = Outfit(label: nil, dressy: 0, busy: 0), selfie: Bool = false, gates: SelfieGates? = nil,
         coverReader: (() -> FaceCover?)? = nil, document: DocumentRead? = nil, body: BodyScore? = nil) {
        let clamp = { (v: Float) in max(0, min(1, v)) }
        var parts: [(name: String, value: Float)] = []
        var filter: String?
        var smile = Smile.none
        var wideEyed = false
        var lowered: [String] = []

        // A document, not a photo of the person — see
        // `ViewController.documentGateEnabled`. First, so the summary names it.
        if ViewController.documentGateEnabled, let document {
            if document.labelSum >= ViewController.documentLabelSumLimit { filter = "document" }
            else if document.handwriting >= ViewController.handwritingLimit { filter = "handwriting" }
            else if document.faceOnPage { filter = "document" }
        }

        // What covers the face. Sunglasses and a hand rule the photo out of the
        // ranking; a cap only pulls it down — see `capMultiplier`.
        if (labels["sunglasses"] ?? 0) >= Self.sunglassesConfidence { filter = filter ?? "sunglasses" }
        if handOnFace { filter = filter ?? "hand over face" }
        let capped = labels.contains { Self.hatLabels.contains($0.key) && $0.value >= Self.hatConfidence }

        // Face cut by the frame. Vision's box, with a little tolerance.
        let box = face.boundingBox
        if box.minX < 0.01 || box.maxX > 0.99 || box.minY < 0.01 || box.maxY > 0.99 {
            filter = "face cut by the frame"
        }

        // Two requests on the handler that already holds the image.
        let qualityRequest = VNDetectFaceCaptureQualityRequest()
        qualityRequest.inputFaceObservations = [face]
        let landmarksRequest = VNDetectFaceLandmarksRequest()
        landmarksRequest.inputFaceObservations = [face]
        try? handler.perform([qualityRequest, landmarksRequest])
        let quality = qualityRequest.results?.first?.faceCaptureQuality ?? 0.5
        parts.append(("quality", clamp(quality)))

        // Pose: each axis costs separately, so a turn and a tilt together score
        // lower than either alone.
        let degrees = { (n: NSNumber?) in abs(Float(n?.doubleValue ?? 0)) * 180 / .pi }
        let yaw = degrees(face.yaw), pitch = degrees(face.pitch), roll = degrees(face.roll)
        let pose = clamp(1 - yaw / Self.poseLimitDegrees) * clamp(1 - pitch / Self.poseLimitDegrees) * clamp(1 - roll / (Self.poseLimitDegrees * 0.66))
        parts.append(("pose", pose))
        let tilted = selfie && (pitch > Self.tiltedPitchDegrees || yaw > Self.tiltedYawDegrees)

        // Light, from a 64px copy of the face with a little margin.
        let size = CGSize(width: image.width, height: image.height)
        let pad = box.insetBy(dx: -box.width * 0.1, dy: -box.height * 0.1).intersection(CGRect(x: 0, y: 0, width: 1, height: 1))
        let faceStats = Self.stats(of: image, region: pad, side: 64)
        let imageStats = Self.stats(of: image, region: CGRect(x: 0, y: 0, width: 1, height: 1), side: 32)
        var light: Float = 0.5
        if let f = faceStats {
            let exposure = clamp(1 - abs(f.mean - 0.5) / 0.35)
            let clip = clamp(1 - f.clipped / 0.2)
            let balance = clamp(1 - abs(f.left - f.right) / 0.25)
            let backlit = clamp(1 - ((imageStats?.mean ?? f.mean) - f.mean - 0.05) / 0.25)
            // Skin reads warm: red at or above green at or above blue, and not
            // by a wild margin. Anything else is a cast.
            let cast: Float = (f.r >= f.g && f.g >= f.b) ? (f.r - f.b > 0.5 ? 0.7 : 1) : 0.6
            light = (exposure + clip + balance + backlit + cast) / 5
            // A gate under the v2 selfie rules, a demotion otherwise.
            if f.mean < 0.08 || f.mean > 0.92 {
                if gates == nil { lowered.append("exposure") } else { filter = filter ?? "exposure" }
            }
            if f.laplacian < Self.blurVariance { filter = filter ?? "blurred" }
        }
        parts.append(("light", light))

        parts.append(("size", clamp((Float(faceWidth) - 120) / (Self.fullSizePixels - 120))))

        // Mouth, eyes and brows: from the expression reader when it ran, else
        // from Vision's landmarks, with neutral values when it has none.
        var mouth: Float = 0.7, eyes: Float = 0.7, brow: Float = 0.7
        if let e = expression {
            mouth = clamp(1 - e.smile) * clamp(1 - e.jawOpen)
            // The more open eye sets the term, so a wink ranks lower; both shut
            // is the filter.
            eyes = clamp((Self.closedBlink - e.blinkMax) / (Self.closedBlink - 0.1))
            // Raised brows, and the wide-eyed stare that goes with them: relaxed
            // eyes squint a little (0.35–0.6), a stare hardly at all (under 0.1).
            brow = clamp(1 - e.browUp / 0.5) * clamp(e.squint / 0.15)
            if e.blinkBoth > Self.closedBlink { filter = filter ?? "eyes closed" }
            else if e.blinkMax >= Self.winkBlink { filter = filter ?? "one eye closed" }
            // A smile ranks low, lower still with the lips parted; with brows up or
            // eyes wide it also counts as wide-eyed. An open mouth without a smile ranks low.
            let lipsParted = e.jawOpen >= Self.lipsPartedJaw || e.teeth >= Self.teethShowing
            if e.smile >= Self.smileFilter {
                // Brows up or eyes held open with it counts as wide-eyed too,
                // so the two multipliers compound — see `smileBrowUp`.
                smile = lipsParted ? .open : .closed
                if e.browUp >= Self.smileBrowUp || e.eyeWide >= Self.smileEyeWide { wideEyed = true }
            } else if e.jawOpen >= Self.mouthOpenFilter, gates == nil { lowered.append("mouth open") }
            // Wide-eyed, three readings, ranks low — see `wideEyedMultiplier`.
            // With a smile it is out, above.
            if (e.browUp >= Self.staringBrow && e.squint < Self.staringSquintBelow)
                || (e.browUp >= Self.wideEyedBrow && e.squint < Self.wideEyedSquintBelow)
                || e.eyeWide >= Self.eyeWideFilter { wideEyed = true }
        } else if let lm = landmarksRequest.results?.first?.landmarks {
            func bounds(_ region: VNFaceLandmarkRegion2D?) -> CGRect? {
                guard let pts = region?.pointsInImage(imageSize: size), !pts.isEmpty else { return nil }
                let xs = pts.map(\.x), ys = pts.map(\.y)
                return CGRect(x: xs.min()!, y: ys.min()!, width: xs.max()! - xs.min()!, height: ys.max()! - ys.min()!)
            }
            if let outer = bounds(lm.outerLips), outer.width > 1, let outerPts = lm.outerLips?.pointsInImage(imageSize: size) {
                let openness = Float((bounds(lm.innerLips)?.height ?? 0) / outer.width)
                let closed = clamp(1 - (openness - Self.mouthOpenRatio) / 0.17)
                // Corners above the lips' centre line read as a smile (Vision's y runs up).
                let centre = outerPts.map(\.y).reduce(0, +) / CGFloat(outerPts.count)
                let left = outerPts.min { $0.x < $1.x }!, right = outerPts.max { $0.x < $1.x }!
                let lift = Float(((left.y + right.y) / 2 - centre) / outer.width)
                let neutral = clamp(1 - (lift - Self.smileLift) / Self.smileRamp)
                mouth = closed * neutral
            }
            let ratios = [lm.leftEye, lm.rightEye].compactMap { bounds($0) }.filter { $0.width > 1 }.map { Float($0.height / $0.width) }
            if !ratios.isEmpty {
                let open = ratios.max()!
                eyes = clamp((open - Self.eyeClosedRatio) / (Self.eyeOpenRatio - Self.eyeClosedRatio))
                // Two signals together: the eye outline alone brushes against
                // smiling squints, Apple's quality collapses on shut eyes.
                if eyes < 0.3 && quality < 0.3 { filter = filter ?? "eyes closed" }
            }
        }
        parts.append(("mouth", mouth))
        parts.append(("eyes", eyes))
        parts.append(("brow", brow))

        // The v2 selfie gates — see `ViewController.selfieGatesV2`. Each is a
        // filter where 1.3.x ranked the photo lower or let it through. The
        // first filter found above stays the named one.
        var cameraCm: Float?
        var cameraFrom: String?
        var focalAssumed = false
        var cover: FaceCover?
        if let gates {
            if pitch > ViewController.gatePitchDegrees { filter = filter ?? "head pitched" }
            if yaw > ViewController.gateYawDegrees { filter = filter ?? "head turned" }
            // The jaw gates every face; the teeth only one that is not smiling —
            // see `smileKeepsTeeth`.
            if let e = expression {
                if e.jawOpen >= Self.mouthOpenFilter { filter = filter ?? "mouth open" }
                if e.smile < Self.smileKeepsTeeth, e.teeth >= Self.teethShowing { filter = filter ?? "teeth showing" }
            }
            // The face contour at the frame's edge: a chin or an ear the box's
            // margin above still clears. The hairline has no landmark; the box
            // test keeps the top.
            if let contour = landmarksRequest.results?.first?.landmarks?.faceContour?.pointsInImage(imageSize: size),
               contour.contains(where: { $0.x < size.width * 0.01 || $0.x > size.width * 0.99 || $0.y < size.height * 0.01 }) {
                filter = filter ?? "face cut by the frame"
            }
            // Camera to face: focal length in the original's pixels, then the
            // iris (every iris is 11.7 mm) or, without iris points, the eyes.
            // A camera photo with a lens length but no 35 mm equivalent (a DSLR
            // on a test library read 85 mm, which is 136 mm on its sensor) gives
            // no distance; only a photo with no camera data at all is read as a
            // phone's front camera.
            let focal35: Float?
            if let known = gates.camera?.focal35mm { focal35 = known }
            else if gates.camera?.focalMm != nil { focal35 = nil }
            else { focal35 = ViewController.assumedFocal35mm; focalAssumed = true }
            if let focal35 {
                let focalPx = focal35 / 36 * gates.originalLongSide
                if let iris = expression?.irisPixels, iris > 0 {
                    cameraCm = focalPx * ViewController.irisMm / (iris * gates.originalScale) / 10
                    cameraFrom = "iris"
                } else if let eyes = gates.eyeSpacingOriginal, eyes > 0 {
                    cameraCm = focalPx * ViewController.eyeSpacingMm / eyes / 10
                    cameraFrom = "eyes"
                }
            }
            if ViewController.tooCloseGateEnabled, let cm = cameraCm, cm < ViewController.tooCloseCm { filter = filter ?? "too close" }
            if ViewController.noCameraDataGateEnabled, gates.camera?.present == false { filter = filter ?? "no camera data" }
            // What covers the face — see `ViewController.coverGatesEnabled`. The
            // segmenter runs last and only for a selfie nothing above has
            // dropped; with the gates off it runs for every selfie, to be logged.
            if ViewController.coverGatesEnabled {
                if capped { filter = filter ?? "cap or hat" }
                if filter == nil { cover = coverReader?() }
                if let cover {
                    if cover.hairline >= ViewController.coverHairlineLimit { filter = filter ?? "hairline covered" }
                    if cover.jaw >= ViewController.coverJawLimit { filter = filter ?? "jaw covered" }
                    if cover.face >= ViewController.coverFaceLimit { filter = filter ?? "face covered" }
                }
            } else {
                cover = coverReader?()
            }
        }
        self.cameraCm = cameraCm
        self.cameraFrom = cameraFrom
        self.focalAssumed = focalAssumed
        self.cameraDetail = gates.map { $0.camera?.detail ?? "unreadable (only in iCloud?)" }
        self.cover = cover

        // Sharpness on a log scale: variance 1e-3 scores 0, 3e-2 scores 1 — see
        // `blurVariance` for where real faces land.
        let sharp = faceStats.map { clamp((log10(max($0.laplacian, 1e-8)) + 3) / 1.5) } ?? 0.5
        parts.append(("sharp", sharp))

        // What the parts above were worked out from, for `breakdown`. One
        // assignment each: a literal this long is more than the type-checker will take.
        let fixed = { (v: Float, places: Double) in (Double(v) * pow(10, places)).rounded() / pow(10, places) }
        var readings: [String: Double] = [:]
        readings["yaw"] = fixed(yaw, 1)
        readings["pitch"] = fixed(pitch, 1)
        readings["roll"] = fixed(roll, 1)
        readings["faceWidth"] = Double(faceWidth).rounded()
        readings["quality"] = fixed(quality, 3)
        readings["sunglasses"] = fixed(labels["sunglasses"] ?? 0, 2)
        readings["cap"] = fixed(labels.filter { Self.hatLabels.contains($0.key) }.values.max() ?? 0, 2)
        readings["handOnFace"] = handOnFace ? 1 : 0
        readings["dressy"] = fixed(outfit.dressy, 2)
        readings["busy"] = fixed(outfit.busy, 3)
        if let f = faceStats {
            readings["brightness"] = fixed(f.mean, 3)
            readings["clipped"] = fixed(f.clipped, 3)
            readings["backlight"] = fixed((imageStats?.mean ?? f.mean) - f.mean, 3)
            readings["blur"] = fixed(f.laplacian, 5)
        }
        if let e = expression {
            readings["smile"] = fixed(e.smile, 2)
            readings["jawOpen"] = fixed(e.jawOpen, 2)
            readings["blink"] = fixed(e.blinkMax, 2)
            readings["browUp"] = fixed(e.browUp, 2)
            readings["squint"] = fixed(e.squint, 2)
            readings["eyeWide"] = fixed(e.eyeWide, 2)
            readings["teeth"] = fixed(e.teeth, 2)
            readings["pucker"] = fixed(e.pucker, 2)
            readings["funnel"] = fixed(e.funnel, 2)
            readings["press"] = fixed(e.press, 2)
            readings["browDown"] = fixed(e.browDown, 2)
            // Logged only, for the camera-height signal — see `FaceExpression.faceRatio`.
            readings["gazeUp"] = fixed(e.gazeUp, 2)
            readings["gazeDown"] = fixed(e.gazeDown, 2)
            readings["gazeSide"] = fixed(e.gazeSide, 2)
            if let ratio = e.faceRatio { readings["faceRatio"] = fixed(ratio, 3) }
            if let p = e.headPitch { readings["mpPitch"] = fixed(p, 1) }
            if let y = e.headYaw { readings["mpYaw"] = fixed(y, 1) }
            if let r = e.headRoll { readings["mpRoll"] = fixed(r, 1) }
        }
        if let cm = cameraCm { readings["cameraCm"] = fixed(cm, 1) }
        if let gates {
            if let iris = expression?.irisPixels { readings["irisPx"] = fixed(iris * gates.originalScale, 1) }
            if let eyes = gates.eyeSpacingOriginal { readings["eyeSpacingPx"] = fixed(eyes, 1) }
            if let focal = gates.camera?.focal35mm { readings["focal35"] = fixed(focal, 1) }
            readings["focalAssumed"] = focalAssumed ? 1 : 0
            if let camera = gates.camera { readings["cameraData"] = camera.present ? 1 : 0 }
        }
        if let cover {
            readings["coverHairline"] = fixed(cover.hairline, 2)
            readings["coverJaw"] = fixed(cover.jaw, 2)
            readings["coverFace"] = fixed(cover.face, 2)
        }
        self.readings = readings

        self.expression = expression
        self.labels = labels
        self.handOnFace = handOnFace
        self.capped = capped
        self.tilted = tilted
        self.headDegrees = (yaw, pitch)
        self.smile = smile
        self.wideEyed = wideEyed
        self.lowered = lowered
        self.outfit = outfit
        self.document = document
        let dressy = outfit.dressy >= Self.dressyConfidence
        let busy = outfit.busy >= Self.busyTorso
        self.dressy = dressy
        self.busy = busy
        let weighted = zip(Self.weights, parts).reduce(0) { $0 + $1.0.weight * $1.1.value }
        // Two bands, so a clean face always ranks above a demoted one: clean photos
        // score 0.5–1, demoted ones 0–0.5. The outfit only moves a photo within its band.
        var multiplier: Float = 1
        if capped { multiplier *= Self.capMultiplier }
        if tilted { multiplier *= Self.tiltMultiplier }
        if smile == .closed { multiplier *= Self.closedSmileMultiplier }
        if smile == .open { multiplier *= Self.openSmileMultiplier }
        if wideEyed { multiplier *= Self.wideEyedMultiplier }
        for _ in lowered { multiplier *= Self.loweredMultiplier }
        let demoted = multiplier < 1
        // Under the v2 full-length score nothing on the face demotes the photo.
        self.demoted = body == nil && demoted
        if dressy { multiplier *= Self.outfitMultiplier }
        if busy { multiplier *= Self.outfitMultiplier }
        let banded = demoted ? 0.5 * weighted * multiplier : 0.5 + 0.5 * weighted * multiplier

        // The v2 selfie score — see `ViewController.selfieScoreV2`. `gates` is
        // passed for selfies only. Replaces the parts, bands and multipliers.
        var tier: String?
        var reasons: [String] = []
        var wideEyesV2 = false
        if ViewController.selfieScoreV2, let gates {
            typealias V = ViewController
            // 1 at `good` or better, 0 at `bad` or worse, a straight line between.
            func ramp(_ value: Float, _ curve: (good: Float, bad: Float)) -> Float {
                clamp((value - curve.bad) / (curve.good - curve.bad))
            }
            // The lowest of a group's signals, and what it was.
            func lowest(_ signals: [(why: String, value: Float)]) -> Float {
                guard let low = signals.min(by: { $0.value < $1.value }) else { return 1 }
                if low.value < 1 { reasons.append(low.why) }
                return low.value
            }
            var poseSignals: [(String, Float)] = [
                (String(format: "pitch %.0f°", pitch), ramp(pitch, V.posePitch)),
                (String(format: "yaw %.0f°", yaw), ramp(yaw, V.poseYaw)),
                (String(format: "roll %.0f°", roll), ramp(roll, V.poseRoll)),
            ]
            if let cm = cameraCm { poseSignals.append((String(format: "camera %.0f cm", cm), ramp(cm, V.poseDistance))) }
            let poseGroup = lowest(poseSignals)

            var lightSignals: [(String, Float)] = []
            if let f = faceStats {
                let bright = max(f.left, f.right), dark = max(min(f.left, f.right), 0.01)
                lightSignals.append((String(format: "uneven light %.1f×", bright / dark), ramp(bright / dark, V.lightEvenness)))
                if let whole = imageStats {
                    let ratio = f.mean / max(whole.mean, 0.01)
                    lightSignals.append((String(format: "backlit %.2f", ratio), ramp(ratio, V.lightBacklight)))
                }
                lightSignals.append((String(format: "blown %.0f%%", f.blown * 100), ramp(f.blown, V.lightClipped)))
                let cast: Float = (f.r >= f.g && f.g >= f.b) ? (f.r - f.b > 0.5 ? 0.7 : 1) : 0.6
                lightSignals.append(("colour cast", cast))
            }
            let lightGroup = lowest(lightSignals)

            // Scores 1 until measured — plan, item 3 decisions.
            let gazeGroup: Float = 1

            var expressionSignals: [(String, Float)] = []
            if smile == .closed { expressionSignals.append(("closed smile", V.expressionCapped)) }
            if smile == .open { expressionSignals.append(("open smile", V.expressionOpenSmile)) }
            let wideEyes = wideEyed || (expression?.eyeWide ?? 0) >= V.wideEyesLine
            if wideEyes { expressionSignals.append(("wide-eyed", V.expressionCapped)) }
            if let e = expression {
                if e.pucker >= V.puckerLimit { expressionSignals.append((String(format: "pucker %.2f", e.pucker), V.expressionCapped)) }
                if e.browDown >= V.frownLimit { expressionSignals.append((String(format: "frown %.2f", e.browDown), V.expressionCapped)) }
            }
            let expressionGroup = lowest(expressionSignals)

            var visibilitySignals: [(String, Float)] = []
            if let cover { visibilitySignals.append((String(format: "face %.0f%% visible", (1 - cover.face) * 100), ramp(1 - cover.face, V.visibilityShare))) }
            if (labels["eyeglasses"] ?? 0) >= V.glassesConfidence { visibilitySignals.append(("glasses", V.glassesCap)) }
            let visibilityGroup = lowest(visibilitySignals)

            var detailSignals: [(String, Float)] = [(String(format: "sharpness %.2f", sharp), sharp)]
            if let eyes = gates.eyeSpacingOriginal { detailSignals.append((String(format: "eyes %.0f px apart", eyes), ramp(eyes, V.detailEyeSpacing))) }
            let detailGroup = lowest(detailSignals)

            let groups: [Float] = [poseGroup, lightGroup, gazeGroup, expressionGroup, visibilityGroup, detailGroup]
            let t = zip(V.scoreWeightsV2, groups).reduce(Float(1)) { $0 * pow($1.1, $1.0.weight) }
            self.parts = zip(V.scoreWeightsV2, groups).map { ($0.name, $1) }
            self.value = filter == nil ? t : 0
            let eyesTooSmall = (gates.eyeSpacingOriginal ?? .infinity) < V.tierAEyeSpacingMin
            // Already named when it was the detail group's lowest signal.
            let eyesWhy = String(format: "eyes %.0f px apart", gates.eyeSpacingOriginal ?? 0)
            if eyesTooSmall, !reasons.contains(eyesWhy) { reasons.append(eyesWhy) }
            if filter == nil { tier = t >= V.tierALine && !eyesTooSmall ? "A" : "B" }
            wideEyesV2 = wideEyes
        } else if let body {
            // The v2 full-length score: the face only had to match. Its filters
            // stand down, bar the document gate; the body's own gates apply.
            if let f = filter, f != "document", f != "handwriting" { filter = nil }
            filter = filter ?? body.filter
            self.parts = body.parts
            // The outfit multiplier lowers the value, and the tier follows the
            // final value — see `fullLengthOutfitMultiplier`: a busy print hides
            // the body shape as much as a loose fit does, so a photo it pulls
            // under the Tier A line is Tier B.
            var outfitMultiplier: Float = 1
            if ViewController.fullLengthOutfitMultiplier {
                if dressy, !ViewController.garmentCapsEnabled { outfitMultiplier *= Self.outfitMultiplier }
                if busy { outfitMultiplier *= Self.outfitMultiplier }
            }
            let finalValue = body.value * outfitMultiplier
            self.value = filter == nil ? finalValue : 0
            if filter == nil, body.tier != nil {
                tier = finalValue >= ViewController.fullLengthTierALine ? "A"
                    : (finalValue >= ViewController.fullLengthUsableFloor ? "B" : nil)
            }
            reasons = body.reasons
        } else {
            self.parts = parts
            self.value = filter == nil ? banded : 0
        }
        self.filter = filter
        self.tier = tier
        self.reasons = reasons
        self.wideEyesV2 = wideEyesV2
        self.body = body
    }

    /// For the console: the value, then every part, or the filter that zeroed it.
    var note: String {
        let top = labels.filter { $0.value >= 0.3 }.sorted { $0.value > $1.value }.prefix(2)
        let seen = top.map { String(format: "%@ %.2f", $0.key, $0.value) }.joined(separator: " ")
        // In pieces: one literal this long is more than the type-checker will take.
        var extraParts: [String?] = [expression?.note, seen.isEmpty ? nil : "labels " + seen, handOnFace ? "hand on face" : nil]
        // Cover labels the two above left out, so a hood or scarf is always on the line.
        let coverSeen = labels.filter { label in Self.coverLabels.contains(label.key) && label.value >= Self.coverConfidence && !top.contains { $0.key == label.key } }
            .sorted { $0.value > $1.value }.map { String(format: "%@ %.2f", $0.key, $0.value) }.joined(separator: " ")
        extraParts.append(coverSeen.isEmpty ? nil : "labels " + coverSeen)
        extraParts.append(cameraCm.map { String(format: "camera %.0fcm (%@%@)", $0, cameraFrom ?? "", focalAssumed ? ", focal assumed" : "") })
        extraParts.append(cameraDetail.map { "meta " + $0 })
        extraParts.append(cover?.note)
        extraParts.append(String(format: "head yaw %.0f° pitch %.0f°", headDegrees.yaw, headDegrees.pitch))
        if let body {
            extraParts.append(body.note)
            if ViewController.fullLengthOutfitMultiplier {
                extraParts.append(dressy && !ViewController.garmentCapsEnabled ? "\(outfit.label ?? "dressy") \(String(format: "%.2f", outfit.dressy)) ×\(Self.outfitMultiplier)" : nil)
                extraParts.append(busy ? "busy torso \(String(format: "%.2f", outfit.busy)) ×\(Self.outfitMultiplier)" : nil)
            }
            if !outfit.labels.isEmpty {
                extraParts.append("labels " + outfit.labels.map { String(format: "%@ %.2f", $0.label, $0.confidence) }.joined(separator: " "))
            }
        } else if tier != nil {
            // The v2 score has no multipliers: what held each group down instead.
            extraParts.append(reasons.isEmpty ? nil : "held down by " + reasons.joined(separator: ", "))
        } else {
            extraParts.append(capped ? "cap ×\(Self.capMultiplier)" : nil)
            extraParts.append(tilted ? "tilted ×\(Self.tiltMultiplier)" : nil)
            extraParts.append(smile == .closed ? "closed smile ×\(Self.closedSmileMultiplier)" : nil)
            extraParts.append(smile == .open ? "open smile ×\(Self.openSmileMultiplier)" : nil)
            extraParts.append(wideEyed ? "wide-eyed ×\(Self.wideEyedMultiplier)" : nil)
            extraParts.append(lowered.isEmpty ? nil : lowered.map { "\($0) ×\(Self.loweredMultiplier)" }.joined(separator: "; "))
            extraParts.append(dressy ? "\(outfit.label ?? "dressy") \(String(format: "%.2f", outfit.dressy)) ×\(Self.outfitMultiplier)" : nil)
            extraParts.append(busy ? "busy torso \(String(format: "%.2f", outfit.busy)) ×\(Self.outfitMultiplier)" : nil)
        }
        extraParts.append(document?.note)
        let extras = extraParts.compactMap { $0 }.joined(separator: "; ")
        if let filter { return String(format: "score=0 (%@)%@", filter, extras.isEmpty ? "" : "  " + extras) }
        let detail = parts.map { String(format: "%@ %.2f", $0.name, $0.value) }.joined(separator: " ")
        let tierNote = tier.map { " tier \($0)" } ?? ""
        return String(format: "score=%.2f%@ [%@]%@", value, tierNote, detail, extras.isEmpty ? "" : "  " + extras)
    }

    /// For the page's analytics, sent with the match next to `score`: each part,
    /// the penalties applied, and the filter that zeroed it, if one did — so a
    /// ranking can be explained without the console.
    var breakdown: [String: Any] {
        var penalties: [String] = []
        if capped { penalties.append("cap") }
        if tilted { penalties.append("tilted") }
        if smile == .closed { penalties.append("closed smile") }
        if smile == .open { penalties.append("open smile") }
        if wideEyed { penalties.append("wide-eyed") }
        penalties += lowered
        if dressy { penalties.append("dressy") }
        if busy { penalties.append("busy") }
        var fields: [String: Any] = [
            "scoreParts": Dictionary(parts.map { ($0.name, (Double($0.value) * 100).rounded() / 100) }) { _, last in last },
            "scoreInputs": readings,
        ]
        // Under the v2 selfie score the parts are its six groups and the
        // penalties are gone; `tier` tells the page what it may pre-select.
        if let tier { fields["tier"] = tier } else if body == nil { fields["scorePenalties"] = penalties }
        if let body {
            var inputs = readings
            for (k, v) in body.readings { inputs[k] = (v * 1000).rounded() / 1000 }
            fields["scoreInputs"] = inputs
            fields["usable"] = tier != nil
            // The clothing colour, for the page's session rule — item 5c.
            if let outfit = body.outfit { fields["outfit"] = outfit }
        }
        if wideEyesV2 { fields["wideEyes"] = true }
        if let filter { fields["scoreFilter"] = filter }
        return fields
    }

    /// The head crop for the expression reader and classifier: the face box with hair
    /// and cap brim inside it. Normalised, bottom-left origin, clipped to the image.
    static func headBox(_ face: CGRect) -> CGRect {
        CGRect(x: face.minX - face.width * 0.6, y: face.minY - face.height * 0.5, width: face.width * 2.2, height: face.height * 2.4)
            .intersection(CGRect(x: 0, y: 0, width: 1, height: 1))
    }

    /// Luminance and colour statistics of one region of the image, read from a
    /// small square copy: mean, clipped fraction (blown or black), blown
    /// fraction (bright only), left and right half means, average colour, and
    /// the Laplacian variance for sharpness.
    static func stats(of image: CGImage, region: CGRect, side: Int) -> (mean: Float, clipped: Float, blown: Float, left: Float, right: Float, r: Float, g: Float, b: Float, laplacian: Float)? {
        let w = CGFloat(image.width), h = CGFloat(image.height)
        // Vision's region has its origin at the bottom; CGImage cropping at the top.
        let rect = CGRect(x: region.minX * w, y: (1 - region.maxY) * h, width: region.width * w, height: region.height * h).integral
        guard rect.width >= 2, rect.height >= 2, let cropped = image.cropping(to: rect) else { return nil }
        var pixels = [UInt8](repeating: 0, count: side * side * 4)
        guard let ctx = CGContext(data: &pixels, width: side, height: side, bitsPerComponent: 8, bytesPerRow: side * 4,
                                  space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        else { return nil }
        ctx.interpolationQuality = .medium
        ctx.draw(cropped, in: CGRect(x: 0, y: 0, width: side, height: side))

        var lum = [Float](repeating: 0, count: side * side)
        var sumR: Float = 0, sumG: Float = 0, sumB: Float = 0, clipped: Float = 0, blown: Float = 0, left: Float = 0, right: Float = 0
        for i in 0..<(side * side) {
            let r = Float(pixels[i * 4]) / 255, g = Float(pixels[i * 4 + 1]) / 255, b = Float(pixels[i * 4 + 2]) / 255
            let y = 0.299 * r + 0.587 * g + 0.114 * b
            lum[i] = y; sumR += r; sumG += g; sumB += b
            if y > 0.96 || y < 0.04 { clipped += 1 }
            if y > 0.96 { blown += 1 }
            if i % side < side / 2 { left += y } else { right += y }
        }
        let n = Float(side * side)
        var lapSum: Float = 0, lapSq: Float = 0
        for y in 1..<(side - 1) {
            for x in 1..<(side - 1) {
                let i = y * side + x
                let l = 4 * lum[i] - lum[i - 1] - lum[i + 1] - lum[i - side] - lum[i + side]
                lapSum += l; lapSq += l * l
            }
        }
        let m = Float((side - 2) * (side - 2))
        let lapMean = lapSum / m
        return (mean: (sumR * 0.299 + sumG * 0.587 + sumB * 0.114) / n, clipped: clipped / n, blown: blown / n,
                left: left / (n / 2), right: right / (n / 2), r: sumR / n, g: sumG / n, b: sumB / n,
                laplacian: lapSq / m - lapMean * lapMean)
    }
}

/// What decided one photo, in the order the scan applies them.
enum EvalGate: String, CaseIterable {
    case noImage, noFace, group, faceTooSmall, otherPeople, notFullBody, noMatch, sensitive
    /// Matched, but its original is over the cap, or could not be read or sized.
    case tooLarge, noOriginal
    /// Passed everything and was shown to the user.
    case grid
    /// Matched under the cut-off, then withdrawn by the gap rule — see `gapCutEnabled`.
    case gapCut
    /// Matched, but the face is unusable for the Muse — see `unusableFaceDrops`.
    case unusableFace
}

/// One photo's fate in one scan.
struct EvalRecord {
    let id: String
    let gate: EvalGate
    let distance: Float?
    let type: PhotoType?
    /// Nil for a photo that never reached the body check.
    let body: BodyCheck?
    let metrics: FaceMetrics?
    /// Face re-cropped from a larger render. Nil for a photo never scored.
    let fullRes: Bool?
    let rotated: Bool
    let screenshot: Bool
    /// In the answer-key album — a photo that *should* reach the grid.
    let labelled: Bool
    /// When it was taken, so it can be found in Photos — the id cannot be
    /// searched for.
    let taken: Date?
    /// The original's own size, from its metadata — nothing is loaded to get it.
    /// Beside `renderWidth`, it says whether a larger crop was even possible.
    let originalSize: String
    /// Width of the render the scan actually worked on.
    let renderWidth: Int?
    /// The original file's size, for a photo that reached the grid.
    let originalBytes: Int?
    /// How well the photo would serve the Muse — matches only. See `MuseScore`.
    let score: MuseScore?
    /// Decided from an earlier scan's record, without loading the photo. See `ScanStore`.
    let fromStore: Bool
}

/// Scores one scan against the answer-key album. A value, not a class, so the
/// scan loop hands a finished copy to the main thread and nothing is shared.
struct ScanEval {

    /// The album's ids. Nil when eval mode is off or the album is missing, which
    /// makes every method below a no-op — so the scan loop needs no `if` of its own.
    let labels: Set<String>?
    private(set) var records: [EvalRecord] = []

    /// What a Muse needs. Mirrors `COVERAGE` in galleryConstants.ts — keep in step.
    static let coverageNeed: [(PhotoType, Int)] = [(.selfie, 1), (.front, 2), (.side, 2)]

    init(labels: Set<String>?) { self.labels = labels }

    /// How a date reads in the printed report — how Photos shows it.
    static let shownDate: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "d MMM yyyy HH:mm"
        return formatter
    }()

    /// How a date sits in the CSV — sortable.
    static let csvDate: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd HH:mm"
        return formatter
    }()

    mutating func note(_ asset: PHAsset, image: UIImage?, rotated: Bool = false, gate: EvalGate,
                       distance: Float? = nil, type: PhotoType? = nil,
                       body: BodyCheck? = nil, metrics: FaceMetrics? = nil,
                       fullRes: Bool? = nil, originalBytes: Int? = nil, score: MuseScore? = nil,
                       fromStore: Bool = false) {
        guard let labels else { return }
        records.append(EvalRecord(
            id: asset.localIdentifier,
            gate: gate,
            distance: distance,
            type: type,
            body: body,
            metrics: metrics,
            fullRes: fullRes,
            rotated: rotated,
            screenshot: asset.mediaSubtypes.contains(.photoScreenshot),
            labelled: labels.contains(asset.localIdentifier),
            taken: asset.creationDate,
            originalSize: "\(asset.pixelWidth)x\(asset.pixelHeight)",
            renderWidth: image?.cgImage?.width,
            originalBytes: originalBytes,
            score: score,
            fromStore: fromStore
        ))
    }

    /// Moves photos already noted as `.grid` to another gate — for the gap rule,
    /// which withdraws matches after the scan has noted them.
    mutating func regate(_ ids: Set<String>, to gate: EvalGate) {
        guard labels != nil else { return }
        records = records.map { r in
            guard r.gate == .grid, ids.contains(r.id) else { return r }
            return EvalRecord(id: r.id, gate: gate, distance: r.distance, type: r.type, body: r.body,
                              metrics: r.metrics, fullRes: r.fullRes, rotated: r.rotated, screenshot: r.screenshot,
                              labelled: r.labelled, taken: r.taken, originalSize: r.originalSize,
                              renderWidth: r.renderWidth, originalBytes: r.originalBytes, score: r.score,
                              fromStore: r.fromStore)
        }
    }

    /// Builds the printed summary and writes the CSV. Nil when eval mode is off.
    /// `grid` is the order the shopper sees, which is what "the top" means.
    func finish(grid: [String]) -> String? {
        guard let labels else { return nil }

        let byId = Dictionary(records.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        let labelledInWindow = records.filter(\.labelled).count
        let outsideWindow = labels.count - labelledInWindow

        // The matcher alone: every photo that reached scoring. Gates are measured
        // separately below.
        let scored = records.filter { $0.distance != nil }
        let correctDistances = scored.filter(\.labelled).compactMap(\.distance)
        let wrongDistances = scored.filter { !$0.labelled }.compactMap(\.distance)
        let auc = Self.auc(correct: correctDistances, wrong: wrongDistances)

        // Split by kind: a close-up selfie is easy, a small full-length face is not,
        // and one number would let the easy half hide the hard one.
        func splitAUC(_ types: Set<PhotoType>) -> (auc: Double?, correct: Int, wrong: Int) {
            let group = scored.filter { $0.type.map(types.contains) ?? false }
            let correct = group.filter(\.labelled).compactMap(\.distance)
            let wrong = group.filter { !$0.labelled }.compactMap(\.distance)
            return (Self.auc(correct: correct, wrong: wrong), correct.count, wrong.count)
        }
        let selfieAUC = splitAUC([.selfie])
        let fullBodyAUC = splitAUC([.front, .side])
        let aucText = { (value: Double?) in value.map { String(format: "%.3f", $0) } ?? "n/a" }

        let top = grid.prefix(ViewController.evalTopN)
        let topCorrect = top.filter { labels.contains($0) }.count
        let gridCorrect = grid.filter { labels.contains($0) }.count

        // Whether the correct photos alone could complete a Muse. Precision can be
        // bought by showing nothing; this is what catches that.
        var have: [PhotoType: Int] = [:]
        for id in grid where labels.contains(id) {
            if let type = byId[id]?.type { have[type, default: 0] += 1 }
        }
        let fillable = Self.coverageNeed.allSatisfy { have[$0.0, default: 0] >= $0.1 }
        let coverage = Self.coverageNeed
            .map { "\($0.0.rawValue) \(have[$0.0, default: 0])/\($0.1)" }
            .joined(separator: ", ")

        // Per gate: what it rightly kept out, and what it wrongly threw away.
        let gates = EvalGate.allCases.filter { $0 != .grid }.map { gate -> String in
            let here = records.filter { $0.gate == gate }
            let lost = here.filter(\.labelled).count
            let name = gate.rawValue.padding(toLength: 14, withPad: " ", startingAt: 0)
            return "  \(name)\(here.count - lost) wrong caught, \(lost) correct lost"
        }.joined(separator: "\n")

        let screenshots = records.filter(\.screenshot)
        let rank = Dictionary(grid.enumerated().map { ($1, $0 + 1) }, uniquingKeysWith: { first, _ in first })
        let csv = writeCSV(rank: rank)

        func ratio(_ part: Int, _ whole: Int) -> String {
            whole == 0 ? "n/a" : String(format: "%.2f", Double(part) / Double(whole))
        }

        // Every photo worth looking at, in terms that find it in Photos: the grid,
        // and each labelled photo that never reached it.
        func where_(_ r: EvalRecord) -> String {
            let taken = r.taken.map(Self.shownDate.string(from:)) ?? "no date"
            return "\(taken)   \(r.originalSize), scanned at \(r.renderWidth.map(String.init) ?? "–")px"
        }
        let gridLines = grid.prefix(ViewController.evalTopN).enumerated().compactMap { index, id -> String? in
            guard let r = byId[id] else { return nil }
            let who = r.labelled ? "YOU" : "no "
            let score = r.distance.map { String(format: "%.3f", $0) } ?? "?"
            let kind = (r.type?.rawValue ?? "?").padding(toLength: 6, withPad: " ", startingAt: 0)
            let bodySays = r.type == .front || r.type == .side || r.type == .threeQuarter
                ? "sh \((r.body?.shoulderSpread.map { String(format: "%.2f", $0) } ?? "?").padding(toLength: 7, withPad: " ", startingAt: 0))"
                : "          "
            return "  tile \(String(index + 1).padding(toLength: 3, withPad: " ", startingAt: 0)) \(who)  \(kind) d \(score)  \(bodySays)  \(r.fullRes == true ? "re-cropped" : "          ")  \(where_(r))"
        }
        // The shoulders decide the type; the head turn is logged beside them to see how
        // often it would have disagreed. Only full-length photos that reached scoring.
        let fullLength = scored.filter { $0.type == .front || $0.type == .side || $0.type == .threeQuarter }
        let typeCompared = fullLength.filter { $0.body?.shoulderSpread != nil }
        let typeDisagree = typeCompared.filter { r in
            r.metrics?.yaw.map { ViewController.headType(yaw: $0) != r.type } ?? false
        }

        let missedLines = records.filter { $0.labelled && $0.gate != .grid }.map { r in
            "  \(r.gate.rawValue.padding(toLength: 13, withPad: " ", startingAt: 0)) \(where_(r))"
        }
        let gridBlock = (["grid        in the order shown"] + gridLines).joined(separator: "\n")
        let missedBlock = missedLines.isEmpty
            ? "missed      none"
            : (["missed      \(missedLines.count) of yours never reached the grid"] + missedLines).joined(separator: "\n")

        return """

        ==============================
        MATCHING EVAL — "\(ViewController.evalAlbumTitle)"
        ==============================
        settings    threshold \(String(format: "%.2f", ViewController.matchThreshold)) (\(String(format: "%.2f", ViewController.profileMatchThreshold)) profile side, \(String(format: "%.2f", ViewController.selfieMatchThreshold)) selfie), face padding \(String(format: "%.2f", ViewController.facePadding)), body span \(String(format: "%.2f", ViewController.minBodySpan)) (\(String(format: "%.2f", ViewController.minBodySpanBothAnkles)) with both ankles), feet room \(String(format: "%.2f", ViewController.minFootRoom))×span, ankles \(ViewController.minAnkles)+; or knees \(ViewController.minKnees)+, knee span \(String(format: "%.2f", ViewController.minKneeSpan)) (\(String(format: "%.2f", ViewController.minKneeSpanBothKnees)) with both), knee drop \(String(format: "%.1f", ViewController.minKneeDrop)); side from \(Int(ViewController.sideTurnDegrees))° (spread under \(String(format: "%.2f", ViewController.sideShoulderSpread)))
        labelled    \(labelledInWindow) in the window\(outsideWindow > 0 ? ", \(outsideWindow) outside it (ignored)" : "")
        AUC         \(aucText(auc))   (matcher only: \(correctDistances.count) correct vs \(wrongDistances.count) wrong, of photos that reached scoring)
          selfies     \(aucText(selfieAUC.auc))   (\(selfieAUC.correct) correct vs \(selfieAUC.wrong) wrong)
          full body   \(aucText(fullBodyAUC.auc))   (\(fullBodyAUC.correct) correct vs \(fullBodyAUC.wrong) wrong — front and side)
        top \(ViewController.evalTopN)      precision \(ratio(topCorrect, top.count))   (\(topCorrect) of \(top.count) correct; grid has \(grid.count))
        recall      \(ratio(gridCorrect, labelledInWindow))   (\(gridCorrect) of \(labelledInWindow) correct photos reached the grid)
        coverage    \(fillable ? "fillable" : "NOT fillable")   (correct photos only: \(coverage))
        in grid     \(gridCorrect) correct, \(grid.count - gridCorrect) wrong
        by gate
        \(gates)
        rotated     \(records.filter(\.rotated).count) photo(s) arrived rotated (turned upright)
        type check  \(typeCompared.count) of \(fullLength.count) full-length photo(s) typed by shoulders (side under \(String(format: "%.2f", ViewController.sideShoulderSpread))), \(fullLength.count - typeCompared.count) by head turn (shoulders not measured); head turn would have differed on \(typeDisagree.count)\(typeDisagree.isEmpty ? "" : " — " + typeDisagree.map { "\($0.type?.rawValue ?? "?") at \(String(format: "%.2f", $0.body?.shoulderSpread ?? 0))" }.joined(separator: "; "))
        full-res    \(records.filter { $0.fullRes == true }.count) of \(scored.count) scored photo(s) re-cropped from a larger render
        screenshots \(screenshots.count) in the window, \(screenshots.filter { $0.gate == .grid }.count) reached the grid
        \(gridBlock)
        \(missedBlock)
        csv         \(csv ?? "not written")
        note        eval mode adds a face-quality pass per photo — compare scan rates with it on both times
        ==============================

        """
    }

    /// The chance a correct photo scores closer than a wrong one, ties counting half:
    /// 0.5 is a coin toss, 1.0 perfect separation.
    static func auc(correct: [Float], wrong: [Float]) -> Double? {
        guard !correct.isEmpty, !wrong.isEmpty else { return nil }
        var wins = 0.0
        for c in correct {
            for w in wrong { wins += c < w ? 1 : (c == w ? 0.5 : 0) }
        }
        return wins / Double(correct.count * wrong.count)
    }

    /// Ids and numbers only, no pixels, into Documents. Pull it off the device with
    /// Xcode > Devices and Simulators > Download Container.
    private func writeCSV(rank: [String: Int]) -> String? {
        guard let dir = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first else { return nil }

        let stamp = DateFormatter()
        stamp.dateFormat = "yyyyMMdd-HHmmss"
        let name = "swan-eval-\(stamp.string(from: Date())).csv"

        let number = { (value: Double?) in value.map { String(format: "%.4f", $0) } ?? "" }
        var lines = ["id,gate,labelled,gridRank,distance,type,joints,ankles,headSeen,span,footRoom,people,shoulders,hips,headSays,faceRatio,yaw,pitch,quality,rotated,screenshot,fullRes,taken,original,renderWidth,originalKB,score,sQuality,sPose,sLight,sSize,sMouth,sEyes,sBrow,sSharp,sFilter,exprSmile,exprJaw,exprBlinkL,exprBlinkR,exprBrow,exprSquint,exprWide,exprTeeth,exprGazeUp,exprGazeDown,exprGazeSide,sunglasses,hat,handOnFace,capped,tilted,smile,wideEyed,lowered,dressy,busy,outfitLabel,fromStore"]
        for record in records {
            // Typed, and in three parts: one literal this long is more than Swift's
            // type-checker will solve in reasonable time.
            let body = record.body
            let identity: [String] = [
                record.id,
                record.gate.rawValue,
                "\(record.labelled)",
                rank[record.id].map(String.init) ?? "",
                number(record.distance.map { Double($0) }),
                record.type?.rawValue ?? "",
            ]
            let bodyFields: [String] = [
                body.map { String($0.lowerJoints) } ?? "",
                body.map { String($0.ankles) } ?? "",
                body.map { String($0.headSeen) } ?? "",
                number(body.map { Double($0.span) }),
                number(body.map { Double($0.footRoom) }),
                body.map { String($0.people) } ?? "",
                number(body?.shoulderSpread.map { Double($0) }),
                number(body?.hipSpread.map { Double($0) }),
                record.metrics?.yaw.map { ViewController.headType(yaw: $0).rawValue } ?? "",
            ]
            let faceFields: [String] = [
                number(record.metrics.map { Double($0.ratio) }),
                number(record.metrics?.yaw),
                number(record.metrics?.pitch),
                number(record.metrics?.quality.map { Double($0) }),
                "\(record.rotated)",
                "\(record.screenshot)",
                record.fullRes.map { String($0) } ?? "",
                record.taken.map(Self.csvDate.string(from:)) ?? "",
                record.originalSize,
                record.renderWidth.map(String.init) ?? "",
                record.originalBytes.map { String($0 / 1024) } ?? "",
            ]
            // The Muse score and its parts, in `MuseScore.weights` order.
            let expr = record.score?.expression
            let hat = record.score?.labels.filter { MuseScore.hatLabels.contains($0.key) }.values.max()
            // In pieces: one literal this long is more than the type-checker will take.
            let parts: [(name: String, value: Float)] = record.score?.parts ?? []
            var scoreParts: [String] = []
            for w in MuseScore.weights {
                let found = parts.first(where: { $0.name == w.name })
                let value: Double? = found.map { Double($0.value) }
                scoreParts.append(number(value))
            }
            func exprNumber(_ pick: (FaceExpression) -> Float) -> String {
                let value: Double? = expr.map { Double(pick($0)) }
                return number(value)
            }
            var exprFields: [String] = []
            exprFields.append(exprNumber { $0.smile })
            exprFields.append(exprNumber { $0.jawOpen })
            exprFields.append(exprNumber { $0.blinkLeft })
            exprFields.append(exprNumber { $0.blinkRight })
            exprFields.append(exprNumber { $0.browUp })
            exprFields.append(exprNumber { $0.squint })
            exprFields.append(exprNumber { $0.eyeWide })
            exprFields.append(exprNumber { $0.teeth })
            exprFields.append(exprNumber { $0.gazeUp })
            exprFields.append(exprNumber { $0.gazeDown })
            exprFields.append(exprNumber { $0.gazeSide })
            let flagFields: [String] = [
                number(record.score?.labels["sunglasses"].map { Double($0) }), number(hat.map { Double($0) }),
                record.score.map { String($0.handOnFace) } ?? "", record.score.map { String($0.capped) } ?? "",
                record.score.map { String($0.tilted) } ?? "", record.score?.smile.rawValue ?? "", record.score.map { String($0.wideEyed) } ?? "", record.score?.lowered.joined(separator: " ") ?? "",
                number(record.score.map { Double($0.outfit.dressy) }), number(record.score.map { Double($0.outfit.busy) }),
                record.score?.outfit.label ?? "",
                String(record.fromStore),
            ]
            let scoreFields: [String] = [number(record.score.map { Double($0.value) })] + scoreParts
                + [record.score?.filter ?? ""] + exprFields + flagFields
            lines.append((identity + bodyFields + faceFields + scoreFields).joined(separator: ","))
        }

        do {
            try lines.joined(separator: "\n")
                .write(to: dir.appendingPathComponent(name), atomically: true, encoding: .utf8)
            return name
        } catch {
            print("\u{1f9ea} eval CSV not written: \(error)")
            return nil
        }
    }
}

/// Carries one answer out of the Task above by reference; the semaphore orders the
/// write before the read, so there is no concurrent access.
private final class SensitivityResult: @unchecked Sendable {
    var value = false
}

// MARK: - Sensitive content
// Best-effort nudity filtering with Apple's on-device classifier; opt-in per device, so usually off.

extension ViewController {

    /// Prints whether the filter will do anything this scan: a scan with no
    /// "sensitive" lines is either a clean library or a filter that never ran.
    func logSensitivityPolicy() {
        let policy = SCSensitivityAnalyzer().analysisPolicy
        print(policy == .disabled
              ? "\u{1f6ab} sensitivity filter: OFF — no entitlement, or Sensitive Content Warning is off in Settings"
              : "\u{1f6ab} sensitivity filter: on (\(policy))")
    }

    /// Whether Apple's classifier says this photo is sensitive. Opt-in per device, so
    /// usually false. Runs last, on matched photos only.
    func isSensitiveContent(_ image: UIImage) -> Bool {
        guard let cgImage = image.cgImage else { return false }

        let analyzer = SCSensitivityAnalyzer()

        // Apple's contract: check the policy and respect it. Analysing anyway is
        // not a supported path — this is a consent mechanism, not a feature flag.
        guard analyzer.analysisPolicy != .disabled else { return false }

        let semaphore = DispatchSemaphore(value: 0)
        let result = SensitivityResult()

        Task {
            defer { semaphore.signal() }
            do {
                result.value = try await analyzer.analyzeImage(cgImage).isSensitive
            } catch {
                // Shown rather than skipped: a failed analysis says nothing about the photo.
                print("\u{26a0}\u{fe0f} Sensitive content analysis failed: \(error)")
            }
        }

        semaphore.wait()
        return result.value
    }
}

// MARK: - Captured photos

/// What the scan worked out about one photo, kept so it need not be worked out twice.
struct ScanAnalysis {
    let type: PhotoType
    let body: BodyCheck
}

/// What pose detection found of one person's body, and the verdict drawn from it,
/// so the scan, the tap and `isFullBody` all read the same rule.
struct BodyCheck {
    /// Knees and ankles seen, 0–4. What the old gate counted, and still what the web
    /// receives as `lowerBodyJoints`.
    let lowerJoints: Int
    let ankles: Int
    /// Any of the nose, eyes or ears.
    let headSeen: Bool
    /// Highest head point to lowest ankle, as a fraction of the image height.
    let span: CGFloat
    /// Lowest ankle to the bottom edge, as a fraction of the image height. Zero with
    /// no ankle seen.
    let footRoom: CGFloat
    /// People Vision's person detector finds in the whole photo, faces or not.
    let people: Int

    /// Knees seen, 0–2, and the head-to-lowest-knee span as a fraction of the image
    /// height — the knee-length rule's own span. See `minKnees`.
    var knees = 0
    var kneeSpan: CGFloat = 0
    /// How far the lowest knee sits below the hips, against the torso (standing ~1,
    /// seated ~0). Nil when not found, treated as standing. See `minKneeDrop`.
    var kneeDrop: CGFloat?

    /// How many of the faces in the photo are the shopper's — above 1 in a mirror
    /// shot, where each reflection also has a body. See `sameShopperFacesMax`.
    var shopperFaces = 1

    /// Someone besides the shopper is in the photo. One rule for the scan gate and
    /// what the web is told as `otherPeople`, so a photo cannot pass one and fail the other.
    var hasOthers: Bool { people > max(1, shopperFaces) }

    /// Shoulder and hip width across the photo against the torso's length: about 0.6
    /// facing the camera, under 0.35 side-on. Nil when the joints were not found.
    let shoulderSpread: CGFloat?
    let hipSpread: CGFloat?

    /// Which way the body faces, by the shoulders. Decides front or side whatever the
    /// head is doing; the head's turn is used only when this is nil.
    var bodyFacing: PhotoType? {
        shoulderSpread.map { $0 < ViewController.sideShoulderSpread ? .side : .front }
    }

    static let none = BodyCheck(lowerJoints: 0, ankles: 0, headSeen: false, span: 0, footRoom: 0, people: 0,
                                shoulderSpread: nil, hipSpread: nil)

    /// Head to toe: head in frame, enough ankles, a body tall enough to be the
    /// subject, and room below the ankles for the feet.
    var isHeadToAnkle: Bool {
        let needed = ankles >= 2 ? ViewController.minBodySpanBothAnkles : ViewController.minBodySpan
        return headSeen && ankles >= ViewController.minAnkles && span >= needed
            && footRoom >= ViewController.minFootRoom * span
    }

    /// Head to knee: the head in frame, enough knees, the figure tall enough, and
    /// the knees below the hips so a seated person does not count. See `minKnees`.
    var isHeadToKnee: Bool {
        let needed = knees >= 2 ? ViewController.minKneeSpanBothKnees : ViewController.minKneeSpan
        return headSeen && knees >= ViewController.minKnees && kneeSpan >= needed
            && (kneeDrop ?? 1) >= ViewController.minKneeDrop
    }

    /// Enough of the body for the Muse: head to toe, or head to knee — see
    /// `minKnees`. The name is what the web receives it as, `isFullBody`, and
    /// what the gate has always been called in the logs.
    var isHeadToToe: Bool { isHeadToAnkle || (ViewController.kneeLengthEnabled && isHeadToKnee) }

    /// In only on the knee rule — counted so the scan summary says how many.
    var byKnees: Bool { ViewController.kneeLengthEnabled && !isHeadToAnkle && isHeadToKnee }
}

/// Analyses produced during the scan, by asset id, so a tap is a lookup that agrees
/// with the scan. Locked: written on the scan's queue, read on the analysis queue.
enum ScanAnalysisStore {
    private static var held: [String: ScanAnalysis] = [:]
    private static let lock = NSLock()

    static func store(_ analysis: ScanAnalysis, id: String) {
        lock.lock(); defer { lock.unlock() }
        held[id] = analysis
    }

    static func analysis(for id: String) -> ScanAnalysis? {
        lock.lock(); defer { lock.unlock() }
        return held[id]
    }

    static func removeAll() {
        lock.lock(); defer { lock.unlock() }
        held.removeAll()
    }
}

/// Photos taken inside the flow, held in memory as `Data` and never written to the
/// photo library; a dozen decoded captures in the web view would crash its process.
enum CaptureStore {

    /// How many photos the flow will hold. Generous for five slots with retakes,
    /// low enough that the store stays a rounding error against the app's budget.
    static let limit = 12

    /// Original capture JPEGs by id. `Data`, never `UIImage`: twelve decoded
    /// captures would be 120MB.
    private static var held: [String: Data] = [:]
    private static var order: [String] = []

    /// Reads and writes arrive on different queues; held only across the dictionary
    /// access, decoding happens outside.
    private static let lock = NSLock()

    /// False when the store is full. Refusing beats evicting a photo that is still
    /// on screen looking selectable.
    static func store(_ data: Data, id: String) -> Bool {
        lock.lock(); defer { lock.unlock() }
        guard held[id] != nil || held.count < limit else { return false }
        if held[id] == nil { order.append(id) }
        held[id] = data
        return true
    }

    static func data(for id: String) -> Data? {
        lock.lock(); defer { lock.unlock() }
        return held[id]
    }

    static func removeAll() {
        lock.lock(); defer { lock.unlock() }
        held.removeAll()
        order.removeAll()
    }

    static var count: Int {
        lock.lock(); defer { lock.unlock() }
        return held.count
    }

    /// The held bytes at a requested size. Returned untouched when nothing needs
    /// shrinking, so the upload path costs no decode; only the grid tile resizes.
    static func render(_ data: Data, maxPixel: CGFloat, quality: CGFloat) -> Data? {
        guard let image = UIImage(data: data) else { return nil }
        let longest = max(image.size.width, image.size.height)
        guard longest > maxPixel else { return data }

        let scale = maxPixel / longest
        let size = CGSize(width: image.size.width * scale, height: image.size.height * scale)

        let format = UIGraphicsImageRendererFormat.default()
        format.scale = 1
        let resized = UIGraphicsImageRenderer(size: size, format: format).image { _ in
            image.draw(in: CGRect(origin: .zero, size: size))
        }
        return resized.jpegData(compressionQuality: quality)
    }
}

// MARK: - Thumbnails

/// Shared by both delivery paths so a photo looks identical however it arrives.
enum Thumbnail {

    /// Grid tiles. Small and fast — dozens are requested at once.
    static let gridPixels: CGFloat = 256
    static let gridQuality: CGFloat = 0.7

    /// A large render, for the `?size=full` display path and for photos taken in the
    /// flow. Library photos are uploaded as their original file — see `Original`.
    static let fullPixels: CGFloat = 1600
    static let fullQuality: CGFloat = 0.85

    /// JPEG bytes for a `PHAsset.localIdentifier` or a `CaptureStore` id. `allowNetwork`
    /// is the iCloud split: grid tiles pass true, full renders never do. Metadata is dropped.
    static func jpeg(for localIdentifier: String,
                     maxPixel: CGFloat,
                     quality: CGFloat,
                     allowNetwork: Bool = false) -> Data? {
        if let held = CaptureStore.data(for: localIdentifier) {
            let rendered = CaptureStore.render(held, maxPixel: maxPixel, quality: quality)
            // Logged for every size: captures are at most a dozen, and one that will
            // not render is this store's most likely failure.
            print(rendered == nil
                  ? "  ❌ capture render FAILED \(localIdentifier) at \(Int(maxPixel))px"
                  : "  🖼 served capture \(localIdentifier) — \(rendered!.count / 1024)KB at \(Int(maxPixel))px")
            return rendered
        }

        guard let asset = PHAsset.fetchAssets(withLocalIdentifiers: [localIdentifier],
                                              options: nil).firstObject else { return nil }

        let options = PHImageRequestOptions()
        options.deliveryMode = .highQualityFormat
        options.resizeMode = .exact
        options.isNetworkAccessAllowed = allowNetwork
        options.isSynchronous = true

        var data: Data?
        PHImageManager.default().requestImage(
            for: asset,
            targetSize: CGSize(width: maxPixel, height: maxPixel),
            // `.aspectFit` at every size: `.aspectFill` cropped portraits, and on a
            // full-length photo that removed the legs from the tile.
            contentMode: .aspectFit,
            options: options
        ) { image, _ in
            data = image?.jpegData(compressionQuality: quality)
        }
        return data
    }
}

/// One streamed read, locked because the caller may time out while chunks still
/// arrive on PhotoKit's queue. Once `done` is set, later chunks are dropped.
private final class ReadState {
    private var collected = Data()
    private var counted = 0
    private var overCap = false
    private var failed = false
    private var done = false
    private let lock = NSLock()

    /// Counts the chunk, keeping it only when `keep` is set. True once past the cap,
    /// so the read can stop there.
    func append(_ chunk: Data, cap: Int, keep: Bool) -> Bool {
        lock.lock(); defer { lock.unlock() }
        guard !done, !overCap else { return overCap }
        counted += chunk.count
        if counted > cap {
            // Dropped rather than kept: past the cap these bytes are never going
            // to be sent, so holding them is pure cost.
            overCap = true
            collected.removeAll(keepingCapacity: false)
            return true
        }
        if keep { collected.append(chunk) }
        return false
    }

    func finish(failed didFail: Bool) {
        lock.lock(); defer { lock.unlock() }
        guard !done else { return }
        done = true
        failed = didFail
        if didFail { collected.removeAll(keepingCapacity: false) }
    }

    func result() -> (data: Data, count: Int, overCap: Bool, failed: Bool) {
        lock.lock(); defer { lock.unlock() }
        return (collected, counted, overCap, failed)
    }
}

/// The photo's own file, as the camera wrote it, via `PHAssetResource`. A photo is
/// sent as its original or not at all.
enum Original {

    /// How much of one file we will carry: at the cap a file is 13.3MB as base64
    /// crossing the bridge. Each half of a Live Photo is measured separately.
    static let byteCap = 10 * 1024 * 1024

    /// How long an upload waits for one file, inside the web layer's own 30s deadline.
    static let readTimeout: DispatchTimeInterval = .seconds(20)

    /// How long the scan waits to size one iCloud-only original. 20 s, as
    /// `cloudTimeout`: at 10 s a matched iCloud photo was hidden as "original too
    /// slow" on a run where every copy took 7 to 10 s.
    static let sizeTimeout: DispatchTimeInterval = .seconds(20)
    /// When sizing an iCloud original still times out (several downloads and a
    /// throttled iCloud), a matched photo is shown rather than hidden if its
    /// pixel count says the original cannot be over the byte cap: under this
    /// many megapixels a camera HEIC or JPEG is a few MB. Only 48MP shots and
    /// ProRAW sit above it, and those are hidden as before. The upload fetches
    /// the original later with its own retry. 30, not 24: a phone's "24MP"
    /// default is 5712x4284, 24.5MP, and sat just over the line.
    static let sizeByPixelsWhenSlow = true
    static let sizeByPixelsMaxMegapixels: Double = 30

    /// Marks the paired video of a Live Photo, appended to the asset id. The two
    /// halves travel as two uploads and the service pairs them by stripping this.
    static let videoSuffix = ".mov"

    /// Why an original cannot be sent. Reported to the web layer, which counts the
    /// photo as failed — there is nothing else to send.
    enum Unavailable: String, Error {
        /// The file is larger than we will carry.
        case tooLarge
        /// No resource, or the read failed — including an iCloud download that
        /// could not complete.
        case unreadable
        /// The read did not finish in time — almost always an iCloud download on
        /// a poor connection.
        case tooSlow
    }

    struct Bytes {
        let data: Data
        /// From the resource's UTI — `image/heic` for most modern photos. The
        /// presigned PUT signs for whatever this says, so it has to be right.
        let mime: String
    }

    /// The resource's bytes, for upload. `allowNetwork` fetches an iCloud-offloaded
    /// original: the handful of photos the shopper picked are worth the download.
    static func bytes(for asset: PHAsset,
                      allowNetwork: Bool,
                      type: PHAssetResourceType = .photo) -> Result<Bytes, Unavailable> {
        read(asset, allowNetwork: allowNetwork, type: type, keep: true, timeout: readTimeout)
            .map { Bytes(data: $0.data, mime: $0.mime) }
    }

    /// The original's size in bytes, counted as it streams and kept nowhere. Stops
    /// the moment it passes the cap.
    static func size(for asset: PHAsset, allowNetwork: Bool) -> Result<Int, Unavailable> {
        read(asset, allowNetwork: allowNetwork, type: .photo, keep: false, timeout: sizeTimeout)
            .map { $0.count }
    }

    /// What the camera wrote about itself, for the v2 selfie gates: whether
    /// there is any camera data at all (`noCameraDataGateEnabled`) and the
    /// 35 mm-equivalent focal length (`tooCloseCm`).
    struct Camera {
        let present: Bool
        let focal35mm: Float?
        /// The lens's own focal length, present on a camera photo that carries
        /// no 35 mm equivalent: the sensor size is unknown, so no distance is
        /// read from it.
        let focalMm: Float?
        /// What the read saw, for the console: size, type, the fields found.
        let detail: String
    }
    /// Read from the phone's copy of the original, with network access off: a
    /// photo whose original is only in iCloud comes back nil, unknown, and is
    /// not judged on its metadata. The whole file, up to `byteCap`: a HEIC cut
    /// short loses its EXIF to ImageIO, and a local file of a few MB reads in
    /// milliseconds. Bounded in time like the other reads.
    static let headerTimeout: DispatchTimeInterval = .seconds(2)

    static func camera(for asset: PHAsset) -> Camera? {
        let resources = PHAssetResource.assetResources(for: asset)
        // The original first (GALLERY_PICK_V2_PLAN.md, item 4): an edit saved by
        // another app can drop the metadata, and an edited photo must not fail
        // the no-camera-data gate for being edited.
        guard let resource = resources.first(where: { $0.type == .photo })
                ?? resources.first(where: { $0.type == .fullSizePhoto }) else { return nil }
        let options = PHAssetResourceRequestOptions()
        options.isNetworkAccessAllowed = false
        let lock = NSLock()
        var head = Data()
        var complete = false
        let done = DispatchSemaphore(value: 0)
        let request = PHAssetResourceManager.default().requestData(
            for: resource, options: options,
            dataReceivedHandler: { chunk in
                lock.lock(); defer { lock.unlock() }
                guard head.count < byteCap else { return }
                head.append(chunk)
                if head.count >= byteCap { done.signal() }
            },
            completionHandler: { error in
                lock.lock(); complete = error == nil; lock.unlock()
                done.signal()
            })
        _ = done.wait(timeout: .now() + headerTimeout)
        PHAssetResourceManager.default().cancelDataRequest(request)
        lock.lock()
        let bytes = head, whole = complete
        lock.unlock()
        let kind = (resource.uniformTypeIdentifier.split(separator: ".").last).map(String.init) ?? "?"
        let size = "\(bytes.count / 1024)KB \(kind)\(whole ? "" : " partial")"
        guard !bytes.isEmpty, let properties = properties(of: bytes, complete: whole) else { return nil }
        let exif = properties[kCGImagePropertyExifDictionary] as? [CFString: Any]
        let tiff = properties[kCGImagePropertyTIFFDictionary] as? [CFString: Any]
        let focal35 = (exif?[kCGImagePropertyExifFocalLenIn35mmFilm] as? NSNumber)?.floatValue
        let model = (tiff?[kCGImagePropertyTIFFModel] as? String) ?? (tiff?[kCGImagePropertyTIFFMake] as? String)
        let focalMm = (exif?[kCGImagePropertyExifFocalLength] as? NSNumber)?.floatValue
        let present = focal35 != nil || focalMm != nil || model != nil
        var found: [String] = []
        if let model { found.append(model) }
        if let focal35 { found.append(String(format: "%.0fmm eq", focal35)) } else if let focalMm { found.append(String(format: "%.1fmm, no 35mm eq", focalMm)) }
        if exif == nil && tiff == nil { found.append("no exif") }
        return Camera(present: present, focal35mm: focal35, focalMm: focalMm, detail: "\(size): \(found.isEmpty ? "nothing" : found.joined(separator: ", "))")
    }

    /// The image properties ImageIO can read from the start of a file. Incremental
    /// first, which is built for partial data; a plain source after it.
    private static func properties(of bytes: Data, complete: Bool) -> [CFString: Any]? {
        let source = CGImageSourceCreateIncremental(nil)
        CGImageSourceUpdateData(source, bytes as CFData, complete)
        if let props = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any] { return props }
        guard let plain = CGImageSourceCreateWithData(bytes as CFData, [kCGImageSourceShouldCache: false] as CFDictionary) else { return nil }
        return CGImageSourceCopyPropertiesAtIndex(plain, 0, nil) as? [CFString: Any]
    }

    /// One streamed read, abandoned the moment the total crosses the cap, since
    /// `PHAssetResource` exposes no size.
    private static func read(_ asset: PHAsset,
                             allowNetwork: Bool,
                             type: PHAssetResourceType,
                             keep: Bool,
                             timeout: DispatchTimeInterval) -> Result<(data: Data, count: Int, mime: String), Unavailable> {
        let resources = PHAssetResource.assetResources(for: asset)
        // `.fullSizePhoto`/`.fullSizePairedVideo` exist once a photo is edited and
        // are what the user sees, so they come first.
        let edited: PHAssetResourceType = type == .photo ? .fullSizePhoto : .fullSizePairedVideo
        guard let resource = resources.first(where: { $0.type == edited })
                ?? resources.first(where: { $0.type == type }) else { return .failure(.unreadable) }

        let options = PHAssetResourceRequestOptions()
        options.isNetworkAccessAllowed = allowNetwork

        let state = ReadState()
        let done = DispatchSemaphore(value: 0)

        let request = PHAssetResourceManager.default().requestData(
            for: resource,
            options: options,
            // Past the cap the waiting thread is woken at once, and cancels.
            dataReceivedHandler: { chunk in
                if state.append(chunk, cap: byteCap, keep: keep) { done.signal() }
            },
            completionHandler: { error in
                state.finish(failed: error != nil)
                done.signal()
            }
        )

        let waited = done.wait(timeout: .now() + timeout)
        let (collected, count, overCap, failed) = state.result()

        if overCap {
            PHAssetResourceManager.default().cancelDataRequest(request)
            state.finish(failed: true)
            return .failure(.tooLarge)
        }
        if waited == .timedOut {
            PHAssetResourceManager.default().cancelDataRequest(request)
            state.finish(failed: true)
            return .failure(.tooSlow)
        }
        // With network access off this is an asset that lives only in iCloud;
        // with it on, a download that did not complete.
        if failed || count == 0 { return .failure(.unreadable) }

        return .success((collected, count, mime(for: resource)))
    }

    /// The resource's UTI as a MIME type. Falls back to JPEG rather than guessing
    /// wrong: a declared type the bytes do not match breaks the presigned PUT.
    static func mime(for resource: PHAssetResource) -> String {
        switch resource.uniformTypeIdentifier.lowercased() {
        case "public.heic", "public.heif": return "image/heic"
        case "public.png": return "image/png"
        case "com.compuserve.gif": return "image/gif"
        case "com.apple.quicktime-movie": return "video/quicktime"
        case "public.mpeg-4": return "video/mp4"
        default: return "image/jpeg"
        }
    }
}

extension ViewController {

    /// Sends one photo to the web layer as a data URI for upload, always the original
    /// file. A Live Photo says so with `hasVideo`; its video is asked for next.
    func sendFullImage(id: String) {
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            func reply(_ payload: [String: Any]) {
                DispatchQueue.main.async {
                    self?.sendToWeb(["type": "onGalleryFullImage", "payload": payload])
                }
            }
            let startedAt = Date()
            func ms() -> Int { Int(Date().timeIntervalSince(startedAt) * 1000) }

            // The paired half of a Live Photo, asked for under the still's id with
            // a suffix. Best effort: a failure here means the still goes up alone.
            let wantsVideo = id.hasSuffix(Original.videoSuffix)
            let assetId = wantsVideo ? String(id.dropLast(Original.videoSuffix.count)) : id

            // A photo taken inside the flow has no asset and no original — it is
            // already a capture at upload size, sent as held.
            if !wantsVideo, CaptureStore.data(for: assetId) != nil {
                guard let data = Thumbnail.jpeg(for: id,
                                                maxPixel: Thumbnail.fullPixels,
                                                quality: Thumbnail.fullQuality) else {
                    print("  \u{274c} capture FAILED \(id)")
                    reply(["id": id, "error": "unavailable"])
                    return
                }
                reply(["id": id, "dataURI": "data:image/jpeg;base64," + data.base64EncodedString(), "original": false])
                return
            }

            guard let asset = PHAsset.fetchAssets(withLocalIdentifiers: [assetId], options: nil).firstObject else {
                print("  \u{274c} no photo for \(assetId)")
                reply(["id": id, "error": "unavailable"])
                return
            }

            if wantsVideo {
                guard asset.mediaSubtypes.contains(.photoLive) else {
                    print("  \u{274c} no paired video for \(assetId)")
                    reply(["id": id, "error": "unavailable"])
                    return
                }
                switch Original.bytes(for: asset, allowNetwork: true, type: .pairedVideo) {
                case .success(let video):
                    print("  \u{1f3ac} paired video \(id) — \(video.data.count / 1024)KB \(video.mime) (\(ms())ms)")
                    reply(["id": id,
                           "dataURI": "data:\(video.mime);base64," + video.data.base64EncodedString(),
                           "original": true])
                case .failure(let reason):
                    print("  \u{2935} paired video \(assetId) — \(reason.rawValue), the still goes alone")
                    reply(["id": id, "error": reason.rawValue])
                }
                return
            }

            let isLive = asset.mediaSubtypes.contains(.photoLive)
            switch Original.bytes(for: asset, allowNetwork: true) {
            case .success(let original):
                print("  \u{1f4e6} original \(id) — \(isLive ? "live" : "still"), \(original.data.count / 1024)KB \(original.mime) (\(ms())ms)")
                reply(["id": id,
                       "dataURI": "data:\(original.mime);base64," + original.data.base64EncodedString(),
                       "original": true,
                       "hasVideo": isLive])
            case .failure(let reason):
                // Not rendered instead: a photo goes as its original or not at all.
                print("  \u{274c} original FAILED \(id) — \(reason.rawValue), not sent (\(ms())ms)")
                reply(["id": id, "error": reason.rawValue])
            }
        }
    }

    /// Reports how the person is positioned in one photo. The web layer requires
    /// both `type` and `isFullBody`; a reply missing either rejects the photo.
    func analysePhoto(id: String) {
        // The scan already worked this out. Answering from the store skips two Vision
        // passes and guarantees the verdict matches the scan's.
        if let cached = ScanAnalysisStore.analysis(for: id) {
            sendAnalysis(id: id, captured: false, body: cached.body, type: cached.type, cached: true)
            return
        }

        DispatchQueue.global(qos: .userInitiated).async { [weak self] in

            guard let self = self else { return }

            // The only PhotoKit part. Everything past it works on a decoded image,
            // which is what lets a photo taken in the flow share the same analysis.
            guard
                let asset = PHAsset.fetchAssets(
                    withLocalIdentifiers: [id],
                    options: nil
                ).firstObject,
                let image = self.loadPhoto(asset: asset)
            else {
                print("❌ analyse FAILED \(id)")

                DispatchQueue.main.async {
                    self.sendToWeb([
                        "type": "onGalleryPhotoAnalysis",
                        "payload": [
                            "assetId": id,
                            "error": "unavailable"
                        ]
                    ])
                }

                return
            }

            self.analyse(image: image, id: id, captured: false)
        }
    }

    /// The analysis itself, off the main thread. `captured` tells the web layer a
    /// photo it just took from one the user picked.
    func analyse(image: UIImage, id: String, captured: Bool) {
        guard let cgImage = image.cgImage else {
            print("❌ analyse FAILED \(id) — no bitmap")
            DispatchQueue.main.async {
                self.sendToWeb([
                    "type": "onGalleryPhotoAnalysis",
                    "payload": ["assetId": id, "captured": captured, "error": "unavailable"]
                ])
            }
            return
        }

        let orientation = Self.cgOrientation(image.imageOrientation)

        // The same face-to-body tie as the scan, so a tapped or captured photo is
        // judged on the body under its own face.
        let face = self.largestFace(in: cgImage, orientation: orientation)
        let body = self.bodyCheck(in: cgImage, orientation: orientation, face: face?.boundingBox)

        // Front / Side classification
        let type = self.classifyPhotoType(in: image, body: body)

        // A captured photo is analysed once, here, and stored so the tap that
        // follows takes the same path as a scanned one.
        if captured { ScanAnalysisStore.store(ScanAnalysis(type: type, body: body), id: id) }

        sendAnalysis(id: id, captured: captured, body: body, type: type, cached: false)
    }

    /// The one place `onGalleryPhotoAnalysis` is built, so a cached verdict and a
    /// freshly computed one cannot describe themselves differently.
    func sendAnalysis(id: String, captured: Bool, body: BodyCheck, type: PhotoType, cached: Bool) {
        // The web layer rejects any photo `isFullBody` reports false for. The same
        // rule as the scan gate, so a photo the scan let through is not refused on tap.
        let isFullBody = body.isHeadToToe

        print("""
        📸 PHOTO ANALYSIS\(captured ? " (captured)" : "")\(cached ? " (cached)" : "")
           ID: \(id)
           TYPE: \(type.rawValue)
           Full Body: \(isFullBody)
           Joints: \(body.lowerJoints)/4, ankles \(body.ankles), head \(body.headSeen), span \(String(format: "%.2f", body.span)), feet room \(String(format: "%.3f", body.footRoom)), people \(body.people)
           Knees: \(body.knees), knee span \(String(format: "%.2f", body.kneeSpan)), knee drop \(body.kneeDrop.map { String(format: "%.2f", $0) } ?? "–")\(body.byKnees ? " — in on the knee rule" : "")
           Shoulders: \(body.shoulderSpread.map { String(format: "%.2f (~%.0f° turn)", $0, Self.turnDegrees(spread: $0)) } ?? "not measured"), hips \(body.hipSpread.map { String(format: "%.2f", $0) } ?? "–") — type by \(body.bodyFacing == nil ? "head turn" : "shoulders")
        """)

        let analysis: [String: Any] = [
            "assetId": id,
            "captured": captured,
            "lowerBodyJoints": body.lowerJoints,
            "isFullBody": isFullBody,
            "kneeUp": body.byKnees,
            // The web refuses the photo on this — the only way a photo from the flow's
            // own camera, which never passes the scan gate, is held to the same rule.
            "otherPeople": body.hasOthers,
            "type": type.rawValue
        ]

        DispatchQueue.main.async {
            self.sendToWeb([
                "type": "onGalleryPhotoAnalysis",
                "payload": analysis
            ])
        }
    }

    /// Takes one photo the user shot in the flow, holds it in memory (see
    /// `CaptureStore`) and analyses it. The reply is the ordinary analysis message.
    func storeCapture(id: String, dataURI: String) {
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self = self else { return }

            func fail(_ reason: String) {
                print("❌ capture FAILED \(id) — \(reason)")
                DispatchQueue.main.async {
                    self.sendToWeb([
                        "type": "onGalleryPhotoAnalysis",
                        "payload": ["assetId": id, "captured": true, "error": reason]
                    ])
                }
            }

            guard !id.isEmpty, let image = Self.image(fromDataURI: dataURI) else {
                fail("unreadable")
                return
            }

            // The bytes as sent, not a re-encode: the web side already captured at
            // upload size and quality, so anything else here loses a generation.
            guard let comma = dataURI.firstIndex(of: ","),
                  let data = Data(base64Encoded: String(dataURI[dataURI.index(after: comma)...])) else {
                fail("unreadable")
                return
            }

            guard CaptureStore.store(data, id: id) else {
                fail("store-full")
                return
            }

            print("📷 stored capture \(id) — \(data.count / 1024)KB, \(CaptureStore.count)/\(CaptureStore.limit) held")
            self.analyse(image: image, id: id, captured: true)
        }
    }


    /// What a photo can be used as. A selfie is a large face with no lower body;
    /// full body is checked first, then classified by yaw.
    func classifyPhotoType(in image: UIImage, body: BodyCheck) -> PhotoType {
        guard let cgImage = image.cgImage else { return .unknown }

        // Landmarks, not just rectangles: the v2 selfie rule reads the eye spacing.
        let faceRequest = VNDetectFaceLandmarksRequest()

        // The image's real orientation: at `.up` a rotated portrait is analysed
        // sideways, no face is found, and the web layer rejects the photo.
        let handler = VNImageRequestHandler(
            cgImage: cgImage,
            orientation: Self.cgOrientation(image.imageOrientation),
            options: [:]
        )
        try? handler.perform([faceRequest])

        guard let face = faceRequest.results?.first else { return .unknown }

        let ratio = Self.faceRatio(boxWidth: face.boundingBox.width, in: cgImage)

        // Yaw is read once and logged on both branches. A selfie is accepted at any
        // angle, but the number tells a head-on reference from a turned one.
        let yaw = face.yaw?.doubleValue

        let eyeSpacing = Self.eyeSpacing(of: face, in: cgImage)
        let turn = yaw.map { String(format: "%.3f", $0) } ?? "n/a"
        print("🔬 FACE \(String(format: "%.2f", ratio)) of frame, eyes \(eyeSpacing.map { String(format: "%.0f", $0) } ?? "?")px, yaw \(turn), joints \(body.lowerJoints)/4, head to toe \(body.isHeadToToe)")

        // The decision itself lives in one place, shared with the scan.
        return Self.photoType(faceRatio: ratio, eyeSpacing: eyeSpacing, yaw: yaw, body: body)
    }

    /// Base64 fallback for one photo the custom scheme could not load. Serial, so a
    /// grid of tiles does not queue the analysis behind blocking PhotoKit requests.
    static let thumbnailQueue = DispatchQueue(label: "co.getswan.gallery.thumbnails")

    func sendThumbnail(for id: String) {
        guard !id.isEmpty else { return }

        Self.thumbnailQueue.async { [weak self] in
            // iCloud allowed: a grid tile is ~20KB and only displayed. The scan never
            // downloads, but a tile the user is looking at is worth fetching.
            guard let data = Thumbnail.jpeg(for: id,
                                            maxPixel: Thumbnail.gridPixels,
                                            quality: Thumbnail.gridQuality,
                                            allowNetwork: true) else {
                print("  \u{274c} thumbnail FAILED  \(id)")
                // Reported, not dropped: the web layer removes the photo on this reply
                // instead of leaving a broken tile.
                DispatchQueue.main.async {
                    self?.sendToWeb(["type": "onGalleryThumbnails",
                                     "payload": ["thumbs": [["id": id, "error": "unavailable"]]]])
                }
                return
            }

            DispatchQueue.main.async {
                // Sent in the same `thumbs` array shape as before, so the web side has
                // one code path whether one arrives or many.
                self?.sendToWeb(["type": "onGalleryThumbnails",
                                 "payload": ["thumbs": [["id": id,
                                                         "dataURI": "data:image/jpeg;base64," + data.base64EncodedString()]]]])
            }
        }
    }

    /// Drops everything held for one run of the flow. Called on GALLERY_RESET and
    /// at the top of every scan, so a second scan inherits nothing from the first.
    func resetScanState() {
        scanGeneration += 1
        scanReportMatches = [:]
        extraReferenceEmbeddings = []
        lastReferenceNote = ""
        lastReferenceFrames = 1
        lastReferenceIndex = 0
        lastReferenceQuality = nil
        referenceEmbedding = nil
        isLimitedAccess = false
        debugCropsSaved = 0
        // Cleared with the reference face: every verdict here was reached against it.
        ScanAnalysisStore.removeAll()
        clearDebugImages()
    }

    /// Removes the debug crops from the previous run, so Documents does not
    /// accumulate files from every scan.
    func clearDebugImages() {
        guard let dir = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first,
              let names = try? FileManager.default.contentsOfDirectory(atPath: dir.path) else { return }

        for name in names where name.hasPrefix("swan-debug-") {
            try? FileManager.default.removeItem(at: dir.appendingPathComponent(name))
        }
    }
}

// MARK: - Custom scheme handler

/// Serves `swan-photo://thumb?id=<percent-encoded localIdentifier>`. The id
/// contains slashes, so it travels as a query parameter.
final class PhotoSchemeHandler: NSObject, WKURLSchemeHandler {

    /// WebKit calls `stop` when a load is cancelled, and messaging a stopped task
    /// crashes the app, so live tasks are tracked.
    private var live = Set<ObjectIdentifier>()
    private let lock = NSLock()

    private func isLive(_ task: WKURLSchemeTask) -> Bool {
        lock.lock(); defer { lock.unlock() }
        return live.contains(ObjectIdentifier(task))
    }

    private func retire(_ task: WKURLSchemeTask) {
        lock.lock(); defer { lock.unlock() }
        live.remove(ObjectIdentifier(task))
    }

    func webView(_ webView: WKWebView, start task: WKURLSchemeTask) {
        lock.lock(); live.insert(ObjectIdentifier(task)); lock.unlock()

        guard let url = task.request.url,
              let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
              let id = components.queryItems?.first(where: { $0.name == "id" })?.value else {
            finish(task, with: nil)
            return
        }

        // ?size=full is the large display render; anything else is a grid tile.
        let wantsFull = components.queryItems?
            .first(where: { $0.name == "size" })?.value == "full"

        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let startedAt = Date()
            // Same split as the base64 fallback: a grid tile may be fetched from
            // iCloud, a full-size render may not.
            let data = Thumbnail.jpeg(
                for: id,
                maxPixel: wantsFull ? Thumbnail.fullPixels : Thumbnail.gridPixels,
                quality: wantsFull ? Thumbnail.fullQuality : Thumbnail.gridQuality,
                allowNetwork: !wantsFull
            )
            let ms = Int(Date().timeIntervalSince(startedAt) * 1000)

            if wantsFull {
                // Only logged for full renders — grid tiles arrive by the dozen and
                // would drown everything else.
                print(data == nil
                      ? "  \u{274c} serve FAILED  \(id)  (\(ms)ms)"
                      : "  \u{2705} served \(data!.count / 1024)KB  \(id)  (\(ms)ms)")
            }

            DispatchQueue.main.async { self?.finish(task, with: data, url: url) }
        }
    }

    func webView(_ webView: WKWebView, stop task: WKURLSchemeTask) {
        retire(task)
    }

    private func finish(_ task: WKURLSchemeTask, with data: Data?, url: URL? = nil) {
        guard isLive(task) else { return }
        retire(task)

        guard let data = data, let url = url ?? task.request.url else {
            task.didFailWithError(URLError(.fileDoesNotExist))
            return
        }

        // Access-Control-Allow-Origin: the page is https and this is another origin.
        let response = HTTPURLResponse(
            url: url,
            statusCode: 200,
            httpVersion: "HTTP/1.1",
            headerFields: ["Content-Type": "image/jpeg",
                           "Content-Length": "\(data.count)",
                           "Access-Control-Allow-Origin": "*",
                           "Cache-Control": "max-age=300"]
        )!

        task.didReceive(response)
        task.didReceive(data)
        task.didFinish()
    }
}

// MARK: - Debug image dump

extension ViewController {

    /// Saves a PNG into Documents; pull it off the device with Xcode > Devices and
    /// Simulators > Download Container.
    func saveDebugImage(_ image: UIImage, name: String) {
        guard debugDumpCrops,
              let data = image.pngData(),
              let dir = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first
        else { return }
        let url = dir.appendingPathComponent("swan-debug-\(name).png")
        try? data.write(to: url)
    }

    /// EXIF orientation as a readable name. Anything other than `up` means face boxes
    /// and crops are in different spaces.
    static func orientationName(_ o: UIImage.Orientation) -> String {
        switch o {
        case .up: return "up"
        case .down: return "down"
        case .left: return "left"
        case .right: return "right"
        case .upMirrored: return "upMirror"
        case .downMirrored: return "downMirror"
        case .leftMirrored: return "leftMirror"
        case .rightMirrored: return "rightMirror"
        @unknown default: return "?"
        }
    }
}

// MARK: - Vision helpers

extension ViewController {

    /// See `saveReferenceFrames`. Frames go to Documents/selfie-frames/frame-N.jpg,
    /// in the order the page sent them (the tapped frame first).
    static func saveFrames(_ frames: [UIImage]) {
        guard let documents = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first else { return }
        let folder = documents.appendingPathComponent("selfie-frames", isDirectory: true)
        try? FileManager.default.removeItem(at: folder)
        do {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            for (i, frame) in frames.enumerated() {
                guard let data = frame.jpegData(compressionQuality: 0.95) else { continue }
                try data.write(to: folder.appendingPathComponent("frame-\(i + 1).jpg"))
            }
            print("🗂️ \(frames.count) selfie frame(s) saved to Files → On My iPhone → photoApp → selfie-frames")
        } catch {
            print("🗂️ Could not save selfie frames: \(error.localizedDescription)")
        }
    }

    /// Decodes a `data:image/jpeg;base64,...` string.
    static func image(fromDataURI uri: String) -> UIImage? {
        guard let comma = uri.firstIndex(of: ","),
              let data = Data(base64Encoded: String(uri[uri.index(after: comma)...]))
        else { return nil }
        return UIImage(data: data).map(upright)
    }

    /// The photo redrawn so its pixels are the right way up: Vision returns boxes
    /// for the upright picture while `crop` cuts raw pixels. After this all is `.up`.
    nonisolated static func upright(_ image: UIImage) -> UIImage {
        guard image.imageOrientation != .up else { return image }
        let format = UIGraphicsImageRendererFormat.default()
        format.scale = image.scale
        return UIGraphicsImageRenderer(size: image.size, format: format).image { _ in
            image.draw(in: CGRect(origin: .zero, size: image.size))
        }
    }

    /// Render size for every photo in the scan. `minFacePixels` is expressed in
    /// these pixels, so the two must be changed together.
    /// Render size for every photo in the scan. `minFacePixels` is expressed in
    /// these pixels, so the two must be changed together.
    static let loadPixels: CGFloat = 1536

    /// A face narrower than this, in the scan's render, is embedded from a larger
    /// render, where the landmarks align better. In practice full-length photos.
    static let fullResFaceBelow: CGFloat = 224

    /// The size of that second render. Capped rather than the whole original: a 48MP
    /// photo decoded in full is about 190MB, and this happens in the middle of a scan.
    static let fullResPixels: CGFloat = 4096

    /// Loads a photo at `loadPixels`, network off. For an iCloud-only photo a second
    /// request takes the phone's smaller copy, unless under `minLocalCopyPixels`.
    /// Loads a photo big enough to crop a usable face from, at `loadPixels`.
    ///
    /// `.highQualityFormat` and `.exact` matter: `.fastFormat`/`.fast` hand back
    /// whatever is cached, often a tiny thumbnail, and the face model then reads
    /// blur rather than a face. Network stays off — this flow never downloads
    /// from iCloud.
    ///
    /// When the full photo is only in iCloud, the first request answers nil. The
    /// phone usually still holds a smaller copy — "Optimise iPhone Storage" keeps a
    /// screen-sized one — and a second, opportunistic request hands that back. One
    /// library was a quarter iCloud-only, and every one of those photos was
    /// skipped; the local copy is plenty for a selfie's face. A copy under
    /// `minLocalCopyPixels` is refused, so a real thumbnail still counts as `noImage`,
    /// and `lastLoadNote` says which of these happened.
    /// What one `loadPhoto` found, as a value, so a photo can be decoded on another
    /// queue (see `decodeAhead`) and its outcome applied on the scan queue.
    struct LoadResult {
        var image: UIImage?
        var note = ""
        var rotated = false
        var localCopy = false
        var thumbnail: UIImage?
        /// Came down from iCloud in this scan, so a bigger copy must come the same way.
        var fromCloud = false
        /// Why an iCloud fetch returned nothing: `diskFull` (Photos refuses to
        /// download when the phone is nearly out of space), `timedOut`, or
        /// `other`. Counted per scan so analytics can tell a full phone from a
        /// slow line.
        var cloudFailure: String?
    }
    final class LoadBox { var result: LoadResult? }

    func applyLoad(_ loaded: LoadResult?) {
        lastLoadNote = loaded?.note ?? ""
        lastLoadRotated = loaded?.rotated ?? false
        lastLoadLocalCopy = loaded?.localCopy ?? false
        lastLoadFromCloud = loaded?.fromCloud ?? false
        lastLoadThumbnail = loaded?.thumbnail
    }

    func loadPhoto(asset: PHAsset, pixels: CGFloat = ViewController.loadPixels) -> UIImage? {
        let loaded = loadPhotoResult(asset: asset, pixels: pixels)
        applyLoad(loaded)
        return loaded.image
    }

    /// The load itself, touching no state on the controller.
    func loadPhotoResult(asset: PHAsset, pixels: CGFloat = ViewController.loadPixels) -> LoadResult {
        var out = LoadResult()
        let options = PHImageRequestOptions()
        options.deliveryMode = .highQualityFormat
        options.resizeMode = .exact
        options.isNetworkAccessAllowed = false
        options.isSynchronous = true

        // 2048, not 1024: a full-body photo has a small face by construction,
        // and more source pixels buy more accuracy than any threshold change.
        let target = CGSize(width: pixels, height: pixels)
        var result: UIImage?
        var inCloud = false
        PHImageManager.default().requestImage(for: asset, targetSize: target, contentMode: .aspectFit, options: options) { image, info in
            result = image
            inCloud = info?[PHImageResultIsInCloudKey] as? Bool ?? false
        }

        if result == nil {
            out.note = inCloud ? "in iCloud, no copy on the phone" : "not flagged as iCloud"
        }
        if result == nil && inCloud {
            // The phone's copy is asked for in `.opportunistic`; it may answer more
            // than once, the largest is kept, and the wait is bounded by `localCopyWait`.
            let local = PHImageRequestOptions()
            local.deliveryMode = .opportunistic
            local.resizeMode = .exact
            local.isNetworkAccessAllowed = false
            local.isSynchronous = false
            let done = DispatchSemaphore(value: 0)
            var best: UIImage?
            PHImageManager.default().requestImage(for: asset, targetSize: target, contentMode: .aspectFit, options: local) { image, info in
                if let image, let cg = image.cgImage,
                   max(cg.width, cg.height) > (best?.cgImage.map { max($0.width, $0.height) } ?? 0) {
                    best = image
                }
                let degraded = info?[PHImageResultIsDegradedKey] as? Bool ?? false
                let cancelled = info?[PHImageCancelledKey] as? Bool ?? false
                let failed = info?[PHImageErrorKey] != nil
                // The degraded answer is followed by another; anything else is final.
                if !degraded || cancelled || failed { done.signal() }
            }
            _ = done.wait(timeout: .now() + Self.localCopyWait)

            if let best, let cg = best.cgImage {
                let longest = max(cg.width, cg.height)
                if longest >= Self.minLocalCopyPixels {
                    result = best
                    out.localCopy = true
                } else {
                    out.note = "in iCloud, phone copy only \(longest)px — under \(Self.minLocalCopyPixels)"
                    out.thumbnail = best
                }
            }
        }

        out.rotated = result.map { $0.imageOrientation != .up } ?? false
        out.image = result.map(Self.upright)
        return out
    }

    /// Downloads a reduced copy of a photo whose full version is in iCloud. Only
    /// the iCloud pass calls this; asynchronous so the wait can be bounded.
    func loadFromCloud(asset: PHAsset, pixels: CGFloat, timeout: DispatchTimeInterval) -> UIImage? {
        let loaded = loadFromCloudResult(asset: asset, pixels: pixels, timeout: timeout)
        applyLoad(loaded)
        return loaded.image
    }

    /// The download itself, touching no state on the controller, so it can run on a
    /// download queue while the scan goes on.
    func loadFromCloudResult(asset: PHAsset, pixels: CGFloat, timeout: DispatchTimeInterval) -> LoadResult {
        var out = LoadResult()
        let options = PHImageRequestOptions()
        options.deliveryMode = .highQualityFormat
        options.resizeMode = .exact
        options.isNetworkAccessAllowed = true
        options.isSynchronous = false

        let done = DispatchSemaphore(value: 0)
        var result: UIImage?
        var error: NSError?
        let request = PHImageManager.default().requestImage(for: asset, targetSize: CGSize(width: pixels, height: pixels),
                                                            contentMode: .aspectFit, options: options) { image, info in
            // High quality delivers once, when it is final.
            if info?[PHImageResultIsDegradedKey] as? Bool != true {
                result = image
                error = info?[PHImageErrorKey] as? NSError
                done.signal()
            }
        }
        if done.wait(timeout: .now() + timeout) == .timedOut {
            PHImageManager.default().cancelImageRequest(request)
            out.note = "iCloud download timed out"
            out.cloudFailure = "timedOut"
            return out
        }
        if result == nil {
            // Photos reports a nearly full phone as CloudPhotoLibraryErrorDomain
            // 1005, "Disk space is very low": it will not download anything until
            // space is freed, and no retry of ours helps.
            let diskFull = error.map { $0.domain == "CloudPhotoLibraryErrorDomain" && $0.code == 1005 } ?? false
            out.cloudFailure = diskFull ? "diskFull" : "other"
            out.note = "iCloud download failed" + (error.map { " — \(diskFull ? "disk space very low" : $0.localizedDescription) (\($0.domain) \($0.code))" } ?? "")
        }
        out.rotated = result.map { $0.imageOrientation != .up } ?? false
        out.image = result.map(Self.upright)
        out.fromCloud = true
        return out
    }

    /// Whether a thumbnail shows one face filling the frame, the shape of a selfie,
    /// by the same rules as the real selfie gate (`bystanderRatio`, `selfieFaceRatio`).
    func isSelfieShaped(_ image: UIImage) -> Bool {
        guard let cgImage = image.cgImage else { return false }
        let request = VNDetectFaceRectanglesRequest()
        try? VNImageRequestHandler(cgImage: cgImage, orientation: Self.cgOrientation(image.imageOrientation), options: [:])
            .perform([request])
        guard let faces = request.results, !faces.isEmpty else { return false }
        let mainWidth = faces.map(\.boundingBox.width).max() ?? 0
        let company = faces.filter { $0.boundingBox.width >= mainWidth * Self.bystanderRatio }
        return company.count == 1 && Self.faceRatio(boxWidth: mainWidth, in: cgImage) >= Self.selfieFaceRatio
    }

    /// Whether a thumbnail shows one person standing tall in the frame, the shape of a
    /// full-length photo. Whose body it is, the download and the face match decide.
    func isFullLengthShaped(_ image: UIImage) -> Bool {
        guard let cgImage = image.cgImage else { return false }
        let request = VNDetectHumanRectanglesRequest()
        request.upperBodyOnly = false
        try? VNImageRequestHandler(cgImage: cgImage, orientation: Self.cgOrientation(image.imageOrientation), options: [:])
            .perform([request])
        guard let people = request.results, !people.isEmpty else { return false }
        let tallest = people.map(\.boundingBox.height).max() ?? 0
        let company = people.filter { $0.boundingBox.height >= tallest * Self.bystanderRatio }
        return company.count == 1 && tallest >= Self.cloudPersonHeight
    }

    /// Second look at a candidate on its small copy before the full download: at
    /// most one face, and the same shape test as the thumbnail, now with pixels
    /// enough to tell a group from one person.
    func cloudPreviewPasses(_ image: UIImage, kind: String) -> (passes: Bool, note: String, faceRatio: CGFloat) {
        guard let cgImage = image.cgImage else { return (false, "unreadable", 0) }
        let faces = VNDetectFaceRectanglesRequest()
        try? VNImageRequestHandler(cgImage: cgImage, orientation: Self.cgOrientation(image.imageOrientation), options: [:])
            .perform([faces])
        let faceCount = faces.results?.count ?? 0
        let faceRatio = faces.results?.map(\.boundingBox.width).max() ?? 0
        guard faceCount <= 1 else { return (false, "\(faceCount) faces", faceRatio) }
        let shaped = kind == "selfie" ? isSelfieShaped(image) : isFullLengthShaped(image)
        return (shaped, shaped ? "\(faceCount) face" : "\(faceCount) face, not one standing person", faceRatio)
    }

    /// The largest face Vision finds, or nil.
    func largestFace(in cgImage: CGImage, orientation: CGImagePropertyOrientation) -> VNFaceObservation? {
        let request = VNDetectFaceRectanglesRequest()
        try? VNImageRequestHandler(cgImage: cgImage, orientation: orientation, options: [:]).perform([request])
        return request.results?.max {
            $0.boundingBox.width * $0.boundingBox.height < $1.boundingBox.width * $1.boundingBox.height
        }
    }

    /// Why a selfie cannot be the reference, or nil when it can. Faces under
    /// `bystanderRatio` of the largest are ignored, as in the scan.
    func selfieRejection(in image: UIImage) -> (error: String, note: String)? {
        guard let cgImage = image.cgImage else { return nil }

        let request = VNDetectFaceRectanglesRequest()
        let handler = VNImageRequestHandler(
            cgImage: cgImage,
            orientation: Self.cgOrientation(image.imageOrientation),
            options: [:]
        )
        try? handler.perform([request])

        let faces = request.results ?? []
        guard let main = faces.max(by: { $0.boundingBox.width < $1.boundingBox.width }) else { return nil }

        let others = faces.filter { $0 !== main && $0.boundingBox.width >= main.boundingBox.width * Self.bystanderRatio }
        if !others.isEmpty {
            return ("several-faces-in-selfie", "\(others.count + 1) faces in frame")
        }

        let degrees = { (angle: NSNumber?) -> Double? in angle.map { abs($0.doubleValue) * 180 / .pi } }
        if let yaw = degrees(main.yaw), yaw > Self.selfieMaxYawDegrees {
            return ("selfie-not-frontal", String(format: "head turned, yaw %.0f° (limit %.0f°)", yaw, Self.selfieMaxYawDegrees))
        }
        if let pitch = degrees(main.pitch), pitch > Self.selfieMaxPitchDegrees {
            return ("selfie-not-frontal", String(format: "head tilted, pitch %.0f° (limit %.0f°)", pitch, Self.selfieMaxPitchDegrees))
        }
        return nil
    }

    func croppedFace(from image: UIImage, padding: CGFloat = ViewController.facePadding) -> UIImage? {
        guard let cgImage = image.cgImage else { return nil }

        let request = VNDetectFaceRectanglesRequest()
        let handler = VNImageRequestHandler(
            cgImage: cgImage,
            orientation: Self.cgOrientation(image.imageOrientation),
            options: [:]
        )
        try? handler.perform([request])

        guard let face = request.results?.max(by: {
            $0.boundingBox.width * $0.boundingBox.height < $1.boundingBox.width * $1.boundingBox.height
        }), let cropped = crop(cgImage, to: face.boundingBox, padding: padding) else { return nil }

        return UIImage(cgImage: cropped)
    }

    /// Why a photo did or did not produce a score. An enum, since the outcomes are
    /// mutually exclusive and each needs its own tally.
    enum PhotoOutcome {
        case noFace
        case group(faceCount: Int)
        case faceTooSmall(pixels: Int)
        case otherPeople(body: BodyCheck)
        case notFullBody(body: BodyCheck)
        /// `profile`: a side with the face turned away, matched against
        /// `profileMatchThreshold` instead of `matchThreshold`.
        case scored(distances: [Float], facePixels: Int, body: BodyCheck, type: PhotoType, profile: Bool, museScore: MuseScore?)
    }

    /// What the Muse score needs for one matched photo: expression and labels from the
    /// head crop, a hand over the face, and the outfit. Well under 100ms together.
    func museContext(face: VNFaceObservation, in image: CGImage, handler: VNImageRequestHandler, readCover: Bool = false)
        -> (expression: FaceExpression?, labels: [String: Float], handOnFace: Bool, outfit: MuseScore.Outfit, coverReader: (() -> FaceCover?)?,
            document: MuseScore.DocumentRead?) {
        let head = MuseScore.headBox(face.boundingBox)
        let w = CGFloat(image.width), h = CGFloat(image.height)
        let headRect = CGRect(x: head.minX * w, y: (1 - head.maxY) * h, width: head.width * w, height: head.height * h).integral
        let headCrop = image.cropping(to: headRect)

        var labels: [String: Float] = [:]
        var expression: FaceExpression?
        let expressionGroup = DispatchGroup()
        var expressionResult: FaceExpression?
        var expressionMs = 0.0
        // What covers the face — see `FaceCover`. Selfies only, on the same
        // head crop with Vision's face box placed inside it. Handed to the
        // score as a closure so it runs only when no cheaper gate has already
        // dropped the photo: at about 200 ms a read it was most of the score's
        // time on a library of test selfies.
        var coverReader: (() -> FaceCover?)?
        if readCover, let headCrop {
            let faceRect = CGRect(x: face.boundingBox.minX * w, y: (1 - face.boundingBox.maxY) * h,
                                  width: face.boundingBox.width * w, height: face.boundingBox.height * h)
                .offsetBy(dx: -headRect.minX, dy: -headRect.minY)
            coverReader = { [self] in timed("score.cover") { FaceCover.read(headCrop: headCrop, face: faceRect) } }
        }
        if let headCrop {
            let classify = VNClassifyImageRequest()
            timed("score.labels") { try? VNImageRequestHandler(cgImage: headCrop, orientation: .up, options: [:]).perform([classify]) }
            for result in classify.results ?? [] where result.confidence >= 0.1 {
                let name = result.identifier
                if name == "sunglasses" || name == "eyeglasses" || MuseScore.hatLabels.contains(name) || MuseScore.coverLabels.contains(name) { labels[name] = result.confidence }
            }
            if Self.scoreInParallel {
                // MediaPipe on the CPU while Vision takes the Neural Engine: the two
                // overlap instead of queueing — see `scoreInParallel`.
                expressionGroup.enter()
                DispatchQueue.global(qos: .userInitiated).async {
                    let started = Date()
                    expressionResult = FaceExpression.read(headCrop: headCrop)
                    expressionMs = Date().timeIntervalSince(started) * 1000
                    expressionGroup.leave()
                }
            } else {
                expression = timed("score.expression") { FaceExpression.read(headCrop: headCrop) }
            }
        }

        // Hands anywhere in the render; one with most of its points on the face
        // is over it. Skin-coloured, so no colour check would see it.
        let hands = VNDetectHumanHandPoseRequest()
        hands.maximumHandCount = 2
        var zone = face.boundingBox.insetBy(dx: -face.boundingBox.width * 0.15, dy: -face.boundingBox.height * 0.15)
        timed("score.hands") {
            if Self.handsOnHeadCrop, let (crop, zoneInCrop) = FaceRecognizer.crop(image, around: zone, scale: Self.handsCropScale) {
                try? VNImageRequestHandler(cgImage: crop, orientation: .up, options: [:]).perform([hands])
                zone = zoneInCrop
            } else {
                try? handler.perform([hands])
            }
        }
        let handOnFace = (hands.results ?? []).contains { hand in
            guard let points = try? hand.recognizedPoints(.all) else { return false }
            return points.values.filter { $0.confidence > 0.3 && zone.contains($0.location) }.count >= MuseScore.handPointsOnFace
        }

        // The outfit (see `MuseScore.outfitMultiplier`): formal-wear labels over the
        // whole render, busyness from the clothing below the face.
        let whole = VNClassifyImageRequest()
        timed("score.outfit") { try? handler.perform([whole]) }
        var dressy: Float = 0
        var dressyLabel: String?
        for result in whole.results ?? [] where MuseScore.dressyLabels.contains(result.identifier) && result.confidence > dressy {
            dressy = result.confidence
            dressyLabel = result.identifier
        }
        let box = face.boundingBox
        let torso = CGRect(x: box.midX - box.width * 1.5, y: box.minY - box.height * 3, width: box.width * 3, height: box.height * 2.8)
            .intersection(CGRect(x: 0, y: 0, width: 1, height: 1))
        let torsoRect = CGRect(x: torso.minX * w, y: (1 - torso.maxY) * h, width: torso.width * w, height: torso.height * h).integral
        var busy: Float = 0
        if torsoRect.width > 8, torsoRect.height > 8, let torsoCrop = image.cropping(to: torsoRect) {
            busy = timed("score.busy") { MuseScore.busyness(of: torsoCrop) }
        }
        // Document facts — see `documentReadEnabled`: the classifier's top
        // labels over the whole photo (already computed above) and how much of
        // the frame Vision's text detector covers.
        var document: MuseScore.DocumentRead?
        if Self.documentReadEnabled {
            let scene = (whole.results ?? []).prefix(4).map { (label: $0.identifier, confidence: $0.confidence) }
            let docLabels = (whole.results ?? []).filter { Self.documentLabels.contains($0.identifier) && $0.confidence >= 0.01 }
                .map { (label: $0.identifier, confidence: $0.confidence) }
            let text = VNDetectTextRectanglesRequest()
            let page = VNDetectDocumentSegmentationRequest()
            timed("score.text") { try? handler.perform([text, page]) }
            let boxes = text.results ?? []
            let area = boxes.reduce(Float(0)) { $0 + Float($1.boundingBox.width * $1.boundingBox.height) }
            let found = page.results?.first
            let pageBox = found?.boundingBox ?? .zero
            document = MuseScore.DocumentRead(scene: scene, textBoxes: boxes.count, textArea: min(area, 1),
                                              docConfidence: found?.confidence ?? 0,
                                              docArea: Float(pageBox.width * pageBox.height),
                                              faceInDoc: pageBox.contains(CGPoint(x: face.boundingBox.midX, y: face.boundingBox.midY)),
                                              docLabels: docLabels)
        }
        if Self.scoreInParallel {
            expressionGroup.wait()
            expression = expressionResult
            stageMs["score.expression", default: 0] += expressionMs
        }
        var outfit = MuseScore.Outfit(label: dressyLabel, dressy: dressy, busy: busy)
        let capLabels = Set(Self.garmentCaps.flatMap { $0.labels })
        outfit.garments = (whole.results ?? []).filter { capLabels.contains($0.identifier) && $0.confidence > 0.1 }
            .map { (label: $0.identifier, confidence: $0.confidence) }
        if Self.fullLengthLabelLog {
            outfit.labels = (whole.results ?? []).filter { $0.confidence >= Self.fullLengthLabelFloor }
                .map { (label: $0.identifier, confidence: $0.confidence) }
        }
        return (expression, labels, handOnFace, outfit, coverReader, document)
    }

    func matchPerson(in image: UIImage, asset: PHAsset) -> PhotoOutcome {
        lastFaceMetrics = nil
        lastCropFullRes = false
        // Cleared first, not after the body check: a photo that leaves early — no
        // face, a group — must not carry the previous photo's retry into the log.
        lastBodyRetry = nil
        lastEarlyNoMatch = false
        lastEmbeddings = []
        guard let reference = referenceEmbedding, let recognizer = Self.faceRecognizer,
              let cgImage = image.cgImage else { return .noFace }

        let request = VNDetectFaceRectanglesRequest()
        let handler = VNImageRequestHandler(
            cgImage: cgImage,
            orientation: Self.cgOrientation(image.imageOrientation),
            options: [:]
        )
        timed("detect") { try? handler.perform([request]) }

        guard let allFaces = request.results, !allFaces.isEmpty else { return .noFace }

        // Faces too small beside the largest are bystanders (see `bystanderRatio`):
        // they neither reject the photo nor get a turn at matching.
        let mainFaceWidth = allFaces.map(\.boundingBox.width).max() ?? 0
        // Largest first: the body check and the type read the first face, and with
        // several faces of the shopper the largest is the one the photo is of.
        let faces = allFaces.filter { $0.boundingBox.width >= mainFaceWidth * Self.bystanderRatio }
            .sorted { $0.boundingBox.width > $1.boundingBox.width }

        // Several faces are a group unless every one is the shopper, a mirror shot.
        // Checked largest first and stopped at the first miss.
        lastShopperFaces = 1
        if Self.requireSingleFace && faces.count > 1 {
            guard faces.count <= Self.sameShopperFacesMax else { return .group(faceCount: faces.count) }
            // With a store, every face's vector is wanted whatever the verdict,
            // so the next scan can judge the group against a new selfie without
            // loading the photo; without one the first miss ends the loop.
            var vectors: [[Float]] = []
            var allMatch = true
            for face in faces {
                guard let candidate = timed("group", { recognizer.embedding(in: cgImage, near: face.boundingBox, seed: face) }) else {
                    allMatch = false
                    break
                }
                vectors.append(candidate)
                if FaceRecognizer.distance(reference, candidate) >= Self.matchThreshold {
                    allMatch = false
                    if scanStore == nil { break }
                }
            }
            lastEmbeddings = vectors.count == faces.count ? vectors : []
            guard allMatch else { return .group(faceCount: faces.count) }
            lastShopperFaces = faces.count
        }

        // Vision boxes are normalised, so this is the face's width in real pixels of
        // the render we loaded.
        let widest = faces.map { $0.boundingBox.width * CGFloat(cgImage.width) }.max() ?? 0

        // Recorded for `ScanEval`, not used by any gate yet: which of these separate
        // good matches from bad is what the evaluation is there to find out.
        if Self.evalMode, let face = faces.first {
            lastFaceMetrics = FaceMetrics(face, handler: handler)
        }

        // A larger render of the same photo, loaded at most once and only if asked
        // for. Network off, so nil when no larger copy is on the phone.
        var largerLoaded = false
        var largerCache: CGImage?
        func largerRender() -> CGImage? {
            if !largerLoaded {
                largerLoaded = true
                // `loadPhotoResult`, not `loadPhoto`: the latter rewrites
                // `lastLoadFromCloud`, and for an iCloud photo with no copy on the
                // phone it set it false, so the fetch below never ran.
                largerCache = loadPhotoResult(asset: asset, pixels: Self.fullResPixels).image?.cgImage
                    .flatMap { $0.width > cgImage.width ? $0 : nil }
                // A photo that came from iCloud has no bigger copy on the phone. Fetch
                // one just large enough for the face floor, not the full original.
                if largerCache == nil, lastLoadFromCloud, Self.cloudDownloadsAllowed {
                    let ratio = faces.map(\.boundingBox.width).max() ?? 0
                    let needed = min(Self.fullResPixels, max(Self.loadPixels * 1.5, Self.minFacePixels / max(ratio, 0.01) * 1.25))
                    let began = Date()
                    let fetched = loadFromCloudResult(asset: asset, pixels: needed, timeout: Self.cloudTimeoutNow)
                    largerCache = fetched.image?.cgImage.flatMap { $0.width > cgImage.width ? $0 : nil }
                    if largerCache != nil { cloudLargerDownloads += 1 }
                    if Self.verboseLogging {
                        let got = fetched.image?.cgImage.map { "\($0.width)x\($0.height)" } ?? "nothing (\(fetched.note))"
                        print("  ☁️  bigger copy for a \(Int(widest))px face: asked \(Int(needed))px, got \(got) in \(String(format: "%.1f", Date().timeIntervalSince(began)))s\(largerCache == nil ? " — not bigger than \(cgImage.width)px, decided on this copy" : "")")
                    }
                }
            }
            return largerCache
        }

        // The larger render is loaded only when the original is big enough to clear
        // the floor, so a photo small in every copy costs nothing extra.
        let widestRatio = faces.map(\.boundingBox.width).max() ?? 0
        // For a photo that came from iCloud the bigger copy is another download, so
        // the floor waits until the face has matched: a stranger costs nothing more.
        var floorDeferred = false
        if widest < Self.minFacePixels {
            guard widestRatio * CGFloat(asset.pixelWidth) >= Self.minFacePixels else { return .faceTooSmall(pixels: Int(widest)) }
            if lastLoadFromCloud, Self.cloudFloorDeferred {
                floorDeferred = true
            } else {
                guard let larger = largerRender(), widestRatio * CGFloat(larger.width) >= Self.minFacePixels
                else { return .faceTooSmall(pixels: Int(widest)) }
            }
        }

        // After the face gates on purpose: pose detection is the most expensive
        // request, so it runs only on photos with one usable face.

        // Distances of every face in `source` to the selfie; nil when none could be
        // embedded. Defined here so the full-body gate can ask first.
        func score(from source: CGImage) -> (distances: [Float], faceWidth: CGFloat)? {
            timed("embed") { embed(from: source) }
        }
        func embed(from source: CGImage) -> (distances: [Float], faceWidth: CGFloat)? {
            let faceWidth = faces.map { $0.boundingBox.width * CGFloat(source.width) }.max() ?? widest

            var distances: [Float] = []
            var vectors: [[Float]] = []
            for face in faces {
                // Vision's boxes are normalised, so they fit the larger render unchanged.
                // Seeded with the observation when `source` is the render it was detected on.
                guard let candidate = recognizer.embedding(in: source, near: face.boundingBox, seed: source === cgImage ? face : nil) else { continue }
                vectors.append(candidate)
                var distance = FaceRecognizer.distance(reference, candidate)

                // Under `matchAgainstAllFrames` the score is the second-smallest
                // distance, so one frame liking a stranger is not enough.
                if Self.matchAgainstAllFrames, !extraReferenceEmbeddings.isEmpty {
                    let all = [distance] + extraReferenceEmbeddings.map { FaceRecognizer.distance($0, candidate) }
                    distance = all.sorted()[1]
                }
                distances.append(distance)

                // Distance is in the filename, so the closest crops can be found and
                // eyeballed without cross-referencing the console.
                if debugDumpCrops, debugCropsSaved < Self.debugCropLimit,
                   let cropped = crop(source, to: face.boundingBox) {
                    debugCropsSaved += 1
                    saveDebugImage(UIImage(cgImage: cropped),
                                   name: String(format: "%02d-d%.3f", debugCropsSaved, distance))
                }
            }
            guard !distances.isEmpty else { return nil }
            // For the store: only a complete set, so a stored group verdict never
            // rests on a face that was skipped here.
            lastEmbeddings = vectors.count == faces.count ? vectors : []
            return (distances, faceWidth)
        }

        // A selfie is recognised by shape before the full-body gate. Then only the
        // shopper in the photo: the person detector counts anyone, even back-on.
        // Match before pose — see `matchBeforePose`. A face clearly not the
        // shopper's returns here, with an empty body: it never reaches the grid,
        // and the gap rule ignores distances this far out.
        var quick: (distances: [Float], faceWidth: CGFloat)?
        if Self.matchBeforePose {
            quick = score(from: cgImage)
            if let quick {
                let best = quick.distances.min() ?? 1
                if best >= Self.gapCutCeiling && (widest >= Self.fullResFaceBelow || best >= Self.earlyNoMatchSmallFace) {
                    lastEarlyNoMatch = true
                    let unchecked = BodyCheck(lowerJoints: 0, ankles: 0, headSeen: false, span: 0, footRoom: 0, people: 1,
                                              shoulderSpread: nil, hipSpread: nil)
                    let ratio = Self.faceRatio(boxWidth: faces.map(\.boundingBox.width).max() ?? 0, in: cgImage)
                    lastEyeSpacing = nil
                    return .scored(distances: quick.distances, facePixels: Int(quick.faceWidth), body: unchecked,
                                   type: Self.photoType(faceRatio: ratio, yaw: faces.first?.yaw?.doubleValue, body: unchecked),
                                   profile: false, museScore: nil)
                }
            }
        }

        // Ordered after the face gates deliberately — pose detection is the most
        // expensive request here, and this way it only runs on photos that already
        // have one usable face.
        var body = timed("pose") { bodyCheck(in: cgImage, orientation: Self.cgOrientation(image.imageOrientation),
                                             face: faces.first?.boundingBox) }
        // Each reflection of the shopper has a body too; those are not other people.
        body.shopperFaces = lastShopperFaces
        // What the body score reads: the render the kept body was found on.
        var bodyObservation = lastBodyObservation
        var bodyImage = cgImage
        var bodyOrientation = Self.cgOrientation(image.imageOrientation)

        // A selfie has no lower body to find, so the full-body gate would reject
        // every one and none would reach the picker. Recognised by the same shape
        // the classifier uses — a face filling enough of the frame — from numbers
        // already in hand, so this costs nothing.
        // Only the shopper in the photo. The face gate cannot see someone with their
        // back to the camera; the person detector can, and anyone it finds counts.
        if body.hasOthers {
            return .otherPeople(body: body)
        }

        let faceRatio = Self.faceRatio(boxWidth: faces.map(\.boundingBox.width).max() ?? 0, in: cgImage)
        // Eye spacing of the widest face, for the v2 selfie rule and the summary.
        // Only where it can matter: a photo with a lower-body joint in frame is
        // never a selfie under v2, so its landmarks are not fetched.
        let widestFace = faces.max { $0.boundingBox.width < $1.boundingBox.width }
        // Measured on the scan's render, then scaled to the original's pixels,
        // the scale the face floor and the spec use.
        let originalScale = CGFloat(max(asset.pixelWidth, asset.pixelHeight)) / CGFloat(max(cgImage.width, cgImage.height))
        let eyeSpacing = body.lowerJoints == 0
            ? timed("type.eyes") { Self.eyeSpacing(of: widestFace, in: cgImage, handler: handler) }.map { $0 * originalScale }
            : nil
        lastEyeSpacing = eyeSpacing
        // The same rule as `photoType`, read before the body retry: under v2 a
        // photo with a lower-body joint in frame is never a selfie.
        let isSelfie = Self.photoType(faceRatio: faceRatio, eyeSpacing: eyeSpacing, yaw: nil, body: body) == .selfie
        if Self.requireFullBody && !isSelfie && !body.isHeadToToe {
            // Legs seen but not enough of them: one more look at the larger render,
            // only when the face already matches, so strangers cost nothing extra.
            guard body.headSeen, body.lowerJoints >= 1,
                  let quick = quick ?? score(from: cgImage), (quick.distances.min() ?? 1) < Self.matchThreshold,
                  let larger = largerRender()
            else { return .notFullBody(body: body) }
            var again = timed("pose") { bodyCheck(in: larger, orientation: .up, face: faces.first?.boundingBox) }
            again.shopperFaces = lastShopperFaces
            let f = { (v: CGFloat) in String(format: "%.2f", v) }
            lastBodyRetry = ("re-checked at \(larger.width)x\(larger.height) after a face match (d \(String(format: "%.3f", quick.distances.min() ?? 1))): ankles \(body.ankles)→\(again.ankles), span \(f(body.span))→\(f(again.span)), feet room \(f(body.footRoom))→\(f(again.footRoom))",
                             again.isHeadToToe)
            if again.hasOthers { return .otherPeople(body: again) }
            guard again.isHeadToToe else { return .notFullBody(body: body) }
            body = again
            bodyObservation = lastBodyObservation
            bodyImage = larger
            bodyOrientation = .up
        }

        // Free: the ratio, the body check and `yaw` are already in hand from the
        // match gates, so nothing is recomputed.
        let yaw = faces.first?.yaw?.doubleValue
        let type = Self.photoType(faceRatio: faceRatio, eyeSpacing: eyeSpacing, yaw: yaw, body: body)
        // The shoulders must have said side — a side by head turn alone does not count.
        let profile = type == .side && body.bodyFacing == .side && abs(yaw ?? 0) > Self.profileYaw

        // A small face is re-cropped from the larger render. Only photos past every
        // gate get here, a handful per scan; the face box is normalised, so it fits.
        let matchedSoFar = ((quick ?? score(from: cgImage))?.distances.min() ?? 1) < Self.matchThreshold
        if floorDeferred, matchedSoFar {
            guard let larger = largerRender(), widestRatio * CGFloat(larger.width) >= Self.minFacePixels
            else { return .faceTooSmall(pixels: Int(widest)) }
        }
        var source = cgImage
        // A downloaded photo fetches its bigger copy only once the face has matched.
        if widest < Self.fullResFaceBelow, !lastLoadFromCloud || matchedSoFar || largerCache != nil, let larger = largerRender() {
            source = larger
            lastCropFullRes = true
        }
        guard let scored = (source === cgImage ? quick : nil) ?? score(from: source) else { return .noFace }
        // Matches only — the rest never reach the grid, so their score is never
        // read. On the scan's render and its handler, not the larger crop.
        var museScore: MuseScore?
        if (scored.distances.min() ?? 1) < Self.matchThreshold {
            museScore = timed("score") {
                let context = museContext(face: faces[0], in: cgImage, handler: handler, readCover: Self.coverReadEnabled && type == .selfie)
                // The v2 selfie gates' inputs — see `selfieGatesV2`. The camera
                // data comes from the first bytes of the original on the phone.
                var gates: MuseScore.SelfieGates?
                if Self.selfieGatesV2, type == .selfie {
                    let camera = timed("score.camera") { Original.camera(for: asset) }
                    gates = MuseScore.SelfieGates(eyeSpacingOriginal: eyeSpacing.map { Float($0) },
                                                  originalScale: Float(originalScale),
                                                  originalLongSide: Float(max(asset.pixelWidth, asset.pixelHeight)),
                                                  camera: camera)
                }
                // The v2 full-length score — see `fullLengthScoreV2`.
                var bodyScore: BodyScore?
                if Self.fullLengthScoreV2, type != .selfie, let bodyObservation {
                    var objects: [BodyObjects.Object] = []
                    if Self.objectReadEnabled, let upright = BodyScore.upright(bodyImage, bodyOrientation) {
                        objects = timed("score.objects") { BodyObjects.read(upright: upright) }
                    }
                    bodyScore = timed("score.body") { BodyScore(image: bodyImage, orientation: bodyOrientation, body: bodyObservation,
                                                               face: faces[0].boundingBox, originalScale: Double(originalScale) * Double(cgImage.width) / Double(bodyImage.width),
                                                               caps: Self.garmentCaps(for: context.outfit), objects: objects) }
                }
                return timed("score.terms") { MuseScore(face: faces[0], in: cgImage, handler: handler, faceWidth: widest,
                                                         expression: context.expression, labels: context.labels, handOnFace: context.handOnFace,
                                                         outfit: context.outfit, selfie: type == .selfie, gates: gates, coverReader: context.coverReader,
                                                         document: context.document, body: bodyScore) }
            }
        }
        return .scored(distances: scored.distances, facePixels: Int(scored.faceWidth), body: body, type: type, profile: profile, museScore: museScore)
    }

    /// The garment caps a photo's labels call for — see `garmentCaps`. Nil with
    /// the switch off or when no garment reaches its line.
    static func garmentCaps(for outfit: MuseScore.Outfit) -> BodyScore.Caps? {
        guard garmentCapsEnabled else { return nil }
        var caps = BodyScore.Caps()
        for rule in garmentCaps {
            guard let hit = outfit.garments.filter({ rule.labels.contains($0.label) && $0.confidence >= rule.line }).max(by: { $0.confidence < $1.confidence })
            else { continue }
            caps.torso = min(caps.torso, rule.torso); caps.legs = min(caps.legs, rule.legs); caps.arms = min(caps.arms, rule.arms)
            let why = String(format: "%@ %.2f", hit.label, hit.confidence)
            if !caps.why.contains(why) { caps.why.append(why) }
        }
        return caps.why.isEmpty ? nil : caps
    }

    /// How far outside the face box a body's head points may sit and still make it
    /// that face's body, as a fraction of the box. Generous: the ears sit on the box
    /// edge, and a turned head moves the nose.
    static let bodyFaceMargin: CGFloat = 0.5

    /// What pose detection finds of the body. With `face`, only the body whose head
    /// sits on that face is read, never someone else's legs.
    func bodyCheck(in cgImage: CGImage, orientation: CGImagePropertyOrientation,
                   face: CGRect? = nil) -> BodyCheck {
        let request = VNDetectHumanBodyPoseRequest()
        // Counted in the same pass, so the photo is not decoded twice. Whole bodies,
        // not just upper halves, so someone standing beside the shopper is found.
        let peopleRequest = VNDetectHumanRectanglesRequest()
        peopleRequest.upperBodyOnly = false
        let handler = VNImageRequestHandler(cgImage: cgImage, orientation: orientation, options: [:])
        try? handler.perform([request, peopleRequest])

        // Bodies well under the largest are in the distance — see `bystanderRatio`.
        // Heights, not areas: a person side-on is narrow but no shorter.
        let tallest = peopleRequest.results?.map(\.boundingBox.height).max() ?? 0
        let people = peopleRequest.results?.filter { $0.boundingBox.height >= tallest * Self.bystanderRatio }.count ?? 0
        let nobody = BodyCheck(lowerJoints: 0, ankles: 0, headSeen: false, span: 0, footRoom: 0, people: people,
                               shoulderSpread: nil, hipSpread: nil)
        lastBodyObservation = nil
        guard let bodies = request.results, !bodies.isEmpty else { return nobody }

        func seen(_ joints: [VNHumanBodyPoseObservation.JointName],
                  of body: VNHumanBodyPoseObservation) -> [VNRecognizedPoint] {
            joints.compactMap { try? body.recognizedPoint($0) }
                .filter { $0.confidence >= Self.bodyJointConfidence }
        }
        let headJoints: [VNHumanBodyPoseObservation.JointName] = [.nose, .leftEye, .rightEye, .leftEar, .rightEar]

        // Face boxes and joints share Vision's normalised space, so the test is direct.
        var observation = bodies[0]
        if let face {
            let zone = face.insetBy(dx: -face.width * Self.bodyFaceMargin,
                                    dy: -face.height * Self.bodyFaceMargin)
            let onFace = { (body: VNHumanBodyPoseObservation) in
                seen(headJoints, of: body).filter { zone.contains($0.location) }.count
            }
            guard let best = bodies.max(by: { onFace($0) < onFace($1) }), onFace(best) > 0
            else { return nobody }
            observation = best
        }
        lastBodyObservation = observation

        let knees = seen([.leftKnee, .rightKnee], of: observation)
        let ankles = seen([.leftAnkle, .rightAnkle], of: observation)
        let head = seen(headJoints, of: observation)

        // Vision's y runs bottom to top, so the span is the highest head point less
        // the lowest ankle — and zero when either end is missing.
        var span: CGFloat = 0
        if let top = head.map(\.location.y).max(), let bottom = ankles.map(\.location.y).min() {
            span = max(0, top - bottom)
        }

        // The body's own turn: shoulders and hips across the photo, against the torso's
        // length. In pixels, because Vision normalises x and y to different sides.
        let sideways: Set<CGImagePropertyOrientation> = [.left, .right, .leftMirrored, .rightMirrored]
        let w = CGFloat(sideways.contains(orientation) ? cgImage.height : cgImage.width)
        let h = CGFloat(sideways.contains(orientation) ? cgImage.width : cgImage.height)
        func pixel(_ joint: VNHumanBodyPoseObservation.JointName) -> CGPoint? {
            guard let p = try? observation.recognizedPoint(joint),
                  p.confidence >= Self.spreadJointConfidence else { return nil }
            return CGPoint(x: p.location.x * w, y: p.location.y * h)
        }
        let torso: CGFloat? = {
            guard let neck = pixel(.neck), let root = pixel(.root) else { return nil }
            let length = hypot(neck.x - root.x, neck.y - root.y)
            return length > 1 ? length : nil
        }()
        func spread(_ a: VNHumanBodyPoseObservation.JointName,
                    _ b: VNHumanBodyPoseObservation.JointName) -> CGFloat? {
            guard let torso, let pa = pixel(a), let pb = pixel(b) else { return nil }
            return abs(pa.x - pb.x) / torso
        }

        var result = BodyCheck(lowerJoints: knees.count + ankles.count,
                               ankles: ankles.count,
                               headSeen: !head.isEmpty,
                               span: span,
                               footRoom: ankles.map(\.location.y).min() ?? 0,
                               people: people,
                               shoulderSpread: spread(.leftShoulder, .rightShoulder),
                               hipSpread: spread(.leftHip, .rightHip))

        // The knee-length rule's own numbers — see `minKnees`. The drop is in
        // pixels like the spread, against the same torso length.
        result.knees = knees.count
        if let top = head.map(\.location.y).max(), let lowestKnee = knees.map(\.location.y).min() {
            result.kneeSpan = max(0, top - lowestKnee)
            if let torso, let root = pixel(.root) {
                result.kneeDrop = (root.y - lowestKnee * h) / torso
            }
        }
        return result
    }

    /// The sharpest selfie frame by Vision's capture quality. Frames with no face
    /// are out; a tie keeps the tapped frame, the last one sent.
    /// The sharpest of the selfie frames, by Vision's face capture quality. Frames
    /// with no face are out; a tie, or no quality at all, keeps the tapped frame,
    /// which is the last one sent.
    /// Blend the usable selfie frames into one reference — see `blendReferenceFrames`.
    /// Each frame's embedding carries the quirks of that frame (a hint of
    /// expression, a small turn, a shadow), and with one frame as the reference
    /// every distance in the scan inherits them: two sharp frames of the same
    /// face gave two different grids. Averaging the frames' embeddings, as face
    /// systems enrol from several captures, cancels most of that. Frames with no
    /// face or a quality under `blendQualityFloor` (a blurred tap at 0.09) stay
    /// out. Two extra embeddings per scan, once. Off, the sharpest frame alone is
    /// the reference, as before.
    static let blendReferenceFrames = true
    static let blendQualityFloor: Float = 0.3

    func chooseReference(_ frames: [UIImage]) -> (image: UIImage, index: Int, note: String, quality: Float?, qualities: [Float?]) {
        guard frames.count > 1 else { return (frames[0], 0, "1 frame", nil, [nil]) }

        let qualities: [Float?] = frames.map { image in
            guard let cgImage = image.cgImage else { return nil }
            let handler = VNImageRequestHandler(cgImage: cgImage, orientation: Self.cgOrientation(image.imageOrientation), options: [:])
            let request = VNDetectFaceRectanglesRequest()
            try? handler.perform([request])
            guard let face = request.results?.max(by: { $0.boundingBox.width < $1.boundingBox.width }) else { return nil }
            return FaceMetrics(face, handler: handler).quality
        }

        var best = frames.count - 1
        for (index, quality) in qualities.enumerated() {
            guard let quality = quality else { continue }
            if let current = qualities[best], current >= quality { continue }
            best = index
        }
        // Three decimals: frames a second apart often tie at two, and the line
        // should show why one won.
        let scores = qualities.map { $0.map { String(format: "%.3f", $0) } ?? "no face" }.joined(separator: " / ")
        return (frames[best], best, "\(frames.count) frames, quality \(scores) → frame \(best + 1)\(best == frames.count - 1 ? " (tapped)" : "")", qualities[best], qualities)
    }

    /// Margin around the face box in the debug crops, as a fraction of the box.
    /// Matching does not crop: `FaceRecognizer` aligns on landmarks instead.
    static let facePadding: CGFloat = 0.1

    /// Vision boxes are normalised with a bottom-left origin; CGImage is top-left.
    /// `padding` is a fraction of the face box.
    func crop(_ image: CGImage, to boundingBox: CGRect, padding: CGFloat = ViewController.facePadding) -> CGImage? {
        let w = CGFloat(image.width)
        let h = CGFloat(image.height)

        let rect = CGRect(x: boundingBox.origin.x * w,
                          y: (1 - boundingBox.origin.y - boundingBox.height) * h,
                          width: boundingBox.width * w,
                          height: boundingBox.height * h)

        let padded = rect.insetBy(dx: -rect.width * padding, dy: -rect.height * padding)
        let clamped = padded.intersection(CGRect(x: 0, y: 0, width: w, height: h))
        guard clamped.width > 1, clamped.height > 1 else { return nil }

        return image.cropping(to: clamped)
    }

    /// Vision needs the EXIF orientation — without it a portrait photo is analysed
    /// sideways and no face is found.
    static func cgOrientation(_ orientation: UIImage.Orientation) -> CGImagePropertyOrientation {
        switch orientation {
        case .up: return .up
        case .down: return .down
        case .left: return .left
        case .right: return .right
        case .upMirrored: return .upMirrored
        case .downMirrored: return .downMirrored
        case .leftMirrored: return .leftMirrored
        case .rightMirrored: return .rightMirrored
        @unknown default: return .up
        }
    }
}

// MARK: - Weak bridge proxy

/// Breaks the retain cycle described in `setupWebView`.
final class BridgeProxy: NSObject, WKScriptMessageHandler {
    weak var target: WKScriptMessageHandler?

    init(target: WKScriptMessageHandler) {
        self.target = target
    }

    func userContentController(_ controller: WKUserContentController, didReceive message: WKScriptMessage) {
        target?.userContentController(controller, didReceive: message)
    }
}
