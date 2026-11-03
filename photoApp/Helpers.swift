// Small helpers shared by the scan, the scores and the photo readers.

import UIKit
import MediaPipeTasksVision

// MARK: - Numbers

/// The middle value; with an even count, the mean of the two middle values.
nonisolated func median(_ values: [Float]) -> Float {
    let sorted = values.sorted()
    return sorted.count % 2 == 1 ? sorted[sorted.count / 2] : (sorted[sorted.count / 2 - 1] + sorted[sorted.count / 2]) / 2
}

/// `value` held to 0–1.
nonisolated func clamp01(_ value: Float) -> Float {
    max(0, min(1, value))
}

/// 1 at `good` or better, 0 at `bad` or worse, a straight line between.
nonisolated func ramp(_ value: Float, _ curve: (good: Float, bad: Float)) -> Float {
    clamp01((value - curve.bad) / (curve.good - curve.bad))
}

// MARK: - Formatting and timing

/// `value` rounded to two decimals, as a Double for the page.
nonisolated func twoPlaces(_ value: Float) -> Double {
    (Double(value) * 100).rounded() / 100
}

/// `value` to two decimals with no trailing zeros ("%g").
nonisolated func shortNumber(_ value: Float) -> String {
    String(format: "%g", twoPlaces(value))
}

/// Whole milliseconds since `start`.
nonisolated func elapsedMs(since start: Date) -> Int {
    Int(Date().timeIntervalSince(start) * 1000)
}

// MARK: - Images

/// Luma of one colour, with the Rec. 601 weights.
nonisolated func luma(_ r: Float, _ g: Float, _ b: Float) -> Float {
    0.299 * r + 0.587 * g + 0.114 * b
}

/// A CGImage wrapped for MediaPipe, or nil when it cannot be.
nonisolated func mpImage(_ image: CGImage) -> MPImage? {
    try? MPImage(uiImage: UIImage(cgImage: image))
}

extension CGRect {
    /// A Vision box (normalised, origin bottom-left) in `image`'s pixels, origin top-left.
    nonisolated func pixels(in image: CGImage) -> CGRect {
        let w = CGFloat(image.width), h = CGFloat(image.height)
        return CGRect(x: minX * w, y: (1 - maxY) * h, width: width * w, height: height * h)
    }
}
