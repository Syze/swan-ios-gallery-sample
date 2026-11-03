// FaceCover: what covers a selfie's face, from MediaPipe's multiclass selfie segmenter.
import Foundation
import UIKit
import MediaPipeTasksVision

/// What covers a matched selfie's face: MediaPipe's selfie segmenter labels each pixel of the head crop.
/// The model loads once, on first use; when it is missing `read` returns nil and the scan goes on without it.
struct FaceCover {
    /// Share of the hairline band (above the brows) that is clothes or accessories, 0–1: caps, hoods.
    let hairline: Float
    /// Share of the jaw band (inside the chin) that is clothes or accessories, 0–1: masks, scarves.
    let jaw: Float
    /// Share of the face oval that is neither skin nor hair, 0–1: glasses, objects or background over the face.
    let face: Float
    /// Median skin brightness of the brighter half of the face over the darker half, split brow to chin.
    /// Sent to the page for analysis; no rule uses it yet. Nil without landmarks or with too little skin.
    var skinSideRatio: Float? = nil

    /// `FaceModels/selfie_multiclass_256x256.tflite`.
    static let modelName = "selfie_multiclass_256x256"
    /// The crop's longer side is scaled to this many pixels before the model, which takes 256×256 anyway;
    /// this saves most of the conversion time.
    static let inputPixels = 256

    /// The segmenter's classes, in the model's order.
    private enum Class: UInt8 { case background = 0, hair, bodySkin, faceSkin, clothes, accessories }

    /// Built once, on first access. CPU delegate, so it also runs while the app is in the background.
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

    /// Loads the model now rather than on the first selfie.
    static func warmUp() {
        _ = segmenter
    }

    /// Reads the head crop; nil when the model is missing. `face` is Vision's face box in crop pixels,
    /// top-left origin; `landmarks` (`FaceExpression.landmarks`) are needed only for `skinSideRatio`.
    static func read(headCrop: CGImage, face: CGRect, landmarks: [CGPoint]? = nil) -> FaceCover? {
        guard let segmenter else { return nil }
        let small = downscaled(headCrop) ?? headCrop
        let scale = CGFloat(small.width) / CGFloat(headCrop.width)
        guard let image = mpImage(small),
              let result = try? segmenter.segment(image: image),
              let mask = result.categoryMask, mask.dataType == .uInt8
        else { return nil }
        let mw = mask.width, mh = mask.height
        guard mw > 0, mh > 0 else { return nil }
        let sx = Float(mw) / Float(small.width), sy = Float(mh) / Float(small.height)
        let data = mask.uint8Data
        let box = face.applying(CGAffineTransform(scaleX: scale, y: scale))

        // The share of a band's pixels whose class passes `counting`; inside the inscribed ellipse when `oval`.
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
        let notFace: (UInt8) -> Bool = { $0 != Class.faceSkin.rawValue && $0 != Class.bodySkin.rawValue && $0 != Class.hair.rawValue }
        // Vision's box runs from about the brows to the chin. The hairline band straddles its top edge;
        // the jaw band stays inside its bottom edge, so a collar just under the chin does not count.
        let h = box.height
        let hairlineBand = CGRect(x: box.minX, y: box.minY - 0.25 * h, width: box.width, height: 0.4 * h)
        let jawBand = CGRect(x: box.minX + 0.1 * box.width, y: box.maxY - 0.25 * h, width: box.width * 0.8, height: 0.23 * h)
        let oval = box.insetBy(dx: box.width * 0.1, dy: h * 0.05)
        var cover = FaceCover(hairline: share(hairlineBand, counting: covered),
                              jaw: share(jawBand, counting: covered),
                              face: share(oval, oval: true, counting: notFace))
        if let landmarks, landmarks.count >= 468, let pixels = rgba(small) {
            cover.readSkin(mask: data, width: mw, height: mh, pixels: pixels, imageWidth: small.width,
                           imageHeight: small.height, landmarks: landmarks)
        }
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
        for y in 0..<mh {
            for x in 0..<mw where mask[y * mw + x] == Class.faceSkin.rawValue {
                let px = min(imageWidth - 1, Int(Float(x) / sx)), py = min(imageHeight - 1, Int(Float(y) / sy))
                let i = (py * imageWidth + px) * 4
                let r = Float(pixels[i]) / 255, g = Float(pixels[i + 1]) / 255, b = Float(pixels[i + 2]) / 255
                let brightness = luma(r, g, b)
                if (Float(x) - top.x) * dy - (Float(y) - top.y) * dx > 0 { sideA.append(brightness) } else { sideB.append(brightness) }
            }
        }
        if sideA.count > 50, sideB.count > 50 {
            let a = median(sideA), b = median(sideB)
            skinSideRatio = max(a, b) / max(min(a, b), 0.01)
        }
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

    /// The crop with its longer side at `inputPixels`, or nil when it is already that small.
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
