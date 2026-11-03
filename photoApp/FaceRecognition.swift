// FaceRecognition: face identity embeddings from the SFace Core ML model, and the distance between them.
import Foundation
import Vision
import CoreML
import CoreImage

/// Which face-recognition model the matcher runs: a Core ML package in `FaceModels/`.
/// Only the selected one should be a member of the app target, so the bundle carries one.
enum FaceModel: String {
    /// OpenCV's SFace, Apache-2.0 licence, 8-bit weights.
    case sface = "FaceRecognitionSFace"

    /// The distance (1 − cosine similarity) under which a face is the shopper's.
    /// One cutoff serves fronts, sides and selfies.
    var matchThreshold: Float {
        switch self {
        case .sface: return 0.60
        }
    }
}

/// A face-identity embedding: the face aligned on five landmarks to the model's 112×112 layout, then run
/// through the model. Called from the scan's background queue, one photo at a time.
nonisolated final class FaceRecognizer: @unchecked Sendable {
    private let model: MLModel
    private let context = CIContext()

    /// Loads the compiled model (`<kind>.mlmodelc`) from the app bundle; nil, with the reason printed, when it is missing.
    convenience init?(_ kind: FaceModel) {
        guard let url = Bundle.main.url(forResource: kind.rawValue, withExtension: "mlmodelc") else {
            print("🚫 \(kind.rawValue).mlmodelc is not in the app — is it a member of the target?")
            return nil
        }
        do {
            let config = MLModelConfiguration()
            // Not the GPU: the scan keeps running in the background, where iOS refuses GPU work
            // and every face would come back as "no face".
            config.computeUnits = .cpuAndNeuralEngine
            self.init(kind, model: try MLModel(contentsOf: url, configuration: config))
        } catch {
            print("🚫 Could not load \(kind.rawValue): \(error.localizedDescription)")
            return nil
        }
    }

    init?(_ kind: FaceModel, model: MLModel) {
        guard model.modelDescription.inputDescriptionsByName["face"]?.imageConstraint != nil else {
            print("🚫 \(kind.rawValue) has no image input named \"face\"")
            return nil
        }
        self.model = model
    }

    /// With a box, landmarks are detected in a crop this many times the box rather than the whole image;
    /// the full image is used when the crop finds no face.
    static let landmarkCropScale: CGFloat = 2.5

    /// The identity vector of the face at `box` (Vision's normalised coordinates), or of the largest face when
    /// nil. `seed` must be detected on this same image; without it the face is detected afresh. Nil without landmarks.
    func embedding(in image: CGImage, near box: CGRect? = nil, seed: VNFaceObservation? = nil) -> [Float]? {
        if let seed {
            let request = VNDetectFaceLandmarksRequest()
            request.inputFaceObservations = [seed]
            Self.timed("embed.landmarks") { try? VNImageRequestHandler(cgImage: image, orientation: .up, options: [:]).perform([request]) }
            if let face = request.results?.first, face.landmarks != nil, let result = embed(image, face: face) {
                return result
            }
        }
        if let box, let (crop, cropBox) = Self.crop(image, around: box, scale: Self.landmarkCropScale) {
            if let result = embeddingFresh(in: crop, near: cropBox) { return result }
        }
        return embeddingFresh(in: image, near: box)
    }

    /// A crop of `image` around the normalised `box`, and the box in the crop's own
    /// normalised coordinates. Nil when the crop would be the whole image anyway.
    static func crop(_ image: CGImage, around box: CGRect, scale: CGFloat) -> (CGImage, CGRect)? {
        let region = CGRect(x: box.midX - box.width * scale / 2, y: box.midY - box.height * scale / 2,
                            width: box.width * scale, height: box.height * scale)
            .intersection(CGRect(x: 0, y: 0, width: 1, height: 1))
        guard region.width < 0.9 || region.height < 0.9 else { return nil }
        // Vision's origin is bottom-left; CGImage cropping is top-left.
        let pixels = region.pixels(in: image).integral
        guard pixels.width > 16, pixels.height > 16, let cropped = image.cropping(to: pixels) else { return nil }
        let inCrop = CGRect(x: (box.minX - region.minX) / region.width, y: (box.minY - region.minY) / region.height,
                            width: box.width / region.width, height: box.height / region.height)
        return (cropped, inCrop)
    }

    /// Receives each stage's time in ms (landmarks, alignment, model) for the scan's stage timers. Nil costs nothing.
    nonisolated(unsafe) static var timing: ((String, Double) -> Void)?
    private static func timed<T>(_ stage: String, _ work: () -> T) -> T {
        guard let timing else { return work() }
        let started = Date()
        defer { timing(stage, Date().timeIntervalSince(started) * 1000) }
        return work()
    }

    private func embeddingFresh(in image: CGImage, near box: CGRect?) -> [Float]? {
        let request = VNDetectFaceLandmarksRequest()
        Self.timed("embed.landmarks") { try? VNImageRequestHandler(cgImage: image, orientation: .up, options: [:]).perform([request]) }
        let faces = request.results ?? []
        let face: VNFaceObservation?
        if let box {
            face = faces.max { overlap($0.boundingBox, box) < overlap($1.boundingBox, box) }
                .flatMap { overlap($0.boundingBox, box) > 0.3 ? $0 : nil }
        } else {
            face = faces.max { $0.boundingBox.width * $0.boundingBox.height < $1.boundingBox.width * $1.boundingBox.height }
        }
        guard let face else { return nil }
        return embed(image, face: face)
    }

    /// Intersection over union of two boxes.
    private func overlap(_ a: CGRect, _ b: CGRect) -> CGFloat {
        let i = a.intersection(b)
        guard !i.isNull else { return 0 }
        let inter = i.width * i.height
        return inter / (a.width * a.height + b.width * b.height - inter)
    }

    /// 1 − cosine similarity of two unit vectors: 0 is the same face, about 1 unrelated.
    static func distance(_ a: [Float], _ b: [Float]) -> Float {
        1 - zip(a, b).reduce(0) { $0 + $1.0 * $1.1 }
    }

    // MARK: - Alignment

    /// Where the eyes, nose tip and mouth corners sit in the 112×112 crop the
    /// models were trained on — image-left eye first, top-left origin.
    static let template: [CGPoint] = [
        CGPoint(x: 38.2946, y: 51.6963), CGPoint(x: 73.5318, y: 51.5014),
        CGPoint(x: 56.0252, y: 71.7366),
        CGPoint(x: 41.5493, y: 92.3655), CGPoint(x: 70.7299, y: 92.2041),
    ]

    /// The five points, in the image's pixels with Vision's bottom-left origin.
    static func fivePoints(_ face: VNFaceObservation, width: Int, height: Int) -> [CGPoint]? {
        guard let lm = face.landmarks, let leftEye = lm.leftEye, let rightEye = lm.rightEye,
              let crest = lm.noseCrest, let lips = lm.outerLips else { return nil }
        let size = CGSize(width: width, height: height)
        func centre(_ region: VNFaceLandmarkRegion2D) -> CGPoint? {
            let points = region.pointsInImage(imageSize: size)
            guard !points.isEmpty else { return nil }
            return CGPoint(x: points.map(\.x).reduce(0, +) / CGFloat(points.count),
                           y: points.map(\.y).reduce(0, +) / CGFloat(points.count))
        }
        guard let a = centre(leftEye), let b = centre(rightEye),
              // The crest runs down the bridge of the nose; its lowest point is the tip.
              let tip = crest.pointsInImage(imageSize: size).min(by: { $0.y < $1.y })
        else { return nil }
        let mouth = lips.pointsInImage(imageSize: size)
        guard let left = mouth.min(by: { $0.x < $1.x }), let right = mouth.max(by: { $0.x < $1.x }) else { return nil }
        let eyes = [a, b].sorted { $0.x < $1.x }
        return [eyes[0], eyes[1], tip, left, right]
    }

    /// Least-squares rotation, uniform scale and shift taking `src` onto `dst`.
    static func similarity(from src: [CGPoint], to dst: [CGPoint]) -> CGAffineTransform {
        let n = CGFloat(src.count)
        let ms = CGPoint(x: src.map(\.x).reduce(0, +) / n, y: src.map(\.y).reduce(0, +) / n)
        let md = CGPoint(x: dst.map(\.x).reduce(0, +) / n, y: dst.map(\.y).reduce(0, +) / n)
        var a: CGFloat = 0, b: CGFloat = 0, norm: CGFloat = 0
        for (s, d) in zip(src, dst) {
            let sx = s.x - ms.x, sy = s.y - ms.y, dx = d.x - md.x, dy = d.y - md.y
            a += sx * dx + sy * dy
            b += sx * dy - sy * dx
            norm += sx * sx + sy * sy
        }
        let c = a / norm, s = b / norm
        return CGAffineTransform(a: c, b: s, c: -s, d: c,
                                 tx: md.x - (c * ms.x - s * ms.y), ty: md.y - (s * ms.x + c * ms.y))
    }

    /// The face warped onto the 112×112 template, still a Core Image recipe.
    func alignedImage(_ image: CGImage, face: VNFaceObservation) -> CIImage? {
        guard let src = Self.fivePoints(face, width: image.width, height: image.height) else { return nil }
        // Core Image shares Vision's bottom-left origin, so the template is flipped to match.
        let dst = Self.template.map { CGPoint(x: $0.x, y: 112 - $0.y) }
        return CIImage(cgImage: image).transformed(by: Self.similarity(from: src, to: dst))
    }

    /// One reused 112×112 pixel buffer the aligned face is rendered into for the model, which avoids a
    /// per-call image conversion. Render and prediction share it, so they run under `bufferLock`.
    private let bufferLock = NSLock()
    private lazy var faceBuffer: CVPixelBuffer? = {
        var buffer: CVPixelBuffer?
        let attrs = [kCVPixelBufferCGImageCompatibilityKey: true, kCVPixelBufferCGBitmapContextCompatibilityKey: true] as CFDictionary
        CVPixelBufferCreate(nil, 112, 112, kCVPixelFormatType_32BGRA, attrs, &buffer)
        return buffer
    }()

    /// Align and embed one detected face from `image`.
    private func embed(_ image: CGImage, face: VNFaceObservation) -> [Float]? {
        guard let buffer = faceBuffer else { return nil }
        guard let warped = Self.timed("embed.align", { alignedImage(image, face: face) }) else { return nil }
        bufferLock.lock(); defer { bufferLock.unlock() }
        Self.timed("embed.align") {
            context.render(warped, to: buffer, bounds: CGRect(x: 0, y: 0, width: 112, height: 112), colorSpace: CGColorSpaceCreateDeviceRGB())
        }
        return Self.timed("embed.model") {
            let input = MLFeatureValue(pixelBuffer: buffer)
            guard let provider = try? MLDictionaryFeatureProvider(dictionary: ["face": input]),
                  let output = try? model.prediction(from: provider).featureValue(for: "embedding")?.multiArrayValue
            else { return nil }
            return Self.normalised(output)
        }
    }

    private static func normalised(_ output: MLMultiArray) -> [Float]? {
        var vector = (0..<output.count).map { output[$0].floatValue }
        let length = sqrt(vector.reduce(0) { $0 + $1 * $1 })
        guard length > 0 else { return nil }
        for i in vector.indices { vector[i] /= length }
        return vector
    }
}
