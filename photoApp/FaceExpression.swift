import Foundation
import UIKit
import MediaPipeTasksVision

/// The expression on a matched face, read by MediaPipe's face landmarker from
/// the head crop: its 52 blendshapes reduced to the few the Muse score uses.
/// Smiles, open mouths, closed eyes, winks and raised brows — the things a
/// face has to be free of to read as a "model" face. Measured against 4,000
/// labelled faces, the landmarker calls a smile right 94 times in 100 where
/// lip geometry manages 84, and it is the only one of the two that sees a
/// subtle closed-mouth smile or a raised brow.
///
/// The model is loaded once, on first use. When it is not in the bundle the
/// reader is unavailable and the score falls back to its own lip and eye
/// geometry, so the controller keeps working without it.
struct FaceExpression {
    /// Mean of the left and right smile blendshapes, 0–1.
    let smile: Float
    let jawOpen: Float
    let blinkLeft: Float
    let blinkRight: Float
    /// Inner brows raised, 0–1 — a stare or surprise. Head tilt can inflate it,
    /// which is why the pose term stays with Vision.
    let browUp: Float
    /// Mean of the two squint blendshapes. Near 0 is a wide-eyed stare.
    let squint: Float
    /// The larger of the two eye-wide blendshapes: the lids pulled open beyond
    /// rest. Relaxed faces measure 0.00–0.02, eyes held open 0.05–0.26, with or
    /// without the brows going up.
    let eyeWide: Float
    /// Teeth showing: the upper lip raised or the lower lip pulled down, the
    /// larger of the two pairs' means. Smiles with the lips closed measure
    /// 0.00–0.11, smiles showing teeth 0.2 and up.
    let teeth: Float
    /// Where the eyes point, from the eye-look blendshapes: up and down are
    /// the means of the two eyes, side is the stronger of the two sideways
    /// pairs (left eye in + right eye out, or the reverse). A level head with
    /// the eyes raised or lowered reads here and nowhere else. Logged only;
    /// no limit is set until real values have been seen.
    let gazeUp: Float
    let gazeDown: Float
    let gazeSide: Float
    /// Iris diameter in the crop's pixels, the mean of the two irises from the
    /// landmarker's iris points (468–477). Every iris is about 11.7 mm across,
    /// so with the camera's focal length this gives the distance to the face —
    /// the v2 "too close" gate. Nil when the model gave no iris points.
    let irisPixels: Float?
    /// Lips pushed forward (`mouthPucker`) and rounded (`mouthFunnel`); lips
    /// pressed together, the mean of the two sides; brows pulled down (a
    /// frown), the mean of the two sides. Read for the v2 selfie score's
    /// expression group — see `ViewController.selfieScoreV2`.
    let pucker: Float
    let funnel: Float
    let press: Float
    let browDown: Float
    /// Camera height, logged only (plan, item 3: "camera height, to set"). The
    /// nose-to-brow length over the nose-to-chin length (landmarks 9, 1, 152):
    /// a camera below the face shows the lower face larger, so the ratio falls.
    /// One pair measured 30 Oct 2026: a selfie shot from below 0.72, one at eye
    /// level 0.83. Nil without landmarks.
    let faceRatio: Float?
    /// The head's angle to the camera from the landmarker's face transform, in
    /// degrees, signed; pitch is positive when the camera looks up at the face.
    /// The pitch is what the v2 selfie gate and pose group read — see
    /// `ViewController.mediaPipePitchEnabled`; yaw and roll are logged only.
    /// Nil without the transform.
    let headPitch: Float?
    let headYaw: Float?
    let headRoll: Float?
    let ms: Int

    /// The more open eye: a wink leaves one eye open and scores low here while
    /// `blinkBoth` stays low, so it ranks lower without being filtered out.
    var blinkMax: Float { max(blinkLeft, blinkRight) }
    /// Both eyes shut.
    var blinkBoth: Float { min(blinkLeft, blinkRight) }

    var note: String {
        String(format: "expr smile %.2f jaw %.2f blink %.2f/%.2f brow %.2f wide %.2f teeth %.2f pucker %.2f funnel %.2f press %.2f frown %.2f gaze up %.2f down %.2f side %.2f (%dms)", smile, jawOpen, blinkLeft, blinkRight, browUp, eyeWide, teeth, pucker, funnel, press, browDown, gazeUp, gazeDown, gazeSide, ms)
    }

    /// `face_landmarker.task` in the app bundle, float16 with blendshapes, 3.7 MB.
    static let modelName = "face_landmarker"

    /// Built on first access; Swift makes that thread-safe. CPU delegate on
    /// purpose: the scan keeps running when the app goes to the background, and
    /// iOS refuses GPU work there — the same reason the face matcher avoids it.
    private static let landmarker: FaceLandmarker? = {
        guard let path = Bundle.main.path(forResource: modelName, ofType: "task") else {
            print("🚫 \(modelName).task is not in the app — is it a member of the target? Expression falls back to lip and eye geometry.")
            return nil
        }
        let options = FaceLandmarkerOptions()
        options.baseOptions.modelAssetPath = path
        options.baseOptions.delegate = .CPU
        options.runningMode = .image
        options.numFaces = 1
        options.outputFaceBlendshapes = true
        options.outputFacialTransformationMatrixes = true
        do {
            return try FaceLandmarker(options: options)
        } catch {
            print("🚫 Could not load the face landmarker: \(error.localizedDescription) — expression falls back to lip and eye geometry.")
            return nil
        }
    }()

    static var isAvailable: Bool { landmarker != nil }

    /// Loads the model now rather than on the first match, so the first match
    /// line is not a second late. Called when the reference face is ready.
    static func warmUp() {
        let started = Date()
        guard landmarker != nil else { return }
        print("🙂 Expression reader ready in \(Int(Date().timeIntervalSince(started) * 1000))ms")
    }

    /// The expression in a head crop — the face box with generous margin, so
    /// the landmarker, built for faces that fill the frame, gets what it expects.
    /// Nil when the reader is unavailable or finds no face in the crop.
    static func read(headCrop: CGImage) -> FaceExpression? {
        guard let landmarker else { return nil }
        let started = Date()
        guard let image = try? MPImage(uiImage: UIImage(cgImage: headCrop)),
              let result = try? landmarker.detect(image: image),
              let categories = result.faceBlendshapes.first?.categories
        else { return nil }
        var values: [String: Float] = [:]
        for category in categories {
            if let name = category.categoryName { values[name] = category.score }
        }
        func value(_ name: String) -> Float { values[name] ?? 0 }
        // Iris width: the outer two of each iris's four rim points, in pixels.
        var irisPixels: Float?
        var faceRatio: Float?
        if let points = result.faceLandmarks.first, points.count >= 478 {
            let w = Float(headCrop.width), h = Float(headCrop.height)
            func across(_ a: Int, _ b: Int) -> Float {
                hypot((points[a].x - points[b].x) * w, (points[a].y - points[b].y) * h)
            }
            irisPixels = (across(469, 471) + across(474, 476)) / 2
            let lower = across(1, 152)
            if lower > 0 { faceRatio = across(9, 1) / lower }
        }
        // Euler angles from the transform's rotation part, as MediaPipe's own
        // samples read it.
        var headPitch: Float?, headYaw: Float?, headRoll: Float?
        if let m = result.facialTransformationMatrixes.first, m.rows >= 3, m.columns >= 3 {
            let r = { (row: Int, column: Int) in m.value(atRow: UInt(row), column: UInt(column)) }
            let degrees = { (radians: Float) in radians * 180 / .pi }
            headPitch = degrees(atan2(r(2, 1), r(2, 2)))
            headYaw = degrees(asin(max(-1, min(1, -r(2, 0)))))
            headRoll = degrees(atan2(r(1, 0), r(0, 0)))
        }
        return FaceExpression(
            smile: (value("mouthSmileLeft") + value("mouthSmileRight")) / 2,
            jawOpen: value("jawOpen"),
            blinkLeft: value("eyeBlinkLeft"),
            blinkRight: value("eyeBlinkRight"),
            browUp: value("browInnerUp"),
            squint: (value("eyeSquintLeft") + value("eyeSquintRight")) / 2,
            eyeWide: max(value("eyeWideLeft"), value("eyeWideRight")),
            teeth: max((value("mouthUpperUpLeft") + value("mouthUpperUpRight")) / 2,
                       (value("mouthLowerDownLeft") + value("mouthLowerDownRight")) / 2),
            gazeUp: (value("eyeLookUpLeft") + value("eyeLookUpRight")) / 2,
            gazeDown: (value("eyeLookDownLeft") + value("eyeLookDownRight")) / 2,
            gazeSide: max((value("eyeLookInLeft") + value("eyeLookOutRight")) / 2,
                          (value("eyeLookOutLeft") + value("eyeLookInRight")) / 2),
            irisPixels: irisPixels,
            pucker: value("mouthPucker"),
            funnel: value("mouthFunnel"),
            press: (value("mouthPressLeft") + value("mouthPressRight")) / 2,
            browDown: (value("browDownLeft") + value("browDownRight")) / 2,
            faceRatio: faceRatio,
            headPitch: headPitch,
            headYaw: headYaw,
            headRoll: headRoll,
            ms: Int(Date().timeIntervalSince(started) * 1000))
    }
}
