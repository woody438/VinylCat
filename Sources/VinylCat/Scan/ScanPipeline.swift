import CoreGraphics
import Foundation

/// The part of a scan that has nothing to do with the camera: readers → Discogs → rank → save or
/// park. The webcam loop (`ScanController.identify`) and the folder importer (`PhotoImporter`) both
/// run this; what differs is what they do with an answer that needs a person — the loop prompts
/// (label, retry, pick a number, add anyway), the importer parks and moves on. Nothing in here
/// touches the capture engine, the HUD phase, the chimes or the speaker.
extension ScanController {
    /// What the readers and the matcher made of one photo, before anything is saved.
    struct Lookup {
        var outcome: Identifier.Outcome
        var verdict: Matcher.Verdict
        /// Every distinct candidate, best first — what goes into the evidence.
        var ranked: [Candidate]
    }

    /// `partial` is the readers' outcome when Discogs was what failed; nil when the readers themselves did.
    struct LookupError: Error {
        var underlying: Error
        var partial: Identifier.Outcome?
    }

    /// Where one photo ended up.
    enum Resolution {
        /// Saved as a new record, or (`attached`) its photo was added to a photo-less record pulled from Discogs.
        case saved(VinylRecord, Candidate, attached: Bool)
        /// The same release is already catalogued with a photo. Nothing was written.
        case duplicate(existing: VinylRecord, Candidate, Identifier.Outcome)
        /// Several pressings fit. Nothing was written; `close` are the ones to choose between.
        case ambiguous(Identifier.Outcome, close: [Candidate], ranked: [Candidate])
        /// No confident match. Nothing was written.
        case notFound(Identifier.Outcome, ranked: [Candidate])
        /// Something outside the operator's control failed; the photo is in the review queue.
        case parked(VinylRecord, title: String, detail: String)
    }

    /// Readers, then Discogs. Throws `LookupError` so the caller can tell a reader failure from a Discogs one.
    func lookup(image: CGImage, expectLabel: Bool, onStep: @MainActor (String) -> Void) async throws -> Lookup {
        guard let app = appState else { throw LookupError(underlying: CocoaError(.featureUnsupported), partial: nil) }
        var partial: Identifier.Outcome?
        do {
            let outcome = try await app.identifier.identify(image, sessionFormat: app.format.spoken, expectLabel: expectLabel, onStep: onStep)
            partial = outcome
            onStep("searching Discogs")
            // The model's other numbers (matrix, album) go before the OCR tokens: it has seen the print magnified.
            let alternates = (outcome.model?.otherNumbers ?? []) + outcome.local.catalogueCandidates
            let (verdict, ranked) = try await Matcher(discogs: app.discogs).find(reading: outcome.reading, sessionFormat: app.format, catalogueAlternates: alternates)
            return Lookup(outcome: outcome, verdict: verdict, ranked: ranked)
        } catch {
            throw LookupError(underlying: error, partial: partial)
        }
    }

    /// One photo, start to finish, with no one to ask: a confident match is saved, everything that
    /// would need a person comes back undecided, and an error parks the photo so nothing is lost.
    func process(image: CGImage, photo: String, expectLabel: Bool, sessionID: UUID, onStep: @MainActor (String) -> Void) async -> Resolution {
        let look: Lookup
        do { look = try await lookup(image: image, expectLabel: expectLabel, onStep: onStep) } catch let e as LookupError {
            let (title, detail) = describe(e)
            let rec = parkRecord(outcome: e.partial, candidates: [], photo: photo, expectLabel: expectLabel, sessionID: sessionID, error: (title, detail))
            return .parked(rec, title: title, detail: detail)
        } catch {
            let rec = parkRecord(outcome: nil, candidates: [], photo: photo, expectLabel: expectLabel, sessionID: sessionID, error: ("READER ERROR", error.localizedDescription))
            return .parked(rec, title: "READER ERROR", detail: error.localizedDescription)
        }
        switch look.verdict {
        case .match(let c):
            return await commit(candidate: c, outcome: look.outcome, candidates: look.ranked, photo: photo, expectLabel: expectLabel, sessionID: sessionID, allowDuplicate: false)
        case .ambiguous(let close):
            return .ambiguous(look.outcome, close: close, ranked: look.ranked)
        case .none:
            return .notFound(look.outcome, ranked: look.ranked)
        }
    }

    /// A headline and a sentence for a failed lookup, the same words the HUD shows and the queue keeps.
    func describe(_ e: LookupError) -> (title: String, detail: String) {
        let isKey = { if case ReaderError.missingKey = e.underlying { return true } else { return false } }()
        let who = e.partial == nil ? (appState?.identifier.provider.title ?? "The reader") : "Discogs"
        let friendly = FriendlyError.describe(e.underlying, context: who)
        Log.scan.error("identify failed: \(e.underlying) — \(friendly)")
        return (isKey ? "SETUP NEEDED" : e.partial == nil ? "READER ERROR" : "DISCOGS ERROR", friendly)
    }

    /// Save a confirmed release. Comes back `.duplicate` (nothing written) when the release is already
    /// catalogued with a photo, `.saved(attached: true)` when the only copy is photo-less — pulled from
    /// the Discogs collection, never photographed — and this photo becomes its photo. A failed release
    /// fetch parks the photo with what is known. Price and collection sync run in the background.
    func commit(candidate c: Candidate, outcome: Identifier.Outcome, candidates: [Candidate], photo: String, expectLabel: Bool, sessionID: UUID, allowDuplicate: Bool) async -> Resolution {
        guard let app = appState else { return .notFound(outcome, ranked: candidates) }
        let kind: ShotKind = (outcome.reading.isLabelShot ?? false) || expectLabel ? .labelA : .coverFront
        if !allowDuplicate, var dup = store.existing(discogsReleaseID: c.result.id) {
            guard dup.photos.isEmpty else { return .duplicate(existing: dup, c, outcome) }
            dup.photos = [ScanPhoto(recordID: dup.id, fileName: photo, kind: kind, order: 0)]
            dup.readText = outcome.local.text
            dup.confidence = c.score
            store.update(dup)
            store.saveEvidence(Self.evidence(for: dup, outcome: outcome, candidates: candidates, chosen: c))
            enrich(dup.id)
            return .saved(dup, c, attached: true)
        }
        do {
            let release = try await app.discogs.release(c.result.id)
            var rec = Self.record(from: release, sessionID: sessionID)
            rec.confidence = c.score
            rec.barcode = outcome.reading.barcode
            rec.readText = outcome.local.text
            rec.photos = [ScanPhoto(recordID: rec.id, fileName: photo, kind: kind, order: 0)]
            rec.sync = syncToCollection && (CollectionSync.enabledByUser) ? .pending : .off
            store.insert(rec)
            store.saveEvidence(Self.evidence(for: rec, outcome: outcome, candidates: candidates, chosen: c))
            enrich(rec.id)
            return .saved(rec, c, attached: false)
        } catch {
            // The release lookup failed after a good match: park the photo with what we know so it
            // can be finished from Review once Discogs is back.
            let friendly = FriendlyError.describe(error, context: "Discogs")
            Log.scan.error("release r\(c.result.id) failed: \(error) — \(friendly)")
            let rec = parkRecord(outcome: outcome, candidates: candidates, photo: photo, expectLabel: expectLabel, sessionID: sessionID, error: ("DISCOGS ERROR", friendly))
            return .parked(rec, title: "DISCOGS ERROR", detail: friendly)
        }
    }

    /// Into the review queue, with everything the readers saw saved as evidence so the fix made
    /// there can be compared with it later. `outcome` is nil only when the readers themselves failed.
    @discardableResult
    func parkRecord(outcome: Identifier.Outcome?, candidates: [Candidate], photo: String, expectLabel: Bool, sessionID: UUID, error: (title: String, detail: String)? = nil) -> VinylRecord {
        let reading = outcome?.reading ?? SleeveReading()
        var rec = VinylRecord(artist: reading.artist ?? "", title: reading.title ?? "", format: appState?.format.discogsFormat ?? "LP", sessionID: sessionID)
        rec.status = .needsReview
        rec.label = reading.label
        rec.catalogNumber = reading.catalogNumber
        rec.barcode = reading.barcode
        rec.year = reading.year
        rec.readText = outcome?.local.text ?? ""
        if let error { rec.notes = "Scan error: \(error.detail)" }
        rec.photos = [ScanPhoto(recordID: rec.id, fileName: photo, kind: (reading.isLabelShot ?? false) || expectLabel ? .labelA : .coverFront, order: 0)]
        store.insert(rec)
        if let outcome {
            var e = ScanEvidence(recordID: rec.id, mergedReading: outcome.reading)
            e.provider = outcome.provider; e.ocrLines = outcome.local.lines; e.barcodes = outcome.local.barcodes
            e.catalogueCandidates = outcome.local.catalogueCandidates; e.modelReading = outcome.model
            e.candidates = candidates.prefix(12).map {
                .init(releaseID: $0.result.id, title: $0.result.title, label: $0.result.label?.first, catno: $0.result.catno,
                      year: $0.result.year, country: $0.result.country, score: $0.score, reasons: $0.reasons)
            }
            store.saveEvidence(e)
        }
        appState?.reviewCount = store.reviewCount()
        return rec
    }
}
