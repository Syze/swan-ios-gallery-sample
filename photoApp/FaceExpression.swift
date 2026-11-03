// FaceExpression: expression, gaze and head angle of a matched face, from MediaPipe's face landmarker.
import Foundation
import UIKit
import MediaPipeTasksVision

/// The expression on a matched face, read by MediaPipe's face landmarker from the head crop.
/// The model loads once, on first use; when it is missing `read` returns nil and the score uses Vision's geometry.
struct FaceExpression {
    /// Mean of the left and right smile blendshapes, 0–1.
    let smile: Float
    let jawOpen: Float
    let blinkLeft: Float
    let blinkRight: Float
    /// Inner brows raised, 0–1 (a stare or surprise). Head tilt can inflate it.
    let browUp: Float
    /// Mean of the two squint blendshapes, 0–1. Near 0 is a wide-eyed stare.
    let squint: Float
    /// The larger of the two eye-wide blendshapes, 0–1: the lids pulled open beyond rest.
    let eyeWide: Float
    /// Teeth showing, 0–1: upper lip raised or lower lip pulled down, the larger of the two pairs' means.
    let teeth: Float
    /// Eye direction from the eye-look blendshapes, 0–1. `gazeDown` feeds the looking-down filter;
    /// `gazeUp` and `gazeSide` are sent to the page for analysis; no rule uses them yet.
    let gazeUp: Float
    let gazeDown: Float
    let gazeSide: Float
    /// Eye rotation in the head, in degrees, mean of both eyes, from the iris centre against the eye corners.
    /// Yaw is positive toward the image's right, pitch positive downward. Nil without iris points.
    let eyeYaw: Float?
    let eyePitch: Float?
    /// Iris diameter in crop pixels, mean of both irises (points 468–477). An iris is about 11.7 mm across,
    /// so this gives the distance to the face. Nil without iris points.
    let irisPixels: Float?
    /// Lips pushed forward, lips rounded, lips pressed, brows pulled down (a frown), each 0–1.
    /// Read by the selfie score's expression group.
    let pucker: Float
    let funnel: Float
    let press: Float
    let browDown: Float
    /// Nose-to-brow over nose-to-chin length (landmarks 9, 1, 152): lower when the camera is below the face,
    /// higher when above. Read by `ViewController.cameraAboveGate`. Nil without landmarks.
    let faceRatio: Float?
    /// Fine detail on the face: `laplacianVariance` of the box the landmarks span. Compared with the
    /// shopper's other selfies for the relative blur gate. Nil without landmarks.
    let faceDetail: Float?
    /// Head angle to the camera from the landmarker's face transform, in degrees, signed; pitch is
    /// positive when the camera looks up at the face. Nil without the transform.
    let headPitch: Float?
    let headYaw: Float?
    let headRoll: Float?
    /// Eye openness: lid gap (159–145, 386–374) over iris width, the narrower eye. Sent to the page
    /// for analysis; no rule uses it yet. Nil without iris points.
    let lidGap: Float?
    /// The landmarker's points in the head crop, 0–1, top-left origin; used by `FaceCover.read`. Empty without landmarks.
    let landmarks: [CGPoint]

    /// Blink of the more closed eye: high for a wink as well as for both eyes shut.
    var blinkMax: Float { max(blinkLeft, blinkRight) }
    /// Blink of the more open eye: high only when both eyes are shut.
    var blinkBoth: Float { min(blinkLeft, blinkRight) }

    /// `FaceModels/face_landmarker.task`: float16, with blendshapes.
    static let modelName = "face_landmarker"

    /// Built once, on first access (thread-safe). CPU delegate: the scan keeps running in the
    /// background, where iOS refuses GPU work.
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

    /// The Laplacian variance of an image drawn grey at `side` × `side`, × 1000:
    /// how much fine detail it holds. Motion blur and missed focus take it down.
    static func laplacianVariance(_ image: CGImage, side: Int = 256) -> Float? {
        var pixels = [UInt8](repeating: 0, count: side * side)
        let drawn = pixels.withUnsafeMutableBytes { raw -> Bool in
            guard let context = CGContext(data: raw.baseAddress, width: side, height: side, bitsPerComponent: 8, bytesPerRow: side,
                                          space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGImageAlphaInfo.none.rawValue) else { return false }
            context.interpolationQuality = .medium
            context.draw(image, in: CGRect(x: 0, y: 0, width: side, height: side))
            return true
        }
        guard drawn else { return nil }
        var sum = 0.0, sumSquares = 0.0, count = 0.0
        for y in 1..<(side - 1) {
            for x in 1..<(side - 1) {
                let i = y * side + x
                let v = (4 * Double(pixels[i]) - Double(pixels[i - 1]) - Double(pixels[i + 1]) - Double(pixels[i - side]) - Double(pixels[i + side])) / 255
                sum += v; sumSquares += v * v; count += 1
            }
        }
        let mean = sum / count
        return Float((sumSquares / count - mean * mean) * 1000)
    }

    /// Loads the model now so the first match is not slowed. Called when the reference face is ready.
    static func warmUp() {
        _ = landmarker
    }

    /// The expression in a head crop (the face box with a generous margin, as the landmarker expects).
    /// Nil when the model is missing or no face is found.
    static func read(headCrop: CGImage) -> FaceExpression? {
        guard let landmarker else { return nil }
        guard let image = mpImage(headCrop),
              let result = try? landmarker.detect(image: image),
              let categories = result.faceBlendshapes.first?.categories
        else { return nil }
        var values: [String: Float] = [:]
        for category in categories {
            if let name = category.categoryName { values[name] = category.score }
        }
        func value(_ name: String) -> Float { values[name] ?? 0 }
        var irisPixels: Float?
        var faceRatio: Float?
        var eyeYaw: Float?, eyePitch: Float?
        var faceDetail: Float?
        var lidGap: Float?
        if let points = result.faceLandmarks.first, points.count >= 478 {
            let w = Float(headCrop.width), h = Float(headCrop.height)
            func across(_ a: Int, _ b: Int) -> Float {
                hypot((points[a].x - points[b].x) * w, (points[a].y - points[b].y) * h)
            }
            // Iris width: the outer two of each iris's four rim points, in pixels.
            irisPixels = (across(469, 471) + across(474, 476)) / 2
            let lower = across(1, 152)
            if lower > 0 { faceRatio = across(9, 1) / lower }
            // One eye's rotation: its iris centre against its corners, the
            // corner line turned to run left to right in the image.
            func eyeAngles(iris: Int, corners: (Int, Int), irisWidth: Float) -> (yaw: Float, pitch: Float)? {
                let a = (x: points[corners.0].x * w, y: points[corners.0].y * h)
                let b = (x: points[corners.1].x * w, y: points[corners.1].y * h)
                let (left, right) = a.x <= b.x ? (a, b) : (b, a)
                let length = hypot(right.x - left.x, right.y - left.y)
                guard length > 0, irisWidth > 0 else { return nil }
                let ux = (right.x - left.x) / length, uy = (right.y - left.y) / length
                let dx = points[iris].x * w - (left.x + right.x) / 2
                let dy = points[iris].y * h - (left.y + right.y) / 2
                let millimetres = 11.7 / irisWidth
                let degrees = { (offset: Float) in asin(max(-1, min(1, offset * millimetres / 12))) * 180 / .pi }
                return (degrees(dx * ux + dy * uy), degrees(dy * ux - dx * uy))
            }
            let eyes = [eyeAngles(iris: 468, corners: (33, 133), irisWidth: across(469, 471)),
                        eyeAngles(iris: 473, corners: (362, 263), irisWidth: across(474, 476))].compactMap { $0 }
            if !eyes.isEmpty {
                eyeYaw = eyes.map(\.yaw).reduce(0, +) / Float(eyes.count)
                eyePitch = eyes.map(\.pitch).reduce(0, +) / Float(eyes.count)
            }
            let gaps = [(across(159, 145), across(469, 471)), (across(386, 374), across(474, 476))]
                .compactMap { $0.1 > 0 ? $0.0 / $0.1 : nil }
            lidGap = gaps.min()
            let xs = points.map { $0.x * w }, ys = points.map { $0.y * h }
            if let x0 = xs.min(), let x1 = xs.max(), let y0 = ys.min(), let y1 = ys.max(), x1 > x0, y1 > y0,
               let face = headCrop.cropping(to: CGRect(x: CGFloat(x0), y: CGFloat(y0), width: CGFloat(x1 - x0), height: CGFloat(y1 - y0)).integral) {
                faceDetail = laplacianVariance(face)
            }
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
            eyeYaw: eyeYaw,
            eyePitch: eyePitch,
            irisPixels: irisPixels,
            pucker: value("mouthPucker"),
            funnel: value("mouthFunnel"),
            press: (value("mouthPressLeft") + value("mouthPressRight")) / 2,
            browDown: (value("browDownLeft") + value("browDownRight")) / 2,
            faceRatio: faceRatio,
            faceDetail: faceDetail,
            headPitch: headPitch,
            headYaw: headYaw,
            headRoll: headRoll,
            lidGap: lidGap,
            landmarks: (result.faceLandmarks.first ?? []).map { CGPoint(x: CGFloat($0.x), y: CGFloat($0.y)) })
    }
}
