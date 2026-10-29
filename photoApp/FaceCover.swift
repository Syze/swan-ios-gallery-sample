import Foundation
import UIKit
import MediaPipeTasksVision

/// What covers a matched selfie's face — GALLERY_PICK_V2_PLAN.md, item 2,
/// part 2. The MediaPipe multiclass selfie segmenter (background, hair, body
/// skin, face skin, clothes, accessories; 256×256 input) runs on the same head
/// crop the expression reader uses and says what each pixel is. From that,
/// three shares: clothes or accessories over the hairline band above the
/// brows, over the jaw band inside the chin, and anything that is neither skin
/// nor hair inside the face oval. Hats, masks and scarves by name come from
/// Vision's classifier, which already labels them — see
/// `MuseScore.hatLabels` and `coverLabels`.
///
/// Read only for selfies, and only for one that no cheaper gate has already
/// dropped; the limits live in `ViewController` next to `coverGatesEnabled`.
/// The model loads once, on first use; when it is missing from the bundle the
/// reader is unavailable and the scan goes on without it.
struct FaceCover {
    /// Share of the hairline band that is clothes or accessories, 0–1. Caps
    /// measured 0.37–0.52 on a test library, a hood 0.82, bare heads 0.00–0.12.
    let hairline: Float
    /// Share of the jaw band that is clothes or accessories, 0–1. Bare jaws
    /// read 0.00–0.09 on three libraries; a bare jaw with the chin lowered
    /// onto a dark polo collar read 0.33, so the limit sits above that.
    let jaw: Float
    /// Share of the face oval that is neither skin nor hair, 0–1: an object,
    /// cloth, or the frame's background over the face. Eyeglasses measured
    /// 0.05–0.06, sunglasses 0.26–0.31.
    let face: Float
    /// Share of the hairline band that is hair or skin: a bare head reads high.
    let bare: Float
    let ms: Int

    static let modelName = "selfie_multiclass_256x256"
    /// The crop's longer side is brought down to this before the model, which
    /// takes 256×256 anyway: a full-size crop cost 190–300 ms, most of it the
    /// conversion and resize.
    static let inputPixels = 256

    /// The segmenter's classes, in the model's order.
    private enum Class: UInt8 { case background = 0, hair, bodySkin, faceSkin, clothes, accessories }

    private static let segmenter: ImageSegmenter? = {
        guard let path = Bundle.main.path(forResource: modelName, ofType: "tflite") else {
            print("🚫 \(modelName).tflite is not in the app — is it a member of the target? Face cover is not read.")
            return nil
        }
        let options = ImageSegmenterOptions()
        options.baseOptions.modelAssetPath = path
        options.baseOptions.delegate = .CPU
        options.runningMode = .image
        options.shouldOutputCategoryMask = true
        options.shouldOutputConfidenceMasks = false
        do { return try ImageSegmenter(options: options) } catch {
            print("🚫 Could not load the selfie segmenter: \(error.localizedDescription)")
            return nil
        }
    }()

    static var isAvailable: Bool { segmenter != nil }

    /// Loads the model now rather than on the first selfie.
    static func warmUp() {
        let started = Date()
        guard segmenter != nil else { return }
        print("🧣 Face cover reader ready in \(Int(Date().timeIntervalSince(started) * 1000))ms")
    }

    var note: String {
        String(format: "cover hairline %.2f jaw %.2f face %.2f bare %.2f (%dms)", hairline, jaw, face, bare, ms)
    }

    /// Reads the head crop. `face` is Vision's face box inside the crop, in the
    /// crop's pixels with the origin at the top left.
    static func read(headCrop: CGImage, face: CGRect) -> FaceCover? {
        guard let segmenter else { return nil }
        let started = Date()
        let small = downscaled(headCrop) ?? headCrop
        let scale = CGFloat(small.width) / CGFloat(headCrop.width)
        guard let image = try? MPImage(uiImage: UIImage(cgImage: small)),
              let result = try? segmenter.segment(image: image),
              let mask = result.categoryMask, mask.dataType == .uInt8
        else { return nil }
        let mw = mask.width, mh = mask.height
        guard mw > 0, mh > 0 else { return nil }
        let sx = Float(mw) / Float(small.width), sy = Float(mh) / Float(small.height)
        let data = mask.uint8Data
        let box = face.applying(CGAffineTransform(scaleX: scale, y: scale))

        // The share of a band's pixels whose class passes `counting`; inside
        // the inscribed ellipse when `oval`.
        func share(_ rect: CGRect, oval: Bool = false, counting: (UInt8) -> Bool) -> Float {
            let x0 = max(0, Int(Float(rect.minX) * sx)), x1 = min(mw, Int(Float(rect.maxX) * sx))
            let y0 = max(0, Int(Float(rect.minY) * sy)), y1 = min(mh, Int(Float(rect.maxY) * sy))
            guard x1 > x0, y1 > y0 else { return 0 }
            let cx = Float(x0 + x1) / 2, cy = Float(y0 + y1) / 2
            let rx = max(1, Float(x1 - x0) / 2), ry = max(1, Float(y1 - y0) / 2)
            var total = 0, hit = 0
            for y in y0..<y1 {
                for x in x0..<x1 {
                    if oval {
                        let dx = (Float(x) - cx) / rx, dy = (Float(y) - cy) / ry
                        if dx * dx + dy * dy > 1 { continue }
                    }
                    total += 1
                    if counting(data[y * mw + x]) { hit += 1 }
                }
            }
            return total == 0 ? 0 : Float(hit) / Float(total)
        }
        let covered: (UInt8) -> Bool = { $0 == Class.clothes.rawValue || $0 == Class.accessories.rawValue }
        let bareSkin: (UInt8) -> Bool = { $0 == Class.hair.rawValue || $0 == Class.faceSkin.rawValue || $0 == Class.bodySkin.rawValue }
        let notFace: (UInt8) -> Bool = { $0 != Class.faceSkin.rawValue && $0 != Class.bodySkin.rawValue && $0 != Class.hair.rawValue }
        // Vision's box runs from about the brows to the chin. The hairline band
        // straddles its top edge. The jaw band stays inside its bottom edge: a
        // collar just under the chin is not a covered jaw (one read 0.42 when
        // the band reached below the box).
        let h = box.height
        let hairlineBand = CGRect(x: box.minX, y: box.minY - 0.25 * h, width: box.width, height: 0.4 * h)
        let jawBand = CGRect(x: box.minX + 0.1 * box.width, y: box.maxY - 0.25 * h, width: box.width * 0.8, height: 0.23 * h)
        let oval = box.insetBy(dx: box.width * 0.1, dy: h * 0.05)
        return FaceCover(hairline: share(hairlineBand, counting: covered),
                         jaw: share(jawBand, counting: covered),
                         face: share(oval, oval: true, counting: notFace),
                         bare: share(hairlineBand, counting: bareSkin),
                         ms: Int(Date().timeIntervalSince(started) * 1000))
    }

    /// The crop with its longer side at `inputPixels`, or nil when it is
    /// already that small.
    private static func downscaled(_ image: CGImage) -> CGImage? {
        let longest = max(image.width, image.height)
        guard longest > inputPixels else { return nil }
        let scale = CGFloat(inputPixels) / CGFloat(longest)
        let w = max(1, Int(CGFloat(image.width) * scale)), h = max(1, Int(CGFloat(image.height) * scale))
        guard let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
                                  space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else { return nil }
        ctx.interpolationQuality = .medium
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
        return ctx.makeImage()
    }
}
