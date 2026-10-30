import Foundation
import UIKit
import MediaPipeTasksVision

/// Things held or worn over the body — bags, umbrellas, bicycles, chairs —
/// found by MediaPipe's object detector (EfficientDet-Lite0, int8, 4.6 MB) on
/// a matched front or side, with their boxes. The body score lowers each
/// region by the share of it an object covers, and drops the photo when
/// objects cover about a quarter of the body — GALLERY_PICK_V2_PLAN.md,
/// item 5b. Measured 30 Oct 2026 on the test photos: handbags right in 10 of
/// 12 photos at 0.30 and over, backpacks 9 of 11, bicycles 5 of 5; boxes
/// 8–18% of the frame, bicycles larger. About 40 ms on a Mac.
///
/// The model is loaded once, on first use. When it is not in the bundle no
/// objects are read and the body score stands on the mask alone.
struct BodyObjects {
    struct Object {
        let label: String
        let confidence: Float
        /// Normalised to the image it was read on, top-left origin.
        let box: CGRect
    }

    /// `efficientdet_lite0.tflite` in the app bundle.
    static let modelName = "efficientdet_lite0"
    /// What counts: the detector's names for things that hide the body.
    static let labels: Set<String> = ["handbag", "backpack", "suitcase", "umbrella", "bicycle", "motorcycle", "chair", "bench", "couch"]
    static let confidence: Float = 0.3

    /// Built on first access. CPU delegate, as the other readers: the scan
    /// keeps running in the background, where iOS refuses GPU work.
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

    static var isAvailable: Bool { detector != nil }

    /// Loads the model now rather than on the first front, so that match line
    /// is not a second late.
    static func warmUp() {
        let started = Date()
        guard detector != nil else { return }
        print("🎒 Object reader ready in \(Int(Date().timeIntervalSince(started) * 1000))ms")
    }

    /// The objects in an upright image, strongest first. Empty when the reader
    /// is unavailable or finds none.
    static func read(upright image: CGImage) -> [Object] {
        guard let detector, let mpImage = try? MPImage(uiImage: UIImage(cgImage: image)),
              let result = try? detector.detect(image: mpImage) else { return [] }
        let w = CGFloat(image.width), h = CGFloat(image.height)
        return result.detections.compactMap { d -> Object? in
            guard let c = d.categories.first, let name = c.categoryName, labels.contains(name) else { return nil }
            let b = d.boundingBox
            return Object(label: name, confidence: c.score,
                          box: CGRect(x: b.minX / w, y: b.minY / h, width: b.width / w, height: b.height / h))
        }.sorted { $0.confidence > $1.confidence }
    }
}
