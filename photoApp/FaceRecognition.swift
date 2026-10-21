import Foundation
import Vision
import CoreML
import CoreImage

/// Which face-recognition model the matcher runs. Each is a Core ML package in
/// `FaceModels/`; only the selected one should be a member of the app target
/// (see the folder's exceptions in the project), so the bundle carries one.
///
/// Measured on full-length, side and selfie photos of two people, head-turned
/// face shots of seven more people, and 1,756 stranger pairs, all on the same
/// five-point alignment:
///
/// - `sface`: OpenCV's SFace, Apache-2.0, 8-bit weights, 9.6MB. Own photos
///   0.30–0.70, strangers 0.643 and up.
/// - `insightFace`: InsightFace's MobileFaceNet (`w600k_mbf`), 8-bit, 3.5MB.
///   Own photos 0.31–0.87, strangers 0.792 and up; on front-facing photos alone
///   the gap is far wider (own under 0.79, strangers over 0.849). Its weights
///   are licensed for non-commercial use only: do not ship it without a
///   commercial licence from InsightFace.
enum FaceModel: String {
    case sface = "FaceRecognitionSFace"
    case insightFace = "FaceRecognitionInsightFace"

    /// The distance under which a face is the shopper's — 1 − cosine similarity.
    /// One cutoff serves fronts, sides and selfies: unlike FeaturePrint, the
    /// distance is about the face, not the framing around it.
    var matchThreshold: Float {
        switch self {
        // Fronts and sides, two libraries: 10/10 and 112/130 (the misses are heads turned
        // past ~45°). Head turned 60–75°: 57/64. Strangers: none under 0.643.
        case .sface: return 0.60
        // Fronts and sides, two libraries: 10/10 and 129/130. Head turned 60–75°:
        // 61/64. Strangers: none under 0.792 — the turned heads set this bar.
        case .insightFace: return 0.75
        }
    }
}

/// A face-recognition embedding: the face aligned on five landmarks to the
/// 112×112 layout both models were trained on, then run through the model,
/// whose output is an identity vector. Two photos of one person land close
/// together whatever the lighting, framing or background — which a general
/// image descriptor such as FeaturePrint does not do.
///
/// Called from the scan's background queue, one photo at a time.
nonisolated final class FaceRecognizer: @unchecked Sendable {
    let kind: FaceModel
    private let model: MLModel
    private let constraint: MLImageConstraint
    private let context = CIContext()

    /// Loads the compiled model from the app bundle, or nil — with the reason
    /// printed — when it is not there.
    convenience init?(_ kind: FaceModel) {
        guard let url = Bundle.main.url(forResource: kind.rawValue, withExtension: "mlmodelc") else {
            print("🚫 \(kind.rawValue).mlmodelc is not in the app — is it a member of the target?")
            return nil
        }
        do {
            let config = MLModelConfiguration()
            // Not the GPU. A scan keeps running when the shopper switches apps, and
            // iOS refuses GPU work from a backgrounded app — every face then came
            // back as "no face" for as long as the app was in the background
            // (about 150 photos in one library run). The Neural Engine and CPU are
            // allowed in the background, and the handoff measured all three within
            // 0.002 of each other.
            config.computeUnits = .cpuAndNeuralEngine
            self.init(kind, model: try MLModel(contentsOf: url, configuration: config))
        } catch {
            print("🚫 Could not load \(kind.rawValue): \(error.localizedDescription)")
            return nil
        }
    }

    init?(_ kind: FaceModel, model: MLModel) {
        guard let constraint = model.modelDescription.inputDescriptionsByName["face"]?.imageConstraint else {
            print("🚫 \(kind.rawValue) has no image input named \"face\"")
            return nil
        }
        self.kind = kind
        self.model = model
        self.constraint = constraint
    }

    /// The identity vector of the face at `box` — Vision's normalised coordinates,
    /// so a box found on any render of this photo fits — or of the largest face
    /// when nil. Nil when the face's landmarks cannot be found, typically a head
    /// turned fully side-on.
    ///
    /// Vision detects the face afresh on this image rather than being handed the
    /// box: seeded with a detection from a smaller render, the landmarks of a turned
    /// head landed wide and one shopper's half-turned sides scored 0.70–0.89 instead
    /// of 0.58–0.61. The box only picks which of the fresh faces is meant.
    /// With a box, the landmarks are detected inside a crop around it (`landmarkCropScale`
    /// times the box) rather than over the whole image: the same fresh detection, on a
    /// fraction of the pixels. The crop falls back to the full image when it finds no face.
    static let landmarkCropEnabled = true
    static let landmarkCropScale: CGFloat = 2.5

    /// With `seed`, a face observation detected on this same image, the landmarks
    /// request skips its own face search and fits points to that face. Only for the
    /// render the seed was detected on: a box from a smaller render lands wide.
    static let seedLandmarks = true

    func embedding(in image: CGImage, near box: CGRect? = nil, seed: VNFaceObservation? = nil) -> [Float]? {
        if Self.seedLandmarks, let seed {
            let request = VNDetectFaceLandmarksRequest()
            request.inputFaceObservations = [seed]
            Self.timed("embed.landmarks") { try? VNImageRequestHandler(cgImage: image, orientation: .up, options: [:]).perform([request]) }
            if let face = request.results?.first, face.landmarks != nil, let result = embed(image, face: face) {
                return result
            }
        }
        if Self.landmarkCropEnabled, let box, let (crop, cropBox) = Self.crop(image, around: box, scale: Self.landmarkCropScale) {
            if let result = embeddingFresh(in: crop, near: cropBox) { return result }
        }
        return embeddingFresh(in: image, near: box)
    }

    /// One-off: how long one prediction takes on the configured compute units
    /// against a CPU-only copy of the model, printed once so a slow model path
    /// shows up in the console. Diagnostic only.
    func benchmark(on face: CGImage) {
        func time(_ model: MLModel) -> Double? {
            guard let input = try? MLFeatureValue(cgImage: face, constraint: constraint, options: nil),
                  let provider = try? MLDictionaryFeatureProvider(dictionary: ["face": input]) else { return nil }
            _ = try? model.prediction(from: provider)
            let started = Date()
            for _ in 0..<10 { _ = try? model.prediction(from: provider) }
            return Date().timeIntervalSince(started) * 100
        }
        guard let url = Bundle.main.url(forResource: kind.rawValue, withExtension: "mlmodelc") else { return }
        let cpu = MLModelConfiguration(); cpu.computeUnits = .cpuOnly
        let all = MLModelConfiguration(); all.computeUnits = .all
        let onCPU = (try? MLModel(contentsOf: url, configuration: cpu)).flatMap(time)
        let onAll = (try? MLModel(contentsOf: url, configuration: all)).flatMap(time)
        let configured = time(model)
        let f = { (v: Double?) in v.map { String(format: "%.1fms", $0) } ?? "n/a" }
        print("🧮 face model, one prediction: configured (CPU+ANE) \(f(configured)) · CPU only \(f(onCPU)) · all units \(f(onAll))")
    }

    /// A crop of `image` around the normalised `box`, and the box in the crop's own
    /// normalised coordinates. Nil when the crop would be the whole image anyway.
    static func crop(_ image: CGImage, around box: CGRect, scale: CGFloat) -> (CGImage, CGRect)? {
        let region = CGRect(x: box.midX - box.width * scale / 2, y: box.midY - box.height * scale / 2,
                            width: box.width * scale, height: box.height * scale)
            .intersection(CGRect(x: 0, y: 0, width: 1, height: 1))
        guard region.width < 0.9 || region.height < 0.9 else { return nil }
        let w = CGFloat(image.width), h = CGFloat(image.height)
        // Vision's origin is bottom-left; CGImage cropping is top-left.
        let pixels = CGRect(x: region.minX * w, y: (1 - region.maxY) * h, width: region.width * w, height: region.height * h).integral
        guard pixels.width > 16, pixels.height > 16, let cropped = image.cropping(to: pixels) else { return nil }
        let inCrop = CGRect(x: (box.minX - region.minX) / region.width, y: (box.minY - region.minY) / region.height,
                            width: box.width / region.width, height: box.height / region.height)
        return (cropped, inCrop)
    }

    /// Where the embedding's time goes, for the scan's stage timers: landmarks,
    /// alignment, model. Set by the host; nil costs nothing.
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

    // MARK: Alignment

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

    /// The face warped onto the template.
    func aligned(_ image: CGImage, face: VNFaceObservation) -> CGImage? {
        guard let warped = alignedImage(image, face: face) else { return nil }
        return context.createCGImage(warped, from: CGRect(x: 0, y: 0, width: 112, height: 112))
    }

    /// The face warped onto the 112×112 template, still a Core Image recipe.
    func alignedImage(_ image: CGImage, face: VNFaceObservation) -> CIImage? {
        guard let src = Self.fivePoints(face, width: image.width, height: image.height) else { return nil }
        // Core Image shares Vision's bottom-left origin, so the template is flipped to match.
        let dst = Self.template.map { CGPoint(x: $0.x, y: 112 - $0.y) }
        return CIImage(cgImage: image).transformed(by: Self.similarity(from: src, to: dst))
    }

    /// Render the aligned face straight into one reused 112×112 pixel buffer and
    /// hand that to the model, instead of making a CGImage and letting Core ML
    /// convert it per call. The prediction itself is about 1ms; the conversion
    /// was most of the rest. One buffer, so the render and the prediction are
    /// serialised under a lock.
    static let directPixelBuffer = true
    private let bufferLock = NSLock()
    private lazy var faceBuffer: CVPixelBuffer? = {
        var buffer: CVPixelBuffer?
        let attrs = [kCVPixelBufferCGImageCompatibilityKey: true, kCVPixelBufferCGBitmapContextCompatibilityKey: true] as CFDictionary
        CVPixelBufferCreate(nil, 112, 112, kCVPixelFormatType_32BGRA, attrs, &buffer)
        return buffer
    }()

    /// Align and embed one detected face from `image`.
    private func embed(_ image: CGImage, face: VNFaceObservation) -> [Float]? {
        if Self.directPixelBuffer, let buffer = faceBuffer {
            guard let warped = Self.timed("embed.align", { alignedImage(image, face: face) }) else { return nil }
            bufferLock.lock(); defer { bufferLock.unlock() }
            Self.timed("embed.align") {
                context.render(warped, to: buffer, bounds: CGRect(x: 0, y: 0, width: 112, height: 112), colorSpace: CGColorSpaceCreateDeviceRGB())
            }
            return Self.timed("embed.model") {
                guard let input = try? MLFeatureValue(pixelBuffer: buffer) as MLFeatureValue?,
                      let provider = try? MLDictionaryFeatureProvider(dictionary: ["face": input]),
                      let output = try? model.prediction(from: provider).featureValue(for: "embedding")?.multiArrayValue
                else { return nil }
                return Self.normalised(output)
            }
        }
        guard let aligned = Self.timed("embed.align", { aligned(image, face: face) }) else { return nil }
        return Self.timed("embed.model") { embedding(aligned: aligned) }
    }

    private static func normalised(_ output: MLMultiArray) -> [Float]? {
        var vector = (0..<output.count).map { output[$0].floatValue }
        let length = sqrt(vector.reduce(0) { $0 + $1 * $1 })
        guard length > 0 else { return nil }
        for i in vector.indices { vector[i] /= length }
        return vector
    }

    /// Unit-length identity vector for an aligned face. Each package carries its
    /// own pixel scaling, so both models take the same 112×112 RGB image.
    func embedding(aligned face: CGImage) -> [Float]? {
        guard let input = try? MLFeatureValue(cgImage: face, constraint: constraint, options: nil),
              let provider = try? MLDictionaryFeatureProvider(dictionary: ["face": input]),
              let output = try? model.prediction(from: provider).featureValue(for: "embedding")?.multiArrayValue
        else { return nil }
        var vector = (0..<output.count).map { output[$0].floatValue }
        let length = sqrt(vector.reduce(0) { $0 + $1 * $1 })
        guard length > 0 else { return nil }
        for i in vector.indices { vector[i] /= length }
        return vector
    }
}
