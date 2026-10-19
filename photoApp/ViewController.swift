

// Swan Gallery Pick host — pairs with Swan mobile 1.3.0. Release notes and
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
    let sdkURL = URL(string: "https://d3fujk4qpp9eu4.cloudfront.net/swan-mobile")!

    static let bridgeName = "swanBridge"

    // ---- Fill these in before running ----------------------------------------
    // Email and token come from `SwanSession.swift`; put your API keys in `SwanSessionConfig`.

    /// Who the flow is running for. `gender` is optional: "male" or "female" skips
    /// the flow's own gender screen; anything else, or nil, shows it.
    static let shopDomain = "hm_ie"
    static let userGender = "male"        // "male" | "female"

    /// Optional height in cm (a string works too). Inside 152–213 the ruler screen is
    /// skipped; otherwise the ruler is shown and `onComplete` carries the user's answer.
    static let userHeightCm: Any? = 181

    /// How far back the library search reaches, in months (1–36, clamped). Older
    /// photos are reached only through "Load more". 12 is the flow's default.
    static let monthsBack = 12

    /// Brand styling and wording, passed through as `config`: `style` becomes CSS
    /// variables, `content` replaces text. Every value is optional and unvalidated.
    static let theme: [String: Any] = [:]

    // Example values for both halves, with every text key, are in
    // GALLERY_PICK.md and GALLERY_PICK_TEXT_CONFIG.md.

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

    /// Why the last `loadPhoto` came back empty, for the verbose log: whether iOS
    /// said the photo was in iCloud, and how large a copy the phone offered.
    var lastLoadNote = ""

    /// What the second head-to-toe check found, when `matchPerson` ran one — see
    /// the full-body gate there. Nil when no retry happened. Read by the scan log.
    var lastBodyRetry: (note: String, rescued: Bool)?

    /// How many faces in the last photo examined were the shopper's. Above 1 it was
    /// a mirror shot — see `sameShopperFacesMax`. Read by the scan log and summary.
    var lastShopperFaces = 1

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

    /// Longest side of the copy asked for. Enough for a selfie's face at the sizes
    /// the matcher is tuned for; a fraction of the original's bytes.
    static let cloudPixels: CGFloat = 1024
    /// Downloads per scan, most recent first. Whatever the filter finds beyond this
    /// stays out, so a library of strangers' selfies costs a bounded amount.
    static let cloudDownloadCap = 40
    /// Wall-clock budget for the whole iCloud pass, on top of the local scan.
    static let cloudTimeBudget: TimeInterval = 60
    /// Per-photo limit, as for sizing an original.
    static let cloudTimeout: DispatchTimeInterval = .seconds(10)

    /// Wi-Fi, not Low Data Mode, and online. The iCloud pass never spends mobile data.
    static var cloudDownloadsAllowed: Bool {
        let path = pathMonitor.currentPath
        return path.status == .satisfied && !path.isExpensive && !path.isConstrained
    }

    /// Bumped on every reset. A scan loop stops when the value changes, so a block
    /// that outlives a page reload cannot reply into the next scan.
    var scanGeneration = 0

    /// Reload attempts after a WebContent process crash, and the ceiling on them.
    var processReloads = 0
    static let maxProcessReloads = 3

    /// One console line per photo scanned. Useful on a small library, a flood on
    /// a real one — a 10k-photo scan prints 10k lines.
    static let verboseLogging = false

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
    static let debugBridgeLogging = false

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
        setupWebView()
        // The page loads now, behind the sign-in screen, and renders nothing until
        // it is handed a session — see `renderGallery`.
        webView.load(URLRequest(url: sdkURL))
        startWebReadyWatchdog()
    }

    /// Decided once the view is on screen: presenting from `viewDidLoad` is refused
    /// because the view is not in the window yet.
    private var started = false

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        guard !started else { return }
        started = true
        presentSignIn(existing: SwanSession.restoreIfAlive())
    }

    /// The page has said WEB_READY and is waiting for RENDER_COMPONENT.
    private var webReady = false

    /// Signed in. The flow renders as soon as both halves are there: the session
    /// and the page — whichever arrives second triggers it.
    func start(with session: SwanSession) {
        self.session = session
        let until = session.validUntil.map { DateFormatter.localizedString(from: $0, dateStyle: .medium, timeStyle: .short) } ?? "unknown"
        if Self.debugBridgeLogging { print("👤 Signed in as \(session.email) — token valid until \(until)") }
        if webReady { renderGallery() } else { print("⏳ Page still loading — rendering when it is ready") }
    }

    /// RENDER_COMPONENT for GalleryPick, with the signed-in session. Never sent
    /// without one: the page cannot upload without a token.
    func renderGallery() {
        guard let session = session else { return }
        if Self.debugBridgeLogging { print("▶️ Rendering GalleryPick for \(session.email)") }
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

    /// The sign-in screen, over the empty web view. It cannot be dismissed
    /// without a token. With a live session it offers that email and Continue.
    func presentSignIn(existing: SwanSession? = nil) {
        let signIn = SwanSessionViewController(existing: existing)
        signIn.modalPresentationStyle = .fullScreen
        signIn.onSignedIn = { [weak self, weak signIn] session in
            signIn?.dismiss(animated: true) { self?.start(with: session) }
        }
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

    /// A JS error in the bundle gives a successful navigation and a blank page, the
    /// same white screen as a network failure. This log tells them apart.
    func startWebReadyWatchdog() {
        let work = DispatchWorkItem {
            print("⏰ No WEB_READY within 15s — the bundle probably threw. Check Web Inspector.")
        }
        webReadyWatchdog = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 15, execute: work)
    }

    // MARK: - Sending to web

    /// `callAsyncJavaScript` with an arguments dictionary, not a spliced string:
    /// U+2028/U+2029 are legal in JSON but break JS source.
    func sendToWeb(_ payload: [String: Any]) {
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

/// Which way the person in a photo is facing. String-backed so the raw value
/// crosses the bridge as-is; the web side stores the payload without decoding it.
enum PhotoType: String {
    case front
    case side
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
            if session != nil { renderGallery() } else { print("⏳ Page ready — rendering after sign-in") }

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
        webReadyWatchdog?.cancel()
        print("❌ Could not reach \(sdkURL): \(error.localizedDescription)")
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        webReadyWatchdog?.cancel()
        print("❌ Navigation failed: \(error.localizedDescription)")
    }

    /// A version folder that was never published is sent on to the latest release;
    /// any other missing path is a 404 and the flow never starts.
    func webView(_ webView: WKWebView, decidePolicyFor navigationResponse: WKNavigationResponse,
                 decisionHandler: @escaping (WKNavigationResponsePolicy) -> Void) {
        if navigationResponse.isForMainFrame,
           let response = navigationResponse.response as? HTTPURLResponse,
           response.statusCode >= 400 {
            print("❌ \(response.statusCode) for \(response.url?.absoluteString ?? "?") — check sdkURL")
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

    /// How far the selfie's head may be turned before a retake is asked for. Pitch
    /// gets more room, since a chin a little down is normal.
    static let selfieMaxYawDegrees: Double = 20
    static let selfieMaxPitchDegrees: Double = 25

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

    /// A face's width against the frame's shorter side — the one number every
    /// selfie decision reads, so the scan and a tap cannot disagree about it.
    static func faceRatio(boxWidth: CGFloat, in cgImage: CGImage) -> CGFloat {
        boxWidth * CGFloat(cgImage.width) / CGFloat(min(cgImage.width, cgImage.height))
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

    /// Knee length is as good as head to toe: a photo passes with the head, this
    /// many knees, enough span and the knees well below the hips.
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

    /// The body's turn from the camera that a shoulder spread implies, in degrees.
    static func turnDegrees(spread: CGFloat) -> Double {
        acos(Double(min(1, max(0, spread / frontShoulderSpread)))) * 180 / .pi
    }

    /// Joint confidence for the spread, lower than `bodyJointConfidence` because a
    /// side view half hides the far shoulder.
    static let spreadJointConfidence: Float = 0.1

    /// One photo's type, from values the caller already has. Shared by the scan and
    /// `classifyPhotoType` so the two cannot disagree.
    static func photoType(faceRatio: CGFloat, yaw: Double?, body: BodyCheck) -> PhotoType {
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
            if frames.count > 1 { print("🤳 Reference: \(chosen.note)") }

            // One face, looking at the camera (see `selfieMaxYawDegrees`). The page
            // returns to the selfie screen with the reason; nothing below runs.
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
            guard !Self.lowDataMode else { return .lowData }
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

        // The shopper's own library only, not shared albums, and no screenshots:
        // a screenshot of a model passes every other check.
        options.includeAssetSourceTypes = [.typeUserLibrary]
        let withScreenshots = PHAsset.fetchAssets(with: .image, options: options).count
        let noScreenshots = NSPredicate(format: "(mediaSubtypes & %d) == 0",
                                        PHAssetMediaSubtype.photoScreenshot.rawValue)
        options.predicate = options.predicate.map {
            NSCompoundPredicate(andPredicateWithSubpredicates: [$0, noScreenshots])
        } ?? noScreenshots

        let assets = PHAsset.fetchAssets(with: .image, options: options)
        let total = assets.count

        // Visible-to-us count with no date filter. If this is 0 the problem is
        // access; if it is large while `total` is 0 the problem is the date range.
        let visible = PHAsset.fetchAssets(with: .image, options: nil).count
        let window = isLimitedAccess ? "everything you shared" : "the last \(months) months"
        print("\u{1f4f8} \(total) photos in \(window) (\(visible) visible in total\(isLimitedAccess ? ", limited access" : ""), \(withScreenshots - total) screenshots skipped)")
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

        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            var matchedIds: [String] = []
            // Score and type per match, for the eval report and the retry logs.
            var matchScores: [String: (distance: Float, type: PhotoType, score: Float?)] = [:]
            // Every distance scored this run, match or not — the gap rule reads
            // the whole distribution once the scan is over. See `gapCutEnabled`.
            var scoredDistances: [Float] = []
            // Matches between `gapCutFloor` and the cut-off: held back until the gap
            // is known, then appended so nothing on screen moves.
            var heldIds: [String] = []
            // Near-duplicates (see `duplicateDistance`): each match gets a group id,
            // its own or the earlier match it repeats. The page picks one per group.
            var featurePrints: [(id: String, print: VNFeaturePrintObservation)] = []
            var dupGroups: [String: String] = [:]
            var duplicates = 0
            var eval = ScanEval(labels: evalLabels)
            var lastReport = Date.distantPast

            // Per-gate tallies — which stage a disappointing result came from.
            var noImage = 0
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
            var lowDataSkipped = 0
            var sized = 0
            var downloadedToSize = 0
            var sizingSeconds = 0.0

            // What the matches cover, for the summary only; the web layer derives
            // coverage from the selection.
            var found: [PhotoType: Int] = [:]
            var examined = 0

            // iCloud-only photos whose thumbnail looks like a selfie, examined after
            // the local pass — see `cloudDownloadCap`.
            var cloudCandidates: [(asset: PHAsset, n: Int)] = []
            var cloudOnly = 0
            // Second head-to-toe checks at the larger render — see `lastBodyRetry`.
            var bodyRetried = 0
            var bodyRescued = 0
            // Mirror shots: more than one face, all the shopper's — see `sameShopperFacesMax`.
            var sameShopper = 0
            // Matches in on the knee rule alone — see `minKnees`.
            var kneeLength = 0
            // Matches kept out for a face the Muse cannot use — see `unusableFaceDrops`.
            var unusableFace = 0

            // One loaded photo through every gate. Shared by the local pass and the
            // iCloud pass, so a downloaded photo faces exactly the same checks.
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
                        eval.note(asset, image: image, rotated: wasRotated, gate: .noFace)
                        if Self.verboseLogging { print("  ○  [\(n)] no face             \(px) \(orient)") }

                    case .group(let faceCount):
                        groupSkipped += 1
                        eval.note(asset, image: image, rotated: wasRotated, gate: .group)
                        if Self.verboseLogging { print("  \u{1f465} [\(n)] group (\(faceCount) faces) — skipped   \(px) \(orient)") }

                    case .faceTooSmall(let pixels):
                        tooSmall += 1
                        eval.note(asset, image: image, rotated: wasRotated, gate: .faceTooSmall, metrics: metrics)
                        if Self.verboseLogging { print("  \u{1f50e} [\(n)] face too small (\(pixels)px)   \(px) \(orient)") }

                    case .otherPeople(let body):
                        otherPeople += 1
                        eval.note(asset, image: image, rotated: wasRotated, gate: .otherPeople, body: body, metrics: metrics)
                        if Self.verboseLogging { print("  \u{1f465} [\(n)] \(body.people) people — skipped   \(px) \(orient)") }

                    case .notFullBody(let body):
                        notFullBody += 1
                        eval.note(asset, image: image, rotated: wasRotated, gate: .notFullBody, body: body, metrics: metrics)
                        if Self.verboseLogging { print("  \u{1f9cd} [\(n)] not head to toe (head \(body.headSeen), ankles \(body.ankles), span \(String(format: "%.2f", body.span)), feet room \(String(format: "%.3f", body.footRoom)); knees \(body.knees), knee span \(String(format: "%.2f", body.kneeSpan)), knee drop \(body.kneeDrop.map { String(format: "%.2f", $0) } ?? "–"))   \(px) \(orient)") }

                    case .scored(let distances, let facePixels, let body, let type, let profile, let museScore):
                        // A list, not a value, so turning off the single-face gate
                        // does not silently change what is logged.
                        let scores = distances.sorted()
                            .map { String(format: "%.3f", $0) }
                            .joined(separator: " ")
                        let distance = distances.min()!
                        // The gap rule sees clean faces only: covered or strained faces
                        // land between the shopper's photos and strangers.
                        let unusable = Self.unusableFaceDrops ? museScore?.filter : nil
                        if unusable == nil && museScore?.demoted != true { scoredDistances.append(distance) }

                        // A face in profile against a front-facing selfie gets more room; a
                        // selfie, whose own matches score low, gets less.
                        let cutoff = profile ? Self.profileMatchThreshold
                            : type == .selfie ? Self.selfieMatchThreshold
                            : Self.matchThreshold

                        if distance >= cutoff {
                            noMatch += 1
                            if let closest = closestNoMatch, closest <= distance {} else { closestNoMatch = distance }
                            if distance - cutoff <= 0.1 { nearMisses += 1 }
                            eval.note(asset, image: image, rotated: wasRotated, gate: .noMatch, distance: distance,
                                      type: type, body: body, metrics: metrics,
                                      fullRes: self?.lastCropFullRes)
                            if Self.verboseLogging { print("  ·  [\(n)] no match  d=\(String(format: "%.3f", distance)) cut=\(String(format: "%.2f", cutoff))  \(px) \(orient)  face=\(facePixels)px joints=\(body.lowerJoints)  [\(scores)]") }
                        } else if self?.isSensitiveContent(image) == true {
                            sensitiveSkipped += 1
                            eval.note(asset, image: image, rotated: wasRotated, gate: .sensitive, distance: distance,
                                      type: type, body: body, metrics: metrics,
                                      fullRes: self?.lastCropFullRes)
                            if Self.verboseLogging { print("  \u{1f6ab} [\(n)] sensitive content — skipped   \(px) \(orient)") }
                        } else if let why = unusable {
                            // Before sizing: nothing is fetched for a photo that
                            // will not be shown.
                            unusableFace += 1
                            eval.note(asset, image: image, rotated: wasRotated, gate: .unusableFace, distance: distance,
                                      type: type, body: body, metrics: metrics,
                                      fullRes: self?.lastCropFullRes, score: museScore)
                            if Self.verboseLogging { print("  \u{1f648} [\(n)] unusable face — \(why)  d=\(String(format: "%.3f", distance)) type=\(type.rawValue)  \(px) \(orient)  \(museScore?.note ?? "")") }
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
                                return (.tooLarge, "original over \(Original.byteCap / 1_048_576)MB")
                            case .unavailable(let reason):
                                downloadedToSize += 1
                                noOriginal += 1
                                return (.noOriginal, "original \(reason.rawValue)")
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
                            matchScores[asset.localIdentifier] = (distance, type, museScore?.value)
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
                                                                   // Lower is closer; the page falls back to
                                                                   // it when no score is sent.
                                                                   "distance": distance,
                                                                   // Same for every photo that repeats one shot;
                                                                   // the page pre-selects one per group.
                                                                   "dupGroup": dupGroup,
                                                                   "done": n,
                                                                   "total": total]
                                // Higher is better. The page pre-selects the top of each type by it.
                                if let museScore { matchPayload["score"] = museScore.value }
                                DispatchQueue.main.async {
                                    self?.sendToWeb(["type": "onGalleryMatchFound", "payload": matchPayload])
                                }
                            }
                            if Self.verboseLogging { print("  ✅ [\(n)] MATCH\(held ? " (held)" : "")     d=\(String(format: "%.3f", distance)) cut=\(String(format: "%.2f", cutoff))  \(px) \(orient)  face=\(facePixels)px joints=\(body.lowerJoints)\(body.byKnees ? " knee-length" : "") type=\(type.rawValue) shoulders=\(body.shoulderSpread.map { String(format: "%.2f (~%.0f°)", $0, Self.turnDegrees(spread: $0)) } ?? "–") original=\((originalBytes ?? 0) / 1024)KB  [\(scores)]  \(museScore?.note ?? "")") }
                        }
                    }

            }

            for index in 0..<total {
                // Abandons the scan outright: a superseded scan that still reported
                // would overwrite the live one.
                guard self?.scanGeneration == generation else {
                    print("\u{1f6d1} Scan superseded — stopping at \(index) of \(total)")
                    return
                }

                autoreleasepool {
                    let asset = assets.object(at: index)
                    let n = index + 1

                    examined += 1

                    guard let image = self?.loadPhoto(asset: asset) else {
                        let note = self?.lastLoadNote ?? ""
                        if note.hasPrefix("in iCloud") { cloudOnly += 1 }
                        // A selfie-shaped thumbnail is worth a small download; the
                        // verdict waits for the iCloud pass. Anything else is skipped.
                        if let thumb = self?.lastLoadThumbnail, self?.isSelfieShaped(thumb) == true {
                            cloudCandidates.append((asset, n))
                            if Self.verboseLogging { print("  ☁️  [\(n)] in iCloud — looks like a selfie, queued for download") }
                            return
                        }
                        noImage += 1
                        eval.note(asset, image: nil, gate: .noImage)
                        if Self.verboseLogging { print("  ⃠  [\(n)] no local image — \(note)") }
                        return
                    }
                    examine(asset, image, n: n)

                    // Throttled by time, not photo count: per-photo cost varies too
                    // much for "every Nth" to give a predictable update rate.
                    if Date().timeIntervalSince(lastReport) > 0.25 || n == total {
                        lastReport = Date()
                        DispatchQueue.main.async {
                            self?.sendToWeb(["type": "onGalleryScanProgress",
                                             "payload": ["done": n, "total": total]])
                        }
                    }
                }
            }

            // ---- iCloud pass -------------------------------------------------
            // Selfie-shaped thumbnails, downloaded small; Wi-Fi only, capped by count and time.
            var cloudDownloaded = 0
            var cloudFailed = 0
            var cloudLeft = 0
            var cloudSeconds = 0.0
            let cloudAllowed = Self.cloudDownloadsAllowed
            let cloudStarted = Date()
            if !cloudCandidates.isEmpty && !cloudAllowed {
                print("☁️  \(cloudCandidates.count) iCloud selfie(s) not downloaded — not on Wi-Fi, or Low Data Mode is on")
            }
            for candidate in cloudCandidates {
                guard self?.scanGeneration == generation else {
                    print("\u{1f6d1} Scan superseded — stopping in the iCloud pass")
                    return
                }
                let withinBudget = Date().timeIntervalSince(cloudStarted) < Self.cloudTimeBudget
                guard cloudAllowed, withinBudget, cloudDownloaded + cloudFailed < Self.cloudDownloadCap else {
                    cloudLeft += 1
                    noImage += 1
                    eval.note(candidate.asset, image: nil, gate: .noImage)
                    continue
                }
                autoreleasepool {
                    let started = Date()
                    let image = self?.loadFromCloud(asset: candidate.asset, pixels: Self.cloudPixels, timeout: Self.cloudTimeout)
                    cloudSeconds += Date().timeIntervalSince(started)
                    guard let image else {
                        cloudFailed += 1
                        noImage += 1
                        eval.note(candidate.asset, image: nil, gate: .noImage)
                        if Self.verboseLogging { print("  ☁️  [\(candidate.n)] \(self?.lastLoadNote ?? "iCloud download failed")") }
                        return
                    }
                    cloudDownloaded += 1
                    if Self.verboseLogging, let cg = image.cgImage { print("  ☁️  [\(candidate.n)] downloaded \(cg.width)x\(cg.height) in \(String(format: "%.1f", Date().timeIntervalSince(started)))s") }
                    examine(candidate.asset, image, n: candidate.n)
                    // Keeps the page's stall timer quiet while this pass runs; the
                    // bar is already full, so only the message matters.
                    DispatchQueue.main.async {
                        self?.sendToWeb(["type": "onGalleryScanProgress",
                                         "payload": ["done": total, "total": total]])
                    }
                }
            }

            let elapsed = Date().timeIntervalSince(startedAt)
            let rate = Double(examined) / max(elapsed, 0.001)

            // The gap rule, decided with every distance in: matches above the gap
            // are withdrawn from the final list and named in `dropped`.
            var gapCut: Float?
            var gapDropped: [String] = []
            if let cut = Self.gapCut(distances: scoredDistances) {
                gapCut = cut
                gapDropped = matchedIds.filter { (matchScores[$0]?.distance ?? 0) >= cut }
                let droppedSet = Set(gapDropped)
                matchedIds.removeAll { droppedSet.contains($0) }
                for id in gapDropped {
                    if let score = matchScores[id] { found[score.type, default: 0] -= 1 }
                    if ScanAnalysisStore.analysis(for: id)?.body.byKnees == true { kneeLength -= 1 }
                }
                eval.regate(droppedSet, to: .gapCut)
                if Self.verboseLogging {
                    let scores = gapDropped.compactMap { matchScores[$0]?.distance }.sorted()
                        .map { String(format: "%.3f", $0) }.joined(separator: " ")
                    print("  ✂️  gap cut \(String(format: "%.3f", cut)) — withdrew \(gapDropped.count) match(es) scored above the gap  [\(scores)]")
                }
            }

            // The finished list is the streamed order, with the held-back matches
            // appended after it, so tiles only ever appear.
            let heldSet = Set(heldIds)
            let ordered = matchedIds.filter { !heldSet.contains($0) } + matchedIds.filter { heldSet.contains($0) }

            // Built here, off the main thread. The grid is passed in the order the
            // web will show it, because that order is what "the top" means.
            let evalReport = eval.finish(grid: ordered)

            DispatchQueue.main.async {
                guard self?.scanGeneration == generation else { return }

                print("""

                ==============================
                SCAN COMPLETE
                ==============================
                examined    \(examined) of \(total) in window
                reference   \(self?.lastReferenceNote ?? "")
                no image    \(noImage)   (in iCloud with no usable copy on the phone, or unreadable)
                local copy  \(localCopies)   (in iCloud, scanned from the phone's smaller copy)
                iCloud      \(cloudOnly) only in iCloud; \(cloudCandidates.count) looked like selfies; \(cloudDownloaded) downloaded in \(String(format: "%.1f", cloudSeconds))s, \(cloudFailed) failed, \(cloudLeft) left (cap \(Self.cloudDownloadCap), \(Int(Self.cloudTimeBudget))s, Wi-Fi only\(cloudAllowed ? "" : " — was not on Wi-Fi"))
                no face     \(noFace)
                group       \(groupSkipped)   (skipped: more than one face; \(sameShopper) more had several faces all the shopper's and went on)
                others      \(otherPeople)   (skipped: someone else in the photo)
                face small  \(tooSmall)   (under \(Int(Self.minFacePixels))px, even in the original)
                not full body \(notFullBody)   (neither head to toe: head, \(Self.minAnkles)+ ankle, \(Int(Self.minBodySpan * 100))% span or \(Int(Self.minBodySpanBothAnkles * 100))% with both ankles, feet in frame — nor head to knee: \(Self.minKnees)+ knee, \(Int(Self.minKneeSpan * 100))% span or \(Int(Self.minKneeSpanBothKnees * 100))% with both knees, knees \(String(format: "%.1f", Self.minKneeDrop)) torso below the hips)
                body retry  \(bodyRetried) re-checked at \(Int(Self.fullResPixels))px after a face match, \(bodyRescued) rescued
                no match    \(noMatch)
                gap cut     \(gapCut.map { String(format: "%.3f", $0) } ?? "none")   (\(gapDropped.count) withdrawn: matched under \(String(format: "%.2f", Self.matchThreshold)) but above the gap between the shopper's photos and the rest; \(heldIds.count) held back until the end, \(heldIds.count - gapDropped.count) of them shown)
                sensitive   \(sensitiveSkipped)   (matched, then filtered)
                unusable    \(unusableFace)   (matched, but the face is no use for the Muse: sunglasses, hand over it, eyes closed or a wink, cut by the frame, blurred)
                too large   \(tooLargeSkipped)   (original over \(Original.byteCap / 1_048_576)MB — hidden, nothing is sent compressed)
                no original \(noOriginal)   (original unreadable or not downloaded in time)
                low data    \(lowDataSkipped)   (only in iCloud, not downloaded — Low Data Mode is on)
                sized       \(sized) original(s), \(downloadedToSize) from iCloud, \(String(format: "%.1f", sizingSeconds))s
                duplicates  \(duplicates)   (matches that repeat an earlier one; shown, but only one of each is pre-selected)
                MATCHED     \(matchedIds.count)   (selfie \(found[.selfie, default: 0]), front \(found[.front, default: 0]), side \(found[.side, default: 0]); \(kneeLength) in on the knee rule)
                elapsed     \(String(format: "%.1f", elapsed))s  (\(String(format: "%.0f", rate))/s)
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
                summary["gapDropped"] = gapDropped.count
                summary["gapHeld"] = heldIds.count
                summary["sensitive"] = sensitiveSkipped
                summary["unusableFace"] = unusableFace
                summary["duplicates"] = duplicates
                summary["tooLarge"] = tooLargeSkipped
                summary["noOriginal"] = noOriginal
                summary["lowData"] = lowDataSkipped
                summary["matched"] = matchedIds.count
                summary["matchedSelfie"] = found[.selfie, default: 0]
                summary["matchedFront"] = found[.front, default: 0]
                summary["matchedSide"] = found[.side, default: 0]
                summary["kneeLength"] = kneeLength
                summary["model"] = Self.faceModel.rawValue
                summary["cutoff"] = Self.matchThreshold
                summary["frames"] = self?.lastReferenceFrames ?? 1
                summary["chosenFrame"] = (self?.lastReferenceIndex ?? 0) + 1
                summary["referenceQuality"] = self?.lastReferenceQuality
                summary["elapsedMs"] = Int(elapsed * 1000)
                summary["photosPerSecond"] = Int(rate)
                summary["inCloud"] = cloudOnly
                summary["cloudSelfies"] = cloudCandidates.count
                summary["cloudDownloaded"] = cloudDownloaded
                summary["cloudFailed"] = cloudFailed
                summary["cloudLeft"] = cloudLeft

                // The held-back matches, streamed now that the cut is known, so the
                // page learns their type and distance for pre-selection.
                for id in ordered where heldSet.contains(id) {
                    guard let score = matchScores[id] else { continue }
                    var heldPayload: [String: Any] = ["assetId": id,
                                                      "type": score.type.rawValue,
                                                      "isFullBody": ScanAnalysisStore.analysis(for: id)?.body.isHeadToToe ?? true,
                                                      "distance": score.distance,
                                                      "dupGroup": dupGroups[id] ?? id,
                                                      "done": total,
                                                      "total": total]
                    if let value = score.score { heldPayload["score"] = value }
                    self?.sendToWeb(["type": "onGalleryMatchFound", "payload": heldPayload])
                }

                self?.sendToWeb(["type": "onGalleryScanComplete",
                                 "payload": ["assetIds": ordered,
                                             // Matches the page may already show that the
                                             // gap rule withdrew — see `gapCutEnabled`.
                                             "dropped": gapDropped,
                                             "limited": self?.isLimitedAccess ?? false,
                                             // What the scan could not look at, for
                                             // analytics — the page shows none of it.
                                             "skipped": ["inCloud": cloudOnly,
                                                         "cloudSelfies": cloudCandidates.count,
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
    /// What the shopper wears — see `outfitMultiplier`.
    struct Outfit {
        /// The strongest of `dressyLabels` over the whole photo, if any.
        let label: String?
        let dressy: Float
        /// Edge density of the clothing below the face, 0–1.
        let busy: Float
    }
    let outfit: Outfit
    let dressy: Bool
    let busy: Bool

    /// Apple's capture quality carries the most; the three expression terms together
    /// carry 0.35, which puts a neutral face above a smile, stare or wink.
    static let weights: [(name: String, weight: Float)] = [
        ("quality", 0.25), ("pose", 0.15), ("light", 0.10), ("size", 0.10),
        ("mouth", 0.15), ("eyes", 0.10), ("brow", 0.10), ("sharp", 0.05),
    ]

    /// Classifier confidence for sunglasses (filtered) and caps (ranked lower). Clear
    /// glasses read as eyeglasses, not sunglasses.
    static let sunglassesConfidence: Float = 0.4
    static let hatConfidence: Float = 0.5
    static let hatLabels: Set<String> = ["hat", "baseball_hat", "sunhat", "cowboy_hat", "beanie", "helmet", "hardhat"]
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
         outfit: Outfit = Outfit(label: nil, dressy: 0, busy: 0)) {
        let clamp = { (v: Float) in max(0, min(1, v)) }
        var parts: [(name: String, value: Float)] = []
        var filter: String?
        var smile = Smile.none
        var wideEyed = false
        var lowered: [String] = []

        // What covers the face. Sunglasses and a hand rule the photo out of the
        // ranking; a cap only pulls it down — see `capMultiplier`.
        if (labels["sunglasses"] ?? 0) >= Self.sunglassesConfidence { filter = "sunglasses" }
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
            if f.mean < 0.08 || f.mean > 0.92 { lowered.append("exposure") }
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
            } else if e.jawOpen >= Self.mouthOpenFilter { lowered.append("mouth open") }
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

        // Sharpness on a log scale: variance 1e-3 scores 0, 3e-2 scores 1 — see
        // `blurVariance` for where real faces land.
        let sharp = faceStats.map { clamp((log10(max($0.laplacian, 1e-8)) + 3) / 1.5) } ?? 0.5
        parts.append(("sharp", sharp))

        self.parts = parts
        self.filter = filter
        self.expression = expression
        self.labels = labels
        self.handOnFace = handOnFace
        self.capped = capped
        self.smile = smile
        self.wideEyed = wideEyed
        self.lowered = lowered
        self.outfit = outfit
        let dressy = outfit.dressy >= Self.dressyConfidence
        let busy = outfit.busy >= Self.busyTorso
        self.dressy = dressy
        self.busy = busy
        let weighted = zip(Self.weights, parts).reduce(0) { $0 + $1.0.weight * $1.1.value }
        // Two bands, so a clean face always ranks above a demoted one: clean photos
        // score 0.5–1, demoted ones 0–0.5. The outfit only moves a photo within its band.
        var multiplier: Float = 1
        if capped { multiplier *= Self.capMultiplier }
        if smile == .closed { multiplier *= Self.closedSmileMultiplier }
        if smile == .open { multiplier *= Self.openSmileMultiplier }
        if wideEyed { multiplier *= Self.wideEyedMultiplier }
        for _ in lowered { multiplier *= Self.loweredMultiplier }
        let demoted = multiplier < 1
        self.demoted = demoted
        if dressy { multiplier *= Self.outfitMultiplier }
        if busy { multiplier *= Self.outfitMultiplier }
        let banded = demoted ? 0.5 * weighted * multiplier : 0.5 + 0.5 * weighted * multiplier
        self.value = filter == nil ? banded : 0
    }

    /// For the console: the value, then every part, or the filter that zeroed it.
    var note: String {
        let seen = labels.filter { $0.value >= 0.3 }.sorted { $0.value > $1.value }.prefix(2)
            .map { String(format: "%@ %.2f", $0.key, $0.value) }.joined(separator: " ")
        let extras = [expression?.note, seen.isEmpty ? nil : "labels " + seen, handOnFace ? "hand on face" : nil, capped ? "cap ×\(Self.capMultiplier)" : nil, smile == .closed ? "closed smile ×\(Self.closedSmileMultiplier)" : nil, smile == .open ? "open smile ×\(Self.openSmileMultiplier)" : nil, wideEyed ? "wide-eyed ×\(Self.wideEyedMultiplier)" : nil, lowered.isEmpty ? nil : lowered.map { "\($0) ×\(Self.loweredMultiplier)" }.joined(separator: "; "),
                      dressy ? "\(outfit.label ?? "dressy") \(String(format: "%.2f", outfit.dressy)) ×\(Self.outfitMultiplier)" : nil,
                      busy ? "busy torso \(String(format: "%.2f", outfit.busy)) ×\(Self.outfitMultiplier)" : nil]
            .compactMap { $0 }.joined(separator: "; ")
        if let filter { return String(format: "score=0 (%@)%@", filter, extras.isEmpty ? "" : "  " + extras) }
        let detail = parts.map { String(format: "%@ %.2f", $0.name, $0.value) }.joined(separator: " ")
        return String(format: "score=%.2f [%@]%@", value, detail, extras.isEmpty ? "" : "  " + extras)
    }

    /// The head crop for the expression reader and classifier: the face box with hair
    /// and cap brim inside it. Normalised, bottom-left origin, clipped to the image.
    static func headBox(_ face: CGRect) -> CGRect {
        CGRect(x: face.minX - face.width * 0.6, y: face.minY - face.height * 0.5, width: face.width * 2.2, height: face.height * 2.4)
            .intersection(CGRect(x: 0, y: 0, width: 1, height: 1))
    }

    /// Luminance and colour statistics of one region, from a small square copy:
    /// mean, clipping, half means, average colour and Laplacian variance.
    static func stats(of image: CGImage, region: CGRect, side: Int) -> (mean: Float, clipped: Float, left: Float, right: Float, r: Float, g: Float, b: Float, laplacian: Float)? {
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
        var sumR: Float = 0, sumG: Float = 0, sumB: Float = 0, clipped: Float = 0, left: Float = 0, right: Float = 0
        for i in 0..<(side * side) {
            let r = Float(pixels[i * 4]) / 255, g = Float(pixels[i * 4 + 1]) / 255, b = Float(pixels[i * 4 + 2]) / 255
            let y = 0.299 * r + 0.587 * g + 0.114 * b
            lum[i] = y; sumR += r; sumG += g; sumB += b
            if y > 0.96 || y < 0.04 { clipped += 1 }
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
        return (mean: (sumR * 0.299 + sumG * 0.587 + sumB * 0.114) / n, clipped: clipped / n,
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
                       fullRes: Bool? = nil, originalBytes: Int? = nil, score: MuseScore? = nil) {
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
            score: score
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
                              renderWidth: r.renderWidth, originalBytes: r.originalBytes, score: r.score)
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
            let bodySays = r.type == .front || r.type == .side
                ? "sh \((r.body?.shoulderSpread.map { String(format: "%.2f", $0) } ?? "?").padding(toLength: 7, withPad: " ", startingAt: 0))"
                : "          "
            return "  tile \(String(index + 1).padding(toLength: 3, withPad: " ", startingAt: 0)) \(who)  \(kind) d \(score)  \(bodySays)  \(r.fullRes == true ? "re-cropped" : "          ")  \(where_(r))"
        }
        // The shoulders decide the type; the head turn is logged beside them to see how
        // often it would have disagreed. Only full-length photos that reached scoring.
        let fullLength = scored.filter { $0.type == .front || $0.type == .side }
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
        var lines = ["id,gate,labelled,gridRank,distance,type,joints,ankles,headSeen,span,footRoom,people,shoulders,hips,headSays,faceRatio,yaw,pitch,quality,rotated,screenshot,fullRes,taken,original,renderWidth,originalKB,score,sQuality,sPose,sLight,sSize,sMouth,sEyes,sBrow,sSharp,sFilter,exprSmile,exprJaw,exprBlinkL,exprBlinkR,exprBrow,exprSquint,exprWide,exprTeeth,sunglasses,hat,handOnFace,capped,smile,wideEyed,lowered,dressy,busy,outfitLabel"]
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
            let scoreParts: [String] = MuseScore.weights.map { w in number(record.score?.parts.first { $0.name == w.name }.map { Double($0.value) }) }
            let exprFields: [String] = [
                number(expr.map { Double($0.smile) }), number(expr.map { Double($0.jawOpen) }),
                number(expr.map { Double($0.blinkLeft) }), number(expr.map { Double($0.blinkRight) }),
                number(expr.map { Double($0.browUp) }), number(expr.map { Double($0.squint) }),
                number(expr.map { Double($0.eyeWide) }), number(expr.map { Double($0.teeth) }),
            ]
            let flagFields: [String] = [
                number(record.score?.labels["sunglasses"].map { Double($0) }), number(hat.map { Double($0) }),
                record.score.map { String($0.handOnFace) } ?? "", record.score.map { String($0.capped) } ?? "",
                record.score?.smile.rawValue ?? "", record.score.map { String($0.wideEyed) } ?? "", record.score?.lowered.joined(separator: " ") ?? "",
                number(record.score.map { Double($0.outfit.dressy) }), number(record.score.map { Double($0.outfit.busy) }),
                record.score?.outfit.label ?? "",
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

    /// Enough of the body for the Muse: head to toe, or head to knee (see
    /// `minKnees`). The web receives it as `isFullBody`.
    var isHeadToToe: Bool { isHeadToAnkle || isHeadToKnee }

    /// In only on the knee rule — counted so the scan summary says how many.
    var byKnees: Bool { !isHeadToAnkle && isHeadToKnee }
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

    /// How long the scan waits to size one iCloud-only original; a photo that cannot
    /// be sized in time is hidden.
    static let sizeTimeout: DispatchTimeInterval = .seconds(10)

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

        let faceRequest = VNDetectFaceRectanglesRequest()

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

        let turn = yaw.map { String(format: "%.3f", $0) } ?? "n/a"
        print("🔬 FACE \(String(format: "%.2f", ratio)) of frame, yaw \(turn), joints \(body.lowerJoints)/4, head to toe \(body.isHeadToToe)")

        // The decision itself lives in one place, shared with the scan.
        return Self.photoType(faceRatio: ratio, yaw: yaw, body: body)
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
    static let loadPixels: CGFloat = 2048

    /// A face narrower than this, in the scan's render, is embedded from a larger
    /// render, where the landmarks align better. In practice full-length photos.
    static let fullResFaceBelow: CGFloat = 224

    /// The size of that second render. Capped rather than the whole original: a 48MP
    /// photo decoded in full is about 190MB, and this happens in the middle of a scan.
    static let fullResPixels: CGFloat = 4096

    /// Loads a photo at `loadPixels`, network off. For an iCloud-only photo a second
    /// request takes the phone's smaller copy, unless under `minLocalCopyPixels`.
    func loadPhoto(asset: PHAsset, pixels: CGFloat = ViewController.loadPixels) -> UIImage? {
        lastLoadLocalCopy = false
        lastLoadThumbnail = nil
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
            lastLoadNote = inCloud ? "in iCloud, no copy on the phone" : "not flagged as iCloud"
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
                    lastLoadLocalCopy = true
                } else {
                    lastLoadNote = "in iCloud, phone copy only \(longest)px — under \(Self.minLocalCopyPixels)"
                    lastLoadThumbnail = best
                }
            }
        }

        lastLoadRotated = result.map { $0.imageOrientation != .up } ?? false
        return result.map(Self.upright)
    }

    /// Downloads a reduced copy of a photo whose full version is in iCloud. Only
    /// the iCloud pass calls this; asynchronous so the wait can be bounded.
    func loadFromCloud(asset: PHAsset, pixels: CGFloat, timeout: DispatchTimeInterval) -> UIImage? {
        lastLoadLocalCopy = false
        lastLoadThumbnail = nil
        let options = PHImageRequestOptions()
        options.deliveryMode = .highQualityFormat
        options.resizeMode = .exact
        options.isNetworkAccessAllowed = true
        options.isSynchronous = false

        let done = DispatchSemaphore(value: 0)
        var result: UIImage?
        let request = PHImageManager.default().requestImage(for: asset, targetSize: CGSize(width: pixels, height: pixels),
                                                            contentMode: .aspectFit, options: options) { image, info in
            // High quality delivers once, when it is final.
            if info?[PHImageResultIsDegradedKey] as? Bool != true {
                result = image
                done.signal()
            }
        }
        if done.wait(timeout: .now() + timeout) == .timedOut {
            PHImageManager.default().cancelImageRequest(request)
            lastLoadNote = "iCloud download timed out"
            return nil
        }
        if result == nil { lastLoadNote = "iCloud download failed" }
        lastLoadRotated = result.map { $0.imageOrientation != .up } ?? false
        return result.map(Self.upright)
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
    func museContext(face: VNFaceObservation, in image: CGImage, handler: VNImageRequestHandler)
        -> (expression: FaceExpression?, labels: [String: Float], handOnFace: Bool, outfit: MuseScore.Outfit) {
        let head = MuseScore.headBox(face.boundingBox)
        let w = CGFloat(image.width), h = CGFloat(image.height)
        let headRect = CGRect(x: head.minX * w, y: (1 - head.maxY) * h, width: head.width * w, height: head.height * h).integral
        let headCrop = image.cropping(to: headRect)

        var labels: [String: Float] = [:]
        var expression: FaceExpression?
        if let headCrop {
            let classify = VNClassifyImageRequest()
            try? VNImageRequestHandler(cgImage: headCrop, orientation: .up, options: [:]).perform([classify])
            for result in classify.results ?? [] where result.confidence >= 0.1 {
                let name = result.identifier
                if name == "sunglasses" || name == "eyeglasses" || MuseScore.hatLabels.contains(name) { labels[name] = result.confidence }
            }
            expression = FaceExpression.read(headCrop: headCrop)
        }

        // Hands anywhere in the render; one with most of its points on the face
        // is over it. Skin-coloured, so no colour check would see it.
        let hands = VNDetectHumanHandPoseRequest()
        hands.maximumHandCount = 2
        try? handler.perform([hands])
        let zone = face.boundingBox.insetBy(dx: -face.boundingBox.width * 0.15, dy: -face.boundingBox.height * 0.15)
        let handOnFace = (hands.results ?? []).contains { hand in
            guard let points = try? hand.recognizedPoints(.all) else { return false }
            return points.values.filter { $0.confidence > 0.3 && zone.contains($0.location) }.count >= MuseScore.handPointsOnFace
        }

        // The outfit (see `MuseScore.outfitMultiplier`): formal-wear labels over the
        // whole render, busyness from the clothing below the face.
        let whole = VNClassifyImageRequest()
        try? handler.perform([whole])
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
            busy = MuseScore.busyness(of: torsoCrop)
        }
        return (expression, labels, handOnFace, MuseScore.Outfit(label: dressyLabel, dressy: dressy, busy: busy))
    }

    func matchPerson(in image: UIImage, asset: PHAsset) -> PhotoOutcome {
        lastFaceMetrics = nil
        lastCropFullRes = false
        // Cleared first, not after the body check: a photo that leaves early — no
        // face, a group — must not carry the previous photo's retry into the log.
        lastBodyRetry = nil
        guard let reference = referenceEmbedding, let recognizer = Self.faceRecognizer,
              let cgImage = image.cgImage else { return .noFace }

        let request = VNDetectFaceRectanglesRequest()
        let handler = VNImageRequestHandler(
            cgImage: cgImage,
            orientation: Self.cgOrientation(image.imageOrientation),
            options: [:]
        )
        try? handler.perform([request])

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
            for face in faces {
                guard let candidate = recognizer.embedding(in: cgImage, near: face.boundingBox),
                      FaceRecognizer.distance(reference, candidate) < Self.matchThreshold
                else { return .group(faceCount: faces.count) }
            }
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
                largerCache = loadPhoto(asset: asset, pixels: Self.fullResPixels)?.cgImage
                    .flatMap { $0.width > cgImage.width ? $0 : nil }
            }
            return largerCache
        }

        // The larger render is loaded only when the original is big enough to clear
        // the floor, so a photo small in every copy costs nothing extra.
        let widestRatio = faces.map(\.boundingBox.width).max() ?? 0
        if widest < Self.minFacePixels {
            guard widestRatio * CGFloat(asset.pixelWidth) >= Self.minFacePixels,
                  let larger = largerRender(),
                  widestRatio * CGFloat(larger.width) >= Self.minFacePixels
            else { return .faceTooSmall(pixels: Int(widest)) }
        }

        // After the face gates on purpose: pose detection is the most expensive
        // request, so it runs only on photos with one usable face.
        var body = bodyCheck(in: cgImage, orientation: Self.cgOrientation(image.imageOrientation),
                             face: faces.first?.boundingBox)
        // Each reflection of the shopper has a body too; those are not other people.
        body.shopperFaces = lastShopperFaces

        // Distances of every face in `source` to the selfie; nil when none could be
        // embedded. Defined here so the full-body gate can ask first.
        func score(from source: CGImage) -> (distances: [Float], faceWidth: CGFloat)? {
            let faceWidth = faces.map { $0.boundingBox.width * CGFloat(source.width) }.max() ?? widest

            var distances: [Float] = []
            for face in faces {
                // Vision's boxes are normalised, so they fit the larger render unchanged.
                guard let candidate = recognizer.embedding(in: source, near: face.boundingBox) else { continue }
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
            return (distances, faceWidth)
        }

        // A selfie is recognised by shape before the full-body gate. Then only the
        // shopper in the photo: the person detector counts anyone, even back-on.
        if body.hasOthers {
            return .otherPeople(body: body)
        }

        let faceRatio = Self.faceRatio(boxWidth: faces.map(\.boundingBox.width).max() ?? 0, in: cgImage)
        let isSelfie = faceRatio >= Self.selfieFaceRatio
        if Self.requireFullBody && !isSelfie && !body.isHeadToToe {
            // Legs seen but not enough of them: one more look at the larger render,
            // only when the face already matches, so strangers cost nothing extra.
            guard body.headSeen, body.lowerJoints >= 1,
                  let quick = score(from: cgImage), (quick.distances.min() ?? 1) < Self.matchThreshold,
                  let larger = largerRender()
            else { return .notFullBody(body: body) }
            var again = bodyCheck(in: larger, orientation: .up, face: faces.first?.boundingBox)
            again.shopperFaces = lastShopperFaces
            let f = { (v: CGFloat) in String(format: "%.2f", v) }
            lastBodyRetry = ("re-checked at \(larger.width)x\(larger.height) after a face match (d \(String(format: "%.3f", quick.distances.min() ?? 1))): ankles \(body.ankles)→\(again.ankles), span \(f(body.span))→\(f(again.span)), feet room \(f(body.footRoom))→\(f(again.footRoom))",
                             again.isHeadToToe)
            if again.hasOthers { return .otherPeople(body: again) }
            guard again.isHeadToToe else { return .notFullBody(body: body) }
            body = again
        }

        // Free: the ratio, the body check and `yaw` are already in hand from the
        // match gates, so nothing is recomputed.
        let yaw = faces.first?.yaw?.doubleValue
        let type = Self.photoType(faceRatio: faceRatio, yaw: yaw, body: body)
        // The shoulders must have said side — a side by head turn alone does not count.
        let profile = type == .side && body.bodyFacing == .side && abs(yaw ?? 0) > Self.profileYaw

        // A small face is re-cropped from the larger render. Only photos past every
        // gate get here, a handful per scan; the face box is normalised, so it fits.
        var source = cgImage
        if widest < Self.fullResFaceBelow, let larger = largerRender() {
            source = larger
            lastCropFullRes = true
        }
        guard let scored = score(from: source) else { return .noFace }
        // Matches only — the rest never reach the grid, so their score is never
        // read. On the scan's render and its handler, not the larger crop.
        var museScore: MuseScore?
        if (scored.distances.min() ?? 1) < Self.matchThreshold {
            let context = museContext(face: faces[0], in: cgImage, handler: handler)
            museScore = MuseScore(face: faces[0], in: cgImage, handler: handler, faceWidth: widest,
                                  expression: context.expression, labels: context.labels, handOnFace: context.handOnFace,
                                  outfit: context.outfit)
        }
        return .scored(distances: scored.distances, facePixels: Int(scored.faceWidth), body: body, type: type, profile: profile, museScore: museScore)
    }

    /// How far outside the face box a body's head points may sit and still be that
    /// face's body. Generous, since a turned head moves the nose.
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
    func chooseReference(_ frames: [UIImage]) -> (image: UIImage, index: Int, note: String, quality: Float?) {
        guard frames.count > 1 else { return (frames[0], 0, "1 frame", nil) }

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
        return (frames[best], best, "\(frames.count) frames, quality \(scores) → frame \(best + 1)\(best == frames.count - 1 ? " (tapped)" : "")", qualities[best])
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
