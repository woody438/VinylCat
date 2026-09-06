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
    case ambiguous(candidates: [String])
    case needLabel(guess: String)
    case awaitingShot(kind: String, index: Int, total: Int, header: String)
    case notFound(guess: String, detail: String)
    case duplicate(title: String)
}

struct SessionItem: Identifiable, Sendable {
    let id = UUID()
    var recordID: UUID?
    var thumbnail: CGImage?
    var title: String
    var meta: String
    var tone: Tone
    enum Tone: Sendable { case normal, review, incomplete }
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

    private let store: Store
    private let photos: PhotoStore
    private var tasks: [Task<Void, Never>] = []

    init(store: Store = .shared, photos: PhotoStore = .shared) {
        self.store = store
        self.photos = photos
    }

    /// Test hook: feed a still as if the camera engine produced it.
    func inject(still: CapturedStill) async { await handle(still: still) }
    private var shotCounter = 0
    private var expectLabel = false
    private var manualKind: ShotKind?
    private var ambiguity: (outcome: Identifier.Outcome, candidates: [Candidate], photo: String, thumb: CGImage?)?
    private var lastCaptured: (photo: String, thumb: CGImage?)?
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

    /// Reads the capture tunables from UserDefaults (Settings sliders) and pushes them to the engine.
    func applyTuning() {
        var t = CaptureTuning()
        let d = UserDefaults.standard
        if let v = d.object(forKey: "sharpnessMin") as? Double { t.sharpnessMin = v }
        if let v = d.object(forKey: "steadySeconds") as? Double { t.steadySeconds = v }
        if let v = d.object(forKey: "sceneDeltaMin") as? Double { t.sceneDeltaMin = v }
        Task { await engine.setTuning(t) }
    }
    func relearnBaseline() { Task { await engine.relearnBaseline() } }

    private var lastReason = ""
    private func apply(signal s: CaptureSignal) {
        if s.reason != lastReason {
            lastReason = s.reason
            Log.capture.debug("\(s.reason) sharp \(Int(s.metrics.sharpness)) motion \(String(format: "%.1f", s.metrics.motion)) scene \(Int(s.metrics.sceneDelta))")
        }
        signal = s
        switch phase {
        case .learning, .paused, .armed, .steady, .captured: break
        case .reading, .searching: return
        case .awaitingShot, .needLabel:
            // Keep the prompt on screen; the ring shows steadiness via `signal`.
            return
        default:
            if s.armed { break } else { return }
        }
        switch s.reason {
        case "learning": phase = .learning
        case "paused": phase = .paused
        case "steady": phase = .steady(progress: s.steadyProgress)
        case "captured": phase = .captured
        default: phase = .armed(reason: s.reason)
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
        guard let app = appState else { return }
        phase = .reading(step: "starting")
        do {
            let outcome = try await app.identifier.identify(still.image, sessionFormat: app.format.spoken, expectLabel: expectLabel) { [weak self] step in
                self?.phase = .reading(step: step)
            }
            lastOutcome = outcome
            phase = .searching
            let (verdict, ranked) = try await Matcher(discogs: app.discogs).find(reading: outcome.reading, sessionFormat: app.format)
            lastCandidates = ranked
            // Second look at the same record (e.g. flipped to the B-side while ambiguous)? Keep what both shots agree on.
            if let amb = ambiguity {
                let previous = Set(amb.candidates.map(\.id))
                let agreed = ranked.filter { previous.contains($0.id) }
                if agreed.count == 1, let only = agreed.first {
                    ambiguity = nil
                    await finalize(candidate: only, outcome: outcome, photo: fileName, thumb: thumb, allowDuplicate: false)
                    if var rec = current { rec.photos.append(ScanPhoto(recordID: rec.id, fileName: amb.photo, kind: .labelA, order: 0)); rec.photos[rec.photos.count - 2].kind = .labelB; store.update(rec); current = rec }
                    return
                }
            }
            switch verdict {
            case .match(let c):
                await finalize(candidate: c, outcome: outcome, photo: fileName, thumb: thumb, allowDuplicate: false)
            case .ambiguous(let cands):
                ambiguity = (outcome, cands, fileName, thumb)
                phase = .ambiguous(candidates: cands.map(\.summary))
                Chime.ambiguous.play()
                speaker.say("\(cands.count) possible matches. " + cands.enumerated().map { "\($0 + 1): \($1.spoken)" }.joined(separator: ". ") + ". Say one, two, three, or none.")
            case .none:
                let guess = [outcome.reading.artist, outcome.reading.title].compactMap { $0 }.joined(separator: " — ")
                let unreadable = outcome.local.lines.isEmpty && outcome.local.barcodes.isEmpty
                if (!(outcome.reading.isLabelShot ?? false) || unreadable), !expectLabel {
                    expectLabel = true
                    phase = .needLabel(guess: unreadable ? "NOTHING READABLE" : (guess.isEmpty ? "?" : guess.uppercased() + "?"))
                    Chime.needShot.play()
                    speaker.say(unreadable ? "I can't read that. Show me the label, closer." : "No confident match. Show me the label.")
                    await engine.setMode(.shot)
                } else {
                    park(outcome: outcome, photo: fileName, thumb: thumb, guess: guess)
                }
            }
        } catch {
            Log.scan.error("identify failed: \(error.localizedDescription)")
            phase = .notFound(guess: "SETUP NEEDED", detail: error.localizedDescription)
            Chime.notFound.play()
            speaker.say(error.localizedDescription)
            items.insert(SessionItem(thumbnail: thumb, title: "Shot \(shotCounter)", meta: "error · photo kept", tone: .review), at: 0)
        }
        trimItems()
    }

    /// Save a record for a confirmed Discogs release, then ask for the remaining shots.
    private func finalize(candidate c: Candidate, outcome: Identifier.Outcome, photo: String, thumb: CGImage?, allowDuplicate: Bool) async {
        guard let app = appState else { return }
        if !allowDuplicate, let dup = store.existing(discogsReleaseID: c.result.id) {
            duplicate = (c, outcome, photo, thumb)
            phase = .duplicate(title: dup.displayTitle.uppercased())
            Chime.duplicate.play()
            speaker.say("Already catalogued: \(dup.artist), \(dup.title). Say add anyway to keep a second copy.")
            expectLabel = false
            await engine.setMode(.identify)
            return
        }
        do {
            phase = .searching
            let release = try await app.discogs.release(c.result.id)
            var rec = Self.record(from: release, sessionID: sessionID)
            rec.confidence = c.score
            rec.barcode = outcome.reading.barcode
            rec.readText = outcome.local.text
            let firstKind: ShotKind = (outcome.reading.isLabelShot ?? false) || expectLabel ? .labelA : .coverFront
            rec.photos = [ScanPhoto(recordID: rec.id, fileName: photo, kind: firstKind, order: 0)]
            rec.expectedShots = CaptureProfile.load().expected(format: rec.format, discCount: rec.discCount, descriptors: rec.formatDescriptors,
                                                             hadPictureSleeve: firstKind == .coverFront && rec.format == "7\"")
            if !rec.expectedShots.contains(firstKind) { rec.expectedShots.insert(firstKind, at: 0) }
            rec.sync = UserDefaults.standard.object(forKey: "discogsSync") as? Bool ?? true ? .pending : .off
            store.insert(rec)
            current = rec
            pending = rec.missingShots
            expectLabel = false
            let detail = [rec.year.map(String.init), rec.discCount > 1 ? "\(rec.discCount)×\(rec.format)" : rec.format,
                          rec.label.map { "\($0.uppercased()) \(rec.catalogNumber ?? "")" }, rec.country?.uppercased()].compactMap { $0 }.joined(separator: " · ")
            phase = .matched(title: rec.displayTitle.uppercased(), detail: detail, meta: String(format: "%.2f · r%d · %@", c.score, release.id, c.reasons.joined(separator: " ")))
            Chime.matched.play()
            items.insert(SessionItem(recordID: rec.id, thumbnail: thumb, title: rec.displayTitle, meta: detail, tone: pending.isEmpty ? .normal : .incomplete), at: 0)
            var line = "\(rec.artist), \(rec.title)"
            if let y = rec.year { line += ", \(y)" }
            line += ", \(Self.spoken(format: rec.format, discs: rec.discCount))."
            if let next = pending.first { line += " \(next.prompt)." }
            speaker.say(line)
            enrich(rec.id)
            if pending.isEmpty { finishRecord(announce: false) } else { await engine.setMode(.shot); showPrompt() }
        } catch {
            phase = .notFound(guess: "DISCOGS ERROR", detail: error.localizedDescription)
            Chime.notFound.play()
            speaker.say("Discogs error. \(error.localizedDescription)")
        }
    }

    private func showPrompt() {
        guard let rec = current, let kind = pending.first else { return }
        let taken = rec.photos.count
        phase = .awaitingShot(kind: kind.hud, index: taken + 1, total: rec.expectedShots.count, header: "\(rec.displayTitle) · \(rec.format)")
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
        if let rec = current, let idx = items.firstIndex(where: { $0.recordID == rec.id }) {
            items[idx].tone = rec.isComplete ? .normal : .incomplete
            items[idx].meta += " · \(rec.photos.count) shot\(rec.photos.count == 1 ? "" : "s")"
        }
        if announce { Chime.matched.play(); speaker.say("Done. Next record.") }
        current = nil; pending = []; manualKind = nil
        phase = .armed(reason: "next record")
        Task { await engine.setMode(.identify) }
    }

    private func park(outcome: Identifier.Outcome, photo: String, thumb: CGImage?, guess: String) {
        guard let app = appState else { return }
        expectLabel = false
        var rec = VinylRecord(artist: outcome.reading.artist ?? "", title: outcome.reading.title ?? "", format: app.format.discogsFormat, sessionID: sessionID)
        rec.status = .needsReview
        rec.label = outcome.reading.label
        rec.catalogNumber = outcome.reading.catalogNumber
        rec.barcode = outcome.reading.barcode
        rec.year = outcome.reading.year
        rec.readText = outcome.local.text
        rec.photos = [ScanPhoto(recordID: rec.id, fileName: photo, kind: (outcome.reading.isLabelShot ?? false) ? .labelA : .coverFront, order: 0)]
        store.insert(rec)
        app.reviewCount = store.reviewCount()
        let what = outcome.local.lines.prefix(4).joined(separator: " · ")
        phase = .notFound(guess: guess.isEmpty ? "UNKNOWN" : guess.uppercased() + "?", detail: "Read: \(what)")
        Chime.notFound.play()
        speaker.say("Not found. Added to the review queue.")
        items.insert(SessionItem(recordID: rec.id, thumbnail: thumb, title: guess.isEmpty ? "Unknown" : guess, meta: "REVIEW QUEUE", tone: .review), at: 0)
        Task { await engine.setMode(.identify) }
    }

    private func trimItems() { if items.count > 12 { items.removeLast(items.count - 12) } }

    // MARK: - Background enrichment (price + Discogs collection)

    func enrich(_ id: UUID) {
        guard let app = appState else { return }
        Task {
            guard var rec = store.fetch(id), let rid = rec.discogsReleaseID else { return }
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
            if let fresh = store.fetch(id) { rec.photos = fresh.photos }   // photos may have arrived meanwhile
            store.update(rec)
            if current?.id == id { current = rec }
        }
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
            else if case .needLabel = phase, let o = lastOutcome, let f = lastPhotoName { park(outcome: o, photo: f, thumb: lastThumb, guess: [o.reading.artist, o.reading.title].compactMap { $0 }.joined(separator: " — ")) }
            else { speaker.say("Nothing to skip") }
        case .done:
            if current != nil { pending = []; finishRecord(announce: true) } else { speaker.say("Nothing open") }
        case .undo:
            if var rec = current, rec.photos.count > 1, let last = rec.sortedPhotos.last {
                store.deletePhoto(last.id); rec.photos.removeAll { $0.id == last.id }; current = rec
                pending.insert(last.kind, at: 0); speaker.say("Retake \(last.kind.title)"); showPrompt()
            } else if let rec = current {
                store.delete(rec.id); items.removeAll { $0.recordID == rec.id }; current = nil; pending = []
                speaker.say("Deleted"); phase = .armed(reason: "deleted"); Task { await engine.rearm(); await engine.setMode(.identify) }
            } else if let first = items.first, let rid = first.recordID {
                store.delete(rid); items.removeFirst(); speaker.say("Deleted \(first.title)")
                app.reviewCount = store.reviewCount()
            } else { speaker.say("Nothing to undo") }
        case .review:
            if let amb = ambiguity { ambiguity = nil; park(outcome: amb.outcome, photo: amb.photo, thumb: amb.thumb, guess: amb.outcome.reading.title ?? "") }
            else if var rec = current { rec.status = .needsReview; store.update(rec); current = rec; finishRecord(announce: false); speaker.say("Parked for review"); app.reviewCount = store.reviewCount() }
            else if let o = lastOutcome, let f = lastPhotoName { park(outcome: o, photo: f, thumb: lastThumb, guess: o.reading.title ?? "") }
            else { speaker.say("Nothing to park") }
        case .again:
            expectLabel = false; ambiguity = nil
            speaker.say("Go again"); phase = .armed(reason: "again")
            Task { await engine.rearm(); await engine.setMode(.identify) }
        case .one, .two, .three:
            let i = command == .one ? 0 : command == .two ? 1 : 2
            guard let amb = ambiguity, i < amb.candidates.count else { speaker.say("Nothing to choose"); return }
            ambiguity = nil
            Task { await finalize(candidate: amb.candidates[i], outcome: amb.outcome, photo: amb.photo, thumb: amb.thumb, allowDuplicate: false) }
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
        case .yes, .no: break
        }
    }

    private func manualShot(_ kind: ShotKind, say: String) {
        guard current != nil else {
            if kind == .labelB || kind == .labelA { expectLabel = true; speaker.say("Show me the label"); Task { await engine.setMode(.shot) } }
            else { speaker.say("No record open") }
            return
        }
        manualKind = kind
        pending.removeAll { $0 == kind }
        speaker.say(say)
        if var rec = current, !rec.expectedShots.contains(kind) { rec.expectedShots.append(kind); store.update(rec); current = rec }
        phase = .awaitingShot(kind: kind.hud, index: (current?.photos.count ?? 0) + 1, total: current?.expectedShots.count ?? 1, header: current?.displayTitle ?? "")
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
