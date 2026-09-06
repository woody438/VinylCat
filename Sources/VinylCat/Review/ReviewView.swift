import AppKit
import SwiftUI

/// Finish records the scan loop couldn't: add details, re-search Discogs, pick a candidate.
struct ReviewView: View {
    @Environment(AppState.self) private var state
    @State private var selected: UUID?
    @State private var extra = ""
    @State private var candidates: [Candidate] = []
    @State private var status = ""
    @State private var busy = false
    @State private var hovered: UUID?
    private let store = Store.shared

    var body: some View {
        let _ = store.revision
        let all = store.all()
        let queue = all.filter { $0.status == .needsReview }
        let incomplete = all.filter { $0.status != .needsReview && !$0.isComplete }
        let current = all.first { $0.id == selected } ?? queue.first ?? incomplete.first
        HStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 0) {
                Caption("REVIEW QUEUE · \(queue.count)").padding(16)
                ForEach(queue) { r in queueRow(r, active: current?.id == r.id, meta: "not found · \(r.photos.count) shot · \(r.createdAt.formatted(date: .omitted, time: .shortened))") }
                Caption("INCOMPLETE SHOTS · \(incomplete.count)").padding(16)
                ForEach(incomplete.prefix(8)) { r in queueRow(r, active: current?.id == r.id, meta: "\(r.photos.count)/\(r.expectedShots.count) shots · needs \(r.missingShots.map { $0.title.lowercased() }.joined(separator: ", "))") }
                Spacer()
            }
            .frame(width: 320)
            Rectangle().fill(Theme.line).frame(width: 1)
            if let r = current {
                detail(r)
            } else {
                VStack { Text("QUEUE EMPTY").font(Theme.display(40)); Caption("EVERYTHING IS IDENTIFIED AND PHOTOGRAPHED") }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
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
        .onTapGesture { selected = r.id; candidates = []; extra = ""; status = "" }
    }

    private func detail(_ r: VinylRecord) -> some View {
        HStack(alignment: .top, spacing: 24) {
            VStack(spacing: 8) {
                AsyncImage(url: r.sortedPhotos.first?.url) { $0.resizable().aspectRatio(contentMode: .fit) } placeholder: { Theme.raised }
                    .frame(width: 520, height: 520).background(Theme.panel)
                PhotoStrip(photos: r.sortedPhotos, coverArt: r.coverArtURL)
            }
            VStack(alignment: .leading, spacing: 18) {
                HStack(spacing: 14) {
                    Text(r.status == .needsReview ? "NOT FOUND" : "INCOMPLETE").font(Theme.display(22)).tracking(3).foregroundStyle(r.status == .needsReview ? Theme.red : Theme.amber)
                    Text("captured \(r.createdAt.formatted(date: .abbreviated, time: .shortened))").font(Theme.mono(12)).foregroundStyle(Theme.muted)
                }
                if r.status != .needsReview {
                    Text(r.displayTitle.uppercased()).font(Theme.display(36))
                    Text("Missing: \(r.missingShots.map(\.title).joined(separator: ", ")). Go to SCAN, say “label” / “back cover” / “flip” with this record open — or take them in a second pass.")
                        .font(Theme.mono(13)).foregroundStyle(Theme.secondary)
                }
                Caption("WHAT I READ")
                Text(r.readText.isEmpty ? "—" : r.readText).font(Theme.mono(13)).foregroundStyle(Theme.secondary).lineLimit(6)
                    .padding(12).frame(maxWidth: .infinity, alignment: .leading).overlay(Rectangle().stroke(Theme.line, lineWidth: 1))
                Caption("TELL ME MORE — ARTIST, TITLE, LABEL, CATALOGUE NUMBER, YEAR", color: Theme.green)
                HStack(spacing: 12) {
                    TextField("e.g. Donovan Sunshine Superman Pye 7N 17241 1966", text: $extra).textFieldStyle(.plain).font(Theme.mono(15))
                        .onSubmit { Task { await research(r) } }
                    Button(busy ? "…" : "SEARCH") { Task { await research(r) } }.disabled(busy)
                }
                .padding(14).overlay(Rectangle().stroke(Theme.green, lineWidth: 1))
                if !candidates.isEmpty {
                    Caption("CANDIDATES · PICK ONE", color: Theme.orange)
                    ForEach(Array(candidates.prefix(5).enumerated()), id: \.element.id) { i, c in
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
                Spacer()
                Button("SAVE AS MANUAL ENTRY") { saveManual(r) }
                    .buttonStyle(.plain).font(Theme.mono(12)).foregroundStyle(Theme.secondary)
            }
        }
        .padding(24)
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
            reading.artist = r.artist.nilIfEmpty; reading.title = r.title.nilIfEmpty
            reading.label = r.label; reading.catalogNumber = r.catalogNumber; reading.barcode = r.barcode; reading.year = r.year
            let q = extra.trimmingCharacters(in: .whitespaces)
            var pool: [DiscogsClient.SearchResult] = []
            if !q.isEmpty {
                // Pull a catalogue number out of the free text if there is one; the rest becomes the query.
                let cats = CatalogueNumber.candidates(in: [q])
                if let c = cats.first { reading.catalogNumber = c; pool += try await state.discogs.search(catno: c) }
                pool += try await state.discogs.search(query: q, format: VinylFormat.allCases.first { $0.discogsFormat == r.format }?.discogsFormat)
                if pool.isEmpty { pool += try await state.discogs.search(query: q) }
                let words = q.components(separatedBy: " ")
                if reading.artist == nil, words.count >= 2 { reading.artist = words.prefix(2).joined(separator: " ") }
                reading.title = q
            } else {
                let (_, ranked) = try await Matcher(discogs: state.discogs).find(reading: reading, sessionFormat: nil)
                candidates = ranked; status = ranked.isEmpty ? "No hits — add more detail above." : ""; return
            }
            candidates = CandidateRanker.rank(pool, reading: reading, sessionFormat: nil)
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
            rec.expectedShots = CaptureProfile.load().expected(format: rec.format, discCount: rec.discCount, descriptors: rec.formatDescriptors,
                                                             hadPictureSleeve: old.photos.first?.kind == .coverFront && rec.format == "7\"")
            rec.sync = UserDefaults.standard.object(forKey: "discogsSync") as? Bool ?? true ? .pending : .off
            store.update(rec)
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
        rec.status = .manual; rec.expectedShots = rec.photos.map(\.kind)
        store.update(rec); state.reviewCount = store.reviewCount(); selected = nil; extra = ""
    }
}
