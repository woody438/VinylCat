import AppKit
import SwiftUI

/// Finish records the scan loop couldn't, and fix the ones it got wrong: add details, re-search
/// Discogs, pick a candidate. The queue is `needsReview` (nothing found) plus `rejected` (thumbed down).
struct ReviewView: View {
    @Environment(AppState.self) private var state
    @State private var selected: UUID?
    @State private var extra = ""
    @State private var candidates: [Candidate] = []
    @State private var status = ""
    @State private var busy = false
    @State private var hovered: UUID?
    @State private var shownPhoto: UUID?
    @FocusState private var searchFocused: Bool
    private let store = Store.shared

    var body: some View {
        let _ = store.revision
        let all = store.all()
        let queue = all.filter { $0.status == .needsReview || $0.status == .rejected }
        let current = all.first { $0.id == selected } ?? queue.first
        HStack(spacing: 0) {
            // The queue can run to dozens of rows. Without a scroll container the column grew past
            // the window and pushed the top bar — and its tabs — off screen: no scroll, no way back.
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    Caption("REVIEW QUEUE · \(queue.count)").padding(16)
                    ForEach(queue) { r in
                        queueRow(r, active: current?.id == r.id,
                                 meta: "\(r.status == .rejected ? "wrong match" : "not found") · \(r.photos.count) shot\(r.photos.count == 1 ? "" : "s") · \(r.createdAt.formatted(date: .omitted, time: .shortened))")
                    }
                }
            }
            .frame(width: 320)
            Rectangle().fill(Theme.line).frame(width: 1)
            if let r = current {
                // Re-created per record so the cursor lands in the search box every time, not just the first.
                detail(r).id(r.id).onAppear { searchFocused = true }
            } else {
                VStack { Text("QUEUE EMPTY").font(Theme.display(40)); Caption("EVERYTHING IS IDENTIFIED AND PHOTOGRAPHED") }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .clipped()
    }

    private func queueRow(_ r: VinylRecord, active: Bool, meta: String) -> some View {
        HStack(spacing: 10) {
            AsyncImage(url: r.sortedPhotos.first?.url) { $0.resizable().aspectRatio(contentMode: .fill) } placeholder: { Theme.raised }
                .frame(width: 48, height: 48).clipped()
            VStack(alignment: .leading, spacing: 2) {
                Text(r.displayTitle == " — " ? "Unknown" : r.displayTitle).font(Theme.mono(13)).lineLimit(1)
                Text(meta).font(Theme.mono(11)).foregroundStyle(Theme.muted).lineLimit(1)
            }
            Spacer(minLength: 8)
            // Throwing away a mis-fire (a hand, the room, a blurry nothing) is the commonest thing
            // to do in here, so it lives on the row rather than behind a selection.
            Button { discard(r) } label: {
                Image(systemName: "trash").font(.system(size: 13))
                    .foregroundStyle(hovered == r.id ? Theme.red : Theme.muted)
                    .frame(width: 24, height: 30)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("Delete this scan and its photos")
        }
        .padding(.leading, 14).padding(.trailing, 6).padding(.vertical, 12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(active ? Theme.redBg : (hovered == r.id ? Theme.raised.opacity(0.5) : .clear))
        .overlay(alignment: .bottom) { Rectangle().fill(Theme.line).frame(height: 1) }
        .contentShape(Rectangle())
        .onHover { hovered = $0 ? r.id : (hovered == r.id ? nil : hovered) }
        .onTapGesture { selected = r.id; shownPhoto = nil; candidates = []; extra = ""; status = "" }
    }

    private func detail(_ r: VinylRecord) -> some View {
        // The right-hand column scrolls: candidates plus the read text can outrun the window height.
        ScrollView {
          HStack(alignment: .top, spacing: 24) {
            VStack(alignment: .leading, spacing: 8) {
                // The whole point of this pane is reading what the readers couldn't, so the photo
                // carries a loupe; click a thumbnail below to put a different shot under it.
                let shown = r.sortedPhotos.first { $0.id == shownPhoto } ?? r.sortedPhotos.first
                MagnifiedPhoto(url: shown?.url)
                Caption("HOVER TO MAGNIFY")
                PhotoStrip(photos: r.sortedPhotos, coverArt: r.coverArtURL, selected: shown?.id) { shownPhoto = $0.id }
                    .frame(width: 440)
            }
            VStack(alignment: .leading, spacing: 18) {
                let heading = r.status == .rejected ? "WRONG MATCH" : "NOT FOUND"
                HStack(spacing: 14) {
                    Text(heading).font(Theme.display(22)).tracking(3).foregroundStyle(r.status == .matched || r.status == .manual ? Theme.amber : Theme.red)
                    Text("captured \(r.createdAt.formatted(date: .abbreviated, time: .shortened))").font(Theme.mono(12)).foregroundStyle(Theme.muted)
                }
                if r.status == .rejected {
                    // The scan matched this, the operator thumbed it down. Show what it was matched to
                    // (struck through, so nobody re-picks it by eye) and hand over to the search below.
                    Text(r.displayTitle.uppercased()).font(Theme.display(36)).strikethrough(color: Theme.red)
                    Text("Thumbed down as the wrong record\(r.discogsReleaseID.map { " (Discogs r\($0))" } ?? ""). Search again below — that release is left out of the candidates — or save it as a manual entry.")
                        .font(Theme.mono(13)).foregroundStyle(Theme.secondary)
                }
                if r.notes.hasPrefix("Scan error:") {
                    Text(r.notes).font(Theme.mono(13)).foregroundStyle(Theme.red)
                }
                let ev = store.evidence(for: r.id)
                if let m = ev?.modelReading {
                    // The model's reading is what the search ran on; it is the thing to correct.
                    Caption("WHAT THE MODEL READ · \(ev?.provider?.uppercased() ?? "")")
                    Text([[m.artist, m.title].compactMap { $0 }.joined(separator: " — "), [m.label, m.catalogNumber].compactMap { $0 }.joined(separator: " "),
                          m.year.map(String.init), m.otherNumbers.map { "other numbers: " + $0.joined(separator: ", ") }].compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: " · "))
                        .font(Theme.mono(13)).foregroundStyle(Theme.secondary).lineLimit(3)
                        .padding(12).frame(maxWidth: .infinity, alignment: .leading).overlay(Rectangle().stroke(Theme.line, lineWidth: 1))
                } else if ev != nil || r.readText.isEmpty == false {
                    Text(ev?.provider == nil ? "The vision model did not read this one — OCR only." : "").font(Theme.mono(11)).foregroundStyle(Theme.muted)
                }
                Caption("WHAT THE OCR READ")
                Text(r.readText.isEmpty ? "—" : r.readText).font(Theme.mono(13)).foregroundStyle(Theme.secondary).lineLimit(6)
                    .padding(12).frame(maxWidth: .infinity, alignment: .leading).overlay(Rectangle().stroke(Theme.line, lineWidth: 1))
                Caption("TELL ME MORE — ARTIST, TITLE, LABEL, CATALOGUE NUMBER, YEAR", color: Theme.green)
                HStack(spacing: 12) {
                    TextField("Title, artist, catalogue number, label, year — any of them", text: $extra).textFieldStyle(.plain).font(Theme.mono(15))
                        .focused($searchFocused)
                        .onSubmit { Task { await research(r) } }
                    Button(busy ? "…" : "SEARCH") { Task { await research(r) } }.disabled(busy)
                }
                .padding(14).overlay(Rectangle().stroke(Theme.green, lineWidth: 1))
                if !candidates.isEmpty {
                    Caption("CANDIDATES · \(candidates.count) · PICK ONE", color: Theme.orange)
                    ForEach(Array(candidates.enumerated()), id: \.element.id) { i, c in
                        HStack(alignment: .firstTextBaseline, spacing: 18) {
                            Text("\(i + 1)").font(Theme.display(44)).foregroundStyle(Theme.orange).frame(width: 40)
                            VStack(alignment: .leading, spacing: 4) {
                                Text(c.result.title.uppercased()).font(Theme.display(24)).lineLimit(1)
                                Text("\(c.summary) · \(String(format: "%.2f", c.score)) \(c.reasons.joined(separator: " "))").font(Theme.mono(13)).foregroundStyle(Theme.muted).lineLimit(1)
                            }
                            Spacer()
                            Button("USE") { Task { await accept(c, for: r) } }.disabled(busy)
                        }
                    }
                }
                if !status.isEmpty { Text(status).font(Theme.mono(12)).foregroundStyle(Theme.amber) }
                Button("SAVE AS MANUAL ENTRY") { saveManual(r) }
                    .buttonStyle(.plain).font(Theme.mono(12)).foregroundStyle(Theme.secondary)
                    .padding(.top, 12)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
          }
          .padding(24)
        }
    }

    private func discard(_ r: VinylRecord) {
        store.delete(r.id)
        state.reviewCount = store.reviewCount()
        if selected == r.id { selected = nil; candidates = []; extra = ""; status = "" }
    }

    private func research(_ r: VinylRecord) async {
        busy = true; defer { busy = false }
        status = "Searching Discogs…"
        do {
            var reading = SleeveReading()
            if r.status == .rejected, let ev = store.evidence(for: r.id) {
                // A rejected record's fields came from the wrong release. Start again from what
                // the readers actually saw on the sleeve.
                reading = ev.mergedReading
            } else {
                reading.artist = r.artist.nilIfEmpty; reading.title = r.title.nilIfEmpty
                reading.label = r.label; reading.catalogNumber = r.catalogNumber; reading.barcode = r.barcode; reading.year = r.year
            }
            let rejectedRelease = r.status == .rejected ? r.discogsReleaseID : nil
            let q = extra.trimmingCharacters(in: .whitespaces)
            var pool: [DiscogsClient.SearchResult] = []
            if !q.isEmpty {
                // Pull a catalogue number out of the free text if there is one; the rest becomes the query.
                let cats = CatalogueNumber.candidates(in: [q])
                if let c = cats.first { reading.catalogNumber = c; pool += try await state.discogs.search(catno: c, perPage: 50) }
                pool += try await state.discogs.search(query: q, format: VinylFormat.allCases.first { $0.discogsFormat == r.format }?.discogsFormat, perPage: 50)
                if pool.isEmpty { pool += try await state.discogs.search(query: q, perPage: 50) }
                let words = q.components(separatedBy: " ")
                if reading.artist == nil, words.count >= 2 { reading.artist = words.prefix(2).joined(separator: " ") }
                reading.title = q
            } else {
                let (_, ranked) = try await Matcher(discogs: state.discogs).find(reading: reading, sessionFormat: nil)
                candidates = ranked.filter { $0.result.id != rejectedRelease }
                status = candidates.isEmpty ? "No hits — add more detail above." : ""; return
            }
            candidates = CandidateRanker.rank(pool, reading: reading, sessionFormat: nil).filter { $0.result.id != rejectedRelease }
            status = candidates.isEmpty ? "No hits — try the catalogue number or label." : ""
        } catch { status = "Search failed: \(error.localizedDescription)" }
    }

    private func accept(_ c: Candidate, for old: VinylRecord) async {
        busy = true; defer { busy = false }
        do {
            let release = try await state.discogs.release(c.result.id)
            var rec = ScanController.record(from: release, sessionID: old.sessionID)
            rec.id = old.id; rec.createdAt = old.createdAt; rec.photos = old.photos; rec.readText = old.readText; rec.notes = old.notes
            rec.confidence = c.score; rec.status = .matched
            rec.sync = CollectionSync.enabledByUser ? .pending : .off
            store.update(rec)
            // The other half of the tuning signal: what it took to find it by hand.
            store.logFeedback(rec.id, .fixed, correction: CorrectionNote(source: "review", typed: extra.trimmingCharacters(in: .whitespaces),
                                                                        chosenReleaseID: c.result.id, previousReleaseID: old.discogsReleaseID,
                                                                        previousStatus: old.status.rawValue, foundBy: c.reasons.joined(separator: " ")))
            state.scan.enrich(rec.id)
            state.reviewCount = store.reviewCount()
            state.scan.speaker.say("Saved \(rec.artist), \(rec.title)")
            candidates = []; extra = ""; status = ""; selected = nil
        } catch { status = "Failed: \(error.localizedDescription)" }
    }

    private func saveManual(_ r: VinylRecord) {
        var rec = r
        let q = extra.trimmingCharacters(in: .whitespaces)
        if !q.isEmpty {
            let parts = q.components(separatedBy: " - ")
            if parts.count >= 2 { rec.artist = parts[0]; rec.title = parts[1...].joined(separator: " - ") } else { rec.title = q }
        }
        if rec.artist.isEmpty && rec.title.isEmpty { status = "Type at least “Artist - Title” first."; return }
        rec.status = .manual
        store.update(rec)
        store.logFeedback(rec.id, .fixed, correction: CorrectionNote(source: "manual", typed: q, previousReleaseID: r.discogsReleaseID, previousStatus: r.status.rawValue))
        state.reviewCount = store.reviewCount(); selected = nil; extra = ""
    }
}
