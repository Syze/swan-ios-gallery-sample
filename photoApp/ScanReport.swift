// Swan Gallery Pick: one JSON report per scan, posted to Swan's scan ingest, for reviewing test scans.

import UIKit

/// Collects what each scan sent to the page and posts it as one report when the scan ends.
/// Main queue only. Off while `url` is nil.
final class ScanReport {

    /// Where each report is posted, and its ingest key: set for sandbox builds, nil in production
    /// (see `SwanEnvironment`).
    static let url = SwanEnvironment.current.scanReport?.url
    static let key = SwanEnvironment.current.scanReport?.key
    /// Tries per report: retried on 5xx and network errors, never on other 4xx.
    static let attempts = 3
    /// The page pre-selects after the scan ends; the report waits this long for its picks.
    static let pickWait: TimeInterval = 4

    private var matches: [String: [String: Any]] = [:]
    private var picks: [String] = []
    private var droppedWhy: [String: String] = [:]
    private var checks: [String: Any] = [:]
    private var trail: [[String: Any]] = []
    /// Called on the main queue with the stored report's id and photo count.
    var onStored: ((_ id: String, _ photos: Int) -> Void)?

    /// Keeps each match sent to the page; on scan complete, builds and posts the report.
    func collect(_ message: [String: Any], page: URL) {
        guard let url = Self.url, let type = message["type"] as? String,
              let payload = message["payload"] as? [String: Any] else { return }
        if type == "onGalleryMatchFound", let id = payload["assetId"] as? String {
            matches[id] = payload
            return
        }
        guard type == "onGalleryScanComplete" else { return }

        let ids = payload["assetIds"] as? [String] ?? []
        let dropped = payload["dropped"] as? [String] ?? []
        let photos = ids.enumerated().map { index, id in
            entry(id, extra: ["position": index + 1])
        }
        let droppedPhotos = dropped.map { id in
            entry(id, extra: droppedWhy[id].map { ["why": $0] } ?? [:])
        }
        var report: [String: Any] = [
            "at": ISO8601DateFormatter().string(from: Date()),
            "device": UIDevice.current.model + " iOS " + UIDevice.current.systemVersion,
            "model": Self.hardwareModel,
            "page": page.absoluteString,
            "shown": photos.count,
            "dropped": dropped.map(Self.short),
            "droppedPhotos": droppedPhotos,
            "checks": checks,
            // Every photo the scan looked at: outcome, the readings behind it, and its
            // Photos filename. Look a missing photo up here by `file`.
            "trail": trail,
        ]
        for key in ["error", "denied", "limited", "skipped", "summary"] { report[key] = payload[key] }
        matches = [:]
        droppedWhy = [:]
        checks = [:]
        trail = []
        picks = []

        DispatchQueue.main.asyncAfter(deadline: .now() + Self.pickWait) { [self] in
            let picked = picks.filter { ids.contains($0) }.map(Self.short)
            report["picked"] = picked
            report["photos"] = photos.map { photo -> [String: Any] in
                var photo = photo
                photo["picked"] = picked.contains(photo["id"] as? String ?? "")
                return photo
            }
            Self.post(report, to: url, key: Self.key, gzip: true) { [weak self] id, photos in self?.onStored?(id, photos) }
            // A page served by the local dev server (ngrok) also saves the report there.
            if page.host?.contains("ngrok") == true, var local = URLComponents(url: page, resolvingAgainstBaseURL: false) {
                local.path = "/__scan-report"
                local.query = nil
                if let localURL = local.url { Self.post(report, to: localURL, key: nil, gzip: false) }
            }
        }
    }

    /// Notes the page's own pre-selection, reported through `onImageSelect` with `auto`.
    func noteCallback(_ name: String, _ result: [String: Any]) {
        guard Self.url != nil, name == "onImageSelect", result["auto"] as? Bool == true,
              result["selected"] as? Bool == true, let id = result["assetId"] as? String else { return }
        picks.append(id)
    }

    /// Why each withdrawn match went and the end-of-scan checks, set just before scan complete.
    func endOfScan(droppedWhy: [String: String], checks: [String: Any], trail: [[String: Any]] = []) {
        self.droppedWhy = droppedWhy
        self.checks = checks
        self.trail = trail
    }

    /// A match as the page received it, with the id cut to the page's 8-character badge.
    private func entry(_ id: String, extra: [String: Any]) -> [String: Any] {
        var photo = matches[id] ?? [:]
        for key in ["assetId", "done", "total"] { photo.removeValue(forKey: key) }
        photo["id"] = Self.short(id)
        return photo.merging(extra) { _, new in new }
    }

    nonisolated static func short(_ id: String) -> String { String(id.prefix(8)) }

    /// The phone's model identifier, e.g. "iPhone13,2"; camera readings differ by model.
    static var hardwareModel: String {
        var info = utsname()
        uname(&info)
        return withUnsafeBytes(of: &info.machine) { raw in
            String(decoding: raw.prefix { $0 != 0 }, as: UTF8.self)
        }
    }

    /// One JSON POST. NaN or infinite readings go as null, since JSON has no form for them.
    /// The ingest stores a repeated body once, so retries are safe.
    private static func post(_ report: [String: Any], to url: URL, key: String?, gzip: Bool,
                             stored: (@MainActor @Sendable (String, Int) -> Void)? = nil) {
        func clean(_ value: Any) -> Any {
            if let dict = value as? [String: Any] { return dict.mapValues(clean) }
            if let list = value as? [Any] { return list.map(clean) }
            if let d = value as? Double, !d.isFinite { return NSNull() }
            if let f = value as? Float, !f.isFinite { return NSNull() }
            return value
        }
        let report = clean(report)
        guard JSONSerialization.isValidJSONObject(report),
              let json = try? JSONSerialization.data(withJSONObject: report, options: [.sortedKeys]) else {
            print("❌ scan report not sent: not valid JSON")
            return
        }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        if let key { request.setValue(key, forHTTPHeaderField: "x-api-key") }
        if gzip, let packed = Self.gzip(json) {
            request.setValue("gzip", forHTTPHeaderField: "Content-Encoding")
            request.httpBody = packed
        } else {
            request.httpBody = json
        }
        send(request, attempt: 1, stored: stored)
    }

    /// Sends `request`, retrying after `Retry-After` (or 2 s, 4 s) on 5xx and network errors.
    private nonisolated static func send(_ request: URLRequest, attempt: Int, stored: (@MainActor @Sendable (String, Int) -> Void)?) {
        URLSession.shared.dataTask(with: request) { data, response, error in
            let http = response as? HTTPURLResponse
            let status = http?.statusCode ?? 0
            if error == nil, (200..<300).contains(status) {
                // The ingest answers with the report's id; a repeat of the same body says duplicate.
                let reply = data.flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] } ?? [:]
                print("📤 scan report stored at \(request.url?.host ?? "?") — id \(reply["id"] ?? "?"), \(reply["photos"] ?? "?") photos\(reply["duplicate"] as? Bool == true ? ", already stored" : "")")
                if let stored, let id = reply["id"] as? String {
                    let photos = reply["photos"] as? Int ?? 0
                    Task { @MainActor in stored(id, photos) }
                }
                return
            }
            let host = request.url?.host ?? "?"
            guard error != nil || status >= 500, attempt < attempts else {
                print("❌ scan report to \(host) failed: \(error?.localizedDescription ?? "HTTP \(status)")")
                return
            }
            let wait = (http?.value(forHTTPHeaderField: "Retry-After")).flatMap(Double.init) ?? pow(2, Double(attempt))
            DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + wait) { send(request, attempt: attempt + 1, stored: stored) }
        }.resume()
    }

    /// `data` as a gzip file: the 10-byte header, raw DEFLATE, then its CRC-32 and length.
    private nonisolated static func gzip(_ data: Data) -> Data? {
        guard let deflated = try? (data as NSData).compressed(using: .zlib) as Data else { return nil }
        var out = Data([0x1f, 0x8b, 0x08, 0, 0, 0, 0, 0, 0, 0xff])
        out.append(deflated)
        for value in [crc32(data), UInt32(truncatingIfNeeded: data.count)] {
            withUnsafeBytes(of: value.littleEndian) { out.append(contentsOf: $0) }
        }
        return out
    }

    /// The CRC-32 gzip stores to check the unpacked bytes.
    private nonisolated static func crc32(_ data: Data) -> UInt32 {
        var crc: UInt32 = 0xffff_ffff
        for byte in data {
            crc ^= UInt32(byte)
            for _ in 0..<8 { crc = (crc >> 1) ^ (0xedb8_8320 & (0 &- (crc & 1))) }
        }
        return ~crc
    }
}
