import Foundation
import Photos
import CryptoKit

/// What the scan learned about each photo, kept between scans so the next one
/// does not load, detect and download the same photos again.
///
/// One record per photo the scan has judged, keyed by the photo's id. A record
/// holds either a verdict that does not depend on the selfie — no face, a group
/// of four or more, the face too small in every copy, not head to toe, and so on
/// — or, for a photo that could match somebody, the face vectors of its faces.
/// Nothing selfie-dependent is stored: the match itself, its distance, the gap
/// rule and the duplicate groups are recomputed every scan from the vectors,
/// which takes microseconds per photo.
///
/// Verdict records let the scan count the photo and move on without loading it.
/// Candidate records let it compare the new selfie with the stored vectors: a
/// photo that does not match costs nothing; one that does is loaded and examined
/// exactly as before, so every rule that decides a match runs on the real photo.
/// For a photo only in iCloud that means the download happens once in its life,
/// for the first scan that sees it, and only matches are fetched after that.
///
/// A record is ignored when the photo's modified date has changed (it was
/// edited), or when `rulesVersion` has moved on. The file is deleted when a
/// different account signs in. A face vector is derived from a face, so the
/// file never leaves the phone, is never sent anywhere, and sits in the app's
/// private Application Support folder under iOS data protection.
///
/// `enabled` is the switch: off, no file is read or written and the scan is
/// exactly what it was.
final class ScanStore {

    static let enabled = true

    /// Bump when a rule that feeds a stored verdict changes — the face floor, the
    /// group rules, the body gates, the Muse filters — so old records are ignored
    /// and the next scan rebuilds them.
    /// 2: the v2 type sort (29 Oct 2026) — a portrait with a smaller face can
    /// now be a selfie where it was "not head to toe" before.
    /// 3: the v2 selfie gates (29 Oct 2026) — an "unusable face" verdict now
    /// comes from more rules, and the ones written while they were being
    /// tuned are not to be trusted.
    /// 4: a smile showing teeth stays in (`smileKeepsTeeth`), so verdicts that
    /// gated one are stale.
    /// 5: the covered-face gates (`coverGatesEnabled`) — a capped selfie is
    /// now out where it ranked low.
    /// 6: the jaw limit rose to 0.4 (`coverJawLimit`): a bare jaw over a polo
    /// collar read 0.33 and was gated.
    /// 7: the document gate (`documentGateEnabled`) — a photographed ID card
    /// or passport was a match before and is now out.
    /// 8: the document gate's second rule (`documentPageLabelLimit`) — a
    /// document the labels only half see is now out.
    /// 9: camera data is read from the original, not the edited copy — an
    /// edited selfie that failed the no-camera-data gate may now pass.
    /// 10: the v2 full-length score (`fullLengthScoreV2`) — the face filters no
    /// longer drop a front or side, so verdicts of "unusable" must be remade.
    /// 11: the object rules (`BodyScore.furniture`, `objectAround`) — a front
    /// gated as "objects over the body" by a canopy or a sofa behind it is now
    /// scored, so those "unusable" verdicts are stale.
    static let rulesVersion = 11

    enum Verdict: String, Codable {
        /// Decided from the photo alone; the selfie plays no part.
        case noFace, group, faceTooSmall, otherPeople, notFullBody, unusableFace, tooLarge, sensitive
        /// Only in iCloud and the 120px thumbnail did not look like a selfie or
        /// one standing person. Used only while the photo still has no copy on
        /// the phone; a photo that becomes local is examined in full.
        case cloudThumbnail
        /// Only in iCloud and the 320px small copy showed several faces, or not
        /// one standing person. Same rule as `cloudThumbnail`.
        case cloudSmallCopy
        /// Could match somebody: `faces` holds its face vectors.
        case candidate
    }

    struct Record: Codable {
        var verdict: Verdict
        /// The photo's modified date when the record was written; a different
        /// date means the photo was edited and the record is stale.
        var modified: Double
        var version: Int
        /// Face vectors, largest face first, bystanders excluded, as Float32 bytes.
        /// Empty unless `verdict` is `candidate`.
        var faces: [Data]
        /// Why, for the console: "3 faces" for a small-copy drop, and so on.
        var note: String?
        var written: Double

        var vectors: [[Float]] {
            faces.map { data in data.withUnsafeBytes { Array($0.bindMemory(to: Float.self)) } }
        }
    }

    /// Guarded by `lock`: a scan that starts while the previous one is still
    /// closing must not race it on the dictionary.
    /// The file's shape. JSON, not a property list: on the phone the property-list
    /// encoder refused the record type at runtime ("could not cast ... to
    /// Encodable"), a Foundation fault the Mac does not show.
    private struct Archive: Codable { var records: [String: Record] }

    private var records: [String: Record]
    private let lock = NSLock()
    private let url: URL
    private var unsaved = 0
    private var writtenCount = 0
    /// Written this scan, for the summary.
    var written: Int { lock.lock(); defer { lock.unlock() }; return writtenCount }

    private init(url: URL, records: [String: Record]) {
        self.url = url
        self.records = records
    }

    // MARK: Files

    private static var folder: URL? {
        guard let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first else { return nil }
        let folder = base.appendingPathComponent("SwanGalleryPick", isDirectory: true)
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true,
                                                 attributes: [.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication])
        // Face vectors stay on this phone: not in iCloud or computer backups.
        var excluded = folder
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        try? excluded.setResourceValues(values)
        return folder
    }

    private static func fileName(for account: String) -> String {
        let digest = SHA256.hash(data: Data(account.lowercased().utf8))
        let hex = digest.map { String(format: "%02x", $0) }.joined()
        return "scan-store-" + hex.prefix(16) + ".json"
    }

    /// The store for this account. Other accounts' stores on the phone are
    /// deleted here, which is what "cleared on sign-out" means in practice: the
    /// host has no sign-out step of its own, and a new account signing in is the
    /// moment the previous shopper's records must go.
    static func open(for account: String) -> ScanStore? {
        guard enabled, let folder else { return nil }
        let name = fileName(for: account)
        if let others = try? FileManager.default.contentsOfDirectory(atPath: folder.path) {
            for other in others where other.hasPrefix("scan-store-") && other != name {
                try? FileManager.default.removeItem(at: folder.appendingPathComponent(other))
            }
        }
        let url = folder.appendingPathComponent(name)
        var records: [String: Record] = [:]
        if let data = try? Data(contentsOf: url),
           let saved = try? JSONDecoder().decode(Archive.self, from: data) {
            records = saved.records
        }
        return ScanStore(url: url, records: records)
    }

    /// Deletes every store on the phone.
    static func clear() {
        guard let folder else { return }
        try? FileManager.default.removeItem(at: folder)
    }

    func save() {
        lock.lock()
        guard unsaved > 0 else { lock.unlock(); return }
        unsaved = 0
        let snapshot = records
        lock.unlock()
        do {
            let data = try JSONEncoder().encode(Archive(records: snapshot))
            try data.write(to: url, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
        } catch {
            print("\u{1f4be} Scan store not saved: \(error.localizedDescription)")
        }
    }

    /// Saves every `every` new records, so a scan that is killed keeps most of
    /// what it learned.
    func saveIfDue(every: Int = 500) {
        lock.lock()
        let due = unsaved >= every
        lock.unlock()
        if due { save() }
    }

    var count: Int { lock.lock(); defer { lock.unlock() }; return records.count }

    // MARK: Records

    private static func stamp(_ asset: PHAsset) -> Double {
        (asset.modificationDate ?? asset.creationDate ?? .distantPast).timeIntervalSince1970
    }

    /// The record for a photo, if it is current: same modified date, same rules.
    func record(for asset: PHAsset) -> Record? {
        lock.lock(); defer { lock.unlock() }
        guard let record = records[asset.localIdentifier],
              record.version == Self.rulesVersion,
              record.modified == Self.stamp(asset) else { return nil }
        return record
    }

    func remember(_ asset: PHAsset, _ verdict: Verdict, faces: [[Float]] = [], note: String? = nil) {
        let data = faces.map { vector in vector.withUnsafeBufferPointer { Data(buffer: $0) } }
        lock.lock(); defer { lock.unlock() }
        records[asset.localIdentifier] = Record(verdict: verdict, modified: Self.stamp(asset), version: Self.rulesVersion,
                                                faces: verdict == .candidate ? data : [], note: note,
                                                written: Date().timeIntervalSince1970)
        writtenCount += 1
        unsaved += 1
    }

    /// Each stored face's distance to the selfie, largest face first. Under
    /// `matchAgainstAllFrames` the extra frames vote as they do in the scan: the
    /// second-smallest distance counts.
    func distances(_ record: Record, to reference: [Float], extra: [[Float]], allFrames: Bool) -> [Float] {
        record.vectors.map { vector in
            let base = FaceRecognizer.distance(reference, vector)
            guard allFrames, !extra.isEmpty else { return base }
            return ([base] + extra.map { FaceRecognizer.distance($0, vector) }).sorted()[1]
        }
    }
}
