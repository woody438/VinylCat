import SwiftUI

/// Add a record without the camera: type what is known, search Discogs, pick the release. Lives in
/// the Library's detail column. Every hit comes back (50 per query, ranked) in a scrolling list.
struct ManualEntryView: View {
    @Environment(AppState.self) private var state
    /// Called with the new record's id once it is saved, so the Library can select it.
    var onSaved: (UUID) -> Void
    var onCancel: () -> Void
    @State private var artist = ""
    @State private var title = ""
    @State private var label = ""
    @State private var catno = ""
    @State private var barcode = ""
    @State private var year = ""
    @State private var format: VinylFormat? = nil
    @State private var candidates: [Candidate] = []
    @State private var status = ""
    @State private var busy = false
    @FocusState private var focus: Field?
    private let store = Store.shared

    enum Field { case artist, title, label, catno, barcode, year }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Text("ADD A RECORD").font(Theme.display(28))
                Spacer()
                Button("CANCEL") { onCancel() }.buttonStyle(.plain).font(Theme.mono(12)).foregroundStyle(Theme.muted)
            }
            Text("Fill in whatever you know — a catalogue number or barcode alone is usually enough — then SEARCH. RETURN searches too.")
                .font(Theme.mono(11)).foregroundStyle(Theme.muted).fixedSize(horizontal: false, vertical: true)
            field("Artist", $artist, .artist)
            field("Title", $title, .title)
            field("Label", $label, .label)
            field("Cat no.", $catno, .catno)
            field("Barcode", $barcode, .barcode)
            HStack(spacing: 12) {
                field("Year", $year, .year).frame(width: 150)
                Picker("", selection: $format) {
                    Text("ANY FORMAT").tag(VinylFormat?.none)
                    ForEach(VinylFormat.allCases) { Text($0.rawValue).tag(Optional($0)) }
                }
                .labelsHidden().pickerStyle(.menu).fixedSize().font(Theme.mono(12)).tint(Theme.text)
            }
            HStack(spacing: 12) {
                Button(busy ? "SEARCHING…" : "SEARCH DISCOGS") { Task { await search() } }
                    .buttonStyle(.plain).font(Theme.mono(12)).tracking(1).foregroundStyle(Theme.bg)
                    .padding(.horizontal, 14).frame(height: 30).background(Theme.green).disabled(busy || !canSearch)
                    .opacity(canSearch ? 1 : 0.4)
                Button("SAVE WITHOUT DISCOGS") { saveManual() }
                    .buttonStyle(.plain).font(Theme.mono(12)).foregroundStyle(Theme.secondary)
                    .disabled(artist.isEmpty && title.isEmpty)
            }
            if !status.isEmpty { Text(status).font(Theme.mono(12)).foregroundStyle(Theme.amber).fixedSize(horizontal: false, vertical: true) }
            if !candidates.isEmpty {
                Caption("RESULTS · \(candidates.count) · PICK ONE", color: Theme.orange)
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 0) {
                        ForEach(candidates) { c in
                            HStack(alignment: .top, spacing: 10) {
                                VStack(alignment: .leading, spacing: 3) {
                                    Text(c.headline).font(Theme.display(18)).lineLimit(2)
                                    Text(c.summary).font(Theme.mono(11)).foregroundStyle(Theme.secondary).lineLimit(2)
                                    Text(String(format: "%.2f · %@", c.score, c.reasons.joined(separator: " "))).font(Theme.mono(10)).foregroundStyle(Theme.muted).lineLimit(1)
                                }
                                Spacer(minLength: 6)
                                Button("USE") { Task { await use(c) } }.disabled(busy)
                            }
                            .padding(.vertical, 8)
                            .overlay(alignment: .bottom) { Rectangle().fill(Theme.line).frame(height: 1) }
                        }
                    }
                }
            }
        }
        .padding(20)
        .onAppear { focus = .artist }
    }

    private var canSearch: Bool {
        ![artist, title, label, catno, barcode].allSatisfy { $0.trimmingCharacters(in: .whitespaces).isEmpty }
    }

    private func field(_ name: String, _ text: Binding<String>, _ f: Field) -> some View {
        HStack(spacing: 10) {
            Text(name.uppercased()).font(Theme.mono(11)).tracking(1.5).foregroundStyle(Theme.muted).frame(width: 74, alignment: .leading)
            TextField("", text: text).textFieldStyle(.plain).font(Theme.mono(13))
                .focused($focus, equals: f)
                .onSubmit { Task { await search() } }
        }
        .padding(.horizontal, 10).frame(height: 30)
        .overlay(Rectangle().stroke(focus == f ? Theme.green : Theme.raised, lineWidth: 1))
    }

    private var reading: SleeveReading {
        var r = SleeveReading()
        func t(_ s: String) -> String? { s.trimmingCharacters(in: .whitespaces).nilIfEmpty }
        r.artist = t(artist); r.title = t(title); r.label = t(label); r.catalogNumber = t(catno); r.barcode = t(barcode)
        r.year = Int(year.trimmingCharacters(in: .whitespaces))
        r.formatGuess = format?.discogsFormat
        return r
    }

    /// Strongest keys first, then the loose ones; everything found is ranked against what was typed.
    private func search() async {
        guard canSearch, !busy else { return }
        busy = true; defer { busy = false }
        status = "Searching Discogs…"; candidates = []
        let r = reading
        let fmt = format?.discogsFormat
        do {
            var pool: [DiscogsClient.SearchResult] = []
            if let b = r.barcode?.filter(\.isNumber), b.count >= 8 { pool += try await state.discogs.search(barcode: b, perPage: 50) }
            if let c = r.catalogNumber {
                pool += try await state.discogs.search(label: r.label, catno: c, format: fmt, perPage: 50)
                if pool.isEmpty { pool += try await state.discogs.search(catno: c, perPage: 50) }
                if pool.isEmpty { pool += try await state.discogs.search(query: c, format: fmt, perPage: 50) }
            }
            if r.artist != nil || r.title != nil {
                pool += try await state.discogs.search(artist: r.artist, releaseTitle: r.title, label: r.label, format: fmt, perPage: 50)
            }
            if pool.isEmpty {
                let q = [r.artist, r.title, r.label, r.catalogNumber].compactMap { $0 }.joined(separator: " ")
                if !q.isEmpty { pool += try await state.discogs.search(query: q, perPage: 50) }
            }
            candidates = CandidateRanker.rank(pool, reading: r, sessionFormat: format)
            status = candidates.isEmpty ? "Nothing on Discogs for that — try fewer fields, or the catalogue number on its own." : ""
        } catch { status = "Search failed: \(FriendlyError.describe(error, context: "Discogs"))" }
    }

    private func use(_ c: Candidate) async {
        busy = true; defer { busy = false }
        do {
            let release = try await state.discogs.release(c.result.id)
            var rec = ScanController.record(from: release, sessionID: CollectionSync.importSession)
            rec.confidence = c.score
            rec.status = .matched
            rec.barcode = reading.barcode ?? rec.barcode
            rec.sync = CollectionSync.enabledByUser ? .pending : .off
            store.insert(rec)
            store.logFeedback(rec.id, .fixed, correction: CorrectionNote(source: "library", typed: typedSummary, chosenReleaseID: c.result.id, foundBy: c.reasons.joined(separator: " ")))
            state.scan.enrich(rec.id)
            state.scan.speaker.say("Added \(rec.artist), \(rec.title)")
            onSaved(rec.id)
        } catch { status = "Couldn't fetch the release: \(FriendlyError.describe(error, context: "Discogs"))" }
    }

    private func saveManual() {
        let r = reading
        guard r.artist != nil || r.title != nil else { status = "Type at least an artist or a title."; return }
        var rec = VinylRecord(artist: r.artist ?? "", title: r.title ?? "", format: format?.discogsFormat ?? "LP", sessionID: CollectionSync.importSession)
        rec.label = r.label; rec.catalogNumber = r.catalogNumber; rec.barcode = r.barcode; rec.year = r.year
        rec.status = .manual
        store.insert(rec)
        store.logFeedback(rec.id, .fixed, correction: CorrectionNote(source: "manual", typed: typedSummary))
        onSaved(rec.id)
    }

    private var typedSummary: String {
        [("artist", artist), ("title", title), ("label", label), ("catno", catno), ("barcode", barcode), ("year", year)]
            .filter { !$0.1.trimmingCharacters(in: .whitespaces).isEmpty }.map { "\($0.0)=\($0.1.trimmingCharacters(in: .whitespaces))" }.joined(separator: " ")
    }
}
