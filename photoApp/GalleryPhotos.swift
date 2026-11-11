// Swan Gallery Pick — photos served to the page: thumbnails, originals, captures and analysis.

import UIKit
import Photos
import WebKit
import Vision

// MARK: - Scan analysis

/// What the scan worked out about one photo, kept so it need not be worked out twice.
struct ScanAnalysis {
    let type: PhotoType
    let body: BodyCheck
}

/// What pose detection found of one person's body, and the verdict drawn from it,
/// so the scan, the tap and `isFullBody` all read the same rule.
struct BodyCheck {
    /// Knees and ankles seen, 0–4. Sent to the page as `lowerBodyJoints`.
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

    /// How many of the faces in the photo are the shopper's — above 1 in a mirror
    /// shot, where each reflection also has a body. See `sameShopperFacesMax`.
    var shopperFaces = 1

    /// Someone besides the shopper is in the photo. One rule for the scan gate and
    /// what the web is told as `otherPeople`, so a photo cannot pass one and fail the other.
    var hasOthers: Bool { people > max(1, shopperFaces) }

    /// Shoulder width across the photo against the torso's length; low when side-on.
    /// Nil when the joints were not found.
    let shoulderSpread: CGFloat?

    /// No body found: nothing seen, with `people` counted by the person detector.
    static func unseen(people: Int) -> BodyCheck {
        BodyCheck(lowerJoints: 0, ankles: 0, headSeen: false, span: 0, footRoom: 0, people: people, shoulderSpread: nil)
    }

    /// Head to toe: head in frame, enough ankles, a body tall enough to be the
    /// subject, and room below the ankles for the feet.
    var isHeadToAnkle: Bool {
        let needed = ankles >= 2 ? ViewController.minBodySpanBothAnkles : ViewController.minBodySpan
        return headSeen && ankles >= ViewController.minAnkles && span >= needed
            && footRoom >= ViewController.minFootRoom * span
    }

    /// Enough of the body for the Muse: head to toe. Sent to the page as `isFullBody`.
    var isHeadToToe: Bool { isHeadToAnkle }
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

// MARK: - Captured photos

/// Photos taken inside the flow, held in memory as `Data` and never written to the
/// photo library; a dozen decoded captures in the web view would crash its process.
enum CaptureStore {

    /// How many photos the flow will hold. Generous for five slots with retakes,
    /// low enough that the store stays a rounding error against the app's budget.
    static let limit = 12

    /// Original capture JPEGs by id. `Data`, never `UIImage`: twelve decoded
    /// captures would be 120MB.
    private static var held: [String: Data] = [:]

    /// Reads and writes arrive on different queues; held only across the dictionary
    /// access, decoding happens outside.
    private static let lock = NSLock()

    /// False when the store is full. Refusing beats evicting a photo that is still
    /// on screen looking selectable.
    static func store(_ data: Data, id: String) -> Bool {
        lock.lock(); defer { lock.unlock() }
        guard held[id] != nil || held.count < limit else { return false }
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

/// JPEG renders for both delivery paths (custom scheme and base64 fallback), so a
/// photo looks identical however it arrives.
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
            if rendered == nil { print("  ❌ capture render FAILED \(localIdentifier) at \(Int(maxPixel))px") }
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
            // `.aspectFit` at every size: `.aspectFill` would crop the legs off a
            // full-length photo.
            contentMode: .aspectFit,
            options: options
        ) { image, _ in
            data = image?.jpegData(compressionQuality: quality)
        }
        return data
    }
}

// MARK: - Originals

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
            // Past the cap these bytes will never be sent, so they are dropped.
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

    /// How long the scan waits to size one iCloud-only original. Matches `cloudTimeout`,
    /// since a single iCloud copy can take several seconds.
    static let sizeTimeout: DispatchTimeInterval = .seconds(20)
    /// When sizing times out, a matched photo is still shown if its pixel count says the
    /// original cannot be over `byteCap`. The upload fetches it later with its own retry.
    static let sizeByPixelsWhenSlow = true
    /// Under this a camera HEIC or JPEG is a few MB; 48MP shots and ProRAW sit above.
    /// 30, not 24: a phone's "24MP" photo is slightly over 24 megapixels.
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

    /// What the camera wrote about itself, for the selfie gates: whether there is any
    /// camera data (`noCameraDataGateEnabled`) and the 35 mm-equivalent focal length (`tooCloseCm`).
    struct Camera {
        let present: Bool
        let focal35mm: Float?
        /// The lens's own focal length. Without a 35 mm equivalent the sensor size is
        /// unknown, so no distance is read from it.
        let focalMm: Float?
        /// ISO and shutter time (seconds). The phone brightens a face shot in the dark,
        /// so these, not the face, show the low light (see `lowLightISO`).
        let iso: Float?
        let exposure: Float?
        /// The lens's tilt in degrees, + pointing up, from the phone's gravity reading (Apple
        /// maker note key 8). Nil without it (see `headLevelGateEnabled`).
        let tiltUp: Float?
    }
    /// How long `camera(for:)` waits for the file on the phone.
    static let headerTimeout: DispatchTimeInterval = .seconds(2)

    /// Reads the original's metadata from the phone, network off: an iCloud-only original
    /// gives nil. Reads up to `byteCap`, since a HEIC cut short loses its EXIF to ImageIO.
    static func camera(for asset: PHAsset) -> Camera? {
        let resources = PHAssetResource.assetResources(for: asset)
        // The original first: an edit saved by another app can drop the metadata,
        // and an edited photo must not fail the no-camera-data gate.
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
        guard !bytes.isEmpty, let properties = properties(of: bytes, complete: whole) else { return nil }
        let exif = properties[kCGImagePropertyExifDictionary] as? [CFString: Any]
        let tiff = properties[kCGImagePropertyTIFFDictionary] as? [CFString: Any]
        let focal35 = (exif?[kCGImagePropertyExifFocalLenIn35mmFilm] as? NSNumber)?.floatValue
        let model = (tiff?[kCGImagePropertyTIFFModel] as? String) ?? (tiff?[kCGImagePropertyTIFFMake] as? String)
        let focalMm = (exif?[kCGImagePropertyExifFocalLength] as? NSNumber)?.floatValue
        let iso = ((exif?[kCGImagePropertyExifISOSpeedRatings] as? [NSNumber])?.first)?.floatValue
        let exposure = (exif?[kCGImagePropertyExifExposureTime] as? NSNumber)?.floatValue
        // The front camera looks out of the screen (+z), the back camera out of the back (−z).
        let lens = (exif?[kCGImagePropertyExifLensModel] as? String)?.lowercased() ?? ""
        let maker = properties[kCGImagePropertyMakerAppleDictionary] as? [String: Any]
        var tiltUp: Float?
        if let g = (maker?["8"] as? [NSNumber])?.map(\.floatValue), g.count >= 3, lens.contains("front") || lens.contains("back") {
            let length = (g[0] * g[0] + g[1] * g[1] + g[2] * g[2]).squareRoot()
            let along = lens.contains("front") ? -g[2] : g[2]
            if length > 0 { tiltUp = asin(max(-1, min(1, along / length))) * 180 / .pi }
        }
        let present = focal35 != nil || focalMm != nil || model != nil
        return Camera(present: present, focal35mm: focal35, focalMm: focalMm, iso: iso, exposure: exposure, tiltUp: tiltUp)
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

    // MARK: - Upload

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
                    reply(["id": id,
                           "dataURI": "data:\(video.mime);base64," + video.data.base64EncodedString(),
                           "original": true])
                case .failure(let reason):
                    reply(["id": id, "error": reason.rawValue])
                }
                return
            }

            let isLive = asset.mediaSubtypes.contains(.photoLive)
            switch Original.bytes(for: asset, allowNetwork: true) {
            case .success(let original):
                reply(["id": id,
                       "dataURI": "data:\(original.mime);base64," + original.data.base64EncodedString(),
                       "original": true,
                       "hasVideo": isLive])
            case .failure(let reason):
                // Not rendered instead: a photo goes as its original or not at all.
                print("  \u{274c} original FAILED \(id) — \(reason.rawValue), not sent (\(elapsedMs(since: startedAt))ms)")
                reply(["id": id, "error": reason.rawValue])
            }
        }
    }

    // MARK: - Photo analysis

    /// Reports how the person is positioned in one photo. The web layer requires
    /// both `type` and `isFullBody`; a reply missing either rejects the photo.
    func analysePhoto(id: String) {
        // The scan already worked this out. Answering from the store skips two Vision
        // passes and guarantees the verdict matches the scan's.
        if let cached = ScanAnalysisStore.analysis(for: id) {
            sendAnalysis(id: id, captured: false, body: cached.body, type: cached.type)
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
                self.sendAnalysisError(id: id, captured: nil, error: "unavailable")
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
            sendAnalysisError(id: id, captured: captured, error: "unavailable")
            return
        }

        let orientation = Self.cgOrientation(image.imageOrientation)

        // The same face-to-body tie as the scan, so a tapped or captured photo is
        // judged on the body under its own face.
        let face = self.largestFace(in: cgImage, orientation: orientation)
        let body = self.bodyCheck(in: cgImage, orientation: orientation, face: face?.boundingBox)

        let type = self.classifyPhotoType(in: image, body: body)

        // A captured photo is analysed once, here, and stored so the tap that
        // follows takes the same path as a scanned one.
        if captured { ScanAnalysisStore.store(ScanAnalysis(type: type, body: body), id: id) }

        // The scan's gates, so a camera photo cannot pass what a library photo would not.
        if captured, Self.captureGatesEnabled, type != .unknown, let face,
           let gate = captureGate(face: face, in: cgImage, orientation: orientation, type: type, body: body) {
            print("🚫 capture \(id) gated — \(gate)")
            sendAnalysisError(id: id, captured: true, error: "unusable", filter: gate)
            return
        }

        sendAnalysis(id: id, captured: captured, body: body, type: type)
    }

    /// Scores a captured photo as the scan would and returns the gate that fired, or nil.
    /// A capture is the original (scale 1) and carries no camera metadata, which the selfie
    /// gates read as a phone's front camera. The end-of-scan relative gates do not apply.
    func captureGate(face: VNFaceObservation, in cgImage: CGImage, orientation: CGImagePropertyOrientation,
                     type: PhotoType, body: BodyCheck) -> String? {
        let handler = VNImageRequestHandler(cgImage: cgImage, orientation: orientation, options: [:])
        let selfie = type == .selfie
        let context = museContext(face: face, in: cgImage, handler: handler, readCover: Self.coverReadEnabled && selfie)
        var gates: MuseScore.SelfieGates?
        if Self.selfieGatesV2, selfie {
            let eyeSpacing = Self.eyeSpacing(of: face, in: cgImage, handler: handler)
            gates = MuseScore.SelfieGates(eyeSpacingOriginal: eyeSpacing.map { Float($0) }, originalScale: 1,
                                          originalLongSide: Float(max(cgImage.width, cgImage.height)), camera: nil)
        }
        var bodyScore: BodyScore?
        if Self.fullLengthScoreV2, !selfie, let observation = lastBodyObservation {
            var objects: [BodyObjects.Object] = []
            if Self.objectReadEnabled, let upright = BodyScore.upright(cgImage, orientation) {
                objects = BodyObjects.read(upright: upright)
            }
            bodyScore = BodyScore(image: cgImage, orientation: orientation, body: observation, face: face.boundingBox,
                                  originalScale: 1, caps: Self.garmentCaps(for: context.outfit), objects: objects)
        }
        let score = MuseScore(face: face, in: cgImage, handler: handler, faceWidth: face.boundingBox.width * CGFloat(cgImage.width),
                              expression: context.expression, labels: context.labels, handOnFace: context.handOnFace,
                              handNearFace: context.handNearFace, outfit: context.outfit, selfie: selfie, gates: gates,
                              coverReader: context.coverReader, document: context.document, body: bodyScore)
        return score.filter
    }

    /// The one place `onGalleryPhotoAnalysis` is built, so a cached verdict and a
    /// freshly computed one cannot describe themselves differently.
    func sendAnalysis(id: String, captured: Bool, body: BodyCheck, type: PhotoType) {
        // The web layer rejects any photo `isFullBody` reports false for. The same
        // rule as the scan gate, so a photo the scan let through is not refused on tap.
        let isFullBody = body.isHeadToToe

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

    /// Tells the page a photo could not be analysed, on the main queue. `captured` is left out when nil.
    func sendAnalysisError(id: String, captured: Bool?, error: String, filter: String? = nil) {
        var payload: [String: Any] = ["assetId": id, "error": error]
        if let captured { payload["captured"] = captured }
        // The gate that refused a captured photo, for the page's notice.
        if let filter { payload["scoreFilter"] = filter }
        DispatchQueue.main.async {
            self.sendToWeb(["type": "onGalleryPhotoAnalysis", "payload": payload])
        }
    }

    /// Takes one photo the user shot in the flow, holds it in memory (see
    /// `CaptureStore`) and analyses it. The reply is the ordinary analysis message.
    func storeCapture(id: String, dataURI: String) {
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self = self else { return }

            func fail(_ reason: String) {
                print("❌ capture FAILED \(id) — \(reason)")
                self.sendAnalysisError(id: id, captured: true, error: reason)
            }

            guard !id.isEmpty, let image = Self.image(fromDataURI: dataURI) else {
                fail("unreadable")
                return
            }

            // The bytes as sent, not a re-encode: the web side already captured at
            // upload size and quality, so anything else here loses a generation.
            guard let data = Self.data(fromDataURI: dataURI) else {
                fail("unreadable")
                return
            }

            guard CaptureStore.store(data, id: id) else {
                fail("store-full")
                return
            }

            self.analyse(image: image, id: id, captured: true)
        }
    }

    /// What a photo can be used as. A selfie is a large face with no lower body;
    /// full body is checked first, then classified by yaw.
    func classifyPhotoType(in image: UIImage, body: BodyCheck) -> PhotoType {
        guard let cgImage = image.cgImage else { return .unknown }

        // Landmarks, not just rectangles: the selfie rule reads the eye spacing.
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

        let yaw = face.yaw?.doubleValue

        let eyeSpacing = Self.eyeSpacing(of: face, in: cgImage)

        // The decision itself lives in one place, shared with the scan.
        return Self.photoType(faceRatio: ratio, eyeSpacing: eyeSpacing, yaw: yaw, body: body)
    }

    // MARK: - Thumbnail fallback

    /// Serial, so a grid of tiles does not queue the analysis behind blocking PhotoKit requests.
    static let thumbnailQueue = DispatchQueue(label: "co.getswan.gallery.thumbnails")

    /// Base64 fallback for one tile the custom scheme could not load.
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
                // A one-item `thumbs` array, so the page has one code path for one
                // tile or many.
                self?.sendToWeb(["type": "onGalleryThumbnails",
                                 "payload": ["thumbs": [["id": id,
                                                         "dataURI": "data:image/jpeg;base64," + data.base64EncodedString()]]]])
            }
        }
    }

    // MARK: - Reset

    /// Drops everything held for one run of the flow. Called on GALLERY_RESET and
    /// at the top of every scan, so a second scan inherits nothing from the first.
    func resetScanState() {
        scanGeneration += 1
        lastReferenceFrames = 1
        lastReferenceIndex = 0
        lastReferenceQuality = nil
        referenceEmbedding = nil
        isLimitedAccess = false
        // Cleared with the reference face: every verdict here was reached against it.
        ScanAnalysisStore.removeAll()
    }
}

// MARK: - Custom scheme handler

/// Serves `swan-photo://thumb?id=<percent-encoded localIdentifier>[&size=full]` as JPEG.
/// The id contains slashes, so it travels as a query parameter.
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
            let ms = elapsedMs(since: startedAt)

            if wantsFull, data == nil {
                // Only logged for full renders — grid tiles arrive by the dozen and
                // would drown everything else.
                print("  \u{274c} serve FAILED  \(id)  (\(ms)ms)")
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
