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
    var ms: Int
    /// Light across the face, read on its skin pixels only (no hair, glasses
    /// frames or background): the median brightness of the brighter side over
    /// the darker side, split on the face's own midline (brow centre to chin).
    /// Nil without landmarks or with too little skin on either side.
    var skinSideRatio: Float? = nil
    /// The skin's mean lightness, CIELAB L* (0–100), over its face-skin pixels.
    var skinL: Float? = nil

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
            + (skinSideRatio.map { String(format: "; skin sides %.2f×", $0) } ?? "")
            + (skinL.map { String(format: " L %.1f", $0) } ?? "")
    }

    /// Reads the head crop. `face` is Vision's face box inside the crop, in the
    /// crop's pixels with the origin at the top left; `landmarks` are the face
    /// landmarker's points on the same crop, 0–1 (`FaceExpression.landmarks`),
    /// for the readings that need the face's geometry.
    static func read(headCrop: CGImage, face: CGRect, landmarks: [CGPoint]? = nil) -> FaceCover? {
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
        var cover = FaceCover(hairline: share(hairlineBand, counting: covered),
                              jaw: share(jawBand, counting: covered),
                              face: share(oval, oval: true, counting: notFace),
                              bare: share(hairlineBand, counting: bareSkin),
                              ms: 0)
        if let landmarks, landmarks.count >= 468, let pixels = rgba(small) {
            cover.readSkin(mask: data, width: mw, height: mh, pixels: pixels, imageWidth: small.width,
                           imageHeight: small.height, landmarks: landmarks)
        }
        cover.ms = Int(Date().timeIntervalSince(started) * 1000)
        return cover
    }

    /// The readings on the face's skin pixels. `mask` is the segmenter's class
    /// per pixel, `pixels` the RGBA of the image it read, `landmarks` 0–1 on it.
    private mutating func readSkin(mask: UnsafePointer<UInt8>, width mw: Int, height mh: Int, pixels: [UInt8],
                                   imageWidth: Int, imageHeight: Int, landmarks: [CGPoint]) {
        let sx = Float(mw) / Float(imageWidth), sy = Float(mh) / Float(imageHeight)
        // The midline, brow centre (9) to chin (152), in the mask's pixels.
        let top = (x: Float(landmarks[9].x) * Float(mw), y: Float(landmarks[9].y) * Float(mh))
        let chin = (x: Float(landmarks[152].x) * Float(mw), y: Float(landmarks[152].y) * Float(mh))
        let dx = chin.x - top.x, dy = chin.y - top.y
        var sideA: [Float] = [], sideB: [Float] = []
        var sumL: Float = 0
        for y in 0..<mh {
            for x in 0..<mw where mask[y * mw + x] == Class.faceSkin.rawValue {
                let px = min(imageWidth - 1, Int(Float(x) / sx)), py = min(imageHeight - 1, Int(Float(y) / sy))
                let i = (py * imageWidth + px) * 4
                let r = Float(pixels[i]) / 255, g = Float(pixels[i + 1]) / 255, b = Float(pixels[i + 2]) / 255
                let luma = 0.299 * r + 0.587 * g + 0.114 * b
                let lab = Self.lab(r, g, b)
                sumL += lab.l
                if (Float(x) - top.x) * dy - (Float(y) - top.y) * dx > 0 { sideA.append(luma) } else { sideB.append(luma) }
            }
        }
        let count = sideA.count + sideB.count
        if count > 100 { skinL = sumL / Float(count) }
        if sideA.count > 50, sideB.count > 50 {
            let a = Self.median(sideA), b = Self.median(sideB)
            skinSideRatio = max(a, b) / max(min(a, b), 0.01)
        }
    }

    /// sRGB, 0–1, to CIELAB under D65.
    static func lab(_ r: Float, _ g: Float, _ b: Float) -> (l: Float, a: Float, b: Float) {
        func linear(_ c: Float) -> Float { c <= 0.04045 ? c / 12.92 : pow((c + 0.055) / 1.055, 2.4) }
        let (lr, lg, lb) = (linear(r), linear(g), linear(b))
        let x = (0.4124 * lr + 0.3576 * lg + 0.1805 * lb) / 0.95047
        let y = 0.2126 * lr + 0.7152 * lg + 0.0722 * lb
        let z = (0.0193 * lr + 0.1192 * lg + 0.9505 * lb) / 1.08883
        func f(_ t: Float) -> Float { t > 0.008856 ? cbrt(t) : 7.787 * t + 16 / 116 }
        return (116 * f(y) - 16, 500 * (f(x) - f(y)), 200 * (f(y) - f(z)))
    }

    private static func median(_ values: [Float]) -> Float {
        let sorted = values.sorted()
        return sorted.count % 2 == 1 ? sorted[sorted.count / 2] : (sorted[sorted.count / 2 - 1] + sorted[sorted.count / 2]) / 2
    }

    /// The image's pixels as RGBA bytes, row by row from the top.
    private static func rgba(_ image: CGImage) -> [UInt8]? {
        let w = image.width, h = image.height
        guard let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
                                  space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else { return nil }
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
        guard let data = ctx.data else { return nil }
        return Array(UnsafeBufferPointer(start: data.bindMemory(to: UInt8.self, capacity: w * h * 4), count: w * h * 4))
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
