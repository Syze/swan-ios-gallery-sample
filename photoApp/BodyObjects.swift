// BodyObjects: bags, umbrellas, bicycles and furniture over the body, from MediaPipe's object detector.
import Foundation
import UIKit
import MediaPipeTasksVision

/// Things held over or beside the body (bags, umbrellas, bicycles, chairs) on a matched front or side,
/// with their boxes. `BodyScore` lowers each body region by the share of it an object covers.
struct BodyObjects {
    struct Object {
        let label: String
        let confidence: Float
        /// Normalised to the image it was read on, top-left origin.
        let box: CGRect
    }

    /// `FaceModels/efficientdet_lite0.tflite` (EfficientDet-Lite0, int8). When it is missing `read`
    /// returns no objects and the body score uses the person mask alone.
    static let modelName = "efficientdet_lite0"
    /// What counts: the detector's names for things that hide the body.
    static let labels: Set<String> = ["handbag", "backpack", "suitcase", "umbrella", "bicycle", "motorcycle", "chair", "bench", "couch"]
    /// Minimum detection score, 0–1.
    static let confidence: Float = 0.3

    /// Built once, on first access. CPU delegate: the scan keeps running in the background,
    /// where iOS refuses GPU work.
    private static let detector: ObjectDetector? = {
        guard let path = Bundle.main.path(forResource: modelName, ofType: "tflite") else {
            print("🚫 \(modelName).tflite is not in the app — is it a member of the target? Objects over the body are not read.")
            return nil
        }
        let options = ObjectDetectorOptions()
        options.baseOptions.modelAssetPath = path
        options.baseOptions.delegate = .CPU
        options.runningMode = .image
        options.scoreThreshold = confidence
        options.categoryAllowlist = Array(labels)
        options.maxResults = 8
        do {
            return try ObjectDetector(options: options)
        } catch {
            print("🚫 Could not load the object detector: \(error.localizedDescription) — objects over the body are not read.")
            return nil
        }
    }()

    /// Loads the model now so the first front is not slowed.
    static func warmUp() {
        _ = detector
    }

    /// The objects in an upright image, strongest first. Empty when the model is missing or finds none.
    static func read(upright image: CGImage) -> [Object] {
        guard let detector, let input = mpImage(image),
              let result = try? detector.detect(image: input) else { return [] }
        let w = CGFloat(image.width), h = CGFloat(image.height)
        return result.detections.compactMap { d -> Object? in
            guard let c = d.categories.first, let name = c.categoryName, labels.contains(name) else { return nil }
            let b = d.boundingBox
            return Object(label: name, confidence: c.score,
                          box: CGRect(x: b.minX / w, y: b.minY / h, width: b.width / w, height: b.height / h))
        }.sorted { $0.confidence > $1.confidence }
    }
}
