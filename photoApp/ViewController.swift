// Swan Gallery Pick host: loads the Swan page, passes it the session and answers its messages.

import UIKit
import WebKit
import Photos
import PhotosUI
import Vision
import Network

final class ViewController: UIViewController {

    // MARK: - Settings: fill these in before running
    // The page URL and API keys for each build are in `SwanEnvironment.swift`;
    // email and token come from `SwanSession.swift`.

    /// The Swan page for this build (sandbox or production, see `SwanEnvironment`).
    let sdkURL = SwanEnvironment.current.pageURL

    /// Name of the message handler the page posts to.
    static let bridgeName = "swanBridge"

    /// Your shop's id, the same for every build, and the shopper's gender: "male" or "female" skips the
    /// flow's gender screen; anything else, or empty, shows it.
    static let shopDomain = "swantestflight"
    static let userGender = ""        // "male" | "female"

    /// Optional height in cm (a number or a string). Between 152 and 213 the height
    /// screen is skipped; otherwise it is shown and `onComplete` returns the answer.
    static let userHeightCm: Any? = nil

    /// How many months back the library search goes (1–36). Older photos are
    /// reached only through "Load more". 12 is the default.
    static let monthsBack = 12

    /// Brand styling and text, passed to the page as `config`: `style` sets CSS
    /// variables, `content` replaces text. Every key is optional and not validated.
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
                    // A second note under the button. Empty so it does not repeat the footer.
                    "permissionText": "",
                ],
                "searchingPage": [
                    "headingTitle": "Finding photos of you.",
                    "subHeadingTitle": "We're looking for a selfie and clear, full-length photos from the front and side.",
                    // Text before and after the "13 of 1567" progress count.
                    "progressPreText": "Looking through your photos…",
                    "progressPostText": "",
                ],
                "pickerPage": [
                    "scanningHeadingTitle": "Finding photos of you.",
                    "scanningSubHeadingTitle": "We're looking for a selfie and clear, full-length photos from the front and side.",
                    // Text before and after the photo count while the scan runs.
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
                    // Footer on the searching screen and while the grid is still filling.
                    "keepAppOpenNote": "",
                    "poweredBy": "",
                    "notUploadedNote": "Keep the app open. Nothing has been uploaded."
                ],
            ] as [String: Any],
        ] as [String: Any],
    ]

    // MARK: - Photo scheme

    /// Custom URL scheme that serves photos straight into <img src>. Must not be a
    /// scheme WebKit already handles: registering "http" or "https" throws.
    static let photoScheme = "swan-photo"

    /// Kept here so the handler lives as long as this view controller.
    let photoSchemeHandler = PhotoSchemeHandler()

    // MARK: - Scan state

    var webView: WKWebView!

    /// Who is signed in. Set before the page loads, so `WEB_READY` always has a token.
    var session: SwanSession?
    /// Test builds' scan report; does nothing while `ScanReport.url` is nil.
    let scanReport = ScanReport()
    var webReadyWatchdog: DispatchWorkItem?
    var isLimitedAccess = false
    /// The selfie's face vector, which every library face is compared with.
    var referenceEmbedding: [Float]?

    /// Which selfie frame became the reference, for the scan summary.
    var lastReferenceFrames = 1
    var lastReferenceIndex = 0
    var lastReferenceQuality: Float?

    /// How many selfie frames were blended into the reference.
    var lastReferenceBlended = 1
    /// Each frame's quality, how far apart the blended frames were, and how far
    /// the blend moved from the chosen frame.
    var lastReferenceQualities: [Float?] = []
    var lastReferenceSpread: Float?
    var lastReferenceShift: Float?

    /// Whether the last `loadPhoto` returned the phone's smaller copy of an iCloud
    /// photo, or a copy downloaded from iCloud.
    var lastLoadLocalCopy = false
    var lastLoadFromCloud = false
    /// Larger copies downloaded from iCloud for a small face, this scan.
    var cloudLargerDownloads = 0

    /// Why the last `loadPhoto` came back empty, for the scan log.
    var lastLoadNote = ""

    /// Time per scan stage in milliseconds, reset each scan. Scan queue only.
    var stageMs: [String: Double] = [:]
    func timed<T>(_ stage: String, _ work: () -> T) -> T {
        let started = Date()
        defer { stageMs[stage, default: 0] += Date().timeIntervalSince(started) * 1000 }
        return work()
    }

    /// Whether the last `matchPerson` ruled out a match from the face alone,
    /// before body pose (see `matchBeforePose`).
    var lastEarlyNoMatch = false

    /// A photo's capture date as `yyyy-MM-dd`, for the scan summary. Nil without a date.
    static func captureDay(_ date: Date?) -> String? {
        guard let date else { return nil }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter.string(from: date)
    }

    /// This app's memory use in MB, for the scan summary. The web view runs in a
    /// separate process and is not counted.
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

    /// Whether the second head-to-toe check in `matchPerson` found head to toe.
    /// Nil when that check did not run.
    var lastBodyRetry: Bool?
    /// The body pose the last `bodyCheck` kept, for `BodyScore`.
    var lastBodyObservation: VNHumanBodyPoseObservation?
    /// Distance between the pupils of the widest face in the last photo, in the
    /// scan's pixels. Nil without face landmarks.
    var lastEyeSpacing: CGFloat?

    /// How many faces in the last photo were the shopper's. More than 1 means a
    /// mirror shot (see `sameShopperFacesMax`).
    var lastShopperFaces = 1

    /// Results kept between scans (see `ScanStore`). Nil when the store is off.
    var scanStore: ScanStore?
    /// Face vectors from the last `matchPerson`, largest face first; empty if any
    /// face failed. Stored so the next scan can compare without loading the photo.
    var lastEmbeddings: [[Float]] = []

    /// Smallest phone copy worth scanning, on its longer side. Anything smaller is
    /// too blurred to read a face, so the photo counts as "no image".
    static let minLocalCopyPixels = 800

    /// Longest wait for the phone's copy of an iCloud photo: a guard against a
    /// stalled callback, not a download allowance.
    static let localCopyWait: DispatchTimeInterval = .seconds(2)

    /// The small copy iOS offered for an iCloud-only photo. Used only to check
    /// whether the photo looks like a selfie.
    var lastLoadThumbnail: UIImage?

    // MARK: - iCloud downloads
    // Only iCloud photos whose thumbnail looks like a selfie or one standing person are downloaded.

    /// Most downloads per scan, newest first: on Wi-Fi, and on mobile data.
    static let cloudDownloadCapWifi = 200
    static let cloudDownloadCapMobile = 100
    /// Download slots kept for full-length photos, so selfies cannot use them all.
    static let cloudFullLengthReserve = 20
    /// Downloads start during the local pass. Afterwards the scan waits at most this
    /// long for the rest; any still missing are counted as left.
    static let cloudTail: TimeInterval = 30
    /// The wait goes past `cloudTail` only while a photo the small copy confirmed is
    /// still downloading, and never past this.
    static let cloudTailMax: TimeInterval = 90
    /// Per-photo download limit on Wi-Fi. Generous, because `cloudTail` and
    /// `cloudTailMax` bound the whole scan.
    static let cloudTimeout: DispatchTimeInterval = .seconds(20)
    /// Per-photo download limit on mobile data, which is slower.
    static let cloudTimeoutMobile: DispatchTimeInterval = .seconds(30)
    /// The per-photo limit for the current connection.
    static var cloudTimeoutNow: DispatchTimeInterval { cloudOnMobile ? cloudTimeoutMobile : cloudTimeout }
    /// Downloads at once. Fewer on mobile data, where parallel downloads only share
    /// a slow connection and time out.
    static let cloudParallel = 6
    static let cloudParallelMobile = 3
    /// Size of a small copy fetched first. Faces and people are counted on it, and
    /// only a photo with one person goes on to the full download.
    static let cloudPreviewPixels: CGFloat = 320
    /// The small copy overstates face size, so a face under the size floor × this
    /// margin fetches the bigger copy straight away.
    static let cloudFaceEstimateMargin: CGFloat = 1.25
    /// A lone person at least this share of the thumbnail's height is a full-length candidate.
    static let cloudPersonHeight: CGFloat = 0.6

    /// True when online. Mobile data and Low Data Mode are allowed; the caps limit the cost.
    static var cloudDownloadsAllowed: Bool {
        let path = pathMonitor.currentPath
        return path.status == .satisfied
    }
    static var cloudOnMobile: Bool { pathMonitor.currentPath.isExpensive }
    static var cloudDownloadCap: Int { cloudOnMobile ? cloudDownloadCapMobile : cloudDownloadCapWifi }

    // MARK: - Reloads

    /// Bumped on every reset. A scan loop stops when the value changes, so a block
    /// that outlives a page reload cannot reply into the next scan.
    var scanGeneration = 0

    /// Reloads after the web page's process crashed, and the most allowed.
    var processReloads = 0
    static let maxProcessReloads = 3

    // MARK: - Lifecycle

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .systemBackground
        // Started early: the network monitor's first reading takes a moment.
        _ = Self.pathMonitor
        // The screen is let sleep again whenever the app leaves the foreground.
        NotificationCenter.default.addObserver(self, selector: #selector(appDidEnterBackground),
                                               name: UIApplication.didEnterBackgroundNotification, object: nil)
        // A stored scan report's id goes to the gallery page, which records it in PostHog with the user.
        scanReport.onStored = { [weak self] id, photos in
            self?.sendToWeb(["type": "onGalleryScanReportStored", "payload": ["id": id, "photos": photos]])
        }
        // The web view is created after sign-in. Building it here would block the
        // main thread and freeze the email field while the page loads.
    }

    /// Set once the view is on screen; the sign-in screen cannot be presented from
    /// `viewDidLoad` because the view is not in a window yet.
    private var started = false

    /// The sign-in screen, while the gallery page loads. Nil once the page is shown.
    private weak var signInController: SwanSessionViewController?

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        guard !started else { return }
        started = true
        presentSignIn(existing: SwanSession.restoreIfAlive())
    }

    /// The page has sent WEB_READY and is waiting for RENDER_COMPONENT.
    private var webReady = false

    /// Signed in. The sign-in screen shows a spinner until the page is ready, so a
    /// slow load is not a white screen.
    func openGallery(with session: SwanSession) {
        self.session = session
        signInController?.beginOpeningGallery()
        // Wait one run-loop turn so the spinner shows before WebKit blocks the main thread.
        DispatchQueue.main.async { [weak self] in
            self?.loadGalleryPage()
        }
    }

    /// Creates the web view on first use and loads the page. Renders at once when
    /// the page has already sent WEB_READY.
    private func loadGalleryPage() {
        if webView == nil { setupWebView() }
        if webReady {
            revealGallery()
            return
        }
        startWebReadyWatchdog()
        webView.load(URLRequest(url: sdkURL))
    }

    /// Renders the gallery and closes the sign-in screen.
    private func revealGallery() {
        renderGallery()
        guard let signIn = signInController else { return }
        signInController = nil
        signIn.dismiss(animated: true)
    }

    /// The page will not load: shows the error on the sign-in screen.
    private func pageDidFail(_ message: String) {
        guard signInController != nil else { return }
        webReadyWatchdog?.cancel()
        webReady = false
        signInController?.showPageError(message)
    }

    /// Whether `warmUpModels` has run.
    private static var modelsWarmed = false
    /// Loads the face, expression and hand models in the background while the user is
    /// on the intro and selfie screens, so the scan does not wait for them. Runs once.
    func warmUpModels() {
        guard !Self.modelsWarmed else { return }
        Self.modelsWarmed = true
        DispatchQueue.global(qos: .utility).async {
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
        }
    }

    /// Sends RENDER_COMPONENT for GalleryPick with the signed-in session. Never sent
    /// without one: the page cannot upload without a token.
    func renderGallery() {
        guard let session = session else { return }
        warmUpModels()
        sendToWeb([
            "type": "RENDER_COMPONENT",
            "componentName": "GalleryPick",
            "props": [
                "userDetails": [
                    "email": session.email,
                    "shopDomain": Self.shopDomain,
                    "gender": Self.userGender,
                    // Left out when nil, so the page sees no height rather than null.
                    "heightInCm": Self.userHeightCm as Any,
                ].compactMapValues { $0 },
                "token": session.token,
                "config": Self.theme,
                "monthsBack": Self.monthsBack,
            ]
        ])
    }

    // MARK: - Session renewal (the sample's own; a shipped app does this with its token server)

    /// Mints a new session for the signed-in email when the current token has under
    /// `SwanSessionConfig.renewMargin` left, so a build wait cannot outlive it. Keeps the old one on failure.
    func renewSessionIfNeeded() async {
        guard let until = session?.validUntil, until.timeIntervalSinceNow < SwanSessionConfig.renewMargin else { return }
        await renewSession(force: false)
    }

    func renewSession(force: Bool) async {
        guard let current = session else { return }
        do {
            let fresh = try await SwanSessionClient.createSession(email: current.email, name: current.name)
            fresh.save()
            session = fresh
        } catch {
            print("\u{274c} session renew failed\(force ? "" : " (token near expiry)") — \(error.localizedDescription)")
        }
    }

    /// Shows the sign-in screen. It stays up until the page is ready, and with a live
    /// session it offers that email and a Continue button.
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
        NotificationCenter.default.removeObserver(self)
        webView?.configuration.userContentController
            .removeScriptMessageHandler(forName: Self.bridgeName)
        webReadyWatchdog?.cancel()
        setKeepAwake(false)
    }

    /// Keeps the screen on while photos upload and the Muse builds, so a locked phone does not
    /// suspend the page mid-way; cleared on every end state and whenever the app leaves the foreground.
    func setKeepAwake(_ on: Bool) {
        UIApplication.shared.isIdleTimerDisabled = on
    }

    @objc private func appDidEnterBackground() { setKeepAwake(false) }

    // MARK: - Setup

    func setupWebView() {
        guard webView == nil else { return }
        let contentController = WKUserContentController()

        // The content controller holds its handler strongly, so passing `self` would
        // leak this view controller. The proxy holds it weakly.
        contentController.add(BridgeProxy(target: self), name: Self.bridgeName)

        let configuration = WKWebViewConfiguration()
        configuration.userContentController = contentController
        // Without these the camera opens fullscreen and the voice guidance is muted.
        configuration.allowsInlineMediaPlayback = true
        configuration.mediaTypesRequiringUserActionForPlayback = []

        // Lets the page use <img src="swan-photo://…"> instead of sending photo bytes
        // over the bridge. Base64 over the bridge is the fallback.
        configuration.setURLSchemeHandler(photoSchemeHandler, forURLScheme: Self.photoScheme)

        webView = WKWebView(frame: .zero, configuration: configuration)
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

    /// A load cancelled by a newer one. Not a failure.
    private static func cancelled(_ error: Error) -> Bool {
        let error = error as NSError
        return error.domain == NSURLErrorDomain && error.code == NSURLErrorCancelled
    }

    /// How long to wait for WEB_READY before offering Try again. Generous, since a
    /// first load on a slow connection also downloads a model.
    static let webReadyTimeout: TimeInterval = 30

    /// Shows an error if WEB_READY never arrives. A script error in the page loads
    /// fine but leaves a blank page, so only this catches it.
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

    /// Posts a message to the page. Passed as an argument, not built into a string,
    /// because U+2028/U+2029 are valid in JSON but break JavaScript source.
    func sendToWeb(_ payload: [String: Any]) {
        scanReport.collect(payload, page: sdkURL)
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
}

// MARK: - Photo type

/// Which way the person in a photo is facing. The raw value is sent to the page as-is.
enum PhotoType: String {
    case front
    case side
    /// A full-length photo turned partway (see `threeQuarterDegrees`). The page puts
    /// it in a side slot.
    case threeQuarter = "three-quarter"
    case selfie
    /// No face found: usually a back view, sometimes an unusable photo. Check
    /// `isFullBody` to tell them apart.
    case unknown
}

// MARK: - Receiving from web

extension ViewController: WKScriptMessageHandler {

    func userContentController(
        _ userContentController: WKUserContentController,
        didReceive message: WKScriptMessage
    ) {
        // Accept a JSON string or a dictionary; anything else is logged, not dropped silently.
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
            return
        }

        switch type {
        case "WEB_READY":
            webReadyWatchdog?.cancel()
            // A new or reloaded page has no state, so nothing held here, captures
            // included, is still valid.
            CaptureStore.removeAll()
            resetScanState()
            webReady = true
            // A reloaded page gets a token with enough life left for a build wait.
            if session != nil { Task { await renewSessionIfNeeded(); revealGallery() } }

        case "GALLERY_SCAN_START":
            let filters = payload["payload"] as? [String: Any] ?? [:]
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
            // A web page cannot open the Settings app, so the host does it.
            if let url = URL(string: UIApplication.openSettingsURLString) {
                UIApplication.shared.open(url)
            }

        case "GALLERY_PICK_MORE":
            // Reopens iOS's limited-library picker so the user can share more photos.
            PHPhotoLibrary.shared().presentLimitedLibraryPicker(from: self) { [weak self] added in
                guard let self = self, !added.isEmpty else { return }
                // The page still holds the selfie, so telling it to scan again is enough.
                self.sendToWeb(["type": "onGalleryPickedMore", "payload": ["added": added.count]])
            }

        case "WEB_LOG":
            // The page's console trace. Not printed: it carries request bodies.
            break

        case "GALLERY_TOKEN_EXPIRED":
            // The page's token was refused mid-build: mint a new session and send it again.
            Task { await renewSession(force: true); renderGallery() }

        case "GALLERY_RESET":
            // A new scan or an abandoned flow: clear everything from the previous run.
            resetScanState()
            setKeepAwake(false)

        case "GALLERY_ANALYSE_PHOTO":
            // The user selected a photo. See analysePhoto(id:).
            let photoId = (payload["payload"] as? [String: Any])?["assetId"] as? String ?? ""
            analysePhoto(id: photoId)

        case "GALLERY_CAPTURE_PHOTO":
            // A photo taken inside the flow. Held in memory, analysed like any other,
            // never written to the photo library. See storeCapture(id:dataURI:).
            let capture = payload["payload"] as? [String: Any] ?? [:]
            let captureId = capture["id"] as? String ?? ""
            let captureURI = capture["dataURI"] as? String ?? ""
            storeCapture(id: captureId, dataURI: captureURI)

        case "GALLERY_CLEAR_CAPTURES":
            // Separate from GALLERY_RESET: a capture must survive a rescan for more photos.
            CaptureStore.removeAll()

        case "SCHEME_TEST_RESULT":
            // The page reports whether the photo scheme works. Nothing to do.
            break

        case "COMPONENT_CALLBACK":
            let name = payload["callbackName"] as? String ?? ""
            let result = payload["payload"] as? [String: Any] ?? [:]
            scanReport.noteCallback(name, result)
            handleCallback(name, result)

        default:
            print("⚠️ Unhandled message type: \(type)")
        }
    }

    /// Everything the flow reports. Replace each case with your own handling;
    /// some payloads carry signed URLs and the user's email, so keep them out of logs.
    func handleCallback(_ name: String, _ result: [String: Any]) {
        switch name {
        case "onUploadStart":
            // Photos are going up: `photoCount`; `background` is true while the user is still picking.
            setKeepAwake(true)
        case "onUploadEnd":
            // One file is up or failed (`uploaded`, `kind`, `assetId`); a Live Photo's video reports separately.
            break
        case "onCaptureComplete":
            // The camera fallback finished: `photoIds`. Upload follows.
            break
        case "onImageSelect":
            // A photo tapped in the picker: `assetId`, `selected` (false is a deselect), `count`.
            break
        case "onLoadMore":
            // The user asked for more photos: `path` is "shared_library" or "older_photos".
            break
        case "onMuseStart":
            // The Muse build was requested: `photoIds`.
            setKeepAwake(true)
        case "onMuseEnd":
            // The build settled: `status`, `phase`, `museId`, `message`; `data` holds `missingRoles` and `rejectedPhotos`.
            setKeepAwake(false)
        case "onMuseSocketOpen":
            // The build socket connected: `museId`.
            break
        case "onMuseSocketClose":
            // The build socket closed: `code` (1000 normal, 1006 dropped), `reason`, `wasClean`; `early` when before the build settled.
            break
        case "onComplete":
            // The end of the flow: `museId`, `museStatus`, server `photoIds` (what POST /muse/build takes), `heightInCm`, `museImages`.
            setKeepAwake(false)
        case "onError":
            // `stage` is photos, upload or muse, with `message` and `failedCount`; the page already shows the user an error.
            setKeepAwake(false)
        default:
            break
        }
    }
}

// MARK: - Camera

extension ViewController: WKUIDelegate {

    /// Required on iOS 15+: without it the camera never opens.
    func webView(
        _ webView: WKWebView,
        requestMediaCapturePermissionFor origin: WKSecurityOrigin,
        initiatedByFrame frame: WKFrameInfo,
        type: WKMediaCaptureType,
        decisionHandler: @escaping (WKPermissionDecision) -> Void
    ) {
        // Only the camera, and only for the page we loaded. A blanket grant would give
        // any site the web view reaches a live camera.
        guard type == .camera, origin.host == sdkURL.host else {
            decisionHandler(.deny)
            return
        }
        decisionHandler(.grant)
    }
}

// MARK: - Load failures

extension ViewController: WKNavigationDelegate {

    /// The web page's process was killed, usually for memory. Reloaded, but only up to
    /// `maxProcessReloads` times so a page that always runs out of memory stops.
    func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
        setKeepAwake(false)
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

    // Without these, a page that cannot be reached is a blank screen with nothing logged.
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

    /// An HTTP error on the page means the flow never starts. (An unpublished version
    /// folder is redirected to the latest release instead.)
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

    /// Logs when the version in `sdkURL` was not published and the latest release
    /// loaded instead.
    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        guard sdkURL.path.hasPrefix("/v"), let landed = webView.url, landed.path != sdkURL.path else { return }
        print("⚠️ Asked for \(sdkURL.path), got \(landed.path) — that version is not published; the latest release loaded instead")
    }
}

// MARK: - Weak bridge proxy

/// Holds the view controller weakly, so the content controller does not keep it alive.
final class BridgeProxy: NSObject, WKScriptMessageHandler {
    weak var target: WKScriptMessageHandler?

    init(target: WKScriptMessageHandler) {
        self.target = target
    }

    func userContentController(_ controller: WKUserContentController, didReceive message: WKScriptMessage) {
        target?.userContentController(controller, didReceive: message)
    }
}
