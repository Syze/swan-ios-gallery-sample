// Swan Gallery Pick — Vision helpers: loading photos, the selfie check, matching and the body check.

import UIKit
import Photos
import Vision

extension ViewController {

    // MARK: - Data URIs

    /// Decodes a `data:image/jpeg;base64,...` string.
    static func image(fromDataURI uri: String) -> UIImage? {
        guard let data = data(fromDataURI: uri) else { return nil }
        return UIImage(data: data).map(upright)
    }

    /// The bytes of a `data:...;base64,...` string: everything after the first comma, base64-decoded.
    static func data(fromDataURI uri: String) -> Data? {
        guard let comma = uri.firstIndex(of: ",") else { return nil }
        return Data(base64Encoded: String(uri[uri.index(after: comma)...]))
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

    // MARK: - Loading photos

    /// Render size for every photo in the scan. `minFacePixels` is expressed in
    /// these pixels, so the two must be changed together.
    static let loadPixels: CGFloat = 1536

    /// A face narrower than this, in the scan's render, is embedded from a larger
    /// render, where the landmarks align better. In practice full-length photos.
    static let fullResFaceBelow: CGFloat = 224

    /// The size of that second render. Capped rather than the whole original: a 48MP
    /// photo decoded in full is about 190MB, and this happens in the middle of a scan.
    static let fullResPixels: CGFloat = 4096

    /// What one photo load found, as a value, so a photo can be decoded on another
    /// queue (see `decodeAhead`) and its outcome applied on the scan queue.
    struct LoadResult {
        var image: UIImage?
        var note = ""
        var localCopy = false
        var thumbnail: UIImage?
        /// Came down from iCloud in this scan, so a bigger copy must come the same way.
        var fromCloud = false
        /// Why an iCloud fetch returned nothing: `diskFull`, `timedOut` or `other`,
        /// so analytics can tell a full phone from a slow connection.
        var cloudFailure: String?
    }
    /// Carries a `LoadResult` from the queue that decoded it to the scan queue.
    final class LoadBox { var result: LoadResult? }

    /// Copies a load's outcome onto the controller's `lastLoad…` state.
    func applyLoad(_ loaded: LoadResult?) {
        lastLoadNote = loaded?.note ?? ""
        lastLoadLocalCopy = loaded?.localCopy ?? false
        lastLoadFromCloud = loaded?.fromCloud ?? false
        lastLoadThumbnail = loaded?.thumbnail
    }

    /// Loads a photo from the phone, network off, and records the outcome on the controller.
    func loadPhoto(asset: PHAsset, pixels: CGFloat = ViewController.loadPixels) -> UIImage? {
        let loaded = loadPhotoResult(asset: asset, pixels: pixels)
        applyLoad(loaded)
        return loaded.image
    }

    /// The load itself, touching no state on the controller. Never downloads from
    /// iCloud; an iCloud-only photo falls back to the phone's smaller copy.
    func loadPhotoResult(asset: PHAsset, pixels: CGFloat = ViewController.loadPixels) -> LoadResult {
        var out = LoadResult()
        // `.highQualityFormat` and `.exact` matter: the fast modes hand back whatever
        // is cached, often a tiny thumbnail, and the face model then reads blur.
        let options = PHImageRequestOptions()
        options.deliveryMode = .highQualityFormat
        options.resizeMode = .exact
        options.isNetworkAccessAllowed = false
        options.isSynchronous = true

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
            // iCloud-only: "Optimise iPhone Storage" usually keeps a screen-sized copy.
            // `.opportunistic` may answer more than once; the largest is kept, the wait
            // is bounded by `localCopyWait`, and a copy under `minLocalCopyPixels` is refused.
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

        out.image = result.map(Self.upright)
        return out
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
            // CloudPhotoLibraryErrorDomain 1005 is a nearly full phone: Photos will not
            // download anything until space is freed, so no retry helps.
            let diskFull = error.map { $0.domain == "CloudPhotoLibraryErrorDomain" && $0.code == 1005 } ?? false
            out.cloudFailure = diskFull ? "diskFull" : "other"
            out.note = "iCloud download failed" + (error.map { " — \(diskFull ? "disk space very low" : $0.localizedDescription) (\($0.domain) \($0.code))" } ?? "")
        }
        out.image = result.map(Self.upright)
        out.fromCloud = true
        return out
    }

    // MARK: - iCloud candidate checks

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

    // MARK: - Selfie check

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

        // MediaPipe on the head crop, as the scan reads it (see `selfieCheckMediaPipe`).
        // The crop is cut from the stored bitmap, so only an upright image is read.
        var expression: FaceExpression?
        if Self.selfieCheckMediaPipe, image.imageOrientation == .up {
            let rect = MuseScore.headBox(main.boundingBox).pixels(in: cgImage).integral
            if let crop = cgImage.cropping(to: rect) { expression = FaceExpression.read(headCrop: crop) }
        }
        if let e = expression, let yaw = e.headYaw, let pitch = e.headPitch {
            let off = Self.gazeOff(e)
            if Double(abs(yaw)) > Self.selfieMaxYawDegrees {
                return ("selfie-not-frontal", String(format: "head turned, yaw %.0f° (limit %.0f°)", abs(yaw), Self.selfieMaxYawDegrees))
            }
            if Double(abs(pitch)) > Self.selfieMaxPitchDegrees {
                return ("selfie-not-frontal", String(format: "head tilted, pitch %.0f° (limit %.0f°)", abs(pitch), Self.selfieMaxPitchDegrees))
            }
            if let off, off >= Self.selfieMaxGazeDegrees {
                return ("selfie-not-frontal", String(format: "eyes %.0f° off the camera (limit %.0f°)", off, Self.selfieMaxGazeDegrees))
            }
            return nil
        }

        // Without a MediaPipe read, Vision's own yaw and pitch.
        let degrees = { (angle: NSNumber?) -> Double? in angle.map { abs($0.doubleValue) * 180 / .pi } }
        if let yaw = degrees(main.yaw), yaw > Self.selfieMaxYawDegrees {
            return ("selfie-not-frontal", String(format: "head turned, yaw %.0f° (limit %.0f°)", yaw, Self.selfieMaxYawDegrees))
        }
        if let pitch = degrees(main.pitch), pitch > Self.selfieMaxPitchDegrees {
            return ("selfie-not-frontal", String(format: "head tilted, pitch %.0f° (limit %.0f°)", pitch, Self.selfieMaxPitchDegrees))
        }
        return nil
    }

    // MARK: - Matching

    /// Why a photo did or did not produce a score. The outcomes are mutually
    /// exclusive and each has its own tally.
    enum PhotoOutcome {
        case noFace
        case group(faceCount: Int)
        case faceTooSmall(pixels: Int)
        case otherPeople(body: BodyCheck)
        case notFullBody(body: BodyCheck)
        case scored(distances: [Float], body: BodyCheck, type: PhotoType, museScore: MuseScore?)
    }

    /// What the Muse score needs for one matched photo: expression and labels from the
    /// head crop, a hand over the face, and the outfit.
    func museContext(face: VNFaceObservation, in image: CGImage, handler: VNImageRequestHandler, readCover: Bool = false)
        -> (expression: FaceExpression?, labels: [String: Float], handOnFace: Bool, handNearFace: Bool, outfit: MuseScore.Outfit, coverReader: ((FaceExpression?) -> FaceCover?)?,
            document: MuseScore.DocumentRead?) {
        let headRect = MuseScore.headBox(face.boundingBox).pixels(in: image).integral
        let headCrop = image.cropping(to: headRect)

        var labels: [String: Float] = [:]
        var expression: FaceExpression?
        let expressionGroup = DispatchGroup()
        var expressionResult: FaceExpression?
        var expressionMs = 0.0
        // What covers the face (see `FaceCover`), selfies only. A closure, so the costly
        // read runs only if no cheaper gate has dropped the photo; it takes the
        // expression read on the same crop for the face's geometry.
        var coverReader: ((FaceExpression?) -> FaceCover?)?
        if readCover, let headCrop {
            let faceRect = face.boundingBox.pixels(in: image)
                .offsetBy(dx: -headRect.minX, dy: -headRect.minY)
            coverReader = { [self] expression in
                timed("score.cover") { FaceCover.read(headCrop: headCrop, face: faceRect, landmarks: expression?.landmarks) }
            }
        }
        // Glasses, hat and face-cover labels on the head crop.
        if let headCrop {
            let classify = VNClassifyImageRequest()
            timed("score.labels") { try? VNImageRequestHandler(cgImage: headCrop, orientation: .up, options: [:]).perform([classify]) }
            for result in classify.results ?? [] where result.confidence >= 0.1 {
                let name = result.identifier
                if name == "sunglasses" || name == "eyeglasses" || MuseScore.hatLabels.contains(name) || MuseScore.coverLabels.contains(name) { labels[name] = result.confidence }
            }
            // MediaPipe on the CPU while Vision takes the Neural Engine: the two
            // overlap instead of queueing.
            expressionGroup.enter()
            DispatchQueue.global(qos: .userInitiated).async {
                let started = Date()
                expressionResult = FaceExpression.read(headCrop: headCrop)
                expressionMs = Date().timeIntervalSince(started) * 1000
                expressionGroup.leave()
            }
        }

        // Hands anywhere in the render; one with most of its points on the face
        // is over it. Skin-coloured, so no colour check would see it.
        let hands = VNDetectHumanHandPoseRequest()
        hands.maximumHandCount = 2
        var zone = face.boundingBox.insetBy(dx: -face.boundingBox.width * 0.15, dy: -face.boundingBox.height * 0.15)
        timed("score.hands") {
            if let (crop, zoneInCrop) = FaceRecognizer.crop(image, around: zone,
                                                                                  scale: Self.handNearFaceDrops ? Self.handsNearCropScale : Self.handsCropScale) {
                try? VNImageRequestHandler(cgImage: crop, orientation: .up, options: [:]).perform([hands])
                zone = zoneInCrop
            } else {
                try? handler.perform([hands])
            }
        }
        /// Whether a hand has at least `handPointsOnFace` confident points inside `area`.
        func handIn(_ area: CGRect) -> Bool {
            (hands.results ?? []).contains { hand in
                guard let points = try? hand.recognizedPoints(.all) else { return false }
                return points.values.filter { $0.confidence > 0.3 && area.contains($0.location) }.count >= MuseScore.handPointsOnFace
            }
        }
        let handOnFace = handIn(zone)
        // The same count over the wider area — see `handNearFaceDrops`.
        let grow = Self.handNearFaceScale - 1
        let nearZone = zone.insetBy(dx: -zone.width * grow / 2, dy: -zone.height * grow / 2)
        let handNearFace = Self.handNearFaceDrops && handIn(nearZone)

        // The outfit (see `MuseScore.outfitMultiplier`): formal-wear labels over the
        // whole render, busyness from the clothing below the face.
        let whole = VNClassifyImageRequest()
        timed("score.outfit") { try? handler.perform([whole]) }
        var dressy: Float = 0
        for result in whole.results ?? [] where MuseScore.dressyLabels.contains(result.identifier) && result.confidence > dressy {
            dressy = result.confidence
        }
        let box = face.boundingBox
        let torso = CGRect(x: box.midX - box.width * 1.5, y: box.minY - box.height * 3, width: box.width * 3, height: box.height * 2.8)
            .intersection(CGRect(x: 0, y: 0, width: 1, height: 1))
        let torsoRect = torso.pixels(in: image).integral
        var busy: Float = 0
        if torsoRect.width > 8, torsoRect.height > 8, let torsoCrop = image.cropping(to: torsoRect) {
            busy = timed("score.busy") { MuseScore.busyness(of: torsoCrop) }
        }
        // Document facts (see `documentReadEnabled`): the whole-photo labels from
        // above and Vision's document segmentation.
        var document: MuseScore.DocumentRead?
        if Self.documentReadEnabled {
            let docLabels = (whole.results ?? []).filter { Self.documentLabels.contains($0.identifier) && $0.confidence >= 0.01 }
                .map { (label: $0.identifier, confidence: $0.confidence) }
            let page = VNDetectDocumentSegmentationRequest()
            timed("score.text") { try? handler.perform([page]) }
            let found = page.results?.first
            let pageBox = found?.boundingBox ?? .zero
            document = MuseScore.DocumentRead(docConfidence: found?.confidence ?? 0,
                                              docArea: Float(pageBox.width * pageBox.height),
                                              faceInDoc: pageBox.contains(CGPoint(x: face.boundingBox.midX, y: face.boundingBox.midY)),
                                              docLabels: docLabels)
        }
        // Join the expression read started above.
        expressionGroup.wait()
        expression = expressionResult
        stageMs["score.expression", default: 0] += expressionMs
        var outfit = MuseScore.Outfit(dressy: dressy, busy: busy)
        let capLabels = Set(Self.garmentCaps.flatMap { $0.labels }).union(Self.looseGarmentLabels)
        outfit.garments = (whole.results ?? []).filter { capLabels.contains($0.identifier) && $0.confidence > 0.1 }
            .map { (label: $0.identifier, confidence: $0.confidence) }
        return (expression, labels, handOnFace, handNearFace, outfit, coverReader, document)
    }

    /// Whether a photo is of the shopper, run through every gate, and its score if so.
    func matchPerson(in image: UIImage, asset: PHAsset) -> PhotoOutcome {
        // Cleared first, so a photo that leaves early (no face, a group) does not
        // carry the previous photo's state.
        lastBodyRetry = nil
        lastEarlyNoMatch = false
        lastEmbeddings = []
        lastTrace = [:]
        guard let reference = referenceEmbedding, let recognizer = Self.faceRecognizer,
              let cgImage = image.cgImage else { lastTrace["why"] = "no reference or image"; return .noFace }
        lastTrace["render"] = "\(cgImage.width)x\(cgImage.height)"
        lastTrace["orientation"] = "\(image.imageOrientation.rawValue)"

        let request = VNDetectFaceRectanglesRequest()
        let handler = VNImageRequestHandler(
            cgImage: cgImage,
            orientation: Self.cgOrientation(image.imageOrientation),
            options: [:]
        )
        timed("detect") { try? handler.perform([request]) }

        guard let allFaces = request.results, !allFaces.isEmpty else { lastTrace["why"] = "Vision found no face"; return .noFace }
        lastTrace["facesFound"] = allFaces.count

        // Faces too small beside the largest are bystanders (see `bystanderRatio`):
        // they neither reject the photo nor get a turn at matching.
        let mainFaceWidth = allFaces.map(\.boundingBox.width).max() ?? 0
        // Largest first: the body check and the type read the first face, and with
        // several faces of the shopper the largest is the one the photo is of.
        let faces = allFaces.filter { $0.boundingBox.width >= mainFaceWidth * Self.bystanderRatio }
            .sorted { $0.boundingBox.width > $1.boundingBox.width }

        lastTrace["facesUsed"] = faces.count
        // Several faces are a group unless every one is the shopper, a mirror shot.
        lastShopperFaces = 1
        if Self.requireSingleFace && faces.count > 1 {
            guard faces.count <= Self.sameShopperFacesMax else { return .group(faceCount: faces.count) }
            // Without a store the first miss ends the loop. With one, every face's vector
            // is kept, so the next scan can re-judge the group without loading the photo.
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

        // The widest face in pixels of the loaded render (Vision's boxes are normalised).
        let widest = faces.map { $0.boundingBox.width * CGFloat(cgImage.width) }.max() ?? 0
        lastTrace["facePx"] = Int(widest)
        lastTrace["faceYawRad"] = (faces.first?.yaw.map { ($0.doubleValue * 100).rounded() / 100 } as Any?) ?? NSNull()
        lastTrace["faceBoxCentre"] = (faces.first.map { [($0.boundingBox.midX * 100).rounded() / 100, ($0.boundingBox.midY * 100).rounded() / 100] } as Any?) ?? NSNull()

        // A larger render of the same photo, loaded at most once and only if asked
        // for. Network off, so nil when no larger copy is on the phone.
        var largerLoaded = false
        var largerCache: CGImage?
        func largerRender() -> CGImage? {
            if !largerLoaded {
                largerLoaded = true
                // `loadPhotoResult`, not `loadPhoto`: the latter would overwrite
                // `lastLoadFromCloud`, which the fetch below reads.
                largerCache = loadPhotoResult(asset: asset, pixels: Self.fullResPixels).image?.cgImage
                    .flatMap { $0.width > cgImage.width ? $0 : nil }
                // A photo that came from iCloud has no bigger copy on the phone. Fetch
                // one just large enough for the face floor, not the full original.
                if largerCache == nil, lastLoadFromCloud, Self.cloudDownloadsAllowed {
                    let ratio = faces.map(\.boundingBox.width).max() ?? 0
                    let needed = min(Self.fullResPixels, max(Self.loadPixels * 1.5, Self.minFacePixels / max(ratio, 0.01) * 1.25))
                    let fetched = loadFromCloudResult(asset: asset, pixels: needed, timeout: Self.cloudTimeoutNow)
                    largerCache = fetched.image?.cgImage.flatMap { $0.width > cgImage.width ? $0 : nil }
                    if largerCache != nil { cloudLargerDownloads += 1 }
                }
            }
            return largerCache
        }

        // Face-size floor. The larger render is loaded only when the original is big
        // enough to clear it, so a photo small in every copy costs nothing extra.
        let widestRatio = faces.map(\.boundingBox.width).max() ?? 0
        if widest < Self.minFacePixels {
            lastTrace["faceFloor"] = "\(Int(widest))px at the scan render, under \(Int(Self.minFacePixels))"
            guard widestRatio * CGFloat(asset.pixelWidth) >= Self.minFacePixels else { return .faceTooSmall(pixels: Int(widest)) }
            guard let larger = largerRender(), widestRatio * CGFloat(larger.width) >= Self.minFacePixels
            else { return .faceTooSmall(pixels: Int(widest)) }
        }

        // Distances of every face in `source` to the selfie; nil when none could be
        // embedded. Defined here so the full-body gate can ask first.
        func score(from source: CGImage) -> [Float]? {
            timed("embed") { embed(from: source) }
        }
        func embed(from source: CGImage) -> [Float]? {
            var distances: [Float] = []
            var vectors: [[Float]] = []
            for face in faces {
                // Vision's boxes are normalised, so they fit the larger render unchanged.
                // Seeded with the observation when `source` is the render it was detected on.
                guard let candidate = recognizer.embedding(in: source, near: face.boundingBox, seed: source === cgImage ? face : nil) else { continue }
                vectors.append(candidate)
                let distance = FaceRecognizer.distance(reference, candidate)
                distances.append(distance)
            }
            guard !distances.isEmpty else { return nil }
            // For the store: only a complete set, so a stored group verdict never
            // rests on a face that was skipped here.
            lastEmbeddings = vectors.count == faces.count ? vectors : []
            return distances
        }

        // Match before pose (see `matchBeforePose`): a face clearly not the shopper's
        // returns here with an empty body. It never reaches the grid either way.
        var quick: [Float]?
        if Self.matchBeforePose {
            quick = score(from: cgImage)
            if let quick {
                let best = quick.min() ?? 1
                lastTrace["distanceQuick"] = (Double(best) * 1000).rounded() / 1000
                if best >= Self.gapCutCeiling && (widest >= Self.fullResFaceBelow || best >= Self.earlyNoMatchSmallFace) {
                    lastEarlyNoMatch = true
                    let unchecked = BodyCheck.unseen(people: 1)
                    let ratio = Self.faceRatio(boxWidth: faces.map(\.boundingBox.width).max() ?? 0, in: cgImage)
                    lastEyeSpacing = nil
                    lastTrace["why"] = "face too far from the selfie before pose (at or over \(Self.gapCutCeiling))"
                    return .scored(distances: quick, body: unchecked,
                                   type: Self.photoType(faceRatio: ratio, yaw: faces.first?.yaw?.doubleValue, body: unchecked),
                                   museScore: nil)
                }
            }
        }

        // Pose runs after the face gates on purpose: it is the most expensive request,
        // so it only runs on photos that already have one usable face.
        var body = timed("pose") { bodyCheck(in: cgImage, orientation: Self.cgOrientation(image.imageOrientation),
                                             face: faces.first?.boundingBox) }
        // Each reflection of the shopper has a body too; those are not other people.
        body.shopperFaces = lastShopperFaces
        lastTrace["body"] = Self.bodyTrace(body)
        // What the body score reads: the render the kept body was found on.
        var bodyObservation = lastBodyObservation
        var bodyImage = cgImage
        var bodyOrientation = Self.cgOrientation(image.imageOrientation)

        // Only the shopper in the photo. The person detector also finds someone with
        // their back to the camera, whom the face gate cannot see.
        if body.hasOthers {
            lastTrace["why"] = "person detector counted \(body.people) people, \(lastShopperFaces) of them the shopper's face"
            return .otherPeople(body: body)
        }

        let faceRatio = Self.faceRatio(boxWidth: faces.map(\.boundingBox.width).max() ?? 0, in: cgImage)
        // Eye spacing of the widest face, for the selfie rule. Skipped when a lower-body
        // joint is in frame, since such a photo is never a selfie.
        let widestFace = faces.max { $0.boundingBox.width < $1.boundingBox.width }
        // Measured on the scan's render, then scaled to the original's pixels.
        let originalScale = CGFloat(max(asset.pixelWidth, asset.pixelHeight)) / CGFloat(max(cgImage.width, cgImage.height))
        let eyeSpacing = body.lowerJoints == 0
            ? timed("type.eyes") { Self.eyeSpacing(of: widestFace, in: cgImage, handler: handler) }.map { $0 * originalScale }
            : nil
        lastEyeSpacing = eyeSpacing
        lastTrace["faceRatio"] = (Double(faceRatio) * 1000).rounded() / 1000
        lastTrace["eyeSpacingPx"] = (eyeSpacing.map { Int($0) } as Any?) ?? NSNull()
        // A selfie has no lower body, so it skips the full-body gate. The same rule
        // as `photoType`, read before the body retry.
        let isSelfie = Self.photoType(faceRatio: faceRatio, eyeSpacing: eyeSpacing, yaw: nil, body: body) == .selfie
        if Self.requireFullBody && !isSelfie && !body.isHeadToToe {
            // Legs seen but not enough of them: one more look at the larger render,
            // only when the face already matches, so strangers cost nothing extra.
            guard body.headSeen, body.lowerJoints >= 1,
                  let quick = quick ?? score(from: cgImage), (quick.min() ?? 1) < Self.matchThreshold,
                  let larger = largerRender()
            else {
                lastTrace["why"] = "head seen \(body.headSeen), lower joints \(body.lowerJoints), no retry (face distance over the cut or no larger render)"
                return .notFullBody(body: body)
            }
            var again = timed("pose") { bodyCheck(in: larger, orientation: .up, face: faces.first?.boundingBox) }
            again.shopperFaces = lastShopperFaces
            lastBodyRetry = again.isHeadToToe
            lastTrace["bodyRetry"] = Self.bodyTrace(again)
            if again.hasOthers { lastTrace["why"] = "larger render counted \(again.people) people"; return .otherPeople(body: again) }
            guard again.isHeadToToe else { lastTrace["why"] = "not head to toe even on the larger render"; return .notFullBody(body: body) }
            body = again
            bodyObservation = lastBodyObservation
            bodyImage = larger
            bodyOrientation = .up
        }

        // The photo's type, from inputs already in hand.
        let yaw = faces.first?.yaw?.doubleValue
        let type = Self.photoType(faceRatio: faceRatio, eyeSpacing: eyeSpacing, yaw: yaw, body: body)
        lastTrace["typeBy"] = type == .selfie ? "no lower joints and face big enough"
            : body.shoulderSpread != nil ? "shoulder spread \((Double(body.shoulderSpread!) * 1000).rounded() / 1000) (side under \(Self.sideShoulderSpread), three-quarter under \(Self.threeQuarterShoulderSpread))"
            : "head yaw fallback (no shoulder spread)"

        // A small face is re-embedded from the larger render. Only photos past every
        // gate get here; the face box is normalised, so it fits.
        let matchedSoFar = ((quick ?? score(from: cgImage))?.min() ?? 1) < Self.matchThreshold
        var source = cgImage
        // A downloaded photo fetches its bigger copy only once the face has matched.
        if widest < Self.fullResFaceBelow, !lastLoadFromCloud || matchedSoFar || largerCache != nil, let larger = largerRender() {
            source = larger
        }
        guard let scored = (source === cgImage ? quick : nil) ?? score(from: source) else { return .noFace }
        // Matches only — the rest never reach the grid, so their score is never
        // read. On the scan's render and its handler, not the larger crop.
        var museScore: MuseScore?
        if (scored.min() ?? 1) < Self.matchThreshold {
            museScore = timed("score") {
                let context = museContext(face: faces[0], in: cgImage, handler: handler, readCover: Self.coverReadEnabled && type == .selfie)
                // The selfie gates' inputs (see `selfieGatesV2`). Camera data is read
                // from the original on the phone.
                var gates: MuseScore.SelfieGates?
                if Self.selfieGatesV2, type == .selfie {
                    let camera = timed("score.camera") { Original.camera(for: asset) }
                    gates = MuseScore.SelfieGates(eyeSpacingOriginal: eyeSpacing.map { Float($0) },
                                                  originalScale: Float(originalScale),
                                                  originalLongSide: Float(max(asset.pixelWidth, asset.pixelHeight)),
                                                  camera: camera)
                }
                // The full-length body score (see `fullLengthScoreV2`).
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
                                                         handNearFace: context.handNearFace,
                                                         outfit: context.outfit, selfie: type == .selfie, gates: gates, coverReader: context.coverReader,
                                                         document: context.document, body: bodyScore) }
            }
        }
        return .scored(distances: scored, body: body, type: type, museScore: museScore)
    }

    /// The garment caps a photo's labels call for — see `garmentCaps` — and whether a loose
    /// garment was named (`looseGarmentLabels`). Nil with both switches off or nothing hit.
    static func garmentCaps(for outfit: MuseScore.Outfit) -> BodyScore.Caps? {
        guard garmentCapsEnabled || looseGarmentGateEnabled else { return nil }
        var caps = BodyScore.Caps()
        if looseGarmentGateEnabled,
           let loose = outfit.garments.filter({ looseGarmentLabels.contains($0.label) && $0.confidence >= looseGarmentLine }).max(by: { $0.confidence < $1.confidence }) {
            caps.loose = String(format: "%@ %.2f", loose.label, loose.confidence)
        }
        for rule in garmentCaps where garmentCapsEnabled {
            guard let hit = outfit.garments.filter({ rule.labels.contains($0.label) && $0.confidence >= rule.line }).max(by: { $0.confidence < $1.confidence })
            else { continue }
            caps.torso = min(caps.torso, rule.torso); caps.legs = min(caps.legs, rule.legs); caps.arms = min(caps.arms, rule.arms)
            let why = String(format: "%@ %.2f", hit.label, hit.confidence)
            if !caps.why.contains(why) { caps.why.append(why) }
        }
        return caps.why.isEmpty && caps.loose == nil ? nil : caps
    }

    /// A body check as plain numbers, for the scan report's per-photo trail.
    static func bodyTrace(_ body: BodyCheck) -> [String: Any] {
        func r(_ v: CGFloat) -> Double { (Double(v) * 1000).rounded() / 1000 }
        return ["headSeen": body.headSeen, "lowerJoints": body.lowerJoints, "ankles": body.ankles, "span": r(body.span),
                "footRoom": r(body.footRoom), "people": body.people, "headToToe": body.isHeadToToe,
                "shoulderSpread": (body.shoulderSpread.map(r) as Any?) ?? NSNull(),
                "needs": ["ankles": minAnkles, "span": body.ankles >= 2 ? minBodySpanBothAnkles : minBodySpan,
                          "footRoom": r(minFootRoom * body.span)]]
    }

    // MARK: - Body check

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
        let nobody = BodyCheck.unseen(people: people)
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

        // The body's own turn: shoulders across the photo, against the torso's
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

        let result = BodyCheck(lowerJoints: knees.count + ankles.count,
                               ankles: ankles.count,
                               headSeen: !head.isEmpty,
                               span: span,
                               footRoom: ankles.map(\.location.y).min() ?? 0,
                               people: people,
                               shoulderSpread: spread(.leftShoulder, .rightShoulder))
        return result
    }

    // MARK: - Reference selfie

    /// Averages the usable selfie frames' embeddings into one reference, which cancels
    /// one frame's quirks (expression, a small turn, a shadow). Off, the sharpest frame alone is used.
    static let blendReferenceFrames = true
    /// Frames under this face capture quality stay out of the blend.
    static let blendQualityFloor: Float = 0.3

    /// The sharpest selfie frame by Vision's face capture quality. Frames with no face
    /// are out; a tie, or no quality at all, keeps the tapped frame, the last one sent.
    func chooseReference(_ frames: [UIImage]) -> (image: UIImage, index: Int, note: String, quality: Float?, qualities: [Float?]) {
        guard frames.count > 1 else { return (frames[0], 0, "1 frame", nil, [nil]) }

        let qualities: [Float?] = frames.map { image in
            guard let cgImage = image.cgImage else { return nil }
            let handler = VNImageRequestHandler(cgImage: cgImage, orientation: Self.cgOrientation(image.imageOrientation), options: [:])
            let request = VNDetectFaceRectanglesRequest()
            try? handler.perform([request])
            guard let face = request.results?.max(by: { $0.boundingBox.width < $1.boundingBox.width }) else { return nil }
            let quality = VNDetectFaceCaptureQualityRequest()
            quality.inputFaceObservations = [face]
            try? handler.perform([quality])
            return quality.results?.first?.faceCaptureQuality
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

    // MARK: - Orientation

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
