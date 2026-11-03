// ScanStore: per-photo scan results kept on the phone between scans.

import Foundation
import Photos
import CryptoKit

// MARK: - Store

/// Per-photo scan results kept between scans, so the same photos are not loaded or downloaded again.
/// Privacy: kept only on this phone (never uploaded or backed up), one file per account.
final class ScanStore {

    /// Set to false to turn the store off: no file is read or written.
    static let enabled = true

    /// Bump when a rule changes the stored verdicts, so old records are ignored and rebuilt.
    static let rulesVersion = 12

    /// Why a photo was judged. Nothing that depends on the selfie is stored.
    enum Verdict: String, Codable {
        /// Decided from the photo alone; the selfie plays no part.
        case noFace, group, faceTooSmall, otherPeople, notFullBody, unusableFace, tooLarge, sensitive
        /// iCloud-only photo whose thumbnail showed no selfie or standing person.
        /// Used only until the photo has a copy on the phone.
        case cloudThumbnail
        /// iCloud-only photo whose small copy showed several faces or no standing
        /// person. Same rule as `cloudThumbnail`.
        case cloudSmallCopy
        /// Could match somebody: `faces` holds its face vectors.
        case candidate
    }

    /// One photo's result, keyed by the photo's id.
    struct Record: Codable {
        var verdict: Verdict
        /// The photo's modified date when the record was written; a different
        /// date means the photo was edited and the record is stale.
        var modified: Double
        var version: Int
        /// Face vectors, largest face first, bystanders excluded, as Float32 bytes.
        /// Empty unless `verdict` is `candidate`.
        var faces: [Data]
        /// The reason, for the console, such as "3 faces".
        var note: String?

        var vectors: [[Float]] {
            faces.map { data in data.withUnsafeBytes { Array($0.bindMemory(to: Float.self)) } }
        }
    }

    /// The file's format. JSON, because the property-list encoder fails on this type on iOS.
    private struct Archive: Codable { var records: [String: Record] }

    /// Guarded by `lock`: a new scan can start while the previous one is still saving.
    private var records: [String: Record]
    private let lock = NSLock()
    private let url: URL
    private var unsaved = 0
    private var writtenCount = 0
    /// Records written this scan, for the summary.
    var written: Int { lock.lock(); defer { lock.unlock() }; return writtenCount }

    private init(url: URL, records: [String: Record]) {
        self.url = url
        self.records = records
    }

    // MARK: - Files

    /// The store's folder in Application Support, under iOS data protection.
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

    /// A file name from a hash of the account, so the email is not in it.
    private static func fileName(for account: String) -> String {
        let digest = SHA256.hash(data: Data(account.lowercased().utf8))
        let hex = digest.map { String(format: "%02x", $0) }.joined()
        return "scan-store-" + hex.prefix(16) + ".json"
    }

    /// Opens the store for this account and deletes every other account's store,
    /// so a new sign-in clears the previous shopper's data. Nil when `enabled` is false.
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

    /// Saves after every `every` new records, so a scan that is killed keeps most of its work.
    func saveIfDue(every: Int = 500) {
        lock.lock()
        let due = unsaved >= every
        lock.unlock()
        if due { save() }
    }

    var count: Int { lock.lock(); defer { lock.unlock() }; return records.count }

    // MARK: - Records

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

    /// Stores a verdict; face vectors are kept only for a candidate.
    func remember(_ asset: PHAsset, _ verdict: Verdict, faces: [[Float]] = [], note: String? = nil) {
        let data = faces.map { vector in vector.withUnsafeBufferPointer { Data(buffer: $0) } }
        lock.lock(); defer { lock.unlock() }
        records[asset.localIdentifier] = Record(verdict: verdict, modified: Self.stamp(asset), version: Self.rulesVersion,
                                                faces: verdict == .candidate ? data : [], note: note)
        writtenCount += 1
        unsaved += 1
    }

    /// Each stored face's distance to the selfie, largest face first.
    func distances(_ record: Record, to reference: [Float]) -> [Float] {
        record.vectors.map { FaceRecognizer.distance(reference, $0) }
    }
}
