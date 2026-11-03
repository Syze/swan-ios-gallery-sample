// Swan Gallery Pick — starting a library scan: the reference selfie, photo access, the fetch, original sizing, sensitive content.

import UIKit
import Photos
import Vision
import SensitiveContentAnalysis

extension ViewController {

    /// Builds the reference face from the selfie frames off the main thread, then
    /// asks for photo access. The sharpest frame becomes the reference.
    func startGalleryScan(monthsBack: Int, referenceImage: String?, referenceImages: [String]? = nil) {
        // Fail fast: without a usable reference the scan would report a confident zero.
        guard let reference = referenceImage else {
            print("🚫 No reference image in payload")
            sendScanError("no-reference")
            return
        }

        // Whatever the web side did or did not send, a scan always begins clean.
        resetScanState()

        // Show the photo-access prompt now, while the reference is built behind it.
        // `requestAccessAndScan` asks again later; by then the answer is known.
        if PHPhotoLibrary.authorizationStatus(for: .readWrite) == .notDetermined {
            PHPhotoLibrary.requestAuthorization(for: .readWrite) { _ in }
        }

        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self = self else { return }

            // Up to three frames from `referenceImages`, else the single `referenceImage`.
            let sent = referenceImages ?? []
            let frameURIs = Array((sent.isEmpty ? [reference] : sent).prefix(3))
            let frames = frameURIs.compactMap { Self.image(fromDataURI: $0) }

            guard !frames.isEmpty else {
                print("🚫 Reference image could not be decoded")
                DispatchQueue.main.async { self.sendScanError("no-reference") }
                return
            }

            let chosen = self.chooseReference(frames)
            let selfie = chosen.image
            self.lastReferenceFrames = frames.count
            self.lastReferenceIndex = chosen.index
            self.lastReferenceQuality = chosen.quality
            self.lastReferenceQualities = chosen.qualities
            self.lastReferenceSpread = nil
            self.lastReferenceShift = nil

            // Too blurred to be the reference — see `selfieMinQuality`. Checked only
            // when a quality was measured; a single frame has none.
            if let quality = chosen.quality, quality < Self.selfieMinQuality {
                DispatchQueue.main.async { self.sendScanError("selfie-too-blurry") }
                return
            }

            // One face, looking at the camera — see `selfieMaxYawDegrees`. Otherwise the
            // page returns to the selfie screen with the reason and no reference is kept.
            if let rejection = self.selfieRejection(in: selfie) {
                DispatchQueue.main.async { self.sendScanError(rejection.error) }
                return
            }

            guard let recognizer = Self.faceRecognizer else {
                DispatchQueue.main.async { self.sendScanError("matcher-unavailable") }
                return
            }

            // The selfie is the reference: its face aligned and embedded exactly
            // like every library face, by `FaceRecognizer`.
            guard let selfieCG = selfie.cgImage,
                  let embedding = recognizer.embedding(in: selfieCG) else {
                DispatchQueue.main.async { self.sendScanError("no-face-in-selfie") }
                return
            }
            self.referenceEmbedding = embedding

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
                }
                self.lastReferenceBlended = used.count
            }


            // The expression reader and hand detector load on first use; paid here
            // rather than on the first match. Nothing is kept from either pass.
            FaceExpression.warmUp()
            if Self.coverReadEnabled { FaceCover.warmUp() }
            if Self.fullLengthScoreV2 && Self.objectReadEnabled { BodyObjects.warmUp() }
            let warmHands = VNDetectHumanHandPoseRequest()
            try? VNImageRequestHandler(cgImage: selfieCG, orientation: .up, options: [:]).perform([warmHands])

            DispatchQueue.main.async { self.requestAccessAndScan(monthsBack: monthsBack) }
        }
    }

    /// Ends the scan before it starts: an empty `onGalleryScanComplete` naming `error`.
    func sendScanError(_ error: String) {
        sendToWeb(["type": "onGalleryScanComplete", "payload": ["assetIds": [], "error": error]])
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
                    self.isLimitedAccess = true
                    self.scanAssets(monthsBack: monthsBack)
                default:
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
    /// Data Mode. Off hides such photos as "low data".
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

    /// Fetches every photo inside `monthsBack` and runs a `LibraryScan` over them
    /// on a background queue.
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

        // The shopper's own library only (no shared albums), and no screenshots.
        // Screenshots are filtered in code: PhotoKit reads a mediaSubtypes predicate
        // as "no subtype bits at all" and would drop ordinary photos too.
        options.includeAssetSourceTypes = [.typeUserLibrary]
        var assets: [PHAsset] = []
        var screenshots = 0
        PHAsset.fetchAssets(with: .image, options: options).enumerateObjects { asset, _, _ in
            if asset.mediaSubtypes.contains(.photoScreenshot) { screenshots += 1 } else { assets.append(asset) }
        }
        let total = assets.count

        guard total > 0 else {
            sendToWeb(["type": "onGalleryScanComplete",
                       "payload": ["assetIds": [], "limited": isLimitedAccess]])
            return
        }

        let startedAt = Date()

        // Captured once. Anything that resets the flow — a reload, a new scan,
        // starting over — moves scanGeneration past this and ends the loop below.
        let generation = scanGeneration

        // What earlier scans learned about this account's photos — see `ScanStore`.
        scanStore = ScanStore.open(for: session?.email ?? "")
        // Captured for this scan: a scan started on top of this one opens its own,
        // and the two never share a dictionary.
        let store = scanStore

        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            LibraryScan(controller: self, assets: assets, monthsBack: monthsBack, generation: generation,
                        store: store, startedAt: startedAt).run()
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
