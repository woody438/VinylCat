import CoreGraphics
import Foundation
import Observation

/// What the HUD shows. Mirrors the mockup states one-to-one.
enum ScanPhase: Equatable {
    case learning
    case paused
    case armed(reason: String)
    case steady(progress: Double)
    case captured
    case reading(step: String)
    case searching
    case matched(title: String, detail: String, meta: String)
    case ambiguous(candidates: [ScanChoice])
    case needLabel(guess: String)
    case retry(guess: String, detail: String)
    case awaitingShot(kind: String, index: Int, total: Int, header: String)
    case notFound(guess: String, detail: String)
    case duplicate(title: String)
    /// Something outside the operator's control failed (model, Discogs, network). The photo is
    /// parked in the review queue so nothing is lost; `detail` says what went wrong in plain words.
    case error(title: String, detail: String)
}

/// One row of the "N MATCHES" list: who/what it is, then the pressing details that tell the rows apart.
struct ScanChoice: Equatable, Sendable {
    var title: String
    var detail: String
}

struct SessionItem: Identifiable, Sendable {
    let id = UUID()
    var recordID: UUID?
    var thumbnail: CGImage?
    var title: String
    var meta: String
    var tone: Tone
    var verdict: Verdict?
    enum Tone: Sendable { case normal, review, rejected }
}

/// Drives the whole scan loop: capture → identify → match → extra shots → save, plus voice commands.
@MainActor
@Observable
final class ScanController {
    private(set) var phase: ScanPhase = .learning { didSet { if phase != oldValue { Log.scan.info("phase \(String(describing: self.phase).prefix(160))") } } }
    private(set) var signal: CaptureSignal?
    private(set) var items: [SessionItem] = []
    private(set) var lastStill: CGImage?
    private(set) var lastCandidates: [Candidate] = []
    private(set) var lastOutcome: Identifier.Outcome?
    /// Record currently being photographed (after a match) and the shots still wanted.
    private(set) var current: VinylRecord?
    private(set) var pending: [ShotKind] = []
    let sessionID = UUID()
    var recordNumber: Int { items.count + 1 }

    let engine = CaptureEngine()
    let speaker = Speaker()
    weak var appState: AppState?

    let store: Store
    let photos: PhotoStore
    private var tasks: [Task<Void, Never>] = []
    /// Price + collection writes in flight (one token per call, so two for the same record can coexist):
    /// a headless import waits for them before exiting.
    private var enrichTasks: [UUID: Task<Void, Never>] = [:]

    init(store: Store = .shared, photos: PhotoStore = .shared) {
        self.store = store
        self.photos = photos
    }

    /// Test hook: feed a still as if the camera engine produced it.
    func inject(still: CapturedStill) async { await handle(still: still) }
    private var shotCounter = 0
    private var expectLabel = false
    /// Test harnesses (`--scenario`) turn this off: they run against the real Discogs token, and
    /// every rebuild was adding the fixture records to Woody's collection.
    var syncToCollection = true
    /// One re-shoot is offered before a record goes to the review queue (a blurry frame or a
    /// half-read catalogue number usually clears on the second look).
    private var retried = false
    private var manualKind: ShotKind?
    private var ambiguity: (outcome: Identifier.Outcome, candidates: [Candidate], photo: String, thumb: CGImage?)?
    private var lastCaptured: (photo: String, thumb: CGImage?)?
    /// The record most recently closed — "flip" / "back cover" / "add photo" reopen it for an extra shot.
    private var lastClosedRecordID: UUID?
    private var duplicate: (candidate: Candidate, outcome: Identifier.Outcome, photo: String, thumb: CGImage?)?

    // MARK: - Lifecycle

    func start(camera: CameraSession) {
        guard tasks.isEmpty else { return }
        let engine = self.engine
        applyTuning()
        tasks.append(Task { await engine.run(frames: camera.frames) })
        tasks.append(Task { [weak self] in for await s in engine.signals { self?.apply(signal: s) } })
        tasks.append(Task { [weak self] in for await still in engine.stills { await self?.handle(still: still) } })
    }

    func setAuto(_ on: Bool) {
        Task { await engine.setEnabled(on) }
        if !on { phase = .paused }
    }

    func forceCapture() { Task { await engine.forceCapture() } }
    func setAutoCapture(_ on: Bool) { Task { await engine.setAutoCapture(on) } }
    /// Camera diagnostics: log what the next frames look like and keep one as a JPEG.
    func debugFrame() async -> Int { await engine.saveDebugFrame() }

    /// Reads the capture tunables from UserDefaults (Settings sliders) and pushes them to the engine.
    func applyTuning() {
        let t = CaptureTuning.fromDefaults()
        Task { await engine.setTuning(t) }
    }
    func relearnBaseline() { Task { await engine.relearnBaseline() } }

    private var lastReason = ""
    /// When the signal first stopped saying "steady" — used to hold the banner briefly.
    private var notSteadySince: Date?
    private func apply(signal s: CaptureSignal) {
        if s.reason != lastReason {
            lastReason = s.reason
            Log.capture.debug("\(s.reason) sharp \(Int(s.metrics.sharpness)) motion \(String(format: "%.1f", s.metrics.motion)) scene \(Int(s.metrics.sceneDelta))")
        }
        signal = s
        switch phase {
        case .learning, .paused, .armed, .steady, .captured: break
        case .reading, .searching: return
        case .awaitingShot, .needLabel, .retry, .ambiguous:
            // Keep the prompt on screen; the ring shows steadiness via `signal`.
            return
        default:
            if s.armed { break } else { return }
        }
        switch s.reason {
        case "learning": phase = .learning
        case "paused": phase = .paused
        case "steady", "ready — say capture":
            notSteadySince = nil
            phase = .steady(progress: s.steadyProgress)
        case "captured": notSteadySince = nil; phase = .captured
        default:
            // Don't drop the STEADY banner the instant one frame disqualifies: the engine's ring
            // already shows the hold slipping, and flipping the headline back and forth is what
            // made lining a record up feel frantic.
            if case .steady = phase {
                let since = notSteadySince ?? Date()
                notSteadySince = since
                if Date().timeIntervalSince(since) < 0.4 { return }
            }
            notSteadySince = nil
            phase = .armed(reason: s.reason)
        }
    }

    // MARK: - Capture handling

    private func handle(still: CapturedStill) async {
        lastStill = still.image
        Log.scan.info("captured \(still.forced ? "forced" : "auto") sharp \(Int(still.metrics.sharpness)) scene \(Int(still.metrics.sceneDelta))")
        Chime.captured.play()
        shotCounter += 1
        let stamp = Self.stamp.string(from: Date())
        let name = "\(stamp)-\(String(format: "%03d", shotCounter))"
        let thumb = photos.downscale(still.image, maxSide: 160)
        let fileName: String
        do { fileName = try photos.save(still.image, name: name).lastPathComponent } catch {
            speaker.say("Couldn't save the photo"); return
        }

        // Extra shot for the record we just matched?
        if var rec = current, let kind = manualKind ?? pending.first {
            manualKind = nil
            pending.removeAll { $0 == kind }
            rec.photos.append(ScanPhoto(recordID: rec.id, fileName: fileName, kind: kind, discNumber: [.labelC, .labelD].contains(kind) ? 2 : 1, order: rec.photos.count))
            store.update(rec)
            current = rec
            nextPrompt()
            return
        }

        lastCaptured = (fileName, thumb)
        await identify(still: still, fileName: fileName, thumb: thumb)
    }

    private func identify(still: CapturedStill, fileName: String, thumb: CGImage?) async {
        guard appState != nil else { return }
        await engine.setHold(false)
        phase = .reading(step: "starting")
        do {
            let look = try await lookup(image: still.image, expectLabel: expectLabel) { [weak self] step in
                self?.phase = step == "searching Discogs" ? .searching : .reading(step: step)
            }
            let outcome = look.outcome
            lastOutcome = outcome
            lastCandidates = look.ranked
            // Second look at the same record (e.g. flipped to the B-side while ambiguous)? Keep what both shots agree on.
            if let amb = ambiguity {
                let previous = Set(amb.candidates.map(\.id))
                let agreed = look.ranked.filter { previous.contains($0.id) }
                if agreed.count == 1, let only = agreed.first {
                    ambiguity = nil
                    await finalize(candidate: only, outcome: outcome, photo: fileName, thumb: thumb, allowDuplicate: false)
                    if var rec = current { rec.photos.append(ScanPhoto(recordID: rec.id, fileName: amb.photo, kind: .labelA, order: 0)); rec.photos[rec.photos.count - 2].kind = .labelB; store.update(rec); current = rec }
                    return
                }
            }
            switch look.verdict {
            case .match(let c):
                await finalize(candidate: c, outcome: outcome, photo: fileName, thumb: thumb, allowDuplicate: false)
            case .ambiguous(let cands):
                ambiguity = (outcome, cands, fileName, thumb)
                phase = .ambiguous(candidates: cands.map { ScanChoice(title: $0.headline, detail: $0.summary) })
                // Nothing else gets scanned until this is answered: the list used to vanish the
                // moment the next frame armed, taking the shot with it.
                await engine.setHold(true)
                Chime.ambiguous.play()
                speaker.say("\(cands.count) possible matches on screen. Pick a number, or say none.")
            case .none:
                let guess = [outcome.reading.artist, outcome.reading.title].compactMap { $0 }.joined(separator: " — ")
                let unreadable = outcome.local.lines.isEmpty && outcome.local.barcodes.isEmpty
                if (!(outcome.reading.isLabelShot ?? false) || unreadable), !expectLabel {
                    expectLabel = true
                    phase = .needLabel(guess: unreadable ? "NOTHING READABLE" : (guess.isEmpty ? "?" : guess.uppercased() + "?"))
                    Chime.needShot.play()
                    speaker.say(unreadable ? "I can't read that. Show me the label, closer." : "No confident match. Show me the label.")
                    await engine.setMode(.shot)
                } else if !retried {
                    retried = true
                    phase = .retry(guess: guess.isEmpty ? "NO MATCH YET" : guess.uppercased() + "?", detail: outcome.readSummary)
                    Chime.needShot.play()
                    speaker.say("Still no match. One more try — hold it steady and a bit closer.")
                    await engine.rearm()
                    await engine.setMode(.shot)
                } else {
                    park(outcome: outcome, photo: fileName, thumb: thumb, guess: guess)
                }
            }
        } catch let e as LookupError {
            // Reader errors are absorbed upstream (OCR-only fallback), so what lands here is Discogs
            // or the network. Say what broke, in words, and park the photo so the scan isn't lost.
            let (title, detail) = describe(e)
            park(outcome: e.partial, photo: fileName, thumb: thumb, guess: e.partial.map { [$0.reading.artist, $0.reading.title].compactMap { $0 }.joined(separator: " — ") } ?? "",
                 error: (title, detail))
        } catch {
            park(outcome: nil, photo: fileName, thumb: thumb, guess: "", error: ("READER ERROR", error.localizedDescription))
        }
        trimItems()
    }

    /// Save a record for a confirmed Discogs release (the shared `commit`), then tell the operator.
    private func finalize(candidate c: Candidate, outcome: Identifier.Outcome, photo: String, thumb: CGImage?, allowDuplicate: Bool) async {
        await engine.setHold(false)
        phase = .searching
        let wasLabel = expectLabel
        switch await commit(candidate: c, outcome: outcome, candidates: lastCandidates, photo: photo, expectLabel: wasLabel, sessionID: sessionID, allowDuplicate: allowDuplicate) {
        case .saved(let rec, let c, attached: true):
            // Pulled from the Discogs collection, never photographed: this scan *is* its photo.
            lastClosedRecordID = rec.id
            expectLabel = false; retried = false
            phase = .matched(title: rec.displayTitle.uppercased(), detail: "already in your Discogs collection · photo added", meta: String(format: "%.2f · r%d", c.score, c.result.id))
            Chime.matched.play()
            items.insert(SessionItem(recordID: rec.id, thumbnail: thumb, title: rec.displayTitle, meta: "in Discogs already · photo added", tone: .normal), at: 0)
            speaker.say("\(rec.artist), \(rec.title). Already in your collection, photo added.")
            finishRecord(announce: false)
        case .saved(let rec, let c, attached: false):
            current = rec
            pending = []
            expectLabel = false
            retried = false
            let detail = [rec.year.map(String.init), rec.discCount > 1 ? "\(rec.discCount)×\(rec.format)" : rec.format,
                          rec.label.map { "\($0.uppercased()) \(rec.catalogNumber ?? "")" }, rec.country?.uppercased()].compactMap { $0 }.joined(separator: " · ")
            phase = .matched(title: rec.displayTitle.uppercased(), detail: detail, meta: String(format: "%.2f · r%d · %@", c.score, c.result.id, c.reasons.joined(separator: " ")))
            Chime.matched.play()
            items.insert(SessionItem(recordID: rec.id, thumbnail: thumb, title: rec.displayTitle, meta: detail, tone: .normal), at: 0)
            var line = "\(rec.artist), \(rec.title)"
            if let y = rec.year { line += ", \(y)" }
            line += ", \(Self.spoken(format: rec.format, discs: rec.discCount))."
            speaker.say(line)
            finishRecord(announce: false)
        case .duplicate(let dup, let c, let outcome):
            duplicate = (c, outcome, photo, thumb)
            phase = .duplicate(title: dup.displayTitle.uppercased())
            Chime.duplicate.play()
            speaker.say("Already catalogued: \(dup.artist), \(dup.title). Say add anyway to keep a second copy.")
            expectLabel = false
            await engine.setMode(.identify)
        case .parked(let rec, let title, let detail):
            expectLabel = false; retried = false
            announceParked(rec, thumb: thumb, guess: c.headline, outcome: outcome, error: (title, detail))
        case .ambiguous, .notFound:
            break   // `commit` never returns these
        }
    }

    private func showPrompt() {
        guard let rec = current, let kind = pending.first else { return }
        let taken = rec.photos.count
        phase = .awaitingShot(kind: kind.hud, index: taken + 1, total: taken + pending.count, header: "\(rec.displayTitle) · \(rec.format)")
    }

    private func nextPrompt() {
        guard current != nil else { return }
        if pending.isEmpty { finishRecord(announce: true); return }
        Chime.needShot.play()
        speaker.say(pending[0].prompt)
        showPrompt()
        Task { await engine.setMode(.shot) }
    }

    private func finishRecord(announce: Bool) {
        if let rec = current, let idx = items.firstIndex(where: { $0.recordID == rec.id }), rec.photos.count > 1 {
            items[idx].meta += " · \(rec.photos.count) shots"
        }
        if announce { Chime.matched.play(); speaker.say("Done. Next record.") }
        retried = false
        lastClosedRecordID = current?.id
        current = nil; pending = []; manualKind = nil
        phase = .armed(reason: "next record")
        Task { await engine.setMode(.identify) }
    }

    /// Into the review queue (the shared `parkRecord`), then tell the operator.
    private func park(outcome: Identifier.Outcome?, photo: String, thumb: CGImage?, guess: String, error: (title: String, detail: String)? = nil) {
        guard appState != nil else { return }
        let rec = parkRecord(outcome: outcome, candidates: lastCandidates, photo: photo, expectLabel: expectLabel, sessionID: sessionID, error: error)
        expectLabel = false
        retried = false
        announceParked(rec, thumb: thumb, guess: guess, outcome: outcome, error: error)
    }

    /// The HUD, chime, speech and session row for a parked photo, and the engine back to scanning.
    private func announceParked(_ rec: VinylRecord, thumb: CGImage?, guess: String, outcome: Identifier.Outcome?, error: (title: String, detail: String)?) {
        let shown = guess.isEmpty ? "Unknown" : guess
        if let error {
            phase = .error(title: error.title, detail: error.detail)
            Chime.notFound.play()
            speaker.say("\(error.title.capitalized). \(error.detail). The photo is in the review queue.")
            items.insert(SessionItem(recordID: rec.id, thumbnail: thumb, title: shown, meta: "error · REVIEW QUEUE", tone: .review), at: 0)
        } else {
            phase = .notFound(guess: guess.isEmpty ? "UNKNOWN" : guess.uppercased() + "?", detail: outcome?.readSummary ?? "")
            Chime.notFound.play()
            speaker.say("Not found. Added to the review queue.")
            items.insert(SessionItem(recordID: rec.id, thumbnail: thumb, title: shown, meta: "REVIEW QUEUE", tone: .review), at: 0)
        }
        Task { await engine.setHold(false); await engine.setMode(.identify) }
    }

    private func trimItems() { if items.count > 12 { items.removeLast(items.count - 12) } }

    // MARK: - Background enrichment (price + Discogs collection)

    func enrich(_ id: UUID) {
        guard let app = appState else { return }
        let token = UUID()
        enrichTasks[token] = Task { [weak self] in
            defer { self?.enrichTasks[token] = nil }
            guard let self, var rec = store.fetch(id), let rid = rec.discogsReleaseID else { return }
            if let stats = try? await app.discogs.priceStats(rid) {
                rec.valueLow = stats.lowest_price?.value
                rec.numForSale = stats.num_for_sale
                rec.currency = stats.lowest_price?.currency ?? app.discogs.currency
                rec.valuedAt = Date()
            }
            if rec.sync == .pending {
                let user = UserDefaults.standard.string(forKey: "discogsUsername") ?? ""
                if user.isEmpty, let me = try? await app.discogs.identity() { UserDefaults.standard.set(me.username, forKey: "discogsUsername") }
                let u = UserDefaults.standard.string(forKey: "discogsUsername") ?? ""
                if !u.isEmpty, let inst = try? await app.discogs.addToCollection(releaseID: rid, username: u) {
                    rec.discogsInstanceID = inst; rec.sync = .synced
                } else { rec.sync = .failed }
            }
            guard let fresh = store.fetch(id) else { return }            // deleted meanwhile
            rec.photos = fresh.photos                                       // photos may have arrived meanwhile
            if fresh.status == .rejected {                                  // thumbed down while we were adding it
                rec.status = .rejected; rec.verified = false
                await unsync(&rec)
            }
            store.update(rec)
            if current?.id == id { current = rec }
        }
    }

    /// Waits for every price/collection write started by `enrich`. A headless import calls this before exiting.
    func awaitEnrichment() async {
        while let t = enrichTasks.values.first { await t.value }
    }

    // MARK: - Verdicts

    /// Thumbs up / down on a saved match. Down keeps the record (photos, OCR, candidates) as a
    /// rejected example for tuning, pulls it from the Discogs collection, closes it if open, and
    /// puts it in the review queue so the right release can be picked.
    func verdict(_ id: UUID, _ v: Verdict) {
        guard var rec = store.fetch(id) else { speaker.say("Nothing to mark"); return }
        store.logFeedback(id, v)
        if let i = items.firstIndex(where: { $0.recordID == id }) { items[i].verdict = v }
        switch v {
        case .fixed: break
        case .up:
            rec.verified = true
            if rec.status == .rejected { rec.status = .matched; if rec.sync == .off, syncToCollection, UserDefaults.standard.object(forKey: "discogsSync") as? Bool ?? true { rec.sync = .pending } }
            store.update(rec)
            if let i = items.firstIndex(where: { $0.recordID == id }) { items[i].tone = .normal }
            if current?.id == id { current = rec }
            if rec.sync == .pending { enrich(id) }
            speaker.say("Marked correct")
        case .down:
            rec.status = .rejected; rec.verified = false
            store.update(rec)                                    // status lands first so an in-flight enrich sees it
            if let i = items.firstIndex(where: { $0.recordID == id }) { items[i].tone = .rejected; items[i].meta = "wrong record · REVIEW QUEUE" }
            if current?.id == id {
                current = nil; pending = []; manualKind = nil
                phase = .armed(reason: "wrong record")
                Task { await engine.setHold(false); await engine.rearm(); await engine.setMode(.identify) }
            }
            if lastClosedRecordID == id { lastClosedRecordID = nil }
            speaker.say("Wrong record. Sent to the review queue.")
            Task {
                var r = rec
                await unsync(&r)
                // Never write the stale copy back: a thumbs-up or a delete may have landed meanwhile,
                // and a resurrected `rejected` row would sit in the review queue as a ghost.
                guard var fresh = store.fetch(id) else { return }
                fresh.sync = r.sync; fresh.discogsInstanceID = r.discogsInstanceID
                if fresh.status != .rejected, fresh.sync == .off, syncToCollection, UserDefaults.standard.object(forKey: "discogsSync") as? Bool ?? true {
                    fresh.sync = .pending                                // restored while we were removing it: put it back
                }
                store.update(fresh)
                if fresh.sync == .pending { enrich(id) }
            }
        }
        appState?.reviewCount = store.reviewCount()
    }

    /// "Wrong record" by voice: the open record, else the newest one in this session that isn't already rejected.
    func rejectLatest() {
        let target = current?.id ?? items.first(where: { $0.recordID != nil && $0.verdict != .down })?.recordID
        guard let target else { speaker.say("Nothing to reject"); return }
        verdict(target, .down)
    }

    /// Takes a record out of the Discogs collection if it was added. Sync ends up `.off` either way
    /// (or `.failed` if Discogs said no, so the Library shows it still needs doing).
    func unsync(_ rec: inout VinylRecord) async {
        defer { rec.discogsInstanceID = nil }
        guard let app = appState, let rid = rec.discogsReleaseID, let inst = rec.discogsInstanceID else { rec.sync = .off; return }
        let u = UserDefaults.standard.string(forKey: "discogsUsername") ?? ""
        guard !u.isEmpty else { rec.sync = .failed; return }
        do { try await app.discogs.removeFromCollection(releaseID: rid, instanceID: inst, username: u); rec.sync = .off }
        catch { Log.discogs.error("remove r\(rid) instance \(inst) failed: \(error.localizedDescription)"); rec.sync = .failed; rec.discogsInstanceID = inst }
    }

    /// Library delete: pull it from Discogs first, then drop the row and its photos.
    func delete(_ id: UUID) async {
        if var rec = store.fetch(id), rec.discogsInstanceID != nil { await unsync(&rec) }
        store.delete(id)
        items.removeAll { $0.recordID == id }
        if current?.id == id { current = nil; pending = [] }
        if lastClosedRecordID == id { lastClosedRecordID = nil }
        appState?.reviewCount = store.reviewCount()
    }

    static func evidence(for rec: VinylRecord, outcome: Identifier.Outcome, candidates: [Candidate], chosen: Candidate) -> ScanEvidence {
        var e = ScanEvidence(recordID: rec.id, mergedReading: outcome.reading)
        e.provider = outcome.provider
        e.ocrLines = outcome.local.lines
        e.barcodes = outcome.local.barcodes
        e.catalogueCandidates = outcome.local.catalogueCandidates
        e.modelReading = outcome.model
        e.candidates = candidates.prefix(12).map {
            .init(releaseID: $0.result.id, title: $0.result.title, label: $0.result.label?.first, catno: $0.result.catno,
                  year: $0.result.year, country: $0.result.country, score: $0.score, reasons: $0.reasons)
        }
        e.chosenReleaseID = chosen.result.id
        return e
    }

    // MARK: - Voice commands

    func handle(command: VoiceCommand) {
        guard let app = appState else { return }
        switch command {
        case .capture: forceCapture()
        case .flip: manualShot(.labelB, say: "OK, show me the B-side")
        case .label:
            if current != nil { manualShot(.labelA, say: "Show me the label") }
            else { expectLabel = true; speaker.say("Show me the label"); Task { await engine.setMode(.shot) } }
        case .backCover: manualShot(.coverBack, say: "Show me the back cover")
        case .gatefold: manualShot(.gatefold, say: "Show me the gatefold")
        case .discTwo:
            guard current != nil else { speaker.say("No record open"); return }
            for k in [ShotKind.labelC, .labelD] where !pending.contains(k) && !(current?.takenKinds.contains(k) ?? false) { pending.append(k) }
            nextPrompt()
        case .addPhoto: manualShot(.other, say: "Show me the extra photo")
        case .skip:
            if !pending.isEmpty { pending.removeFirst(); nextPrompt() }
            else if isAwaitingRetry, let o = lastOutcome, let f = lastPhotoName { park(outcome: o, photo: f, thumb: lastThumb, guess: [o.reading.artist, o.reading.title].compactMap { $0 }.joined(separator: " — ")) }
            else { speaker.say("Nothing to skip") }
        case .done:
            if current != nil { pending = []; finishRecord(announce: true) } else { speaker.say("Nothing open") }
        case .undo:
            if var rec = current, rec.photos.count > 1, let last = rec.sortedPhotos.last {
                store.deletePhoto(last.id); rec.photos.removeAll { $0.id == last.id }; current = rec
                pending.insert(last.kind, at: 0); speaker.say("Retake \(last.kind.title)"); showPrompt()
            } else if let rec = current {
                // `delete` also pulls it from the Discogs collection — "undo" must not leave a ghost there.
                current = nil; pending = []
                speaker.say("Deleted"); phase = .armed(reason: "deleted")
                Task { await delete(rec.id); await engine.rearm(); await engine.setMode(.identify) }
            } else if let id = lastClosedRecordID, var rec = store.fetch(id), rec.photos.count > 1, let last = rec.sortedPhotos.last {
                // The record closed on its own after an extra shot ("back cover", P): undo steps back
                // that shot first; only the next undo takes the record.
                store.deletePhoto(last.id); rec.photos.removeAll { $0.id == last.id }
                speaker.say("Removed the \(last.kind.title.lowercased())")
            } else if let first = items.first, let rid = first.recordID {
                speaker.say("Deleted \(first.title)")
                Task { await delete(rid) }
            } else { speaker.say("Nothing to undo") }
        case .review:
            if let amb = ambiguity { ambiguity = nil; park(outcome: amb.outcome, photo: amb.photo, thumb: amb.thumb, guess: amb.outcome.reading.title ?? "") }
            else if var rec = current { rec.status = .needsReview; store.update(rec); current = rec; finishRecord(announce: false); speaker.say("Parked for review"); app.reviewCount = store.reviewCount() }
            else if let o = lastOutcome, let f = lastPhotoName { park(outcome: o, photo: f, thumb: lastThumb, guess: o.reading.title ?? "") }
            else { speaker.say("Nothing to park") }
        case .again:
            expectLabel = false; retried = false; ambiguity = nil
            speaker.say("Go again"); phase = .armed(reason: "again")
            Task { await engine.setHold(false); await engine.rearm(); await engine.setMode(.identify) }
        case .one, .two, .three, .four, .five, .six, .seven, .eight, .nine:
            choose([VoiceCommand.one, .two, .three, .four, .five, .six, .seven, .eight, .nine].firstIndex(of: command) ?? 0)
        case .none:
            guard let amb = ambiguity else { speaker.say("Nothing to choose"); return }
            ambiguity = nil
            park(outcome: amb.outcome, photo: amb.photo, thumb: amb.thumb, guess: amb.outcome.reading.title ?? "")
        case .addAnyway:
            guard let d = duplicate else { speaker.say("Nothing to add"); return }
            duplicate = nil
            Task { await finalize(candidate: d.candidate, outcome: d.outcome, photo: d.photo, thumb: d.thumb, allowDuplicate: true) }
        case .sevens: app.format = .seven; speaker.say("Seven inch singles")
        case .twelves: app.format = .twelve; speaker.say("Twelve inch singles")
        case .albums: app.format = .lp; speaker.say("Albums")
        case .pause: app.autoMode = false; setAuto(false); speaker.say("Paused")
        case .resume: app.autoMode = true; setAuto(true); phase = .armed(reason: "resumed"); speaker.say("Ready")
        case .autoMode: app.autoCapture = true; speaker.say("Auto capture on")
        case .manualMode: app.autoCapture = false; speaker.say("Manual. Say capture or press space")
        case .wrong: rejectLatest()
        case .yes, .no: break
        }
    }

    /// Pick one of the candidates on screen — from the number keys or from "one"/"two"/"three".
    func choose(_ index: Int) {
        guard let amb = ambiguity, index < amb.candidates.count else { speaker.say("Nothing to choose"); return }
        ambiguity = nil
        Task { await finalize(candidate: amb.candidates[index], outcome: amb.outcome, photo: amb.photo, thumb: amb.thumb, allowDuplicate: false) }
    }

    /// True while the HUD is asking for another look at the same record (label prompt or retry).
    private var isAwaitingRetry: Bool {
        switch phase { case .needLabel, .retry: true; default: false }
    }

    private func manualShot(_ kind: ShotKind, say: String) {
        if ambiguity != nil {
            speaker.say(say)
            Task { await engine.setHold(false); await engine.setMode(.shot) }
            return
        }
        if current == nil, let id = lastClosedRecordID, let rec = store.fetch(id) { current = rec; pending = [] }
        guard current != nil else {
            if kind == .labelB || kind == .labelA { expectLabel = true; speaker.say("Show me the label"); Task { await engine.setMode(.shot) } }
            else { speaker.say("No record open") }
            return
        }
        manualKind = kind
        pending.removeAll { $0 == kind }
        speaker.say(say)
        phase = .awaitingShot(kind: kind.hud, index: (current?.photos.count ?? 0) + 1, total: (current?.photos.count ?? 0) + 1 + pending.count, header: current?.displayTitle ?? "")
        Task { await engine.setMode(.shot) }
    }

    private var lastPhotoName: String? { ambiguity?.photo ?? duplicate?.photo ?? lastCaptured?.photo }
    private var lastThumb: CGImage? { ambiguity?.thumb ?? duplicate?.thumb ?? lastCaptured?.thumb }

    // MARK: - Helpers

    static func record(from r: DiscogsClient.Release, sessionID: UUID) -> VinylRecord {
        let fmt = r.formats?.first
        let descs = fmt?.descriptions ?? []
        let format = descs.first(where: { ["7\"", "10\"", "12\"", "LP"].contains($0) }) ?? (fmt?.name == "Vinyl" ? "LP" : fmt?.name ?? "LP")
        var rec = VinylRecord(artist: r.artistLine, title: r.title, format: format, sessionID: sessionID)
        rec.discogsReleaseID = r.id
        rec.discogsMasterID = r.master_id
        rec.discogsURI = r.uri.map { $0.hasPrefix("http") ? $0 : "https://www.discogs.com\($0)" }
        rec.label = r.labels?.first?.name.replacingOccurrences(of: #" \(\d+\)$"#, with: "", options: .regularExpression)
        rec.catalogNumber = r.labels?.first?.catno
        rec.formatDescriptors = descs
        rec.discCount = Int(fmt?.qty ?? "1") ?? 1
        rec.year = r.year == 0 ? nil : r.year
        rec.country = r.country
        rec.genres = r.genres ?? []
        rec.styles = r.styles ?? []
        rec.tracks = (r.tracklist ?? []).map { Track(position: $0.position, title: $0.title, duration: $0.duration) }
        rec.coverArtURL = r.images?.first(where: { $0.type == "primary" })?.uri ?? r.images?.first?.uri
        rec.valueLow = r.lowest_price
        rec.numForSale = r.num_for_sale
        return rec
    }

    static func spoken(format: String, discs: Int) -> String {
        let base = switch format { case "7\"": "seven inch"; case "10\"": "ten inch"; case "12\"": "twelve inch"; default: "album" }
        return discs > 1 ? "double \(base)" : base
    }

    private static let stamp: DateFormatter = {
        let f = DateFormatter(); f.dateFormat = "yyyyMMdd-HHmmss"; return f
    }()
}
