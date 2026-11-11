// Swan Gallery Pick — one library scan: the local pass, the iCloud pass, the end-of-scan gates and the results.

import UIKit
import Photos
import Vision

/// One run of the library scan and its counts. Built and run on the scan queue;
/// messages to the page go out on the main queue.
final class LibraryScan {
    /// Score and type per match.
    typealias MatchScore = (distance: Float, type: PhotoType, score: Float?, breakdown: [String: Any]?)

    /// Held weakly: the scan must not keep the controller alive.
    private weak var controller: ViewController?
    private let assets: [PHAsset]
    private let total: Int
    private let monthsBack: Int
    private let generation: Int
    private let store: ScanStore?
    private let startedAt: Date

    private var matchedIds: [String] = []
    private var matchScores: [String: MatchScore] = [:]
    // Each shown selfie's score, for the gaze resting point — see `gazeRestFromLibrary`.
    private var selfieScores: [String: MuseScore] = [:]
    // Each shown selfie's face detail, for the relative blur gate.
    private var selfieDetail: [String: Float] = [:]
    // Every clean distance scored, match or not, for the gap rule — see `gapCutEnabled`.
    private var scoredDistances: [Float] = []
    // Matches from `gapCutFloor` up to the cut-off: held back until the gap rule
    // has run, then sent last so nothing on screen moves.
    private var heldIds: [String] = []
    // Faces under `gapCutCeiling` with their vectors — see `ownPhotoKeepEnabled`.
    private var nearFaces: [(id: String, distance: Float, vector: [Float])] = []
    // Near-duplicates — see `duplicateDistance`. Each match's group is its own id
    // or the earlier match it repeats; the page pre-selects one per group.
    private var featurePrints: [(id: String, print: VNFeaturePrintObservation)] = []
    private var dupGroups: [String: String] = [:]
    private var duplicates = 0
    private var lastReport = Date.distantPast

    // Per-gate counts, for the summary.
    private var noImage = 0
    // Scanned from the phone's smaller copy, the full photo being in iCloud.
    private var localCopies = 0
    private var noFace = 0
    private var noMatch = 0
    // How close the rejected faces came: the smallest no-match distance and
    // how many fell within 0.1 of the cut-off.
    private var closestNoMatch: Float?
    private var nearMisses = 0
    private var groupSkipped = 0
    private var tooSmall = 0
    private var notFullBody = 0
    private var otherPeople = 0
    private var sensitiveSkipped = 0
    // Originals sized after a match — see `checkOriginal`.
    private var tooLargeSkipped = 0
    private var noOriginal = 0
    private var sizedByPixels = 0
    // Matches lowered by `MuseScore.tiltMultiplier` (head pitched or turned).
    private var tiltedMatches = 0
    private var lowDataSkipped = 0

    // What the matches cover, for the summary only; the web layer derives
    // coverage from the selection.
    private var found: [PhotoType: Int] = [:]
    private var examined = 0

    // iCloud-only photos whose thumbnail looks like a selfie or a full-length shot.
    private var cloudCandidates = 0
    // Full-size iCloud downloads in flight; thread-safe.
    final class CloudGauge { private let lock = NSLock(); private var n = 0
        func add(_ d: Int) { lock.lock(); n += d; lock.unlock() }
        var value: Int { lock.lock(); defer { lock.unlock() }; return n } }
    private let cloudFullInFlight = CloudGauge()
    // One download started during the local pass. Its result lands in the job on the
    // download queue; the iCloud pass reads the jobs in order.
    final class CloudJob { let asset: PHAsset; let n: Int; let group = DispatchGroup(); let box = ViewController.LoadBox(); var previewRejected = false; var previewNote = ""; var data: Data?
        init(asset: PHAsset, n: Int) { self.asset = asset; self.n = n } }
    private var cloudJobs: [CloudJob] = []
    private var cloudSelfieCandidates = 0, cloudFullCandidates = 0
    private var cloudStartedSelfie = 0, cloudStartedFull = 0
    private var cloudLeft = 0
    // The page's bar: each download queued during the local pass extends its total,
    // and each one settled (landed, rejected or given up) moves it on.
    private var cloudQueued = 0, cloudSettled = 0
    private var localDone = 0
    private let cloudAllowed: Bool
    private let cloudCap: Int
    private let cloudQueue: OperationQueue
    private var cloudPreviewOut = 0
    private var cloudOnly = 0
    // Second head-to-toe checks at the larger render — see `lastBodyRetry`.
    private var bodyRetried = 0
    private var bodyRescued = 0
    // Mirror shots: more than one face, all the shopper's — see `sameShopperFacesMax`.
    private var sameShopper = 0
    // Matched selfies under `selfieEyeSpacingPixels` — see `selfieEyeFloorEnabled`.
    private var selfieSmallEyes = 0
    // Matches kept out for a face the Muse cannot use — see `unusableFaceDrops`.
    private var unusableFace = 0
    // The same, per gate.
    private var unusableGates: [String: Int] = [:]
    // Matched selfies the classifier marked with a head covering or an
    // object over the face — see `MuseScore.coverLabels`.
    private var coverHints = 0
    // Matched selfies whose focal length was assumed — see `assumedFocal35mm`.
    private var focalAssumed = 0
    // Eye openness of each clean matched selfie, for the relative gate.
    private var selfieOpenness: [String: Float] = [:]
    // Matched selfies the segmenter read, and how many sat over each
    // cover limit — see `coverReadEnabled`.
    private var coverRead = 0
    private var coverFacts: [String: Int] = [:]
    // Skipped from the library record alone — see `shapeReject`.
    private var skippedShape = 0

    // One entry per photo the scan looked at, saying what happened to it and the
    // readings behind it, for the scan report (test builds only: see `ScanReport.url`).
    // The page and production never see it. Filenames are added at the end.
    private let tracing = ScanReport.url != nil
    private var trail: [String: [String: Any]] = [:]
    /// Records what happened to `asset`. A later call for the same photo replaces the
    /// outcome but keeps what was noted before, so a late verdict adds to the picture.
    private func note(_ asset: PHAsset, _ outcome: String, _ extra: [String: Any] = [:]) {
        guard tracing else { return }
        var entry = trail[asset.localIdentifier] ?? [
            "px": "\(asset.pixelWidth)x\(asset.pixelHeight)",
            "taken": asset.creationDate.map { ISO8601DateFormatter().string(from: $0) } ?? "",
        ]
        entry["outcome"] = outcome
        for (key, value) in extra { entry[key] = value }
        trail[asset.localIdentifier] = entry
    }
    /// `note` for a photo `matchPerson` just ran: its outcome with everything it measured.
    private func noteExamined(_ asset: PHAsset, _ outcome: String, _ extra: [String: Any] = [:]) {
        guard tracing else { return }
        var fields = controller?.lastTrace ?? [:]
        fields["shopperFaces"] = controller?.lastShopperFaces ?? 1
        if let retry = controller?.lastBodyRetry { fields["bodyRetryHeadToToe"] = retry }
        if controller?.lastLoadLocalCopy == true { fields["fromSmallLocalCopy"] = true }
        fields["fromICloud"] = controller?.lastLoadFromCloud ?? false
        note(asset, outcome, fields.merging(extra) { _, new in new })
    }
    // No-matches decided before body pose — see `matchBeforePose`.
    private var earlyNoMatch = 0
    private var memoryPeak: Int

    // Photos the store decided without a load, and iCloud candidates it skipped.
    private var storeDecided = 0
    private var storeCloudSkipped = 0

    // The iCloud pass's counts.
    private var cloudDownloaded = 0
    // The first and last iCloud download: the photo's capture date, and when
    // it landed, in ms from the start of the scan. For the scan summary.
    private var cloudFirstDownloaded: (day: String?, atMs: Int)?
    private var cloudLastDownloaded: (day: String?, atMs: Int)?
    private var cloudFailed = 0
    // Failures by reason (`LoadResult.cloudFailure`): diskFull, timedOut, other.
    private var cloudFailures: [String: Int] = [:]
    private var cloudPassStarted = Date.distantPast

    // What the end-of-scan gates decided — see `applyEndOfScanGates`.
    private var eyeDropped: [String] = []
    private var eyeBaseline: Float?
    private var blurDropped: [String] = []
    private var blurBaseline: Float?
    private var gapCut: Float?
    private var gapDropped: [String] = []
    private var weakCut = false
    private var ownKept: [String] = []
    private var gazeRescored: [String] = []
    private var libraryRest: (yaw: Float, pitch: Float)?
    /// The shopper's usual frown reading, the line drawn from it, and the selfies it rescored.
    private var frownBaseline: Float?
    private var frownLine: Float?
    private var frownSelfies = 0
    private var frownRescored: [String] = []
    /// The close selfies the blur gate compared, and the selfies the gaze rest point came from.
    private var blurShown: [(id: String, detail: Float)] = []
    private var gazeSelfies = 0

    /// Reads the cloud limits and resets the controller's per-scan timers, so build it on the scan queue.
    init(controller: ViewController?, assets: [PHAsset], monthsBack: Int, generation: Int, store: ScanStore?, startedAt: Date) {
        self.controller = controller
        self.assets = assets
        self.total = assets.count
        self.monthsBack = monthsBack
        self.generation = generation
        self.store = store
        self.startedAt = startedAt
        cloudAllowed = ViewController.cloudDownloadsAllowed
        cloudCap = ViewController.cloudDownloadCap
        // At the scan's own priority: the scan waits on these at the end, and a
        // lower class there is a priority inversion. The queue caps what runs
        // at once, so no thread is parked on a semaphore.
        let queue = OperationQueue()
        queue.name = "co.getswan.gallery.cloud"
        queue.qualityOfService = .userInitiated
        queue.maxConcurrentOperationCount = ViewController.cloudOnMobile ? ViewController.cloudParallelMobile : ViewController.cloudParallel
        cloudQueue = queue
        controller?.cloudLargerDownloads = 0
        controller?.stageMs = [:]
        memoryPeak = ViewController.residentMB()
        FaceRecognizer.timing = { [weak controller] stage, ms in controller?.stageMs[stage, default: 0] += ms }
    }

    /// The whole scan, in order. Stops quietly when a newer scan has replaced this one.
    func run() {
        guard localPass(), cloudPass() else { return }

        // Not for a scan another one has replaced: its records are already
        // in the newer store, and two writers on one file help nobody.
        if controller?.scanGeneration == generation { store?.save() }

        let cloudWaited = Date().timeIntervalSince(cloudPassStarted)
        let elapsed = Date().timeIntervalSince(startedAt)
        let rate = Double(examined) / max(elapsed, 0.001)

        applyEndOfScanGates()
        finishScan(elapsed: elapsed, rate: rate, cloudWaited: cloudWaited)
    }

    // MARK: - Messages and payloads

    /// Sends `message` to the page on the main queue, if the controller is still there.
    private func sendOnMain(_ message: [String: Any]) {
        DispatchQueue.main.async { [weak controller = self.controller] in
            controller?.sendToWeb(message)
        }
    }

    /// Tells the page how far the scan has got, on the main queue.
    private func sendProgress(done: Int) {
        localDone = done
        sendOnMain(["type": "onGalleryScanProgress", "payload": ["done": done + cloudSettled, "total": total + cloudQueued]])
    }

    /// Progress for photo `n`, at most every quarter second and always for the last.
    private func reportProgress(_ n: Int) {
        // Throttled by time, not photo count: per-photo cost varies too
        // much for "every Nth" to give a predictable update rate.
        if Date().timeIntervalSince(lastReport) > 0.25 || n == total {
            lastReport = Date()
            sendProgress(done: n)
        }
    }

    /// One `onGalleryMatchFound` payload: the match itself, then its score and score fields when it has them.
    private static func matchPayload(id: String, type: PhotoType, isFullBody: Bool, distance: Float, dupGroup: String,
                                     rescored: Bool = false, done: Int, total: Int,
                                     score: Float?, fields: [String: Any]?) -> [String: Any] {
        var payload: [String: Any] = ["assetId": id,
                                      "type": type.rawValue,
                                      "isFullBody": isFullBody,
                                      // Lower is closer; the page falls back to
                                      // it when no score is sent.
                                      "distance": distance,
                                      // Same for every photo that repeats one shot;
                                      // the page pre-selects one per group.
                                      "dupGroup": dupGroup,
                                      "done": done,
                                      "total": total]
        if rescored { payload["rescored"] = true }
        // Higher is better. The page pre-selects the top of each type by it.
        if let score { payload["score"] = score }
        if let fields { payload.merge(fields) { _, new in new } }
        return payload
    }

    // MARK: - Scan store

    /// Writes a photo's verdict to the store — see `ScanStore`. A candidate keeps its
    /// face vectors, so a later scan can compare them with its selfie without a load.
    private func remember(_ asset: PHAsset, _ verdict: ScanStore.Verdict, note: String? = nil) {
        guard let store else { return }
        if verdict == .candidate {
            guard let faces = controller?.lastEmbeddings, !faces.isEmpty else { return }
            store.remember(asset, .candidate, faces: faces)
        } else {
            store.remember(asset, verdict, note: note)
        }
    }

    /// Counts a photo the store already knows, without loading it; false when it must be loaded.
    private func decideFromStore(_ asset: PHAsset) -> Bool {
        guard let store, let record = store.record(for: asset) else { return false }
        func decided() -> Bool {
            storeDecided += 1
            note(asset, "store:\(record.verdict.rawValue)", ["why": "decided by an earlier scan's stored verdict, not looked at again; clear the scan store to re-test"])
            return true
        }
        switch record.verdict {
        case .noFace: noFace += 1; return decided()
        case .group: groupSkipped += 1; return decided()
        case .faceTooSmall: tooSmall += 1; return decided()
        case .otherPeople: otherPeople += 1; return decided()
        case .notFullBody: notFullBody += 1; return decided()
        case .unusableFace: unusableFace += 1; return decided()
        case .tooLarge: tooLargeSkipped += 1; return decided()
        case .sensitive: sensitiveSkipped += 1; return decided()
        case .cloudThumbnail, .cloudSmallCopy:
            // Only while the photo still has no copy on the phone: decided
            // in the iCloud branch, once the load has failed.
            return false
        case .candidate:
            guard let reference = controller?.referenceEmbedding else { return false }
            let distances = store.distances(record, to: reference)
            guard let best = distances.min() else { return false }
            // Several faces: every one must be the shopper, as in `matchPerson`.
            if distances.count > 1, distances.contains(where: { $0 >= ViewController.matchThreshold }) {
                groupSkipped += 1
                return decided()
            }
            guard best >= ViewController.matchThreshold else { return false }
            noMatch += 1
            note(asset, "store:noMatch", ["distance": twoPlaces(best), "why": "stored face vector too far from this selfie (cut \(ViewController.matchThreshold))"])
            scoredDistances.append(best)
            if ViewController.ownPhotoKeepEnabled, best < ViewController.gapCutCeiling,
               let index = distances.firstIndex(of: best), index < record.vectors.count {
                nearFaces.append((asset.localIdentifier, best, record.vectors[index]))
            }
            if let closest = closestNoMatch, closest <= best {} else { closestNoMatch = best }
            if best - ViewController.matchThreshold <= 0.1 { nearMisses += 1 }
            storeDecided += 1
            return true
        }
    }

    // MARK: - One photo

    /// One loaded photo through every gate. Shared by the local pass and the
    /// iCloud pass, so a downloaded photo faces exactly the same checks.
    private func examine(_ asset: PHAsset, _ image: UIImage, n: Int) {
        if controller?.lastLoadLocalCopy == true { localCopies += 1 }

        guard let outcome = controller?.matchPerson(in: image, asset: asset) else { return }
        if let copies = controller?.lastShopperFaces, copies > 1 {
            sameShopper += 1
        }
        if let rescued = controller?.lastBodyRetry {
            bodyRetried += 1
            if rescued { bodyRescued += 1 }
        }

        switch outcome {
        case .noFace:
            noFace += 1
            noteExamined(asset, "noFace")
            remember(asset, .noFace)

        case .group(let faceCount):
            groupSkipped += 1
            noteExamined(asset, "group", ["why": "\(faceCount) faces and not all the shopper's"])
            // Four or more faces, or a face that could not be embedded,
            // is a group whoever the shopper is; two or three faces are
            // a group only against this selfie, so their vectors are kept.
            remember(asset, faceCount > ViewController.sameShopperFacesMax || (controller?.lastEmbeddings.isEmpty ?? true) ? .group : .candidate)

        case .faceTooSmall(let pixels):
            tooSmall += 1
            noteExamined(asset, "faceTooSmall", ["why": "widest face \(pixels)px, under \(Int(ViewController.minFacePixels)) even after the larger render"])
            remember(asset, .faceTooSmall)

        case .otherPeople:
            otherPeople += 1
            noteExamined(asset, "otherPeople")
            // One face: someone else is in the photo whoever the shopper
            // is. Several faces all the shopper's: only against this selfie.
            remember(asset, (controller?.lastShopperFaces ?? 1) == 1 ? .otherPeople : .candidate)

        case .notFullBody(let body):
            notFullBody += 1
            noteExamined(asset, "notFullBody", ["bodyAtGate": ViewController.bodyTrace(body)])
            // Final once the larger render was tried, or when nothing
            // could trigger that retry. Otherwise a match by a later
            // selfie could still rescue it, so the vectors are kept.
            remember(asset, controller?.lastBodyRetry != nil || !body.headSeen || body.lowerJoints < 1 ? .notFullBody : .candidate)

        case .scored(let distances, let body, let type, let museScore):
            let distance = distances.min()!
            noteExamined(asset, "scored", ["distance": twoPlaces(distance), "distances": distances.map { twoPlaces($0) },
                                           "type": type.rawValue, "cut": ViewController.matchThreshold,
                                           "earlyNoMatch": controller?.lastEarlyNoMatch ?? false,
                                           "score": (museScore.map { twoPlaces($0.value) } as Any?) ?? NSNull(),
                                           "isFullBody": body.isHeadToToe])
            // Saved as a candidate first; the final verdicts below overwrite it.
            remember(asset, .candidate)
            // The gap rule sees clean faces only: covered or strained faces
            // land between the shopper's photos and strangers.
            let unusable = ViewController.unusableFaceDrops ? museScore?.filter : nil
            if unusable == nil && museScore?.demoted != true { scoredDistances.append(distance) }
            // The closest face's vector, for the own-photo check. Clean faces only.
            if ViewController.ownPhotoKeepEnabled, unusable == nil, museScore?.demoted != true, distance < ViewController.gapCutCeiling,
               let vectors = controller?.lastEmbeddings, vectors.count == distances.count,
               let index = distances.firstIndex(of: distance) {
                nearFaces.append((asset.localIdentifier, distance, vectors[index]))
            }
            if distance < ViewController.matchThreshold, type == .selfie, let museScore {
                if museScore.coverHint { coverHints += 1 }
                if museScore.focalAssumed { focalAssumed += 1 }
                if let cover = museScore.cover {
                    coverRead += 1
                    if cover.hairline >= ViewController.coverHairlineLimit { coverFacts["hairline", default: 0] += 1 }
                    if cover.jaw >= ViewController.coverJawLimit { coverFacts["jaw", default: 0] += 1 }
                    if cover.face >= ViewController.coverFaceLimit { coverFacts["face", default: 0] += 1 }
                }
            }

            if distance >= ViewController.matchThreshold {
                note(asset, "noMatch", ["why": "face distance \(twoPlaces(distance)) is at or over the cut \(ViewController.matchThreshold)"])
                noMatch += 1
                if controller?.lastEarlyNoMatch == true { earlyNoMatch += 1 }
                if let closest = closestNoMatch, closest <= distance {} else { closestNoMatch = distance }
                if distance - ViewController.matchThreshold <= 0.1 { nearMisses += 1 }
            } else if controller?.isSensitiveContent(image) == true {
                sensitiveSkipped += 1
                note(asset, "sensitive")
                remember(asset, .sensitive)
            } else if let why = unusable {
                note(asset, "unusableFace", ["why": why])
                // Before sizing: nothing is fetched for a photo that
                // will not be shown.
                unusableFace += 1
                unusableGates[why, default: 0] += 1
                remember(asset, .unusableFace)
            } else if hiddenAtSizing(asset) {
                // Hidden: its original cannot be sent as it is.
                note(asset, "hiddenAtSizing", ["why": "matched, but its original could not be sent (too large, unavailable or low data)"])
            } else {
                note(asset, "matched")
                matchedIds.append(asset.localIdentifier)
                let orderFields = ViewController.orderFields(asset: asset, type: type, score: museScore)
                let scoreFields = museScore.map { $0.breakdown.merging(orderFields) { _, new in new } }
                matchScores[asset.localIdentifier] = (distance, type, museScore?.value, scoreFields)
                if museScore?.tilted == true { tiltedMatches += 1 }
                var dupGroup = asset.localIdentifier
                if let fingerprint = ViewController.featurePrint(of: image) {
                    var nearest: (id: String, distance: Float)?
                    for other in featurePrints {
                        var d: Float = 1
                        guard (try? other.print.computeDistance(&d, to: fingerprint)) != nil else { continue }
                        if nearest == nil || d < nearest!.distance { nearest = (other.id, d) }
                    }
                    if let nearest, nearest.distance < ViewController.duplicateDistance {
                        dupGroup = dupGroups[nearest.id] ?? nearest.id
                        duplicates += 1
                    }
                    featurePrints.append((asset.localIdentifier, fingerprint))
                }
                dupGroups[asset.localIdentifier] = dupGroup

                // Kept so the tap that follows does not reload the photo
                // and re-run pose detection for answers already in hand.
                ScanAnalysisStore.store(ScanAnalysis(type: type, body: body),
                                        id: asset.localIdentifier)
                found[type, default: 0] += 1
                if ViewController.gazeRestFromLibrary, type == .selfie, let museScore { selfieScores[asset.localIdentifier] = museScore }
                if ViewController.relativeBlurGateEnabled, type == .selfie, let detail = museScore?.expression?.faceDetail,
                   let cm = museScore?.cameraCm, cm <= ViewController.relativeBlurMaxCm { selfieDetail[asset.localIdentifier] = detail }
                // The more closed eye, for the relative gate at the end.
                if ViewController.relativeEyeGateEnabled, type == .selfie, let e = museScore?.expression {
                    selfieOpenness[asset.localIdentifier] = 1 - e.blinkMax
                }
                // Counted for the summary — see `selfieSmallEyes`.
                if type == .selfie, (controller?.lastEyeSpacing ?? ViewController.selfieEyeSpacingPixels) < ViewController.selfieEyeSpacingPixels { selfieSmallEyes += 1 }

                // Streamed as found so the grid fills during the scan: the id and its
                // verdict only, the page fetches its own pixels. A match the gap rule
                // could still withdraw is held back, so no tile vanishes.
                let held = ViewController.gapCutEnabled && distance >= ViewController.gapCutFloor
                if held {
                    heldIds.append(asset.localIdentifier)
                } else {
                    sendOnMain(["type": "onGalleryMatchFound",
                                "payload": Self.matchPayload(id: asset.localIdentifier, type: type, isFullBody: body.isHeadToToe,
                                                             distance: distance, dupGroup: dupGroup, done: max(n, localDone) + cloudSettled, total: total + cloudQueued,
                                                             score: museScore?.value, fields: scoreFields)])
                }
            }
        }
    }

    /// Sizes a matched photo's original; true when the photo is hidden because it cannot be sent as it is.
    private func hiddenAtSizing(_ asset: PHAsset) -> Bool {
        let check = controller?.checkOriginal(asset) ?? .unavailable(.unreadable)
        switch check {
        case .fits:
            return false
        case .tooLarge:
            tooLargeSkipped += 1
            remember(asset, .tooLarge)
            return true
        case .unavailable(let reason):
            let megapixels = Double(asset.pixelWidth * asset.pixelHeight) / 1_000_000
            if reason == .tooSlow, Original.sizeByPixelsWhenSlow, megapixels <= Original.sizeByPixelsMaxMegapixels {
                sizedByPixels += 1
                return false
            }
            noOriginal += 1
            return true
        case .lowData:
            lowDataSkipped += 1
            return true
        }
    }

    // MARK: - Local pass

    /// Every photo in the window, newest first, from the phone's own copies; iCloud-only
    /// candidates start downloading for the iCloud pass. False when the scan was superseded.
    private func localPass() -> Bool {
        let prefetchQueue = DispatchQueue(label: "co.getswan.gallery.prefetch", qos: .userInitiated)
        var ahead: (index: Int, group: DispatchGroup, box: ViewController.LoadBox)?
        for index in 0..<total {
            // Abandons the scan outright: a superseded scan that still reported
            // would overwrite the live one.
            guard controller?.scanGeneration == generation else {
                return false
            }

            autoreleasepool {
                let asset = assets[index]
                let n = index + 1

                examined += 1

                if let shape = ViewController.shapeReject(asset) {
                    skippedShape += 1
                    note(asset, "shape", ["why": shape])
                    return
                }

                // Known from an earlier scan — see `ScanStore`: counted without
                // a load. A decode already started for it finishes unused.
                if decideFromStore(asset) {
                    ahead = nil
                    // The page's progress still moves while known photos fly by.
                    reportProgress(n)
                    return
                }

                // The photo decoded ahead of time, if `decodeAhead` started it
                // during the previous photo; else loaded now. Either way the next
                // one starts decoding before this one is examined.
                let loaded: ViewController.LoadResult? = controller?.timed("load") {
                    if let ahead, ahead.index == index {
                        ahead.group.wait()
                        return ahead.box.result
                    }
                    return controller?.loadPhotoResult(asset: asset)
                } ?? nil
                ahead = nil
                if ViewController.decodeAhead, index + 1 < total {
                    let nextAsset = assets[index + 1]
                    // No decode for a photo the store will most likely decide
                    // without one; a candidate that turns out to match loads then.
                    let known = store?.record(for: nextAsset).map { $0.verdict != .cloudThumbnail && $0.verdict != .cloudSmallCopy } ?? false
                    if ViewController.shapeReject(nextAsset) == nil, !known {
                        let group = DispatchGroup(), box = ViewController.LoadBox()
                        group.enter()
                        prefetchQueue.async { [weak controller = self.controller] in
                            box.result = controller?.loadPhotoResult(asset: nextAsset); group.leave()
                        }
                        ahead = (index + 1, group, box)
                    }
                }
                controller?.applyLoad(loaded)

                guard let image = loaded?.image else {
                    notLoaded(asset, n: n)
                    return
                }
                examine(asset, image, n: n)
                if n % 25 == 0 { memoryPeak = max(memoryPeak, ViewController.residentMB()) }
                store?.saveIfDue()

                reportProgress(n)
            }
        }
        return true
    }

    /// A photo with no copy on the phone: skipped, or — when its thumbnail is shaped
    /// like a selfie or a lone standing person — downloaded for the iCloud pass.
    private func notLoaded(_ asset: PHAsset, n: Int) {
        let note = controller?.lastLoadNote ?? ""
        if note.hasPrefix("in iCloud") { cloudOnly += 1 }
        self.note(asset, "noImage", ["why": note.isEmpty ? "no copy could be loaded" : note])
        // Judged on its thumbnail or small copy by an earlier scan and
        // still only in iCloud — see `ScanStore`: no test, no download.
        if let store, let record = store.record(for: asset),
           record.verdict == .cloudThumbnail || record.verdict == .cloudSmallCopy {
            storeCloudSkipped += 1
            noImage += 1
            self.note(asset, "noImage:store", ["why": "iCloud-only, judged on its thumbnail by an earlier scan (\(record.verdict.rawValue)) and not downloaded"])
            return
        }
        // A thumbnail shaped like a selfie or a lone standing person is worth a
        // download, started now within the caps and the ceiling. Anything else is skipped.
        if let thumb = controller?.lastLoadThumbnail,
           let kind: String = (controller?.isSelfieShaped(thumb) == true ? "selfie" : (controller?.isFullLengthShaped(thumb) == true ? "full-length" : nil)) {
            cloudCandidates += 1
            if kind == "selfie" { cloudSelfieCandidates += 1 } else { cloudFullCandidates += 1 }
            let started = cloudStartedSelfie + cloudStartedFull
            let selfieRoom = cloudCap - max(0, ViewController.cloudFullLengthReserve - cloudStartedFull)
            let fits = kind == "full-length" ? started < cloudCap : cloudStartedSelfie < selfieRoom && started < cloudCap
            if cloudAllowed, fits {
                if kind == "selfie" { cloudStartedSelfie += 1 } else { cloudStartedFull += 1 }
                let job = CloudJob(asset: asset, n: n)
                cloudJobs.append(job)
                cloudQueued += 1
                job.group.enter()
                cloudQueue.addOperation { [weak controller = self.controller, cloudFullInFlight = self.cloudFullInFlight] in
                    // Small copy first; the full one only for a lone person.
                    let preview = controller?.loadFromCloudResult(asset: asset, pixels: ViewController.cloudPreviewPixels, timeout: ViewController.cloudTimeoutNow)
                    let check: (passes: Bool, note: String, faceRatio: CGFloat)? = preview?.image.map { controller?.cloudPreviewPasses($0, kind: kind) ?? (passes: false, note: "", faceRatio: 0) }
                    if let check, check.passes {
                        cloudFullInFlight.add(1)
                        // The small copy's face box says how big the face will be at the
                        // scan's size. Under the floor, fetch the bigger copy straight away
                        // (the size the scan would ask for anyway) instead of two downloads.
                        var pixels = ViewController.loadPixels
                        if check.faceRatio > 0, check.faceRatio * pixels < ViewController.minFacePixels * ViewController.cloudFaceEstimateMargin {
                            pixels = min(ViewController.fullResPixels, max(pixels, (ViewController.minFacePixels / check.faceRatio * 1.25).rounded(.up)))
                        }
                        var full = controller?.loadFromCloudResult(asset: asset, pixels: pixels, timeout: ViewController.cloudTimeoutNow)
                        // Held as JPEG until the scan reads it: decoded images are large,
                        // and many may wait for the local pass to end.
                        job.data = full?.image?.jpegData(compressionQuality: 0.92)
                        full?.image = nil
                        job.box.result = full
                        cloudFullInFlight.add(-1)
                    } else if let check {
                        job.previewRejected = true
                        job.previewNote = check.note
                    } else {
                        job.box.result = preview
                    }
                    job.group.leave()
                }
            } else {
                cloudLeft += 1
                noImage += 1
                self.note(asset, "noImage:cloudCap", ["why": "iCloud-only \(kind) candidate, not downloaded: \(cloudAllowed ? "download cap reached" : "downloads not allowed")", "kind": kind])
            }
            return
        }
        self.note(asset, "noImage:thumbnail", ["why": "iCloud-only and the thumbnail looks like neither a selfie nor a lone standing person, so it was never downloaded"])
        noImage += 1
        // A thumbnail that failed the shape test fails it next time
        // too; a photo with no thumbnail at all is tried again.
        if note.hasPrefix("in iCloud"), controller?.lastLoadThumbnail != nil { remember(asset, .cloudThumbnail) }
    }

    // MARK: - iCloud pass

    /// Examines the downloads started in the local pass, waiting up to `cloudTail` (to
    /// `cloudTailMax` while a confirmed photo is still coming). False when superseded.
    private func cloudPass() -> Bool {
        cloudPassStarted = Date()
        let deadline = cloudPassStarted.addingTimeInterval(ViewController.cloudTail)
        let hardDeadline = cloudPassStarted.addingTimeInterval(ViewController.cloudTailMax)
        var cloudExtended = false
        for job in cloudJobs {
            guard controller?.scanGeneration == generation else {
                cloudQueue.cancelAllOperations()
                return false
            }
            let wait = max(0, deadline.timeIntervalSinceNow)
            var arrived = job.group.wait(timeout: .now() + wait) == .success
            // Past the base wait: keep going in short steps while a confirmed
            // photo is still coming down, up to `cloudTailMax`. Each step pings
            // the page so its stall timer stays quiet.
            while !arrived, hardDeadline.timeIntervalSinceNow > 0, cloudFullInFlight.value > 0 {
                if !cloudExtended {
                    cloudExtended = true
                }
                sendProgress(done: total)
                let step = min(2, max(0, hardDeadline.timeIntervalSinceNow))
                arrived = job.group.wait(timeout: .now() + step) == .success
            }
            // Settled either way below; the bar moves on whatever became of the download.
            cloudSettled += 1
            defer { sendProgress(done: total) }
            guard arrived else {
                cloudLeft += 1
                noImage += 1
                note(job.asset, "noImage:cloudTimeout", ["why": "iCloud download had not finished when the scan stopped waiting"])
                continue
            }
            if job.previewRejected {
                cloudPreviewOut += 1
                note(job.asset, "cloudPreviewRejected", ["why": job.previewNote])
                remember(job.asset, .cloudSmallCopy, note: job.previewNote)
                continue
            }
            autoreleasepool {
                if let data = job.data { job.box.result?.image = UIImage(data: data); job.data = nil }
                controller?.applyLoad(job.box.result)
                guard let image = job.box.result?.image else {
                    cloudFailed += 1
                    cloudFailures[job.box.result?.cloudFailure ?? "other", default: 0] += 1
                    note(job.asset, "noImage:cloudFailed", ["why": "iCloud download failed: \(job.box.result?.cloudFailure ?? "other")"])
                    noImage += 1
                    return
                }
                cloudDownloaded += 1
                let landed = (day: ViewController.captureDay(job.asset.creationDate), atMs: elapsedMs(since: startedAt))
                if cloudFirstDownloaded == nil { cloudFirstDownloaded = landed }
                cloudLastDownloaded = landed
                examine(job.asset, image, n: job.n)
                memoryPeak = max(memoryPeak, ViewController.residentMB())
            }
        }
        // Nothing reads a download that lands after the deadline: the jobs
        // still queued are dropped here instead of running on in the
        // background. The few already in flight finish within their timeout.
        cloudQueue.cancelAllOperations()
        return true
    }

    // MARK: - End-of-scan gates

    /// Takes `ids` out of the final list and the type counts. With `gate`, also out of
    /// the held list, and counted as unusable faces under that gate's name.
    private func withdraw(_ ids: [String], gate: String? = nil) {
        let droppedSet = Set(ids)
        matchedIds.removeAll { droppedSet.contains($0) }
        if gate != nil { heldIds.removeAll { droppedSet.contains($0) } }
        for id in ids { if let score = matchScores[id] { found[score.type, default: 0] -= 1 } }
        if let gate {
            unusableFace += ids.count
            unusableGates[gate, default: 0] += ids.count
        }
    }

    /// The gates that need every match in: the relative eye and blur gates, the gap
    /// rule with the own-photo keep, and the shopper's own gaze resting point.
    private func applyEndOfScanGates() {
        // Relative eye gate — see `relativeEyeGateEnabled`: withdraws a selfie whose more
        // closed eye is under `relativeOpenness` of the shopper's median openness.
        if ViewController.relativeEyeGateEnabled, selfieOpenness.count >= ViewController.relativeBaselineMin {
            let usual = median(Array(selfieOpenness.values))
            eyeBaseline = usual
            eyeDropped = matchedIds.filter { selfieOpenness[$0].map { $0 < ViewController.relativeOpenness * usual } ?? false }
            if !eyeDropped.isEmpty { withdraw(eyeDropped, gate: "eyes under usual") }
        }

        // Relative blur gate — see `relativeBlurGateEnabled`: withdraws a close selfie
        // whose face detail is under `relativeBlurShare` of the shopper's median.
        let detailShown = matchedIds.compactMap { id in selfieDetail[id].map { (id: id, detail: $0) } }
        if ViewController.relativeBlurGateEnabled, detailShown.count >= ViewController.relativeBlurMin {
            let usual = median(detailShown.map(\.detail))
            blurBaseline = usual
            blurShown = detailShown
            blurDropped = detailShown.filter { $0.detail < ViewController.relativeBlurShare * usual }.map(\.id)
            if !blurDropped.isEmpty { withdraw(blurDropped, gate: "blurred against usual") }
        }

        // Gap rule — see `gapCutEnabled`: matches at or past the cut are withdrawn.
        // With no gap found, a weak reference falls back to `weakReferenceCut`.
        var decidedCut = ViewController.gapCut(distances: scoredDistances)
        if decidedCut == nil, ViewController.weakReferenceCutEnabled,
           let farthest = matchedIds.compactMap({ matchScores[$0]?.distance }).max(), farthest >= ViewController.weakReferenceReach {
            decidedCut = ViewController.weakReferenceCut
            weakCut = true
        }
        // The own-photo keep — see `ownPhotoKeepEnabled`. A face's nearest
        // distance to the sure matches, nil when it has none to compare.
        let sureMatches = nearFaces.filter { $0.distance < ViewController.ownPhotoCore && matchedIds.contains($0.id) }
        func nearestOwn(_ id: String) -> Float? {
            guard let face = nearFaces.first(where: { $0.id == id }) else { return nil }
            return sureMatches.filter { $0.id != id }.map { FaceRecognizer.distance(face.vector, $0.vector) }.min()
        }
        if let cut = decidedCut {
            gapCut = cut
            gapDropped = matchedIds.filter { (matchScores[$0]?.distance ?? 0) >= cut }
            if ViewController.ownPhotoKeepEnabled {
                ownKept = gapDropped.filter { (nearestOwn($0) ?? .infinity) < ViewController.ownPhotoKeepLimit }
                let keptSet = Set(ownKept)
                gapDropped.removeAll { keptSet.contains($0) }
            }
            withdraw(gapDropped)
        }

        // The shopper's own gaze resting point — see `gazeRestFromLibrary`.
        if ViewController.gazeRestFromLibrary, ViewController.gazeCurve != nil {
            let shownSelfies = matchedIds.filter { selfieScores[$0] != nil }
            let offsets = shownSelfies.compactMap { ViewController.gazeOffset(selfieScores[$0]?.expression, rest: (0, 0)) }
            gazeSelfies = offsets.count
            if offsets.count >= ViewController.gazeRestLibraryMin {
                let middle = (yaw: median(offsets.map(\.side)), pitch: median(offsets.map(\.vert)))
                if abs(middle.yaw - ViewController.gazeRest.yaw) <= ViewController.gazeRestMaxShift, abs(middle.pitch - ViewController.gazeRest.pitch) <= ViewController.gazeRestMaxShift {
                    libraryRest = middle
                    var selfieAssets: [String: PHAsset] = [:]
                    PHAsset.fetchAssets(withLocalIdentifiers: shownSelfies, options: nil).enumerateObjects { asset, _, _ in selfieAssets[asset.localIdentifier] = asset }
                    for id in shownSelfies {
                        guard let old = selfieScores[id], let new = old.regazed(rest: middle), let asset = selfieAssets[id],
                              let entry = matchScores[id], abs(new.value - old.value) > 0.0005 || new.tier != old.tier else { continue }
                        let fields = ViewController.orderFields(asset: asset, type: .selfie, score: new)
                        matchScores[id] = (entry.distance, entry.type, new.value, new.breakdown.merging(fields) { _, new in new })
                        selfieScores[id] = new
                        gazeRescored.append(id)
                    }
                }
            }
        }

        // The frown against the shopper's own brows — see `frownRelativeEnabled`. After the gaze
        // rest point, so a selfie rescored there is rescored from its new values.
        if ViewController.frownRelativeEnabled {
            let shownSelfies = matchedIds.filter { selfieScores[$0] != nil }
            let close = shownSelfies.compactMap { id -> Float? in
                guard let score = selfieScores[id], let cm = score.cameraCm, cm <= ViewController.frownBaselineMaxCm else { return nil }
                return score.expression?.browDown
            }
            frownSelfies = close.count
            if close.count >= ViewController.frownBaselineMin {
                let usual = median(close)
                let line = min(max(ViewController.frownLimit, usual + ViewController.frownOverUsual), ViewController.frownCeiling)
                frownBaseline = usual
                frownLine = line
                var selfieAssets: [String: PHAsset] = [:]
                PHAsset.fetchAssets(withLocalIdentifiers: shownSelfies, options: nil).enumerateObjects { asset, _, _ in selfieAssets[asset.localIdentifier] = asset }
                for id in shownSelfies {
                    guard let old = selfieScores[id], let new = old.refrowned(line: line), let asset = selfieAssets[id],
                          let entry = matchScores[id], abs(new.value - old.value) > 0.0005 || new.tier != old.tier else { continue }
                    let fields = ViewController.orderFields(asset: asset, type: .selfie, score: new)
                    matchScores[id] = (entry.distance, entry.type, new.value, new.breakdown.merging(fields) { _, new in new })
                    selfieScores[id] = new
                    frownRescored.append(id)
                }
            }
        }
    }

    // MARK: - Scan report

    /// Why each withdrawn match went, with its reading against the line.
    private func droppedWhy() -> [String: String] {
        var why: [String: String] = [:]
        for id in gapDropped { why[id] = String(format: "gap cut, d %.3f", matchScores[id]?.distance ?? 0) }
        for id in eyeDropped { why[id] = String(format: "eyes under usual, %.2f× (line %.2f×)", (selfieOpenness[id] ?? 0) / max(eyeBaseline ?? 1, 0.001), ViewController.relativeOpenness) }
        for id in blurDropped { why[id] = String(format: "blurred against usual, %.2f× (line %.2f×)", (selfieDetail[id] ?? 0) / max(blurBaseline ?? 1, 0.001), ViewController.relativeBlurShare) }
        return why
    }

    /// The per-photo trail for the report: every photo the scan looked at, with its outcome,
    /// the readings behind it and its filename in the Photos app (IMG_1234.jpg), so a photo
    /// the shopper expected can be found and explained. Withdrawn matches say why.
    /// Test builds only; empty otherwise.
    private func reportTrail() -> [[String: Any]] {
        guard tracing else { return [] }
        let why = droppedWhy()
        for (id, reason) in why where trail[id] != nil {
            trail[id]?["outcome"] = "withdrawn"
            trail[id]?["why"] = reason
        }
        let ids = Array(trail.keys)
        var files: [String: String] = [:]
        PHAsset.fetchAssets(withLocalIdentifiers: ids, options: nil).enumerateObjects { asset, _, _ in
            if let name = PHAssetResource.assetResources(for: asset).first?.originalFilename { files[asset.localIdentifier] = name }
        }
        return ids.sorted { (trail[$0]?["taken"] as? String ?? "") > (trail[$1]?["taken"] as? String ?? "") }.map { id in
            var entry = trail[id] ?? [:]
            entry["id"] = ScanReport.short(id)
            if let name = files[id] { entry["file"] = name }
            return entry
        }
    }

    /// The end-of-scan checks: each one's usual value, its line, and what it withdrew or changed.
    private func reportChecks() -> [String: Any] {
        let short = ScanReport.short
        var checks: [String: Any] = [:]
        if let usual = eyeBaseline {
            checks["eyes"] = ["usual": twoPlaces(usual), "selfies": selfieOpenness.count,
                              "line": twoPlaces(ViewController.relativeOpenness), "withdrawn": eyeDropped.map(short)]
        }
        if let usual = blurBaseline {
            let lowest = blurShown.sorted { $0.detail < $1.detail }.prefix(4)
                .map { ["id": short($0.id), "ratio": twoPlaces($0.detail / max(usual, 0.001))] as [String: Any] }
            checks["blur"] = ["usual": twoPlaces(usual), "closeSelfies": blurShown.count,
                              "line": twoPlaces(ViewController.relativeBlurShare), "withdrawn": blurDropped.map(short), "lowest": lowest]
        }
        if let rest = libraryRest {
            let rescored = gazeRescored.map { id -> [String: Any] in
                ["id": short(id), "score": twoPlaces(matchScores[id]?.score ?? 0), "tier": matchScores[id]?.breakdown?["tier"] as? String ?? ""]
            }
            checks["gazeRest"] = ["yaw": twoPlaces(rest.yaw), "pitch": twoPlaces(rest.pitch), "selfies": gazeSelfies,
                                  "default": [twoPlaces(ViewController.gazeRest.yaw), twoPlaces(ViewController.gazeRest.pitch)],
                                  "rescored": rescored]
        }
        if let usual = frownBaseline, let line = frownLine {
            let rescored = frownRescored.map { id -> [String: Any] in
                ["id": short(id), "score": twoPlaces(matchScores[id]?.score ?? 0), "tier": matchScores[id]?.breakdown?["tier"] as? String ?? ""]
            }
            checks["frown"] = ["usual": twoPlaces(usual), "line": twoPlaces(line), "closeSelfies": frownSelfies, "rescored": rescored]
        }
        return checks
    }

    // MARK: - Results and summary

    /// The final list, the console summary and the last messages to the page: the
    /// rescored and held-back matches, then `onGalleryScanComplete`.
    private func finishScan(elapsed: TimeInterval, rate: Double, cloudWaited: TimeInterval) {
        // The streamed order: newest first, iCloud matches after the local pass, then
        // the held-back matches, so nothing on screen moves when the scan ends.
        let heldSet = Set(heldIds)
        let ordered = matchedIds.filter { !heldSet.contains($0) } + matchedIds.filter { heldSet.contains($0) }

        // Capture dates of the final matches, for the scan summary. The scan runs
        // newest first, so "first" is the newest match and "last" the oldest.
        var matchedDates: [Date] = []
        PHAsset.fetchAssets(withLocalIdentifiers: matchedIds, options: nil).enumerateObjects { asset, _, _ in
            if let date = asset.creationDate { matchedDates.append(date) }
        }
        let matchedFirstDate = ViewController.captureDay(matchedDates.max())
        let matchedLastDate = ViewController.captureDay(matchedDates.min())

        let trailEntries = reportTrail()

        DispatchQueue.main.async { [self] in
            guard controller?.scanGeneration == generation else { return }


            let summaryFields = summary(elapsed: elapsed, rate: rate, cloudWaited: cloudWaited,
                                        matchedFirstDate: matchedFirstDate, matchedLastDate: matchedLastDate)

            // Selfies rescored with the shopper's own gaze resting point are sent again
            // with `rescored` so the page takes the new values; then the held-back
            // matches, now that the cut is known (already rescored).
            func storedPayload(_ id: String, _ score: MatchScore, rescored: Bool) -> [String: Any] {
                Self.matchPayload(id: id, type: score.type, isFullBody: ScanAnalysisStore.analysis(for: id)?.body.isHeadToToe ?? true,
                                  distance: score.distance, dupGroup: dupGroups[id] ?? id, rescored: rescored,
                                  done: total + cloudSettled, total: total + cloudQueued, score: score.score, fields: score.breakdown)
            }
            let shownSet = Set(ordered)
            // Rescored by the gaze rest point, the frown line, or both: sent once.
            let rescoredIds = gazeRescored + frownRescored.filter { !gazeRescored.contains($0) }
            for id in rescoredIds where !heldSet.contains(id) && shownSet.contains(id) {
                guard let score = matchScores[id] else { continue }
                controller?.sendToWeb(["type": "onGalleryMatchFound", "payload": storedPayload(id, score, rescored: true)])
            }
            for id in ordered where heldSet.contains(id) {
                guard let score = matchScores[id] else { continue }
                controller?.sendToWeb(["type": "onGalleryMatchFound", "payload": storedPayload(id, score, rescored: false)])
            }

            if ScanReport.url != nil { controller?.scanReport.endOfScan(droppedWhy: droppedWhy(), checks: reportChecks(), trail: trailEntries) }
            controller?.sendToWeb(["type": "onGalleryScanComplete",
                                   "payload": ["assetIds": ordered,
                                               // Matches the page may already show that an
                                               // end-of-scan gate withdrew.
                                               "dropped": gapDropped + eyeDropped + blurDropped,
                                               "limited": controller?.isLimitedAccess ?? false,
                                               // What the scan could not look at, for
                                               // analytics — the page shows none of it.
                                               "skipped": ["inCloud": cloudOnly,
                                                           "cloudSelfies": cloudSelfieCandidates,
                                                           "cloudFullLength": cloudFullCandidates,
                                                           "cloudDownloaded": cloudDownloaded,
                                                           "cloudLeft": cloudLeft,
                                                           "noImage": noImage],
                                               "summary": summaryFields]])
        }
    }

    /// The console summary as numbers, for analytics. Main queue: it reads the controller.
    private func summary(elapsed: TimeInterval, rate: Double, cloudWaited: TimeInterval,
                         matchedFirstDate: String?, matchedLastDate: String?) -> [String: Any] {
        // Counts only: no ids, no images. Built up front because the literal is too large inline.
        var summary: [String: Any] = [:]
        summary["examined"] = examined
        summary["total"] = total
        summary["monthsBack"] = monthsBack
        summary["limited"] = controller?.isLimitedAccess ?? false
        summary["noImage"] = noImage
        summary["skippedShape"] = skippedShape
        summary["earlyNoMatch"] = earlyNoMatch
        summary["stageMs"] = (controller?.stageMs ?? [:]).mapValues { Int($0) }
        summary["localCopies"] = localCopies
        summary["noFace"] = noFace
        summary["group"] = groupSkipped
        summary["sameShopper"] = sameShopper
        summary["otherPeople"] = otherPeople
        summary["faceTooSmall"] = tooSmall
        summary["notFullBody"] = notFullBody
        summary["bodyRetried"] = bodyRetried
        summary["bodyRescued"] = bodyRescued
        summary["noMatch"] = noMatch
        summary["closestNoMatch"] = closestNoMatch
        summary["nearMisses"] = nearMisses
        summary["gapCut"] = gapCut
        summary["weakCut"] = weakCut
        summary["gapDropped"] = gapDropped.count
        summary["ownKept"] = ownKept.count
        summary["gapHeld"] = heldIds.count
        if let rest = libraryRest {
            summary["gazeRestYaw"] = twoPlaces(rest.yaw)
            summary["gazeRestPitch"] = twoPlaces(rest.pitch)
        }
        summary["gazeRescored"] = gazeRescored.count
        summary["frownBaseline"] = frownBaseline
        summary["frownLine"] = frownLine
        summary["frownRescored"] = frownRescored.count
        summary["blurDropped"] = blurDropped.count
        summary["blurBaseline"] = blurBaseline
        summary["sensitive"] = sensitiveSkipped
        summary["unusableFace"] = unusableFace
        // Per-gate counts, the eye gate's baseline and withdrawals, and the
        // cover and focal-length facts — see `selfieGatesV2`.
        if !unusableGates.isEmpty { summary["unusableGates"] = unusableGates }
        summary["eyeDropped"] = eyeDropped.count
        summary["eyeBaseline"] = eyeBaseline
        summary["coverHints"] = coverHints
        summary["focalAssumed"] = focalAssumed
        summary["coverRead"] = coverRead
        if !coverFacts.isEmpty { summary["coverFacts"] = coverFacts }
        summary["duplicates"] = duplicates
        summary["tooLarge"] = tooLargeSkipped
        summary["noOriginal"] = noOriginal
        summary["lowData"] = lowDataSkipped
        summary["matched"] = matchedIds.count
        summary["matchedSelfie"] = found[.selfie, default: 0]
        summary["matchedFront"] = found[.front, default: 0]
        summary["matchedSide"] = found[.side, default: 0]
        summary["matchedThreeQuarter"] = found[.threeQuarter, default: 0]
        // Matched selfies under the eye-spacing floor.
        summary["selfieSmallEyes"] = selfieSmallEyes
        // Matches lowered for a tilted head; originals sized by pixel count because
        // sizing was too slow; how many iCloud downloads run at once.
        summary["tilted"] = tiltedMatches
        summary["sizedByPixels"] = sizedByPixels
        summary["cloudParallel"] = ViewController.cloudOnMobile ? ViewController.cloudParallelMobile : ViewController.cloudParallel
        summary["model"] = ViewController.faceModel.rawValue
        summary["cutoff"] = ViewController.matchThreshold
        summary["frames"] = controller?.lastReferenceFrames ?? 1
        summary["chosenFrame"] = (controller?.lastReferenceIndex ?? 0) + 1
        summary["referenceQuality"] = controller?.lastReferenceQuality
        summary["blendedFrames"] = controller?.lastReferenceBlended ?? 1
        // Per-frame quality (-1 when none was measured), and how the blend sat.
        summary["frameQualities"] = (controller?.lastReferenceQualities ?? []).map { $0 ?? -1 }
        summary["blendSpread"] = controller?.lastReferenceSpread
        summary["blendShift"] = controller?.lastReferenceShift
        summary["elapsedMs"] = Int(elapsed * 1000)
        summary["memoryPeakMB"] = max(memoryPeak, ViewController.residentMB())
        summary["photosPerSecond"] = Int(rate)
        summary["inCloud"] = cloudOnly
        summary["cloudSelfies"] = cloudSelfieCandidates
        summary["cloudFullLength"] = cloudFullCandidates
        summary["cloudOnMobile"] = ViewController.cloudOnMobile
        summary["cloudPreviewOut"] = cloudPreviewOut
        summary["cloudLargerDownloads"] = controller?.cloudLargerDownloads ?? 0
        summary["cloudDownloaded"] = cloudDownloaded
        summary["cloudFailed"] = cloudFailed
        // Why they failed: diskFull (Photos refuses to download on a nearly
        // full phone), timedOut, other. Left out when nothing failed.
        if !cloudFailures.isEmpty { summary["cloudFailures"] = cloudFailures }
        summary["cloudLeft"] = cloudLeft
        summary["cloudWaitMs"] = Int(cloudWaited * 1000)
        // The store — see `ScanStore`: photos counted without a load,
        // iCloud candidates skipped, records written, records held.
        if let store {
            summary["storeDecided"] = storeDecided
            summary["storeCloudSkipped"] = storeCloudSkipped
            summary["storeWritten"] = store.written
            summary["storeRecords"] = store.count
        }
        summary["cloudFirstDownloadedDate"] = cloudFirstDownloaded?.day
        summary["cloudFirstDownloadedAtMs"] = cloudFirstDownloaded?.atMs
        summary["cloudLastDownloadedDate"] = cloudLastDownloaded?.day
        summary["cloudLastDownloadedAtMs"] = cloudLastDownloaded?.atMs
        summary["matchedFirstDate"] = matchedFirstDate
        summary["matchedLastDate"] = matchedLastDate
        return summary
    }
}
