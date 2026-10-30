import Foundation
import CoreGraphics
import Vision

/// How clearly the body can be seen under the clothes in a matched full-length
/// photo — GALLERY_PICK_V2_PLAN.md, item 5, part a. The face is not judged
/// here; it only had to match. Vision's person segmentation gives the body's
/// outline and the pose request's joints say where the torso, legs and arms
/// are, so each region can be read for how closely the clothes follow the
/// body (fit), how clearly the outline stands off the background, and how it
/// is lit. The pose adds openness (standing open, leaning, sitting, lying,
/// arms crossed, hands hidden, legs crossed) and the body's sharpness and
/// size give image quality. T = visibility^0.7 × openness^0.2 × quality^0.1,
/// with visibility 0.4 torso + 0.4 legs + 0.2 arms.
///
/// Read only for a matched front, three-quarter or side, after the face
/// matched; the switch and the tier line live in `ViewController` next to
/// `fullLengthScoreV2`. Garment caps (coats, suits) and bags come with part b;
/// a long cardigan or a wide skirt already falls on the legs fit here.
///
/// The starting values below were set on 30 Oct 2026 from five test folders
/// (126 photos, three people) read on the Mac with the same requests.
struct BodyScore {
    /// T, 0–1, and the tier it gives: "A" at `ViewController.fullLengthTierALine`
    /// or above, "B" down to `fullLengthUsableFloor`, below that no tier and
    /// the page does not pre-select it.
    let value: Float
    let tier: String?
    /// The parts the page receives as `scoreParts`.
    let parts: [(name: String, value: Float)]
    /// What held each region or the pose down, for the console.
    let reasons: [String]
    /// A gate that zeroes the photo: the body under `minBodyPixels` tall in
    /// the original, or blurred on the body.
    let filter: String?
    /// The raw readings, for `scoreInputs`.
    let readings: [String: Double]
    /// The clothing colour as CIELAB `[L, a, b]` for `"torso"` and `"legs"`
    /// (either may be missing), sent to the page as `outfit` for the session
    /// rule's outfit comparison — item 5c.
    let outfit: [String: [Double]]?
    let ms: Int

    /// sRGB (0–1) to CIELAB, D65.
    static func lab(_ r: Float, _ g: Float, _ b: Float) -> [Double] {
        func lin(_ c: Float) -> Double { let c = Double(c); return c <= 0.04045 ? c / 12.92 : pow((c + 0.055) / 1.055, 2.4) }
        let R = lin(r), G = lin(g), B = lin(b)
        let X = (0.4124 * R + 0.3576 * G + 0.1805 * B) / 0.95047
        let Y = 0.2126 * R + 0.7152 * G + 0.0722 * B
        let Z = (0.0193 * R + 0.1192 * G + 0.9505 * B) / 1.08883
        func f(_ t: Double) -> Double { t > 0.008856 ? cbrt(t) : 7.787 * t + 16 / 116 }
        return [116 * f(Y) - 16, 500 * (f(X) - f(Y)), 200 * (f(Y) - f(Z))].map { ($0 * 10).rounded() / 10 }
    }

    // MARK: Starting values

    /// Fit: the region's outline width against what the joints imply, 1 at
    /// `good` or under, 0 at `bad` or over. Torso: median row width between
    /// the shoulders and the hips with the arm bands cut out, over the wider
    /// of the shoulders and hips (or 0.45 of the torso length when the body is
    /// turned and the joints sit close together). Fitted tops read 0.8–1.1, an
    /// oversized fleece 1.26–1.61. Legs and arms are against the torso length,
    /// since no joint gives a limb's thickness: jeans read 0.30–0.47 at the
    /// thigh and 0.17–0.30 at the shin, fitted sleeves 0.15–0.30.
    static let torsoFit: (good: Double, bad: Double) = (1.05, 1.35)
    static let thighFit: (good: Double, bad: Double) = (0.45, 0.70)
    static let shinFit: (good: Double, bad: Double) = (0.30, 0.50)
    static let armFit: (good: Double, bad: Double) = (0.25, 0.45)
    /// Outline clarity: luminance contrast across the body's edge at the
    /// region's rows (0–1 luminance units). A dark top against a dark wall
    /// read 0.01–0.04, a figure against a plain wall 0.12–0.35.
    static let outline: (good: Double, bad: Double) = (0.14, 0.04)
    /// Light: mean luminance inside the region. Black clothes in daylight read
    /// 0.05–0.10, so only a silhouette or a region in deep shadow fails.
    static let light: (good: Double, bad: Double) = (0.10, 0.03)
    /// Skin showing in a region adds up to this: the outline is the body's own.
    static let skinBonus: Double = 0.1
    /// Sitting: the lowest knee under this far below the hips (torso lengths),
    /// a thigh tilted past this from vertical, or a knee bent past this.
    static let sittingKneeDrop: Double = 0.5
    static let sittingThighTilt: Double = 50
    static let sittingKneeAngle: Double = 120
    /// Leaning: the torso's tilt from vertical, light then heavy; lying past the last.
    static let leanLight: Double = 12
    static let leanHeavy: Double = 25
    static let lyingTilt: Double = 60
    /// Openness values from the spec: standing open 1, light lean 0.7, sitting
    /// 0.6, crossed or hands hidden or heavy lean 0.5, lying 0.3.
    static let opennessLightLean: Float = 0.7
    static let opennessSitting: Float = 0.6
    static let opennessClosed: Float = 0.5
    static let opennessLying: Float = 0.3
    /// Sitting also hides the legs and part of the torso.
    static let sittingLegs: Float = 0.8
    static let sittingTorso: Float = 0.9
    /// Legs crossed: the ankles swap sides by more than this (torso lengths).
    static let crossedAnkles: Double = 0.15
    /// Sharpness: Laplacian variance over the body mask. Sharp bodies read
    /// 0.005–0.05, soft ones 0.0002–0.001. Floored, since plain clothes have
    /// little texture to measure.
    static let sharpness: (good: Double, bad: Double) = (0.003, 0.0005)
    static let sharpnessFloor: Float = 0.3
    /// Head to ankle under this many pixels of the original is a gate.
    static let minBodyPixels: Double = 400
    /// Joint confidence, as the body check's.
    static let jointConfidence: Float = 0.3
    /// The segmentation quality. Balanced read the same widths as accurate on
    /// the test folders at half the time (39 against 80 ms on a Mac).
    static let segmentation: VNGeneratePersonSegmentationRequest.QualityLevel = .balanced
    static let weights: [(name: String, weight: Float)] = [("visibility", 0.7), ("openness", 0.2), ("quality", 0.1)]

    typealias J = VNHumanBodyPoseObservation.JointName

    /// Garment caps — plan item 5b, built by `ViewController.garmentCaps(for:)`
    /// from the whole-photo labels. A region can read no higher than its cap:
    /// a suit jacket shapes the torso, so the torso cannot say "clearly seen".
    struct Caps {
        var torso: Float = 1
        var legs: Float = 1
        var arms: Float = 1
        /// The labels that set them, for the note: "suit 0.83".
        var why: [String] = []
    }

    /// `image` is the scan's render the pose was read on, with the orientation
    /// Vision was given; `body` the pose observation the body check kept;
    /// `face` the matched face box (normalised, Vision's bottom-left origin)
    /// for the skin colour; `originalScale` the original's pixels per render
    /// pixel.
    /// Objects covering this share of the body's mask make the photo unusable —
    /// item 5b's "object or another person over about a quarter of the outline".
    static let objectBodyGate = 0.25
    /// Objects that only count when the shopper sits on them.
    static let furniture: Set<String> = ["chair", "bench", "couch"]
    /// A box over this share of the body's mask is scenery (a canopy read as an
    /// umbrella, a sofa the shopper stands against), not something held: nothing
    /// held encloses the whole person. Ignored, and said so in the note.
    static let objectAround = 0.9

    /// `objects` are what `BodyObjects` found on the upright image, boxes
    /// normalised; each region is lowered by the share of its mask pixels
    /// inside any box.
    init?(image source: CGImage, orientation: CGImagePropertyOrientation, body: VNHumanBodyPoseObservation,
          face: CGRect?, originalScale: Double, caps: Caps? = nil, objects: [BodyObjects.Object] = []) {
        let started = Date()
        // Everything below works upright, as the joints are.
        guard let image = Self.upright(source, orientation) else { return nil }
        let w = image.width, h = image.height
        var rgba = [UInt8](repeating: 0, count: w * h * 4)
        guard let ctx = CGContext(data: &rgba, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
                                  space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        else { return nil }
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
        func lum(_ x: Int, _ y: Int) -> Float {
            guard x >= 0, y >= 0, x < w, y < h else { return 0 }
            let i = (y * w + x) * 4
            return (0.299 * Float(rgba[i]) + 0.587 * Float(rgba[i + 1]) + 0.114 * Float(rgba[i + 2])) / 255
        }
        func rgb(_ x: Int, _ y: Int) -> (Float, Float, Float) {
            let i = (y * w + x) * 4
            return (Float(rgba[i]) / 255, Float(rgba[i + 1]) / 255, Float(rgba[i + 2]) / 255)
        }

        // The person mask.
        let seg = VNGeneratePersonSegmentationRequest()
        seg.qualityLevel = Self.segmentation
        seg.outputPixelFormat = kCVPixelFormatType_OneComponent8
        try? VNImageRequestHandler(cgImage: image, options: [:]).perform([seg])
        guard let pb = seg.results?.first?.pixelBuffer else { return nil }
        CVPixelBufferLockBaseAddress(pb, .readOnly)
        let mw = CVPixelBufferGetWidth(pb), mh = CVPixelBufferGetHeight(pb), rowBytes = CVPixelBufferGetBytesPerRow(pb)
        var mask = [UInt8](repeating: 0, count: mw * mh)
        if let base = CVPixelBufferGetBaseAddress(pb) {
            let p = base.assumingMemoryBound(to: UInt8.self)
            for y in 0..<mh { for x in 0..<mw { mask[y * mw + x] = p[y * rowBytes + x] } }
        }
        CVPixelBufferUnlockBaseAddress(pb, .readOnly)
        func on(_ x: Int, _ y: Int) -> Bool {
            guard x >= 0, y >= 0, x < w, y < h else { return false }
            return mask[(y * mh / h) * mw + (x * mw / w)] >= 128
        }

        // Joints in pixels, y down.
        func joint(_ j: J, _ conf: Float = BodyScore.jointConfidence) -> CGPoint? {
            guard let p = try? body.recognizedPoint(j), p.confidence >= conf else { return nil }
            return CGPoint(x: p.location.x * CGFloat(w), y: (1 - p.location.y) * CGFloat(h))
        }
        let neck = joint(.neck, 0.1), root = joint(.root, 0.1)
        let lS = joint(.leftShoulder, 0.1), rS = joint(.rightShoulder, 0.1)
        let lH = joint(.leftHip, 0.1), rH = joint(.rightHip, 0.1)
        let lE = joint(.leftElbow), rE = joint(.rightElbow), lW = joint(.leftWrist), rW = joint(.rightWrist)
        let lK = joint(.leftKnee), rK = joint(.rightKnee), lA = joint(.leftAnkle), rA = joint(.rightAnkle)
        guard let neck, let root else { return nil }
        let torsoLen = Double(hypot(neck.x - root.x, neck.y - root.y))
        guard torsoLen > 1 else { return nil }
        let shoulderW = (lS != nil && rS != nil) ? Double(abs(lS!.x - rS!.x)) : nil
        let hipW = (lH != nil && rH != nil) ? Double(abs(lH!.x - rH!.x)) : nil
        func lerp(_ a: CGPoint, _ b: CGPoint, _ t: Double) -> CGPoint { CGPoint(x: a.x + (b.x - a.x) * CGFloat(t), y: a.y + (b.y - a.y) * CGFloat(t)) }
        func distToSeg(_ p: CGPoint, _ a: CGPoint, _ b: CGPoint) -> Double {
            let ab = CGPoint(x: b.x - a.x, y: b.y - a.y), ap = CGPoint(x: p.x - a.x, y: p.y - a.y)
            let len2 = Double(ab.x * ab.x + ab.y * ab.y)
            if len2 < 1 { return Double(hypot(ap.x, ap.y)) }
            let t = max(0, min(1, Double(ap.x * ab.x + ap.y * ab.y) / len2))
            return Double(hypot(p.x - (a.x + CGFloat(t) * ab.x), p.y - (a.y + CGFloat(t) * ab.y)))
        }

        // Arm bands, cut out of the torso rows: within `armR` of the shoulder-elbow-wrist segments.
        let armR = torsoLen * 0.11
        var armSegments: [(CGPoint, CGPoint)] = []
        for (s, e, wr) in [(lS, lE, lW), (rS, rE, rW)] {
            if let s, let e { armSegments.append((s, e)) }
            if let e, let wr { armSegments.append((e, wr)) }
        }
        func inArmBand(_ x: Int, _ y: Int) -> Bool {
            let p = CGPoint(x: x, y: y)
            return armSegments.contains { distToSeg(p, $0.0, $0.1) < armR }
        }

        // The face's skin colour, in rg chromaticity, for the skin share.
        var skinRG: (Float, Float)?
        if let face {
            let fx = Int(face.midX * CGFloat(w)), fy = Int((1 - face.midY) * CGFloat(h)), fr = max(1, Int(face.width * CGFloat(w) * 0.2))
            var sr: Float = 0, sg: Float = 0, n: Float = 0
            for y in max(0, fy - fr)...min(h - 1, fy + fr) {
                for x in max(0, fx - fr)...min(w - 1, fx + fr) {
                    let (r, g, b) = rgb(x, y); let s = r + g + b
                    if s > 0.15 { sr += r / s; sg += g / s; n += 1 }
                }
            }
            if n > 0 { skinRG = (sr / n, sg / n) }
        }
        func isSkin(_ x: Int, _ y: Int) -> Bool {
            guard let skinRG, x >= 0, y >= 0, x < w, y < h else { return false }
            let (r, g, b) = rgb(x, y); let s = r + g + b
            guard s > 0.15 else { return false }
            return abs(r / s - skinRG.0) < 0.04 && abs(g / s - skinRG.1) < 0.03
        }

        // One horizontal run of mask through (cx, y): width, edge contrast where
        // the run ends at the body's real edge (-1 when it ends at an arm band
        // or the other leg), mean light, skin share.
        struct Run { var width: Double; var edge: Double; var light: Double; var skin: Double }
        func edgeAt(_ xi: Int, _ y: Int, _ dir: Int) -> Float {
            var inside: Float = 0, outside: Float = 0
            for k in 0..<3 { inside += lum(xi - dir * k, y); outside += lum(xi + dir * (k + 1), y) }
            return abs(inside - outside) / 3
        }
        func run(y: Int, cx: Int, minX: Int = 0, maxX: Int? = nil, cutArms: Bool) -> Run? {
            guard y >= 0, y < h, on(cx, y) else { return nil }
            let maxX = maxX ?? (w - 1)
            var l = cx, r = cx
            while l - 1 >= minX && on(l - 1, y) && !(cutArms && inArmBand(l - 1, y)) { l -= 1 }
            while r + 1 <= maxX && on(r + 1, y) && !(cutArms && inArmBand(r + 1, y)) { r += 1 }
            var light: Float = 0, skin = 0, n = 0
            for x in l...r { light += lum(x, y); if isSkin(x, y) { skin += 1 }; n += 1 }
            var edges: [Float] = []
            if !on(l - 1, y) { edges.append(edgeAt(l, y, -1)) }
            if !on(r + 1, y) { edges.append(edgeAt(r, y, 1)) }
            let e = edges.isEmpty ? Float(-1) : edges.reduce(0, +) / Float(edges.count)
            return Run(width: Double(r - l + 1), edge: Double(e), light: Double(light) / Double(max(n, 1)), skin: Double(skin) / Double(max(n, 1)))
        }
        func median(_ v: [Double]) -> Double? { let s = v.sorted(); return s.isEmpty ? nil : s[s.count / 2] }
        func mean(_ v: [Double]) -> Double? { v.isEmpty ? nil : v.reduce(0, +) / Double(v.count) }
        func ramp(_ v: Double?, _ c: (good: Double, bad: Double)) -> Double? {
            guard let v else { return nil }
            if c.good < c.bad { return max(0, min(1, (c.bad - v) / (c.bad - c.good))) }
            return max(0, min(1, (v - c.bad) / (c.good - c.bad)))
        }

        // Torso rows between the shoulders and the hips, the arm bands cut out;
        // the outline from the whole silhouette at the same row.
        var torsoRuns: [Run] = []
        if let lS, let rS, let lH, let rH {
            let top = CGPoint(x: (lS.x + rS.x) / 2, y: (lS.y + rS.y) / 2), bot = CGPoint(x: (lH.x + rH.x) / 2, y: (lH.y + rH.y) / 2)
            for t in stride(from: 0.2, through: 0.85, by: 0.05) {
                let c = lerp(top, bot, t)
                if var s = run(y: Int(c.y), cx: Int(c.x), cutArms: true) {
                    if let whole = run(y: Int(c.y), cx: Int(c.x), cutArms: false) { s.edge = whole.edge }
                    torsoRuns.append(s)
                }
            }
        }
        var torsoW = median(torsoRuns.map(\.width))
        if let m = torsoW, m < 0.15 * torsoLen { torsoW = nil }   // the centre line missed the body
        let impliedTorso = max(shoulderW ?? 0, hipW ?? 0, 0.45 * torsoLen)
        let torsoRatio = torsoW.map { $0 / impliedTorso }

        // Legs: thigh and shin rows per leg, each run capped at the midline to the other leg.
        func legRuns(_ hip: CGPoint?, _ knee: CGPoint?, _ ankle: CGPoint?, other: (CGPoint?, CGPoint?, CGPoint?)) -> (thigh: Double?, shin: Double?, runs: [Run]) {
            var thigh: [Run] = [], shin: [Run] = []
            func bound(y: Int, cx: Int) -> (Int, Int) {
                guard let oh = other.0, let ok = other.1 else { return (0, w - 1) }
                let oc: CGFloat
                if let oa = other.2, CGFloat(y) > ok.y { oc = lerp(ok, oa, Double((CGFloat(y) - ok.y) / max(1, oa.y - ok.y))).x }
                else { oc = lerp(oh, ok, Double((CGFloat(y) - oh.y) / max(1, ok.y - oh.y))).x }
                let mid = Int((CGFloat(cx) + oc) / 2)
                return cx < Int(oc) ? (0, mid) : (mid, w - 1)
            }
            if let hip, let knee {
                for t in stride(from: 0.25, through: 0.8, by: 0.11) {
                    let c = lerp(hip, knee, t); let (lo, hi) = bound(y: Int(c.y), cx: Int(c.x))
                    if let s = run(y: Int(c.y), cx: Int(c.x), minX: lo, maxX: hi, cutArms: false) { thigh.append(s) }
                }
            }
            if let knee, let ankle {
                for t in stride(from: 0.2, through: 0.8, by: 0.12) {
                    let c = lerp(knee, ankle, t); let (lo, hi) = bound(y: Int(c.y), cx: Int(c.x))
                    if let s = run(y: Int(c.y), cx: Int(c.x), minX: lo, maxX: hi, cutArms: false) { shin.append(s) }
                }
            }
            return (median(thigh.map(\.width)), median(shin.map(\.width)), thigh + shin)
        }
        let legL = legRuns(lH, lK, lA, other: (rH, rK, rA)), legR = legRuns(rH, rK, rA, other: (lH, lK, lA))
        let legRuns = legL.runs + legR.runs

        // Arms: cross-sections across the upper and lower arm, twice the outer
        // half so a sleeve beside the torso is not read into the torso.
        func cross(_ a: CGPoint, _ b: CGPoint, _ t: Double) -> Run? {
            let c = lerp(a, b, t)
            let dx = Double(b.x - a.x), dy = Double(b.y - a.y), len = hypot(dx, dy)
            guard len > 1, on(Int(c.x), Int(c.y)) else { return nil }
            var nx = -dy / len, ny = dx / len
            let axisMid = lerp(neck, root, 0.5)
            if (Double(c.x - axisMid.x) * nx + Double(c.y - axisMid.y) * ny) < 0 { nx = -nx; ny = -ny }
            var k = 0
            let cap = Int(armR * 4)
            while on(Int(Double(c.x) + nx * Double(k + 1)), Int(Double(c.y) + ny * Double(k + 1))) && k < cap { k += 1 }
            if k >= cap { return nil }
            var light: Float = 0, skin = 0, n = 0
            for m in 0...k { let x = Int(Double(c.x) + nx * Double(m)), y = Int(Double(c.y) + ny * Double(m)); light += lum(x, y); if isSkin(x, y) { skin += 1 }; n += 1 }
            var ei: Float = 0, eo: Float = 0
            for m in 0..<3 {
                ei += lum(Int(Double(c.x) + nx * Double(k - m)), Int(Double(c.y) + ny * Double(k - m)))
                eo += lum(Int(Double(c.x) + nx * Double(k + m + 1)), Int(Double(c.y) + ny * Double(k + m + 1)))
            }
            return Run(width: Double(2 * k + 1), edge: Double(abs(ei - eo) / 3), light: Double(light) / Double(max(n, 1)), skin: Double(skin) / Double(max(n, 1)))
        }
        var armWidths: [Double] = [], armRuns: [Run] = []
        for (a, b) in [(lS, lE), (rS, rE), (lE, lW), (rE, rW)] {
            guard let a, let b else { continue }
            let runs = [0.3, 0.5, 0.7].compactMap { cross(a, b, $0) }
            if let m = median(runs.map(\.width)) { armWidths.append(m / torsoLen) }
            armRuns += runs
        }

        // Each region: the lowest of fit, outline and light, plus the skin bonus.
        var reasons: [String] = []
        var readings: [String: Double] = ["torsoLen": torsoLen]
        func region(_ name: String, fit: Double?, runs: [Run]) -> Float {
            let edge = ramp(mean(runs.map(\.edge).filter { $0 >= 0 }), Self.outline)
            let light = ramp(mean(runs.map(\.light)), Self.light)
            let skin = mean(runs.map(\.skin)) ?? 0
            readings[name + "Fit"] = fit; readings[name + "Outline"] = edge; readings[name + "Light"] = light; readings[name + "Skin"] = skin
            guard let fit else { reasons.append("\(name) unread"); return 0 }
            let signals: [(String, Double)] = [("\(name) fit", fit), ("\(name) outline", edge ?? 1), ("\(name) light", light ?? 1)]
            let low = signals.min { $0.1 < $1.1 }!
            if low.1 < 1 { reasons.append(String(format: "%@ %.2f", low.0, low.1)) }
            return Float(min(1, low.1 + Self.skinBonus * skin))
        }
        readings["torsoRatio"] = torsoRatio
        var torso = region("torso", fit: ramp(torsoRatio, Self.torsoFit), runs: torsoRuns)
        var legFits: [Double] = []
        for (th, sh, side) in [(legL.thigh, legL.shin, "L"), (legR.thigh, legR.shin, "R")] {
            readings["thigh" + side] = th.map { $0 / torsoLen }; readings["shin" + side] = sh.map { $0 / torsoLen }
            let f = [ramp(th.map { $0 / torsoLen }, Self.thighFit), ramp(sh.map { $0 / torsoLen }, Self.shinFit)].compactMap { $0 }
            if let m = f.min() { legFits.append(m) }
        }
        var legs = region("legs", fit: mean(legFits), runs: legRuns)
        readings["armWidth"] = armWidths.min()
        var arms = region("arms", fit: ramp(armWidths.min(), Self.armFit), runs: armRuns)

        // Pose, from the joints — read here because furniture only counts as an
        // object when the shopper sits on it.
        var kneeDrop: Double?
        if let lowestKnee = [lK, rK].compactMap({ $0 }).map(\.y).max() { kneeDrop = Double(lowestKnee - root.y) / torsoLen }
        let torsoTilt = abs(atan2(Double(neck.x - root.x), Double(root.y - neck.y))) * 180 / .pi
        var thighTilt: Double?, kneeAngle: Double?
        for (hip, knee, ankle) in [(lH, lK, lA), (rH, rK, rA)] {
            guard let hip, let knee else { continue }
            thighTilt = max(thighTilt ?? 0, abs(atan2(Double(knee.x - hip.x), Double(knee.y - hip.y))) * 180 / .pi)
            if let ankle {
                let a = CGPoint(x: hip.x - knee.x, y: hip.y - knee.y), b = CGPoint(x: ankle.x - knee.x, y: ankle.y - knee.y)
                let cosv = Double(a.x * b.x + a.y * b.y) / max(1, Double(hypot(a.x, a.y) * hypot(b.x, b.y)))
                kneeAngle = min(kneeAngle ?? 180, acos(max(-1, min(1, cosv))) * 180 / .pi)
            }
        }
        let sitting = (kneeDrop ?? 1) < Self.sittingKneeDrop || (thighTilt ?? 0) > Self.sittingThighTilt || (kneeAngle ?? 180) < Self.sittingKneeAngle

        // Objects over the body: the share of each region's mask inside a box.
        // A chair, bench or couch behind a standing shopper hides nothing, so
        // furniture counts only when sitting.
        var objectShare = 0.0
        let standingBehind = objects.filter { !sitting && Self.furniture.contains($0.label) }
        if !standingBehind.isEmpty {
            reasons.append(standingBehind.prefix(2).map { String(format: "%@ %.2f", $0.label, $0.confidence) }.joined(separator: " ") + " behind")
        }
        var objects = objects.filter { sitting || !Self.furniture.contains($0.label) }
        if !objects.isEmpty {
            // Boxes around the whole body are scenery — see `objectAround`.
            var maskCount = 0
            var inBox = [Int](repeating: 0, count: objects.count)
            for y in stride(from: 0, to: h, by: 3) {
                for x in stride(from: 0, to: w, by: 3) where on(x, y) {
                    maskCount += 1
                    for (i, o) in objects.enumerated() where o.box.contains(CGPoint(x: CGFloat(x) / CGFloat(w), y: CGFloat(y) / CGFloat(h))) { inBox[i] += 1 }
                }
            }
            let around = objects.enumerated().filter { maskCount > 0 && Double(inBox[$0.offset]) / Double(maskCount) >= Self.objectAround }.map(\.element)
            if !around.isEmpty {
                reasons.append(around.prefix(2).map { String(format: "%@ %.2f", $0.label, $0.confidence) }.joined(separator: " ") + " around the body")
                objects = objects.enumerated().filter { maskCount > 0 && Double(inBox[$0.offset]) / Double(maskCount) < Self.objectAround }.map(\.element)
            }
        }
        if !objects.isEmpty {
            let boxes = objects.map { CGRect(x: $0.box.minX * CGFloat(w), y: $0.box.minY * CGFloat(h), width: $0.box.width * CGFloat(w), height: $0.box.height * CGFloat(h)) }
            func covered(_ x: Int, _ y: Int) -> Bool { let p = CGPoint(x: x, y: y); return boxes.contains { $0.contains(p) } }
            let footEnd = Int([lA, rA].compactMap { $0 }.map(\.y).max() ?? CGFloat(h - 1))
            var count = [0, 0, 0, 0], hit = [0, 0, 0, 0]   // torso, legs, arms, whole body
            for y in stride(from: 0, to: h, by: 3) {
                for x in stride(from: 0, to: w, by: 3) where on(x, y) {
                    let c = covered(x, y)
                    count[3] += 1; if c { hit[3] += 1 }
                    let region: Int
                    if inArmBand(x, y) { region = 2 }
                    else if y >= Int(neck.y) && y <= Int(root.y) { region = 0 }
                    else if y > Int(root.y) && y <= footEnd { region = 1 }
                    else { continue }
                    count[region] += 1; if c { hit[region] += 1 }
                }
            }
            func share(_ i: Int) -> Double { count[i] > 0 ? Double(hit[i]) / Double(count[i]) : 0 }
            let shares = (torso: share(0), legs: share(1), arms: share(2))
            objectShare = share(3)
            readings["objTorso"] = shares.torso; readings["objLegs"] = shares.legs; readings["objArms"] = shares.arms; readings["objBody"] = objectShare
            torso *= Float(1 - shares.torso); legs *= Float(1 - shares.legs); arms *= Float(1 - shares.arms)
            let names = objects.prefix(3).map { String(format: "%@ %.2f", $0.label, $0.confidence) }.joined(separator: " ")
            var over: [String] = []
            if shares.torso >= 0.05 { over.append(String(format: "torso %.0f%%", shares.torso * 100)) }
            if shares.legs >= 0.05 { over.append(String(format: "legs %.0f%%", shares.legs * 100)) }
            if shares.arms >= 0.05 { over.append(String(format: "arms %.0f%%", shares.arms * 100)) }
            reasons.append(names + (over.isEmpty ? " beside the body" : " over " + over.joined(separator: ", ")))
        }

        // The garment caps, before the pose factors.
        if let caps, !caps.why.isEmpty {
            var capped: [String] = []
            if torso > caps.torso { torso = caps.torso; capped.append(String(format: "torso %.1f", caps.torso)) }
            if legs > caps.legs { legs = caps.legs; capped.append(String(format: "legs %.1f", caps.legs)) }
            if arms > caps.arms { arms = caps.arms; capped.append(String(format: "arms %.1f", caps.arms)) }
            readings["capTorso"] = Double(caps.torso); readings["capLegs"] = Double(caps.legs); readings["capArms"] = Double(caps.arms)
            if !capped.isEmpty { reasons.append(caps.why.joined(separator: " ") + " caps " + capped.joined(separator: ", ")) }
        }

        // Pose, continued.
        let lying = torsoTilt > Self.lyingTilt
        var armsCrossed = false
        if let lS, let rS, let lW, let rW {
            let mid = { (y: CGFloat) -> CGFloat in lerp(neck, root, Double((y - neck.y) / max(1, root.y - neck.y))).x }
            armsCrossed = ((lW.x - mid(lW.y)).sign != (lS.x - neck.x).sign) && ((rW.x - mid(rW.y)).sign != (rS.x - neck.x).sign)
                && lW.y > neck.y && lW.y < root.y + 0.2 * (root.y - neck.y)
        }
        let handsHidden = lW == nil && rW == nil && (lE != nil || rE != nil)
        var legsCrossed = false
        if let lH, let rH, let lA, let rA { legsCrossed = (lH.x - rH.x).sign != (lA.x - rA.x).sign && Double(abs(lA.x - rA.x)) > Self.crossedAnkles * torsoLen }
        var openness: Float = 1
        var pose: [String] = []
        if lying { openness = Self.opennessLying; pose.append("lying") }
        else if sitting { openness = Self.opennessSitting; pose.append("sitting"); legs *= Self.sittingLegs; torso *= Self.sittingTorso }
        if !lying && torsoTilt > Self.leanHeavy { openness = min(openness, Self.opennessClosed); pose.append(String(format: "leaning %.0f°", torsoTilt)) }
        else if !lying && torsoTilt > Self.leanLight { openness = min(openness, Self.opennessLightLean); pose.append(String(format: "light lean %.0f°", torsoTilt)) }
        if armsCrossed { openness = min(openness, Self.opennessClosed); pose.append("arms crossed") }
        if handsHidden { openness = min(openness, Self.opennessClosed); pose.append("hands hidden") }
        if legsCrossed { openness = min(openness, Self.opennessClosed); pose.append("legs crossed") }
        reasons += pose
        readings["kneeDrop"] = kneeDrop; readings["thighTilt"] = thighTilt; readings["kneeAngle"] = kneeAngle; readings["torsoTilt"] = torsoTilt
        readings["sitting"] = sitting ? 1 : 0; readings["armsCrossed"] = armsCrossed ? 1 : 0; readings["handsHidden"] = handsHidden ? 1 : 0; readings["legsCrossed"] = legsCrossed ? 1 : 0

        // Image quality: sharpness over the mask, and the body's height in the original.
        var lapSum = 0.0, lapSq = 0.0, ln = 0.0
        for y in stride(from: 2, to: h - 2, by: 3) {
            for x in stride(from: 2, to: w - 2, by: 3) where on(x, y) {
                let l = 4 * lum(x, y) - lum(x - 1, y) - lum(x + 1, y) - lum(x, y - 1) - lum(x, y + 1)
                lapSum += Double(l); lapSq += Double(l * l); ln += 1
            }
        }
        let sharp = ln > 0 ? lapSq / ln - (lapSum / ln) * (lapSum / ln) : 0
        let quality = max(Self.sharpnessFloor, Float(ramp(sharp, Self.sharpness) ?? 0))
        let headTop = [J.nose, .leftEye, .rightEye, .leftEar, .rightEar].compactMap { joint($0) }.map(\.y).min()
        let footY = [lA, rA].compactMap { $0 }.map(\.y).max()
        var bodyPixels: Double?
        if let headTop, let footY { bodyPixels = Double(footY - headTop) * originalScale }
        readings["sharpness"] = sharp; readings["bodyPx"] = bodyPixels
        var filter: String?
        if let bodyPixels, bodyPixels < Self.minBodyPixels { filter = "body under \(Int(Self.minBodyPixels)) px" }
        if sharp < Self.sharpness.bad * 0.4 { filter = filter ?? "blurred body" }
        if objectShare >= Self.objectBodyGate { filter = filter ?? String(format: "objects over %.0f%% of the body", objectShare * 100) }
        if quality < 1 { reasons.append(String(format: "sharpness %.2f", quality)) }

        // The outfit's colour, for the page's session rule (item 5c): CIELAB
        // means over the middle of the trunk and along the thighs. Measured 30
        // Oct 2026: the same outfit in one session reads under ΔE 10, a
        // different one 20–40.
        func labMean(along a: CGPoint, _ b: CGPoint, halfWidth: CGFloat, from: Double, to: Double) -> (n: Int, lab: [Double])? {
            var n = 0; var sr: Float = 0, sg: Float = 0, sb: Float = 0
            var t = from
            while t <= to {
                let c = lerp(a, b, t)
                var dx = -halfWidth
                while dx <= halfWidth {
                    let x = Int(c.x + dx), y = Int(c.y)
                    if on(x, y) { let p = rgb(x, y); sr += p.0; sg += p.1; sb += p.2; n += 1 }
                    dx += 2
                }
                t += 0.02
            }
            guard n >= 40 else { return nil }
            return (n, Self.lab(sr / Float(n), sg / Float(n), sb / Float(n)))
        }
        var outfit: [String: [Double]] = [:]
        let halfTrunk = (shoulderW ?? torsoLen * 0.6) * 0.3
        if let t = labMean(along: neck, root, halfWidth: halfTrunk, from: 0.25, to: 0.8) { outfit["torso"] = t.lab }
        var legSamples: [(n: Int, lab: [Double])] = []
        for (hip, knee) in [(lH, lK), (rH, rK)] {
            guard let hip, let knee, let s = labMean(along: hip, knee, halfWidth: torsoLen * 0.08, from: 0.3, to: 0.8) else { continue }
            legSamples.append(s)
        }
        if !legSamples.isEmpty {
            let total = Double(legSamples.reduce(0) { $0 + $1.n })
            outfit["legs"] = (0..<3).map { i in legSamples.reduce(0.0) { $0 + $1.lab[i] * Double($1.n) } / total }
        }
        self.outfit = outfit.isEmpty ? nil : outfit

        let visibility = 0.4 * torso + 0.4 * legs + 0.2 * arms
        let groups: [Float] = [visibility, openness, quality]
        let t = zip(Self.weights, groups).reduce(Float(1)) { $0 * pow($1.1, $1.0.weight) }
        self.value = filter == nil ? t : 0
        self.filter = filter
        self.parts = [("torso", torso), ("legs", legs), ("arms", arms), ("openness", openness), ("quality", quality)]
        self.tier = filter != nil ? nil : (t >= ViewController.fullLengthTierALine ? "A" : (t >= ViewController.fullLengthUsableFloor ? "B" : nil))
        self.reasons = reasons
        self.readings = readings
        self.ms = Int(Date().timeIntervalSince(started) * 1000)
    }

    var note: String {
        let detail = parts.map { String(format: "%@ %.2f", $0.name, $0.value) }.joined(separator: " ")
        let held = reasons.isEmpty ? "" : "; held down by " + reasons.joined(separator: ", ")
        return String(format: "body [%@]%@ (%dms)", detail, held, ms)
    }

    /// The image drawn upright, so pixel reads match the joints' normalised space.
    static func upright(_ image: CGImage, _ orientation: CGImagePropertyOrientation) -> CGImage? {
        if orientation == .up { return image }
        let w = image.width, h = image.height
        let swap = [.left, .right, .leftMirrored, .rightMirrored].contains(orientation)
        let ow = swap ? h : w, oh = swap ? w : h
        guard let ctx = CGContext(data: nil, width: ow, height: oh, bitsPerComponent: 8, bytesPerRow: 0,
                                  space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        ctx.translateBy(x: CGFloat(ow) / 2, y: CGFloat(oh) / 2)
        switch orientation {
        case .down, .downMirrored: ctx.rotate(by: .pi)
        case .left, .leftMirrored: ctx.rotate(by: .pi / 2)
        case .right, .rightMirrored: ctx.rotate(by: -.pi / 2)
        default: break
        }
        if [.upMirrored, .downMirrored, .leftMirrored, .rightMirrored].contains(orientation) { ctx.scaleBy(x: -1, y: 1) }
        ctx.draw(image, in: CGRect(x: -CGFloat(w) / 2, y: -CGFloat(h) / 2, width: CGFloat(w), height: CGFloat(h)))
        return ctx.makeImage()
    }
}
