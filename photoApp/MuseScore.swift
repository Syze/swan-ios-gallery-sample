// Swan Gallery Pick: scores how well a matched photo would serve the Muse.

import UIKit
import Vision

/// How well a matched photo would serve the Muse, 0–1; 0 when a filter rules it out.
/// Sent to the page as `score`.
struct MuseScore {
    // MARK: - Score result

    var value: Float
    /// Each part 0–1, in the order of the score's weights.
    var parts: [(name: String, value: Float)]
    /// The hard filter that zeroed the score, if one did.
    let filter: String?
    /// What the expression reader saw, when it ran.
    let expression: FaceExpression?
    /// Vision's classifier on the head crop, the labels the score reads.
    let labels: [String: Float]
    /// A hand over the face, from Vision's hand detector.
    let handOnFace: Bool
    /// A hand near the face (`ViewController.handNearFaceDrops`); filters selfies only.
    let handNearFace: Bool
    /// A cap or hat: ranked lower, never filtered — see `capMultiplier`.
    let capped: Bool
    /// A selfie with the head not level with the camera: ranked lower, never filtered.
    let tilted: Bool
    /// A smile stays in and ranks lower: closed lips by `closedSmileMultiplier`,
    /// teeth or open mouth by `openSmileMultiplier`.
    enum Smile: String { case none = "", closed, open }
    let smile: Smile
    /// A stare or eyes held wide open: ranked lower, never filtered.
    let wideEyed: Bool
    /// Other reasons to rank lower, each worth `loweredMultiplier`: an open mouth
    /// without a smile, a black or blown exposure.
    let lowered: [String]
    /// Ranked lower for any reason above: the photo sits in the lower score band,
    /// and its distance is left out of the gap rule.
    let demoted: Bool
    /// Tier "A" or "B" under the v2 selfie or body score, and what held the score down.
    var tier: String?
    var reasons: [String]
    /// v2 selfie score: each group's signals, 0–1; the lowest sets the group.
    /// Sent as `scoreSignals`; empty for other photos.
    var signals: [String: [(why: String, value: Float)]]
    /// How each signal in `signals` was worked out, by its `why`.
    /// Sent as each signal's `how`.
    var signalHows: [String: String]
    /// v2 selfie score: eyes held wide or brows raised. Sent as `wideEyes`.
    let wideEyesV2: Bool
    /// v2 body score of a front, three-quarter or side: it supplies the value, parts
    /// and tier, and the face filters stand down. Nil for selfies.
    let body: BodyScore?
    /// What the shopper wears — see `outfitMultiplier`.
    struct Outfit {
        let dressy: Float
        /// Edge density of the clothing below the face, 0–1.
        let busy: Float
        /// Garment labels `ViewController.garmentCaps` knows, over 0.1 confidence, strongest first.
        var garments: [(label: String, confidence: Float)] = []
    }
    let outfit: Outfit
    let dressy: Bool
    let busy: Bool
    /// Signs the whole photo is a document; the gate is `ViewController.documentGateEnabled`.
    struct DocumentRead {
        /// Vision's document segmentation: confidence that a flat document is in the photo,
        /// the share of the frame it covers, and whether the matched face is inside it.
        let docConfidence: Float
        let docArea: Float
        let faceInDoc: Bool
        /// Document-like labels at 0.01 or more, best first — see `ViewController.documentLabels`.
        let docLabels: [(label: String, confidence: Float)]
        var labelSum: Float { docLabels.reduce(0) { $0 + $1.confidence } }
        var handwriting: Float { docLabels.first { $0.label == "handwriting" }?.confidence ?? 0 }
        /// Some document labels and a page that holds the face without filling the photo.
        var faceOnPage: Bool {
            labelSum >= ViewController.documentPageLabelLimit
                && docConfidence >= ViewController.documentConfidenceLog && faceInDoc
                && docArea < ViewController.documentPageAreaLimit
        }
    }
    let document: DocumentRead?
    /// Raw readings behind the parts: angles in degrees, face width in pixels, the rest
    /// as the detectors report them. Sent as `scoreInputs`.
    var readings: [String: Double]
    /// Camera to face in centimetres (v2 selfie gates only), and whether the focal
    /// length was assumed (`ViewController.assumedFocal35mm`).
    let cameraCm: Float?
    let focalAssumed: Bool
    /// What covers the face (`FaceCover`); nil when an earlier gate fired first.
    let cover: FaceCover?
    /// A head covering or object over the face by the classifier's labels. Logged, not filtered.
    var coverHint: Bool { labels.contains { Self.coverLabels.contains($0.key) && $0.value >= Self.coverConfidence } }

    // MARK: - Weights and cover labels

    /// Pre-v2 score weights: quality, pose, light, size, mouth, eyes, brow, sharpness.
    /// The three expression terms carry 0.35, so a neutral face beats a smile, stare or wink.
    static let weights: [(name: String, weight: Float)] = [
        ("quality", 0.25), ("pose", 0.15), ("light", 0.10), ("size", 0.10),
        ("mouth", 0.15), ("eyes", 0.10), ("brow", 0.10), ("sharp", 0.05),
    ]

    /// Classifier confidence for sunglasses (filtered) and caps (ranked lower). Clear
    /// glasses read as eyeglasses, not sunglasses.
    static let sunglassesConfidence: Float = 0.4
    static let hatConfidence: Float = 0.5
    static let hatLabels: Set<String> = ["hat", "baseball_hat", "sunhat", "cowboy_hat", "beanie", "helmet", "hardhat"]
    /// Head coverings and objects over the face, by classifier label: logged and counted,
    /// not filtered. Only a scarf is filtered (`ViewController.scarfGateEnabled`).
    static let coverLabels: Set<String> = ["scarf", "mask", "gas_mask", "hoodie", "earmuffs", "headphones", "tiara"]
    static let coverConfidence: Float = 0.3

    // MARK: - Inputs

    /// What the v2 selfie gates read beyond the face. Passed for selfies only.
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

    // MARK: - Cap, hand and expression thresholds

    /// What a capped photo keeps of its score: behind a bare-headed one, ahead of a poor one.
    static let capMultiplier: Float = 0.6
    /// Hand points (of 21) inside the padded face box that count as a hand over the face.
    static let handPointsOnFace = 10
    /// Blink value above which both eyes count as shut.
    static let closedBlink: Float = 0.5
    /// Smile level that counts as smiling; a slight smile (0.3) stays in as neutral.
    static let smileFilter: Float = 0.5
    /// Under the v2 selfie gates, a smile at this level may show teeth: it ranks lower
    /// instead of being filtered. `mouthOpenFilter` still filters a laugh.
    static let smileKeepsTeeth: Float = 0.3
    /// Lips count as parted at this jaw opening or this teeth reading.
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

    // MARK: - Outfit

    /// The outfit: formal wear (`dressyLabels`) and a busy torso (edge density below
    /// the face) each pull the score down by `outfitMultiplier`. Never a filter.
    static let dressyLabels: Set<String> = ["suit", "tuxedo", "necktie", "bowtie", "jacket", "sari", "gown", "wedding_dress", "kimono", "costume"]
    static let dressyConfidence: Float = 0.3
    static let busyTorso: Float = 0.11
    static let outfitMultiplier: Float = 0.8

    /// How busy a crop is, 0–1: mean gradient magnitude over a 64px copy.
    static func busyness(of crop: CGImage) -> Float {
        let n = 64
        guard let ctx = CGContext(data: nil, width: n, height: n, bitsPerComponent: 8, bytesPerRow: n * 4,
                                  space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else { return 0 }
        ctx.interpolationQuality = .high
        ctx.draw(crop, in: CGRect(x: 0, y: 0, width: n, height: n))
        guard let data = ctx.data else { return 0 }
        let p = data.bindMemory(to: UInt8.self, capacity: n * n * 4)
        var grey = [Float](repeating: 0, count: n * n)
        for i in 0..<(n * n) { grey[i] = luma(Float(p[i * 4]), Float(p[i * 4 + 1]), Float(p[i * 4 + 2])) }
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

    // MARK: - Eye, pose and image thresholds

    /// Jaw opening that counts as an open mouth.
    static let mouthOpenFilter: Float = 0.3
    /// One eye's blink value that counts as a wink.
    static let winkBlink: Float = 0.5
    /// A smaller wink is filtered too: one eye at least `unevenBlink` closed and at least
    /// `unevenBlinkGap` more than the other. Off, only `winkBlink` counts.
    static let unevenBlinkDrops = true
    static let unevenBlink: Float = 0.35
    static let unevenBlinkGap: Float = 0.2
    /// A stare: brows up this far with little squint, or a smaller lift with almost none.
    static let staringBrow: Float = 0.6
    static let staringSquintBelow: Float = 0.25
    static let wideEyedBrow: Float = 0.25
    static let wideEyedSquintBelow: Float = 0.10
    /// Eye-wide reading from which the lids count as held open, even with the brows at rest.
    static let eyeWideFilter: Float = 0.08
    /// What a wide-eyed photo keeps of its score: behind neutral faces and closed-lip smiles.
    static let wideEyedMultiplier: Float = 0.4
    static let loweredMultiplier: Float = 0.4

    /// Head turn, in degrees, at which the pose term reaches 0.
    static let poseLimitDegrees: Float = 30
    /// Selfie head pitch or yaw past which it keeps `tiltMultiplier` of its score, never
    /// filtered. Pitch gets less room: looking up or down hurts a Muse most.
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
    /// Laplacian variance of the 64px face below which it counts as blurred.
    static let blurVariance: Float = 5e-4

    // MARK: - Scoring

    init(face: VNFaceObservation, in image: CGImage, handler: VNImageRequestHandler, faceWidth: CGFloat,
         expression: FaceExpression? = nil, labels: [String: Float] = [:], handOnFace: Bool = false, handNearFace: Bool = false,
         outfit: Outfit = Outfit(dressy: 0, busy: 0), selfie: Bool = false, gates: SelfieGates? = nil,
         coverReader: ((FaceExpression?) -> FaceCover?)? = nil, document: DocumentRead? = nil, body: BodyScore? = nil) {
        var parts: [(name: String, value: Float)] = []
        var filter: String?
        var smile = Smile.none
        var wideEyed = false
        var lowered: [String] = []

        // Filters for every photo.

        // A document, not a photo of the person. First, so it is the named filter.
        if ViewController.documentGateEnabled, let document {
            if document.labelSum >= ViewController.documentLabelSumLimit { filter = "document" }
            else if document.handwriting >= ViewController.handwritingLimit { filter = "handwriting" }
            else if document.faceOnPage { filter = "document" }
        }

        // What covers the face. Sunglasses and a hand rule the photo out of the
        // ranking; a cap only pulls it down — see `capMultiplier`.
        if (labels["sunglasses"] ?? 0) >= Self.sunglassesConfidence { filter = filter ?? "sunglasses" }
        if handOnFace { filter = filter ?? "hand over face" }
        if selfie && handNearFace { filter = filter ?? "hand near face" }
        let capped = labels.contains { Self.hatLabels.contains($0.key) && $0.value >= Self.hatConfidence }

        // Face cut by the frame. Vision's box, with a little tolerance.
        let box = face.boundingBox
        if box.minX < 0.01 || box.maxX > 0.99 || box.minY < 0.01 || box.maxY > 0.99 {
            filter = "face cut by the frame"
        }

        // Face readings and pre-v2 parts.

        // Capture quality and landmarks, on the handler that already holds the image.
        let qualityRequest = VNDetectFaceCaptureQualityRequest()
        qualityRequest.inputFaceObservations = [face]
        let landmarksRequest = VNDetectFaceLandmarksRequest()
        landmarksRequest.inputFaceObservations = [face]
        try? handler.perform([qualityRequest, landmarksRequest])
        let quality = qualityRequest.results?.first?.faceCaptureQuality ?? 0.5
        parts.append(("quality", clamp01(quality)))

        // Pose: each axis costs separately, so a turn and a tilt together score
        // lower than either alone.
        let degrees = { (n: NSNumber?) in abs(Float(n?.doubleValue ?? 0)) * 180 / .pi }
        let yaw = degrees(face.yaw), pitch = degrees(face.pitch), roll = degrees(face.roll)
        let pose = clamp01(1 - yaw / Self.poseLimitDegrees) * clamp01(1 - pitch / Self.poseLimitDegrees) * clamp01(1 - roll / (Self.poseLimitDegrees * 0.66))
        parts.append(("pose", pose))
        let tilted = selfie && (pitch > Self.tiltedPitchDegrees || yaw > Self.tiltedYawDegrees)

        // Light, from a 64px copy of the face with a little margin.
        let size = CGSize(width: image.width, height: image.height)
        let pad = box.insetBy(dx: -box.width * 0.1, dy: -box.height * 0.1).intersection(CGRect(x: 0, y: 0, width: 1, height: 1))
        let faceStats = Self.stats(of: image, region: pad, side: 64)
        let imageStats = Self.stats(of: image, region: CGRect(x: 0, y: 0, width: 1, height: 1), side: 32)
        var light: Float = 0.5
        if let f = faceStats {
            let exposure = clamp01(1 - abs(f.mean - 0.5) / 0.35)
            let clip = clamp01(1 - f.clipped / 0.2)
            let balance = clamp01(1 - abs(f.left - f.right) / 0.25)
            let backlit = clamp01(1 - ((imageStats?.mean ?? f.mean) - f.mean - 0.05) / 0.25)
            // Skin reads warm: red at or above green at or above blue, and not
            // by a wild margin. Anything else is a cast.
            let cast = Self.colourCast(r: f.r, g: f.g, b: f.b)
            light = (exposure + clip + balance + backlit + cast) / 5
            // A gate under the v2 selfie rules, a demotion otherwise.
            if f.mean < 0.08 || f.mean > 0.92 {
                if gates == nil { lowered.append("exposure") } else { filter = filter ?? "exposure" }
            }
            if f.laplacian < Self.blurVariance { filter = filter ?? "blurred" }
        }
        parts.append(("light", light))

        parts.append(("size", clamp01((Float(faceWidth) - 120) / (Self.fullSizePixels - 120))))

        // Mouth, eyes and brows: from the expression reader when it ran, else
        // from Vision's landmarks, with neutral values when it has none.
        var mouth: Float = 0.7, eyes: Float = 0.7, brow: Float = 0.7
        if let e = expression {
            mouth = clamp01(1 - e.smile) * clamp01(1 - e.jawOpen)
            // The more open eye sets the term, so a wink ranks lower; both shut
            // is the filter.
            eyes = clamp01((Self.closedBlink - e.blinkMax) / (Self.closedBlink - 0.1))
            // Raised brows and the wide-eyed stare that goes with them: relaxed eyes squint a little.
            brow = clamp01(1 - e.browUp / 0.5) * clamp01(e.squint / 0.15)
            if e.blinkBoth > Self.closedBlink { filter = filter ?? "eyes closed" }
            else if e.blinkMax >= Self.winkBlink { filter = filter ?? "one eye closed" }
            else if Self.unevenBlinkDrops && e.blinkMax >= Self.unevenBlink && e.blinkMax - e.blinkBoth >= Self.unevenBlinkGap {
                filter = filter ?? "one eye closed"
            }
            // A smile ranks lower, more so with the lips parted. An open mouth without a smile ranks lower.
            let lipsParted = e.jawOpen >= Self.lipsPartedJaw || e.teeth >= Self.teethShowing
            if e.smile >= Self.smileFilter {
                // Brows up or eyes held open with it counts as wide-eyed too,
                // so the two multipliers compound — see `smileBrowUp`.
                smile = lipsParted ? .open : .closed
                if e.browUp >= Self.smileBrowUp || e.eyeWide >= Self.smileEyeWide { wideEyed = true }
            } else if e.jawOpen >= Self.mouthOpenFilter, gates == nil { lowered.append("mouth open") }
            // Wide-eyed by any of three readings: ranked lower, never filtered.
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
                let closed = clamp01(1 - (openness - Self.mouthOpenRatio) / 0.17)
                // Corners above the lips' centre line read as a smile (Vision's y runs up).
                let centre = outerPts.map(\.y).reduce(0, +) / CGFloat(outerPts.count)
                let left = outerPts.min { $0.x < $1.x }!, right = outerPts.max { $0.x < $1.x }!
                let lift = Float(((left.y + right.y) / 2 - centre) / outer.width)
                let neutral = clamp01(1 - (lift - Self.smileLift) / Self.smileRamp)
                mouth = closed * neutral
            }
            let ratios = [lm.leftEye, lm.rightEye].compactMap { bounds($0) }.filter { $0.width > 1 }.map { Float($0.height / $0.width) }
            if !ratios.isEmpty {
                let open = ratios.max()!
                eyes = clamp01((open - Self.eyeClosedRatio) / (Self.eyeOpenRatio - Self.eyeClosedRatio))
                // Two signals together: the eye outline alone brushes against
                // smiling squints, Apple's quality collapses on shut eyes.
                if eyes < 0.3 && quality < 0.3 { filter = filter ?? "eyes closed" }
            }
        }
        parts.append(("mouth", mouth))
        parts.append(("eyes", eyes))
        parts.append(("brow", brow))

        // Selfie gates (v2).

        // Each gate is a filter; the first filter found stays the named one.
        var cameraCm: Float?
        var focalAssumed = false
        var headVsFloor: Float?
        var cover: FaceCover?
        // Pitch and roll from the expression reader when switched on, else Vision's.
        let signedPitch: Float? = ViewController.mediaPipePitchEnabled ? expression?.headPitch : nil
        let selfiePitch = signedPitch.map { abs($0) } ?? pitch
        let mediaPipeRoll: Float? = ViewController.mediaPipeRollEnabled ? expression?.headRoll.map { abs($0) } : nil
        let selfieRoll = mediaPipeRoll ?? roll
        if let gates {
            if selfiePitch > ViewController.gatePitchDegrees { filter = filter ?? "head pitched" }
            // The camera well below or above the face — see `cameraBelowGate`, `cameraAboveGate`.
            if let line = ViewController.cameraBelowGate, let p = signedPitch, p >= line { filter = filter ?? "camera below" }
            if let gate = ViewController.cameraAboveGate, let ratio = expression?.faceRatio, ratio >= gate.faceRatio, pitch >= gate.visionPitch {
                filter = filter ?? "camera above"
            }
            // The head against the floor (`headLevelGateEnabled`): phone tilt, plus the angle up
            // to the face from the lens's axis, less MediaPipe's pitch (+ with the camera below).
            if let tilt = gates.camera?.tiltUp, let focal35 = gates.camera?.focal35mm, let p = expression?.headPitch {
                let focalPx = focal35 / 36 * Float(max(image.width, image.height))
                let faceAbove = Float(face.boundingBox.midY - 0.5) * Float(image.height)
                let down = tilt + atan(faceAbove / focalPx) * 180 / .pi - p
                headVsFloor = down
                if ViewController.headLevelGateEnabled {
                    if down >= ViewController.headDownDegrees { filter = filter ?? "head down" }
                    else if down <= -ViewController.headUpDegrees { filter = filter ?? "head up" }
                }
            }
            if yaw > ViewController.gateYawDegrees { filter = filter ?? "head turned" }
            if ViewController.rollGateEnabled, selfieRoll >= ViewController.gateRollDegrees { filter = filter ?? "head tilted" }
            // The jaw gates every face; the teeth only one that is not smiling —
            // see `smileKeepsTeeth`.
            if let e = expression {
                if e.jawOpen >= Self.mouthOpenFilter { filter = filter ?? "mouth open" }
                if e.smile < Self.smileKeepsTeeth, e.teeth >= Self.teethShowing { filter = filter ?? "teeth showing" }
                // Eyes off the camera.
                if ViewController.lookingAwayGateEnabled, let o = ViewController.gazeOffset(e) {
                    if hypot(o.side, o.vert) >= ViewController.lookingAwayDegrees { filter = filter ?? "looking away" }
                    else if o.vert <= -ViewController.lookingUpDegrees { filter = filter ?? "looking up" }
                    else if o.vert >= ViewController.lookingDownDegrees { filter = filter ?? "looking down" }
                    else if let line = ViewController.lookingDownConfirmed, o.vert >= line.degrees, e.gazeDown >= line.mediaPipe { filter = filter ?? "looking down" }
                }
            }
            // The face contour at the frame's edge: a chin or an ear the box's
            // margin above still clears. The hairline has no landmark; the box
            // test keeps the top.
            if let contour = landmarksRequest.results?.first?.landmarks?.faceContour?.pointsInImage(imageSize: size),
               contour.contains(where: { $0.x < size.width * 0.01 || $0.x > size.width * 0.99 || $0.y < size.height * 0.01 }) {
                filter = filter ?? "face cut by the frame"
            }
            // Camera to face: focal length in the original's pixels, then the iris (11.7 mm) or
            // the eye spacing. A lens length with no 35 mm equivalent gives no distance;
            // a photo with no camera data is read as a phone's front camera.
            let focal35: Float?
            if let known = gates.camera?.focal35mm { focal35 = known }
            else if gates.camera?.focalMm != nil { focal35 = nil }
            else { focal35 = ViewController.assumedFocal35mm; focalAssumed = true }
            if let focal35 {
                let focalPx = focal35 / 36 * gates.originalLongSide
                if let iris = expression?.irisPixels, iris > 0 {
                    cameraCm = focalPx * ViewController.irisMm / (iris * gates.originalScale) / 10
                } else if let eyes = gates.eyeSpacingOriginal, eyes > 0 {
                    cameraCm = focalPx * ViewController.eyeSpacingMm / eyes / 10
                }
            }
            if ViewController.tooCloseGateEnabled, let cm = cameraCm, cm < ViewController.tooCloseCm { filter = filter ?? "too close" }
            if ViewController.noCameraDataGateEnabled, gates.camera?.present == false { filter = filter ?? "no camera data" }
            if let line = ViewController.tooDarkISO, let iso = gates.camera?.iso, iso >= line { filter = filter ?? "too dark" }
            if ViewController.scarfGateEnabled, (labels["scarf"] ?? 0) >= ViewController.scarfConfidence {
                filter = filter ?? "scarf or high collar"
            }
            // What covers the face. The segmenter runs last and only for a
            // selfie nothing above has dropped.
            if capped { filter = filter ?? "cap or hat" }
            if filter == nil { cover = coverReader?(expression) }
            if let cover {
                if cover.hairline >= ViewController.coverHairlineLimit { filter = filter ?? "hairline covered" }
                if cover.jaw >= ViewController.coverJawLimit { filter = filter ?? "jaw covered" }
                if cover.face >= ViewController.coverFaceLimit { filter = filter ?? "face covered" }
            }
        }
        self.cameraCm = cameraCm
        self.focalAssumed = focalAssumed
        self.cover = cover

        // Sharpness and raw readings.

        // Sharpness on a log scale: variance 1e-3 scores 0, 3e-2 scores 1.
        let sharp = faceStats.map { clamp01((log10(max($0.laplacian, 1e-8)) + 3) / 1.5) } ?? 0.5
        parts.append(("sharp", sharp))

        // Raw readings for `breakdown`, one assignment each: a single literal this long
        // is too much for the type-checker.
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
        readings["handNearFace"] = handNearFace ? 1 : 0
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
            // Recorded only, not scored.
            readings["gazeUp"] = fixed(e.gazeUp, 2)
            readings["gazeDown"] = fixed(e.gazeDown, 2)
            readings["gazeSide"] = fixed(e.gazeSide, 2)
            if let y = e.eyeYaw { readings["eyeYaw"] = fixed(y, 2) }
            if let p = e.eyePitch { readings["eyePitch"] = fixed(p, 2) }
            // The resting point the gaze was measured from.
            if e.eyeYaw != nil {
                let rest = ViewController.gazeRest
                readings["gazeRestYaw"] = fixed(rest.yaw, 2)
                readings["gazeRestPitch"] = fixed(rest.pitch, 2)
            }
            if let ratio = e.faceRatio { readings["faceRatio"] = fixed(ratio, 3) }
            if let detail = e.faceDetail { readings["faceDetail"] = fixed(detail, 3) }
            // Recorded only, not scored: eye openness by the lid gap.
            if let gap = e.lidGap { readings["lidGap"] = fixed(gap, 3) }
            // Two decimals, so it is clear which side of the camera-below line a reading falls.
            if let p = e.headPitch { readings["mpPitch"] = fixed(p, 2) }
            if let y = e.headYaw { readings["mpYaw"] = fixed(y, 2) }
            if let r = e.headRoll { readings["mpRoll"] = fixed(r, 2) }
        }
        if let cm = cameraCm { readings["cameraCm"] = fixed(cm, 1) }
        if let gates {
            if let iris = expression?.irisPixels { readings["irisPx"] = fixed(iris * gates.originalScale, 1) }
            if let eyes = gates.eyeSpacingOriginal { readings["eyeSpacingPx"] = fixed(eyes, 1) }
            if let focal = gates.camera?.focal35mm { readings["focal35"] = fixed(focal, 1) }
            if let iso = gates.camera?.iso { readings["iso"] = fixed(iso, 0) }
            if let exposure = gates.camera?.exposure { readings["exposureMs"] = fixed(exposure * 1000, 2) }
            readings["focalAssumed"] = focalAssumed ? 1 : 0
            if let camera = gates.camera { readings["cameraData"] = camera.present ? 1 : 0 }
            if let tilt = gates.camera?.tiltUp { readings["cameraTilt"] = fixed(tilt, 1) }
            if let down = headVsFloor { readings["headVsFloor"] = fixed(down, 1) }
        }
        if let cover {
            // Recorded only, not scored: light evenness on the skin.
            if let ratio = cover.skinSideRatio { readings["skinSideRatio"] = fixed(ratio, 3) }
            readings["coverHairline"] = fixed(cover.hairline, 2)
            readings["coverJaw"] = fixed(cover.jaw, 2)
            readings["coverFace"] = fixed(cover.face, 2)
        }
        self.readings = readings

        self.expression = expression
        self.labels = labels
        self.handOnFace = handOnFace
        self.handNearFace = handNearFace
        self.capped = capped
        self.tilted = tilted
        self.smile = smile
        self.wideEyed = wideEyed
        self.lowered = lowered
        self.outfit = outfit
        self.document = document
        let dressy = outfit.dressy >= Self.dressyConfidence
        let busy = outfit.busy >= Self.busyTorso
        self.dressy = dressy
        self.busy = busy

        // Pre-v2 score: bands and multipliers.

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

        // Selfie score (v2).

        // `gates` is passed for selfies only. Replaces the pre-v2 parts, bands and multipliers.
        var tier: String?
        var reasons: [String] = []
        var groupSignals: [String: [(why: String, value: Float)]] = [:]
        var hows: [String: String] = [:]
        var wideEyesV2 = false
        if ViewController.selfieScoreV2, let gates {
            typealias V = ViewController
            func ramped(_ why: String, _ reading: Float, _ curve: (good: Float, bad: Float)) -> (String, Float) {
                let value = ramp(reading, curve)
                hows[why] = V.rampHow(reading, curve, value)
                return (why, value)
            }
            func noted(_ why: String, _ value: Float, _ how: String) -> (String, Float) {
                hows[why] = how
                return (why, value)
            }
            // The lowest of a group's signals, and what it was. Every signal is
            // kept for the page's score sheet — see `signals`.
            func lowest(_ group: String, _ signals: [(why: String, value: Float)]) -> Float {
                groupSignals[group] = signals
                guard let low = signals.min(by: { $0.value < $1.value }) else { return 1 }
                if low.value < 1 { reasons.append(low.why) }
                return low.value
            }
            var poseSignals: [(String, Float)] = [
                ramped(String(format: "pitch %.0f°", selfiePitch), selfiePitch, V.posePitch),
                ramped(String(format: "yaw %.0f°", yaw), yaw, V.poseYaw),
                ramped(String(format: "roll %.0f°", selfieRoll), selfieRoll, mediaPipeRoll == nil ? V.poseRoll : V.mediaPipeRoll),
            ]
            if let cm = cameraCm { poseSignals.append(ramped(String(format: "camera %.0f cm", cm), cm, V.poseDistance)) }
            if let slope = V.cameraBelowSlope, let p = signedPitch, p > slope.good {
                let sloped = ramp(p, slope)
                poseSignals.append(noted(String(format: "camera below %+.1f°", p), max(sloped, V.cameraBelowCap),
                    "(\(shortNumber(slope.bad)) − \(shortNumber(p))) ÷ (\(shortNumber(slope.bad)) − \(shortNumber(slope.good))) = \(String(format: "%.2f", sloped))" + (sloped < V.cameraBelowCap ? ", never under \(shortNumber(V.cameraBelowCap))" : "")))
            }
            let poseGroup = lowest("pose", poseSignals)

            var lightSignals: [(String, Float)] = []
            if let f = faceStats {
                let bright = max(f.left, f.right), dark = max(min(f.left, f.right), 0.01)
                lightSignals.append(ramped(String(format: "uneven light %.1f×", bright / dark), bright / dark, V.lightEvenness))
                if let whole = imageStats {
                    let ratio = f.mean / max(whole.mean, 0.01)
                    lightSignals.append(ramped(String(format: "backlit %.2f", ratio), ratio, V.lightBacklight))
                }
                // In percent, so the working reads in the label's units.
                lightSignals.append(ramped(String(format: "blown %.0f%%", f.blown * 100), f.blown * 100, (V.lightClipped.good * 100, V.lightClipped.bad * 100)))
                let cast = Self.colourCast(r: f.r, g: f.g, b: f.b)
                lightSignals.append(noted("colour cast", cast, "red \(shortNumber(f.r)), green \(shortNumber(f.g)), blue \(shortNumber(f.b)): red ≥ green ≥ blue is skin-like, 1 (0.7 when red − blue is over 0.5); any other order 0.6"))
            }
            if let curve = V.lowLightISO, let iso = gates.camera?.iso {
                lightSignals.append(ramped(String(format: "low light, ISO %.0f", iso), iso, curve))
            }
            let lightGroup = lowest("light", lightSignals)

            // How far the eyes point from their resting point on the screen; 1 when off or unread.
            var gazeSignals: [(String, Float)] = []
            if let curve = V.gazeCurve, let off = V.gazeOff(expression) {
                gazeSignals.append(ramped(String(format: "eyes %.0f° off the screen", off), off, curve))
            }
            let gazeGroup = lowest("gaze", gazeSignals)

            var expressionSignals: [(String, Float)] = []
            let smileReading = expression.map { "smile \(shortNumber($0.smile))" } ?? "a smile from the lip shape"
            if smile == .closed { expressionSignals.append(noted("closed smile", V.expressionCapped, "\(smileReading), lips closed: capped at \(shortNumber(V.expressionCapped))")) }
            if smile == .open { expressionSignals.append(noted("open smile", V.expressionOpenSmile, "\(smileReading), lips parted or teeth showing: capped at \(shortNumber(V.expressionOpenSmile))")) }
            let wideEyes = wideEyed || (expression?.eyeWide ?? 0) >= V.wideEyesLine
            if wideEyes { expressionSignals.append(noted("wide-eyed", V.expressionCapped, "eyes wide \(shortNumber(expression?.eyeWide ?? 0)) (counts from \(shortNumber(V.wideEyesLine))), or brows up with a smile: capped at \(shortNumber(V.expressionCapped))")) }
            if let e = expression {
                if e.pucker >= V.puckerLimit { expressionSignals.append(noted(String(format: "pucker %.2f", e.pucker), V.expressionCapped, "\(shortNumber(e.pucker)) is at or over \(shortNumber(V.puckerLimit)): capped at \(shortNumber(V.expressionCapped))")) }
                if e.browDown >= V.frownLimit { expressionSignals.append(noted(String(format: "frown %.2f", e.browDown), V.frownCap, "brows pulled down \(shortNumber(e.browDown)), at or over \(shortNumber(V.frownLimit)): capped at \(shortNumber(V.frownCap))")) }
            }
            let expressionGroup = lowest("expression", expressionSignals)

            var visibilitySignals: [(String, Float)] = []
            // Glasses frames read as covering part of the oval; with glasses on
            // that much is allowed for — see `glassesOvalAllowance`.
            let glassesOn = (labels["eyeglasses"] ?? 0) >= V.glassesConfidence
            if let cover {
                let visible = 1 - max(0, cover.face - (glassesOn ? V.glassesOvalAllowance : 0))
                visibilitySignals.append(ramped(String(format: "face %.0f%% visible", visible * 100), visible * 100, (V.visibilityShare.good * 100, V.visibilityShare.bad * 100)))
            }
            if (labels["eyeglasses"] ?? 0) >= V.glassesConfidence { visibilitySignals.append(noted("glasses", V.glassesCap, "glasses label \(shortNumber(labels["eyeglasses"] ?? 0)), at or over \(shortNumber(V.glassesConfidence)): capped at \(shortNumber(V.glassesCap))")) }
            let visibilityGroup = lowest("visibility", visibilitySignals)

            var detailSignals: [(String, Float)] = [noted(String(format: "sharpness %.2f", sharp), sharp, "the face's sharpness, 0–1, used as it is")]
            if let eyes = gates.eyeSpacingOriginal { detailSignals.append(ramped(String(format: "eyes %.0f px apart", eyes), eyes, V.detailEyeSpacing)) }
            let detailGroup = lowest("detail", detailSignals)

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
            // Body score (v2).
            // The face only had to match: its filters stand down except the document gate.
            if let f = filter, f != "document", f != "handwriting" { filter = nil }
            filter = filter ?? body.filter
            self.parts = body.parts
            // A dressy or busy outfit lowers the value and the tier follows: a busy print
            // hides the body shape like a loose fit.
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
            if outfitMultiplier < 1 {
                let outfitWhy = [dressy && !ViewController.garmentCapsEnabled ? "dressy" : nil, busy ? "busy top" : nil].compactMap { $0 }.joined(separator: " and ")
                reasons.append(String(format: "%@ ×%.2f", outfitWhy, outfitMultiplier))
            }
        } else {
            // Pre-v2 score.
            // Used when neither v2 score applies, e.g. a front or side with no body reading.
            self.parts = parts
            self.value = filter == nil ? banded : 0
        }
        self.filter = filter
        self.tier = tier
        self.reasons = reasons
        self.signals = groupSignals
        self.signalHows = hows
        self.wideEyesV2 = wideEyesV2
        self.body = body
    }

    // MARK: - Gaze re-score

    /// The same selfie score with gaze measured from another resting point. Nil when
    /// there is nothing to re-measure: not a scored v2 selfie, gaze off, eyes unread.
    func regazed(rest: (yaw: Float, pitch: Float)) -> MuseScore? {
        typealias V = ViewController
        guard filter == nil, body == nil, tier != nil, let curve = V.gazeCurve,
              let off = V.gazeOff(expression, rest: rest),
              let index = parts.firstIndex(where: { $0.name == "gaze" }) else { return nil }
        let gaze = ramp(off, curve)
        let why = String(format: "eyes %.0f° off the screen", off)
        var copy = self
        let oldWhy = signals["gaze"]?.first?.why
        copy.parts[index].value = gaze
        copy.signals["gaze"] = [(why, gaze)]
        copy.signalHows[why] = V.rampHow(off, curve, gaze)
        copy.reasons.removeAll { $0 == oldWhy }
        if gaze < 1 { copy.reasons.append(why) }
        copy.value = zip(V.scoreWeightsV2, copy.parts).reduce(Float(1)) { $0 * pow($1.1.value, $1.0.weight) }
        // A Tier B over the line was held there by the eye spacing, which stands.
        let spacingHeld = tier == "B" && value >= V.tierALine
        copy.tier = copy.value >= V.tierALine && !spacingHeld ? "A" : "B"
        copy.readings["gazeRestYaw"] = twoPlaces(rest.yaw)
        copy.readings["gazeRestPitch"] = twoPlaces(rest.pitch)
        return copy
    }

    // MARK: - Page fields

    /// Sent to the page with the match, next to `score`: each part, the penalties and
    /// the filter that zeroed it, so a ranking can be explained.
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
            "scoreParts": Dictionary(parts.map { ($0.name, twoPlaces($0.value)) }) { _, last in last },
            "scoreInputs": readings,
        ]
        // A v2 score sends its tier, which tells the page what it may pre-select, instead of penalties.
        if let tier { fields["tier"] = tier } else if body == nil { fields["scorePenalties"] = penalties }
        if let body {
            var inputs = readings
            for (k, v) in body.readings { inputs[k] = (v * 1000).rounded() / 1000 }
            fields["scoreInputs"] = inputs
            fields["usable"] = tier != nil
            // The clothing colour, for the page's session rule.
            if let outfit = body.outfit { fields["outfit"] = outfit }
        }
        if wideEyesV2 { fields["wideEyes"] = true }
        if let filter { fields["scoreFilter"] = filter }
        // For the page's score sheet: what held each part under 1, and every v2 selfie signal.
        if tier != nil || body != nil { fields["scoreReasons"] = reasons }
        if !signals.isEmpty {
            fields["scoreSignals"] = signals.mapValues { list in
                list.map { ["why": $0.why, "value": twoPlaces($0.value), "how": signalHows[$0.why] ?? ""] as [String: Any] }
            }
        }
        return fields
    }

    // MARK: - Image helpers

    /// The colour-cast term from a face's average colour: 1 for skin-like red ≥ green ≥ blue,
    /// 0.7 when red − blue is over 0.5, 0.6 for any other order.
    static func colourCast(r: Float, g: Float, b: Float) -> Float {
        (r >= g && g >= b) ? (r - b > 0.5 ? 0.7 : 1) : 0.6
    }

    /// The head crop for the expression reader and classifier: the face box with hair
    /// and cap brim inside it. Normalised, bottom-left origin, clipped to the image.
    static func headBox(_ face: CGRect) -> CGRect {
        CGRect(x: face.minX - face.width * 0.6, y: face.minY - face.height * 0.5, width: face.width * 2.2, height: face.height * 2.4)
            .intersection(CGRect(x: 0, y: 0, width: 1, height: 1))
    }

    /// Luminance and colour statistics of one region, from a small square copy: mean, clipped,
    /// blown, left and right half means, average colour, and Laplacian variance for sharpness.
    static func stats(of image: CGImage, region: CGRect, side: Int) -> (mean: Float, clipped: Float, blown: Float, left: Float, right: Float, r: Float, g: Float, b: Float, laplacian: Float)? {
        // Vision's region has its origin at the bottom; CGImage cropping at the top.
        let rect = region.pixels(in: image).integral
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
            let y = luma(r, g, b)
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
        return (mean: luma(sumR, sumG, sumB) / n, clipped: clipped / n, blown: blown / n,
                left: left / (n / 2), right: right / (n / 2), r: sumR / n, g: sumG / n, b: sumB / n,
                laplacian: lapSq / m - lapMean * lapMean)
    }
}
