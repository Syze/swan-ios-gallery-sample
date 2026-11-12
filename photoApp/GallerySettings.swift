// Swan Gallery Pick — the scan's tuning values and the small rules that read them.

import UIKit
import Photos
import Vision

extension ViewController {

    // MARK: - Matching

    /// The face-recognition model (see `FaceModel`). Its package in `FaceModels/`
    /// must be a member of the target.
    static let faceModel: FaceModel = .sface

    /// Loaded once, at the first scan. Nil only when the model is missing from the
    /// bundle; the scan then reports it and stops.
    static let faceRecognizer = FaceRecognizer(faceModel)

    /// Match cutoff for every photo type. Lower distance = more similar.
    static let matchThreshold: Float = faceModel.matchThreshold

    /// Gap rule: once every photo is scored, lower the cutoff into the gap between
    /// the shopper's photos and a lookalike's. Borderline matches are shown at the end.
    static let gapCutEnabled = true

    /// On, a match whose face the Muse cannot use (see `MuseScore.filter`) is kept
    /// out of the grid; off, it is shown and ranks last.
    static let unusableFaceDrops = true
    /// On, a photo taken with the flow's own camera goes through the same gates as a scanned one
    /// (selfie gates, body score, loose garment), so the camera cannot sidestep the scan's rules.
    static let captureGatesEnabled = true

    /// Match the face before running body pose (the most expensive request), so a
    /// face at or past `gapCutCeiling` skips pose. A small face, which the final
    /// score re-crops, is only decided early at or past `earlyNoMatchSmallFace`.
    static let matchBeforePose = true
    static let earlyNoMatchSmallFace: Float = 0.75

    /// Decode the next photo while Vision works on this one. Costs one extra render
    /// in memory, about 16 MB.
    static let decodeAhead = true

    // MARK: - Hands

    /// The hand detector runs on a crop of the padded face box times this, instead
    /// of the whole render. Only points inside the face box count, so nothing is lost.
    static let handsCropScale: CGFloat = 1.8

    /// Selfies only: a hand in the padded face box times `handNearFaceScale` (a V sign,
    /// a wave, a hand on the chin) rules the selfie out. Off: only a hand over the face.
    static let handNearFaceDrops = true
    static let handNearFaceScale: CGFloat = 2.5
    /// The hand detector's crop while `handNearFaceDrops` is on: wide enough to
    /// see a whole hand at the edge of that area.
    static let handsNearCropScale: CGFloat = 3.5

    // MARK: - Photo shape and duplicates

    /// Skip a photo from its library record alone, before loading it: longer side
    /// under `minLocalCopyPixels`, or a panorama (flagged, or wider than this ratio).
    static let panoramaAspect = 3.0
    /// On, a landscape photo (wider than tall) is skipped too: portrait photos only (client's call, 3 Nov 2026).
    static let portraitOnly = true
    static func shapeReject(_ asset: PHAsset) -> String? {
        let w = asset.pixelWidth, h = asset.pixelHeight
        guard w > 0, h > 0 else { return nil }
        if max(w, h) < minLocalCopyPixels { return "only \(max(w, h))px" }
        if asset.mediaSubtypes.contains(.photoPanorama) || Double(max(w, h)) / Double(min(w, h)) > panoramaAspect { return "panorama \(w)x\(h)" }
        if portraitOnly && w > h { return "landscape \(w)x\(h)" }
        return nil
    }

    /// Two matches whose Vision feature prints are closer than this repeat one shot
    /// (repeats ~0.2, unrelated ~0.8). Both stay in the grid; the page pre-selects one.
    static let duplicateDistance: Float = 0.2

    static func featurePrint(of image: UIImage) -> VNFeaturePrintObservation? {
        guard let cgImage = image.cgImage else { return nil }
        let request = VNGenerateImageFeaturePrintRequest()
        try? VNImageRequestHandler(cgImage: cgImage, orientation: Self.cgOrientation(image.imageOrientation), options: [:]).perform([request])
        return request.results?.first
    }

    // MARK: - Gap rule and cutoff fallbacks

    /// Only distances under this are searched for the gap: just past the cutoff, so
    /// the first stranger is included.
    static let gapCutCeiling: Float = 0.65

    /// The cut never goes below this, so a tiny library is not split inside the
    /// shopper's own cluster.
    static let gapCutFloor: Float = 0.45

    /// The smallest distance gap that counts as a gap.
    static let gapCutMinGap: Float = 0.08

    /// When the gap rule finds no gap but matches reach `weakReferenceReach`, the
    /// reference is likely a poor selfie and the cut tightens to `weakReferenceCut`.
    static let weakReferenceCutEnabled = true
    static let weakReferenceCut: Float = 0.50
    /// The fallback applies only when a match sits at or above this, so a clean
    /// library is untouched.
    static let weakReferenceReach: Float = 0.55

    /// Matches under this distance are the shopper's "sure" matches, used as a second
    /// reference by the own-photo keep.
    static let ownPhotoCore: Float = 0.40

    /// On, a match the gap rule or weak-reference cut would withdraw stays when its
    /// face is under `ownPhotoKeepLimit` from the nearest sure match (`ownPhotoCore`).
    static let ownPhotoKeepEnabled = true
    static let ownPhotoKeepLimit: Float = 0.48

    /// The sharpest selfie frame must reach this Vision capture quality, else the page
    /// asks for a retake (`selfie-too-blurry`). Set low: quality varies by phone and light.
    static let selfieMinQuality: Float = 0.25

    /// The lowered cutoff for this run's distances, or nil to keep
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

    // MARK: - Faces in the photo

    /// Only consider photos with exactly one face. The best distance over N faces
    /// is a best-of-N draw, so this is a precision fix as much as a speed one.
    static let requireSingleFace = true

    /// Mirror shots: up to this many faces are checked and the photo is one person only if every
    /// face matches the shopper. 1 (client's call, 3 Nov 2026): the shopper with a reflection is a group.
    static let sameShopperFacesMax = 1

    /// How large a second face or body must be, against the largest, to count as
    /// someone else rather than a passer-by, poster or reflection.
    static let bystanderRatio: CGFloat = 0.25

    /// How far (degrees) the reference selfie's head may be turned before a retake is
    /// asked for. Same limits as the library's flat-face rule in `MuseScore`.
    static let selfieMaxYawDegrees: Double = Double(MuseScore.tiltedYawDegrees)
    static let selfieMaxPitchDegrees: Double = Double(MuseScore.tiltedPitchDegrees)

    /// A face narrower than this (pixels, in the best copy the phone holds) is
    /// skipped. Permissive, since a full-body photo has a small face.
    static let minFacePixels: CGFloat = 120

    /// Require the lower body to be visible: only body pose separates a headshot
    /// from a full-length photo.
    static let requireFullBody = true

    /// Face width, as a fraction of the frame's shorter side, for a photo with no
    /// lower body to count as a selfie. Used only while the eye floor is off.
    static let selfieFaceRatio: CGFloat = 0.30

    /// Pupil-to-pupil distance (pixels, in the original photo) under which a face is
    /// too small to be a selfie. The floor applies while `selfieEyeFloorEnabled` is on.
    static let selfieEyeSpacingPixels: CGFloat = 60
    static let selfieEyeFloorEnabled = true

    // MARK: - Selfie gates

    /// On, a selfie is ruled out (score 0, hidden) for head pitch, yaw or roll past
    /// the gates, open mouth, bad exposure, face at the frame edge, or camera too close.
    static let selfieGatesV2 = true
    /// A selfie with the head pitched this far (degrees) or more is ruled out.
    static let gatePitchDegrees: Float = 12
    /// "Camera below": MediaPipe pitch (degrees, positive = camera looking up at the
    /// face) at or over this rules a selfie out. Nil: off.
    static let cameraBelowGate: Float? = 8
    /// "Camera above": rules a selfie out when `FaceExpression.faceRatio` and Vision's
    /// pitch (degrees) both reach these values. Nil: off.
    static let cameraAboveGate: (faceRatio: Float, visionPitch: Float)? = (1.10, 12)
    /// "Head down" / "head up": the head against the floor (`headVsFloor`, + down) at or past
    /// these degrees rules a selfie out; a photo without the phone's tilt is not judged. Off: logged only.
    static let headLevelGateEnabled = true
    static let headDownDegrees: Float = 15
    static let headUpDegrees: Float = 15
    /// "Blurred against usual": at scan end, a selfie whose face detail is under
    /// `relativeBlurShare` of the median over at least `relativeBlurMin` selfies is withdrawn.
    /// Only selfies within `relativeBlurMaxCm` take part, since a far face holds less detail.
    static let relativeBlurGateEnabled = true
    static let relativeBlurShare: Float = 0.45
    static let relativeBlurMin = 5
    static let relativeBlurMaxCm: Float = 60
    /// A selfie with the head turned this far (degrees) or more is ruled out.
    static let gateYawDegrees: Float = 20
    /// "Too close": camera-to-face under `tooCloseCm`, from the iris size or eye spacing
    /// and the focal length. A photo with no camera data is assumed `assumedFocal35mm`.
    static let tooCloseGateEnabled = true
    static let tooCloseCm: Float = 25
    /// Camera-to-face over `tooFarCm` is not an arm's-length selfie (a mirror shot, a photo from
    /// across a room): Tier B, shown but never pre-selected over a Tier A.
    static let tooFarDemotes = true
    static let tooFarCm: Float = 90
    static let irisMm: Float = 11.7
    static let eyeSpacingMm: Float = 63
    static let assumedFocal35mm: Float = 30
    /// A selfie with no camera make, model or focal length (saved from an app) is
    /// ruled out. A photo whose metadata cannot be read in time (iCloud only) is not.
    static let noCameraDataGateEnabled = true
    /// Either eye under `relativeOpenness` of the shopper's median openness (over at
    /// least `relativeBaselineMin` clean selfies) withdraws the selfie at scan end.
    static let relativeEyeGateEnabled = true
    static let relativeOpenness: Float = 0.4
    static let relativeBaselineMin = 3

    // MARK: - Selfie score

    /// On, a selfie that passed the gates scores T (0 to 1): a weighted geometric mean
    /// of six signal groups (`scoreWeightsV2`). T at `tierALine` or above is Tier A.
    static let selfieScoreV2 = true
    static let tierALine: Float = 0.70

    // MARK: - Results order

    /// On, each match carries `order` for the grid and pre-selection, and `takenAt`
    /// (capture time, ms). `score` stays T. Off: the page ranks by `score`.
    static let orderV2Enabled = true
    /// Recency, in months: 1 up to the first, 0 from the second.
    static let selfieRecency: (good: Double, bad: Double) = (12, 36)
    static let fullLengthRecency: (good: Double, bad: Double) = (6, 24)

    /// `order` and `takenAt` for one match. Tier A sends 1 + R so it always ranks
    /// above Tier B, which sends T.
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
            fields["orderParts"] = ["choices": choices, "personal": p, "recency": recency]
        } else {
            r = 0.8 * t + 0.2 * recency
            fields["orderParts"] = ["recency": recency]
        }
        fields["order"] = 1 + r
        return fields
    }

    // MARK: - Selfie score signals

    static let scoreWeightsV2: [(name: String, weight: Float)] = [
        ("pose", 0.30), ("light", 0.20), ("gaze", 0.15), ("expression", 0.15), ("visibility", 0.10), ("detail", 0.10),
    ]
    /// Pose, in degrees: full marks up to `good`, zero at `bad`. Yaw ends at the yaw
    /// gate, so a selfie the gate lets through never scores a zero pose.
    static let posePitch: (good: Float, bad: Float) = (3, 15)
    static let poseYaw: (good: Float, bad: Float) = (5, 20)
    static let poseRoll: (good: Float, bad: Float) = (5, 20)
    /// Camera to face, in centimetres: full marks from 40, zero at the too-close gate.
    static let poseDistance: (good: Float, bad: Float) = (40, 25)
    /// On, the selfie pitch gate and pose group read MediaPipe's signed pitch instead
    /// of Vision's, which over-reads level faces and has no sign. Falls back to Vision.
    static let mediaPipePitchEnabled = true
    /// On, the pose group reads MediaPipe's roll on the `mediaPipeRoll` curve (degrees);
    /// falls back to Vision's roll on `poseRoll`.
    static let mediaPipeRollEnabled = true
    static let mediaPipeRoll: (good: Float, bad: Float) = (2, 30)
    /// A selfie with the head tilted this far (degrees) or more is ruled out. Reads
    /// the same roll as the pose group.
    static let rollGateEnabled = true
    static let gateRollDegrees: Float = 30
    /// The lowest the pose signal goes for a camera below the face.
    static let cameraBelowCap: Float = 0.6
    /// Camera below, in MediaPipe pitch degrees: the pose signal falls from 1 at `good`
    /// toward 0 at `bad`, never under `cameraBelowCap`. Nil: off.
    static let cameraBelowSlope: (good: Float, bad: Float)? = (0, 6)
    /// Light: brighter over darker face half; face over whole frame (backlight);
    /// share of blown-out face pixels. Full marks at `good`, zero at `bad`.
    static let lightEvenness: (good: Float, bad: Float) = (1.3, 2.0)
    static let lightBacklight: (good: Float, bad: Float) = (0.8, 0.4)
    static let lightClipped: (good: Float, bad: Float) = (0.01, 0.05)
    /// Gaze, in degrees from `gazeRest` (where the eyes sit looking at the screen):
    /// full marks up to `good`, zero at `bad`. Nil: gaze scores 1.
    static let gazeCurve: (good: Float, bad: Float)? = (4, 12)
    static let gazeRest: (yaw: Float, pitch: Float) = (0, -7.5)
    /// Share of the head's yaw taken off the eyes' sideways reading, so eyes turned
    /// back to the lens from a turned head count as on the lens.
    static let gazeHeadShare: Float = 0.37

    /// How far the eyes point from the resting point, in degrees (see `gazeCurve`).
    /// Nil without iris points.
    static func gazeOff(_ e: FaceExpression?, rest: (yaw: Float, pitch: Float)? = nil) -> Float? {
        gazeOffset(e, rest: rest).map { hypot($0.side, $0.vert) }
    }

    /// The same, split: sideways (+ toward the image's right) and up or down
    /// (+ downward), in degrees from the resting point.
    static func gazeOffset(_ e: FaceExpression?, rest: (yaw: Float, pitch: Float)? = nil) -> (side: Float, vert: Float)? {
        guard let y = e?.eyeYaw, let p = e?.eyePitch else { return nil }
        let sideways = y - gazeHeadShare * (e?.headYaw ?? 0)
        let rest = rest ?? gazeRest
        return (sideways - rest.yaw, p - rest.pitch)
    }

    /// "Looking away": a selfie with the eyes this far (degrees) off `gazeRest` is ruled
    /// out; up and down have their own, smaller limits. Off: gaze only lowers the score.
    static let lookingAwayGateEnabled = true
    static let lookingAwayDegrees: Float = 12
    static let lookingUpDegrees: Float = 5
    static let lookingDownDegrees: Float = 9
    /// "Looking down" from `degrees` when MediaPipe's `gazeDown` also reads `mediaPipe`
    /// or more (dropped lids hide the iris). Nil: only `lookingDownDegrees`.
    static let lookingDownConfirmed: (degrees: Float, mediaPipe: Float)? = (5, 0.35)

    /// On, at scan end the resting point becomes the median of the shown selfies' eyes
    /// (at least `gazeRestLibraryMin`, within `gazeRestMaxShift`); changed selfies are resent.
    static let gazeRestFromLibrary = true
    static let gazeRestLibraryMin = 5

    /// The working behind a signal read against a curve, for the score sheet.
    static func rampHow(_ reading: Float, _ curve: (good: Float, bad: Float), _ value: Float) -> String {
        let (good, bad) = (curve.good, curve.bad)
        // Higher is better when `good` is above `bad` (distance, eye spacing).
        return value >= 1 ? "\(shortNumber(reading)) is \(good > bad ? "at or above" : "within") \(shortNumber(good)): full marks"
            : value <= 0 ? "\(shortNumber(reading)) is \(good > bad ? "at or below" : "at or past") \(shortNumber(bad)): zero"
            : good > bad ? "(\(shortNumber(reading)) − \(shortNumber(bad))) ÷ (\(shortNumber(good)) − \(shortNumber(bad))) = \(String(format: "%.2f", value))"
            : "(\(shortNumber(bad)) − \(shortNumber(reading))) ÷ (\(shortNumber(bad)) − \(shortNumber(good))) = \(String(format: "%.2f", value))"
    }
    /// How far (degrees, per axis) the library resting point may move from `gazeRest`.
    static let gazeRestMaxShift: Float = 6

    /// On, the reference selfie's head angles come from MediaPipe and its eyes are
    /// checked; a failure sends `selfie-not-frontal`. Falls back to Vision's angles.
    static let selfieCheckMediaPipe = true
    /// Eyes this far (degrees) off the screen or more send the reference selfie back.
    static let selfieMaxGazeDegrees: Float = 12
    /// Low light, from the photo's ISO: full marks up to `good`, zero at `bad`. The
    /// phone brightens a dark face, so only ISO shows it. Nil: no low-light signal.
    static let lowLightISO: (good: Float, bad: Float)? = (1600, 5000)
    /// "Too dark": a selfie at this ISO or over is ruled out. Nil: low light only
    /// lowers the score.
    static let tooDarkISO: Float? = 2500
    /// Expression caps: a closed smile, wide eyes or raised brows, or a pucker cap the
    /// group at `expressionCapped`; an open smile at `expressionOpenSmile`.
    static let expressionCapped: Float = 0.5
    static let expressionOpenSmile: Float = 0.4
    /// Pucker and frown readings at or over these limits cap expression.
    static let puckerLimit: Float = 0.6
    static let frownLimit: Float = 0.25
    /// A frown's cap on expression; other caps use `expressionCapped`.
    static let frownCap: Float = 0.6
    /// At the scan's end the frown is judged against the shopper's own brows: from their usual reading
    /// (median over close selfies) + `frownOverUsual`, never under `frownLimit`, always from `frownCeiling`.
    static let frownRelativeEnabled = true
    static let frownOverUsual: Float = 0.15
    static let frownCeiling: Float = 0.60
    static let frownBaselineMin = 5
    static let frownBaselineMaxCm: Float = 60
    /// Eyes-wide reading from which expression is capped and `wideEyes` is sent; the
    /// page pre-selects such a selfie only when no other Tier A selfie is left.
    static let wideEyesLine: Float = 0.05
    /// Visibility: the share of the face oval that is skin or hair, from
    /// `FaceCover`. Clear glasses cap it at `glassesCap`.
    static let visibilityShare: (good: Float, bad: Float) = (0.95, 0.85)
    static let glassesCap: Float = 0.85
    /// With glasses on, this share of the oval is forgiven before visibility drops,
    /// since the segmenter reads frames as neither skin nor hair. 0: no allowance.
    static let glassesOvalAllowance: Float = 0.08
    static let glassesConfidence: Float = 0.5
    /// Detail: eye spacing, in the original's pixels.
    static let detailEyeSpacing: (good: Float, bad: Float) = (120, 60)
    /// A selfie with eyes under this many pixels apart (in the original) is Tier B
    /// whatever its T: too small to be a good reference. It stays in the grid.
    static let tierAEyeSpacingMin: Float = 90

    // MARK: - Full-length score

    /// On, a matched front, three-quarter or side is scored by `BodyScore` (how clearly
    /// the body shows), not the face. Tier A at `fullLengthTierALine`, usable from the floor.
    static let fullLengthScoreV2 = true
    static let fullLengthTierALine: Float = 0.70
    static let fullLengthUsableFloor: Float = 0.45
    /// On, the outfit multipliers (`MuseScore.outfitMultiplier`) also apply to the body
    /// score. The tier stays the body's own; only the value and order move.
    static let fullLengthOutfitMultiplier = true
    /// On, a garment the classifier names at or over its line caps the body regions
    /// it covers (`BodyScore.Caps`), whatever the fit and outline say.
    static let garmentCapsEnabled = true
    /// On, MediaPipe's object detector (`BodyObjects`, about 80 ms) lowers body regions
    /// covered by a bag, umbrella, bicycle or chair. Off: no detector, no model load.
    static let objectReadEnabled = true
    /// On, a photo in a loose outfit is dropped, not capped: a loose garment hides the body,
    /// so nothing in it can be measured. Loose by label, or by the outline reading wide for the joints.
    static let looseGarmentGateEnabled = true
    /// Garments that hide the body whatever the fit says, at or over this confidence.
    static let looseGarmentLabels: Set<String> = ["gown", "sari", "kimono", "wedding_dress", "cloak", "poncho", "bathrobe", "costume"]
    static let looseGarmentLine: Float = 0.3
    /// Fit at or under which a region reads as loose clothing (torso 0.35 is a width 1.25× the
    /// joints imply). Not when an object covers the region, and legs only when standing with legs apart.
    static let looseTorsoFit: Double = 0.35
    static let looseLegsFit: Double = 0.35
    /// On, a full-length photo whose torso width could not be read gets no tier: it stays in the
    /// grid but is never pre-selected, since the Muse cannot be measured from it.
    static let torsoUnreadNoTier = true
    /// Garment caps: labels, confidence line, then the cap on torso, legs and arms.
    /// `suit` has two lines: a sure suit takes the full cap, a likely one a jacket's.
    static let garmentCaps: [(labels: Set<String>, line: Float, torso: Float, legs: Float, arms: Float)] = [
        (["suit", "tuxedo"], 0.4, 0.2, 1, 0.2),
        (["lab_coat"], 0.3, 0.2, 1, 0.2),
        (["suit", "tuxedo"], 0.22, 0.5, 1, 0.5),
        (["gown", "sari", "kimono", "wedding_dress"], 0.3, 1, 0.2, 1),
        (["hoodie"], 0.5, 0.5, 1, 1),
        (["jacket"], 0.6, 0.5, 1, 0.5),
    ]

    // MARK: - Face cover and documents

    /// On, `FaceCover` reads what covers a matched selfie's face; it is ruled out past
    /// the limits below (share of each region covered), or for a cap or hat label.
    static let coverReadEnabled = true
    static let coverHairlineLimit: Float = 0.3
    static let coverJawLimit: Float = 0.4
    static let coverFaceLimit: Float = 0.15
    /// "Scarf or high collar": a selfie whose head crop Vision calls a scarf at
    /// `scarfConfidence` or more is ruled out. Off: logged only.
    static let scarfGateEnabled = true
    static let scarfConfidence: Float = 0.3
    /// Documents (passport, ID card, printed page) must never reach the Muse or an
    /// upload. A match of any type is ruled out when the classifier's
    /// `documentLabels` sum to `documentLabelSumLimit`, or handwriting reaches
    /// `handwritingLimit`.
    ///
    /// Also ruled out: labels at `documentPageLabelLimit` or more plus a Vision document
    /// page (at `documentConfidenceLog`) holding the face and under `documentPageAreaLimit` of the frame.
    static let documentReadEnabled = true
    static let documentGateEnabled = true
    static let documentLabels: Set<String> = ["document", "printed_page", "screenshot", "passport", "handwriting",
                                              "ticket", "receipt", "text", "id_card", "signature", "paper"]
    static let documentLabelSumLimit: Float = 0.5
    static let handwritingLimit: Float = 0.3
    static let documentPageLabelLimit: Float = 0.3
    static let documentPageAreaLimit: Float = 0.9
    /// Vision's document segmentation counts at this confidence when the matched face
    /// sits inside the document it found.
    static let documentConfidenceLog: Float = 0.8

    // MARK: - Photo type

    /// A face's width against the frame's shorter side — shared so the scan and a
    /// tap cannot disagree about it.
    static func faceRatio(boxWidth: CGFloat, in cgImage: CGImage) -> CGFloat {
        boxWidth * CGFloat(cgImage.width) / CGFloat(min(cgImage.width, cgImage.height))
    }

    /// Pupil to pupil in the image's pixels, from the eye landmarks of one face.
    /// Nil when the face has no landmarks.
    static func eyeSpacing(of face: VNFaceObservation?, in cgImage: CGImage, handler: VNImageRequestHandler? = nil) -> CGFloat? {
        guard var face else { return nil }
        // The scan detects faces as rectangles; fetch landmarks here for this one
        // face, on the handler that already holds the image (a few ms).
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
    /// side when no shoulders are found.
    static let sideYawThreshold = 0.25

    /// How sure Vision must be of a joint before it counts as seen.
    static let bodyJointConfidence: Float = 0.3

    /// Ankles a head-to-toe photo must show. One, since a side photo often hides
    /// the far ankle.
    static let minAnkles = 1

    /// Share of the image height, eyes to lowest ankle, the person must span with
    /// one ankle found; with both, `minBodySpanBothAnkles`.
    static let minBodySpan: CGFloat = 0.55
    static let minBodySpanBothAnkles: CGFloat = 0.40

    /// Room below the lowest ankle, as a fraction of the span, so the feet are in
    /// frame.
    static let minFootRoom: CGFloat = 0.10

    /// Body turn, in degrees, from which a full-length photo is a side. Estimated from
    /// the shoulder spread against a front's spread, to about ±10°.
    static let sideTurnDegrees: Double = 45
    static let frontShoulderSpread: CGFloat = 0.60

    /// `sideTurnDegrees` as a shoulder spread.
    static let sideShoulderSpread: CGFloat = frontShoulderSpread * CGFloat(cos(sideTurnDegrees * .pi / 180))

    /// Turn, in degrees, from which a full-length photo is a three-quarter rather than
    /// a front. Three-quarters and sides both fill side slots on the page.
    static let threeQuarterDegrees: Double = 30
    static let threeQuarterShoulderSpread: CGFloat = frontShoulderSpread * CGFloat(cos(threeQuarterDegrees * .pi / 180))

    /// Joint confidence for the spread, lower than `bodyJointConfidence` because a
    /// side view half hides the far shoulder.
    static let spreadJointConfidence: Float = 0.1

    /// One photo's type, from values the caller already has. Shared by the scan and
    /// `classifyPhotoType` so the two cannot disagree.
    static func photoType(faceRatio: CGFloat, eyeSpacing: CGFloat? = nil, yaw: Double?, body: BodyCheck) -> PhotoType {
        // A selfie is a face with no lower-body joint in frame and big enough eyes.
        // With the eye floor off, a large face ratio also counts.
        let bigEnough = selfieEyeFloorEnabled
            ? (eyeSpacing ?? 0) >= selfieEyeSpacingPixels
            : faceRatio >= selfieFaceRatio || (eyeSpacing ?? 0) >= selfieEyeSpacingPixels
        if body.lowerJoints == 0 && bigEnough { return .selfie }
        // Not a selfie and not head to toe: neither.
        if !body.isHeadToToe { return .unknown }
        // Decided by the body's turn; the head's turn only without shoulders.
        if let spread = body.shoulderSpread {
            if spread < sideShoulderSpread { return .side }
            return spread < threeQuarterShoulderSpread ? .threeQuarter : .front
        }
        guard let yaw else { return .unknown }
        return headType(yaw: yaw)
    }

    /// Front or side by the head's turn alone: the fallback above.
    static func headType(yaw: Double) -> PhotoType {
        abs(yaw) > sideYawThreshold ? .side : .front
    }
}
