import AppKit
import SwiftUI

struct LibraryView: View {
    @Environment(AppState.self) private var state
    @State private var search = ""
    @State private var filter: Filter = .all
    @State private var selected: UUID?
    @State private var exportMessage = ""
    @State private var pendingDelete: VinylRecord?
    private let store = Store.shared

    enum Filter: String, CaseIterable, Identifiable {
        case all = "ALL", seven = "7\"", twelve = "12\"", lp = "LP", incomplete = "INCOMPLETE", review = "REVIEW", rejected = "REJECTED"
        var id: String { rawValue }
    }

    var body: some View {
        let _ = store.revision
        let everything = store.all()
        let all = everything.filter(\.isLive)     // the catalogue: counts, value and export ignore rejected scans
        let rows = filtered(everything)
        HStack(spacing: 0) {
            VStack(spacing: 0) {
                HStack(spacing: 12) {
                    HStack(spacing: 8) {
                        Image(systemName: "magnifyingglass").foregroundStyle(Theme.muted)
                        TextField("Search artist, title, label, cat no…", text: $search).textFieldStyle(.plain).font(Theme.mono(13))
                    }
                    .padding(.horizontal, 8).frame(width: 300, height: 30).overlay(Rectangle().stroke(Theme.raised, lineWidth: 1))
                    ForEach(Filter.allCases) { f in
                        let n = count(f, in: everything)
                        // One line, one height: "INCOMPLETE · 0" was wrapping and making its chip
                        // taller than the rest of the row.
                        Text("\(f.rawValue) · \(n)").font(Theme.mono(12)).tracking(1)
                            .lineLimit(1).fixedSize()
                            .foregroundStyle(filter == f ? Theme.green : Theme.secondary)
                            .padding(.horizontal, 12).frame(height: 30)
                            .overlay(Rectangle().stroke(filter == f ? Theme.green : Theme.line, lineWidth: 1))
                            .contentShape(Rectangle()).onTapGesture { filter = f }
                    }
                    Spacer()
                }
                .padding(.horizontal, 24).padding(.vertical, 16)
                Rectangle().fill(Theme.line).frame(height: 1)
                header
                Rectangle().fill(Theme.line).frame(height: 1)
                ScrollView {
                    LazyVStack(spacing: 0) {
                        ForEach(rows) { r in
                            LibraryRow(record: r, selected: selected == r.id, onDelete: { pendingDelete = r })
                                .onTapGesture { selected = r.id }
                        }
                    }
                }
                Rectangle().fill(Theme.line).frame(height: 1)
                HStack(spacing: 28) {
                    Text("\(all.count) RECORDS · EST. VALUE \(estValue(all))")
                    Text(exportMessage).foregroundStyle(Theme.green)
                    Spacer()
                    Button("EXPORT CSV") { export() }.buttonStyle(.plain).foregroundStyle(Theme.secondary)
                    if store.feedbackCount() > 0 {
                        Button("EXPORT FEEDBACK") { exportFeedback() }.buttonStyle(.plain).foregroundStyle(Theme.secondary)
                    }
                    Button("OPEN PHOTOS FOLDER") { NSWorkspace.shared.open(PhotoStore.shared.root) }.buttonStyle(.plain).foregroundStyle(Theme.secondary)
                }
                .font(Theme.mono(12)).foregroundStyle(Theme.muted).padding(.horizontal, 24).frame(height: 44)
            }
            Rectangle().fill(Theme.line).frame(width: 1)
            RecordDetail(record: everything.first { $0.id == selected }, onDelete: { r in pendingDelete = r })
                .frame(width: 400)
        }
        .confirmationDialog(
            "Delete \u{201C}\(pendingDelete?.title ?? "")\u{201D} by \(pendingDelete?.artist ?? "")?",
            isPresented: Binding(get: { pendingDelete != nil }, set: { if !$0 { pendingDelete = nil } }),
            titleVisibility: .visible,
            presenting: pendingDelete
        ) { r in
            Button("Delete Record", role: .destructive) { delete(r) }
            Button("Cancel", role: .cancel) {}
        } message: { r in
            Text(r.photos.isEmpty ? "This can't be undone." : "Its \(r.photos.count) photo\(r.photos.count == 1 ? "" : "s") will be removed too. This can't be undone."
                 + (r.discogsInstanceID != nil ? " It will also be removed from your Discogs collection." : ""))
        }
    }

    private func delete(_ r: VinylRecord) {
        if selected == r.id { selected = nil }
        pendingDelete = nil
        Task { await state.scan.delete(r.id) }   // removes the Discogs collection entry first when there is one
    }

    private func exportFeedback() {
        do {
            let url = try store.exportFeedback(to: URL(fileURLWithPath: "/Users/ianwoodall/Documents/VinylCat/output"))
            exportMessage = "SAVED \(url.lastPathComponent)"
            NSWorkspace.shared.activateFileViewerSelecting([url])
        } catch { exportMessage = "EXPORT FAILED: \(error.localizedDescription)" }
    }

    private var header: some View {
        HStack(spacing: 12) {
            Text("ARTIST").frame(width: 170, alignment: .leading)
            Text("TITLE").frame(maxWidth: .infinity, alignment: .leading)
            Text("YEAR").frame(width: 50, alignment: .leading)
            Text("FMT").frame(width: 50, alignment: .leading)
            Text("LABEL · CAT NO.").frame(maxWidth: .infinity, alignment: .leading)
            Text("VALUE").frame(width: 70, alignment: .leading)
            Text("SHOTS").frame(width: 50, alignment: .leading)
            Text("DISCOGS").frame(width: 80, alignment: .leading)
            Color.clear.frame(width: 24)
        }
        .font(Theme.mono(11)).tracking(1.5).foregroundStyle(Theme.muted)
        .padding(.horizontal, 16).padding(.vertical, 10)
    }

    private func filtered(_ all: [VinylRecord]) -> [VinylRecord] {
        let q = search.lowercased().trimmingCharacters(in: .whitespaces)
        return all.filter { matches(filter, $0) }.filter { r in
            q.isEmpty || [r.artist, r.title, r.label ?? "", r.catalogNumber ?? "", r.year.map(String.init) ?? "", r.notes]
                .contains { $0.lowercased().contains(q) }
        }
    }

    private func count(_ f: Filter, in all: [VinylRecord]) -> Int { all.filter { matches(f, $0) }.count }

    private func matches(_ f: Filter, _ r: VinylRecord) -> Bool {
        if f == .rejected { return r.status == .rejected }
        guard r.isLive else { return false }
        switch f {
        case .all, .rejected: return true
        case .seven: return r.format == "7\""
        case .twelve: return r.format == "12\""
        case .lp: return r.format == "LP"
        case .incomplete: return !r.isComplete && r.status != .needsReview
        case .review: return r.status == .needsReview
        }
    }

    private func estValue(_ all: [VinylRecord]) -> String {
        let total = all.compactMap { $0.valueMedian ?? $0.valueLow }.reduce(0, +)
        let cur = all.first?.currency ?? state.discogs.currency
        return "\(cur) \(Int(total)) (DISCOGS LOWEST)"
    }

    private func export() {
        do {
            let url = try store.exportCSV(to: URL(fileURLWithPath: "/Users/ianwoodall/Documents/VinylCat/output"))
            exportMessage = "SAVED \(url.lastPathComponent)"
            NSWorkspace.shared.activateFileViewerSelecting([url])
        } catch { exportMessage = "EXPORT FAILED: \(error.localizedDescription)" }
    }
}

struct LibraryRow: View {
    let record: VinylRecord
    let selected: Bool
    var onDelete: () -> Void = {}
    @State private var hovering = false
    var body: some View {
        let r = record
        let sync: (String, Color) = switch r.status {
        case .needsReview: ("REVIEW", Theme.red)
        case .duplicate: ("DUP", Theme.amber)
        case .rejected: ("WRONG", Theme.red)
        default: r.sync == .synced ? (r.verified ? "SYNCED ✓" : "SYNCED", Theme.green) : r.sync == .failed ? ("FAILED", Theme.red) : r.sync == .pending ? ("PENDING", Theme.muted) : (r.verified ? "✓" : "—", Theme.muted)
        }
        HStack(spacing: 12) {
            Text(r.artist).frame(width: 170, alignment: .leading).lineLimit(1).strikethrough(r.status == .rejected, color: Theme.red)
            Text(r.title).frame(maxWidth: .infinity, alignment: .leading).lineLimit(1).strikethrough(r.status == .rejected, color: Theme.red)
            Text(r.year.map(String.init) ?? "—").foregroundStyle(Theme.muted).frame(width: 50, alignment: .leading)
            Text(r.discCount > 1 ? "\(r.discCount)×\(r.format)" : r.format).frame(width: 50, alignment: .leading)
            Text([r.label, r.catalogNumber].compactMap { $0 }.joined(separator: " · ")).foregroundStyle(Theme.secondary).frame(maxWidth: .infinity, alignment: .leading).lineLimit(1)
            Text(r.valueLow.map { "\($0 < 10 ? String(format: "%.2f", $0) : String(Int($0)))" } ?? "—").frame(width: 70, alignment: .leading)
            Text("\(r.photos.count)/\(max(r.expectedShots.count, r.photos.count))").foregroundStyle(r.isComplete ? Theme.muted : Theme.amber).frame(width: 50, alignment: .leading)
            Text(sync.0).foregroundStyle(sync.1).frame(width: 80, alignment: .leading)
            Button(action: onDelete) {
                Image(systemName: "trash")
                    .font(.system(size: 12))
                    .foregroundStyle(hovering || selected ? Theme.red : Theme.muted.opacity(0.5))
                    .frame(width: 24, height: 20)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("Delete this record")
        }
        .font(Theme.mono(13)).foregroundStyle(Theme.text)
        .padding(.horizontal, 16).padding(.vertical, 10)
        .background(selected ? Theme.greenBg : hovering ? Theme.raised.opacity(0.35) : .clear)
        .overlay(alignment: .bottom) { Rectangle().fill(Theme.line).frame(height: 1) }
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
    }
}

struct RecordDetail: View {
    @Environment(AppState.self) private var state
    let record: VinylRecord?
    var onDelete: (VinylRecord) -> Void = { _ in }
    @State private var notes = ""

    var body: some View {
        if let r = record {
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    PhotoStrip(photos: r.sortedPhotos, coverArt: r.coverArtURL)
                    VStack(alignment: .leading, spacing: 4) {
                        Text(r.title.uppercased()).font(Theme.display(40)).lineLimit(2).minimumScaleFactor(0.6)
                        Text(r.artist.uppercased()).font(Theme.display(30, weight: .medium)).foregroundStyle(Theme.secondary)
                    }
                    Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 6) {
                        row("Format", r.discCount > 1 ? "\(r.discCount) × \(r.format) · \(r.formatDescriptors.joined(separator: ", "))" : "\(r.format) · \(r.formatDescriptors.joined(separator: ", "))")
                        row("Label", [r.label, r.catalogNumber].compactMap { $0 }.joined(separator: " · "))
                        row("Released", [r.year.map(String.init), r.country].compactMap { $0 }.joined(separator: " · "))
                        row("Genre", (r.genres + r.styles).joined(separator: ", "))
                        row("Value", r.valueLow.map { "from \(r.currency ?? "") \(String(format: "%.2f", $0)) · \(r.numForSale ?? 0) for sale" } ?? "—")
                        row("Discogs", r.discogsReleaseID.map { "r\($0) · \(r.sync.rawValue)" } ?? "—")
                        row("Status", (r.status == .rejected ? "REJECTED — wrong record, kept for tuning" : r.verified ? "\(r.status.rawValue) · verified" : r.status.rawValue)
                            + " · \(r.photos.count)/\(r.expectedShots.count) shots" + (r.isComplete ? "" : " · missing \(r.missingShots.map(\.title).joined(separator: ", "))"))
                        row("Added", r.createdAt.formatted(date: .abbreviated, time: .shortened))
                        row("Confidence", String(format: "%.2f", r.confidence))
                    }
                    if !r.tracks.isEmpty {
                        Caption("TRACKLIST")
                        VStack(alignment: .leading, spacing: 4) {
                            ForEach(r.tracks, id: \.position) { t in
                                HStack { Text("\(t.position) · \(t.title)"); Spacer(); Text(t.duration ?? "").foregroundStyle(Theme.muted) }
                            }
                        }.font(Theme.mono(13))
                    }
                    if !r.readText.isEmpty {
                        Caption("WHAT WAS READ")
                        Text(r.readText).font(Theme.mono(11)).foregroundStyle(Theme.muted).lineLimit(6)
                    }
                    Caption("NOTES")
                    TextEditor(text: $notes).font(Theme.mono(13)).frame(height: 70).scrollContentBackground(.hidden).background(Theme.panel)
                        .onChange(of: notes) { _, v in var u = r; u.notes = v; if u.notes != r.notes { Store.shared.update(u) } }
                    HStack(spacing: 16) {
                        if let u = r.discogsURI, let url = URL(string: u) { Button("OPEN ON DISCOGS") { NSWorkspace.shared.open(url) } }
                        if r.status == .rejected {
                            Button("RESTORE") { state.scan.verdict(r.id, .up) }.foregroundStyle(Theme.green)
                        } else if r.discogsReleaseID != nil {
                            Button("RE-VALUE") { state.scan.enrich(r.id) }
                            Button(r.verified ? "VERIFIED ✓" : "CORRECT") { state.scan.verdict(r.id, .up) }.foregroundStyle(r.verified ? Theme.green : Theme.secondary).disabled(r.verified)
                            Button("WRONG RECORD") { state.scan.verdict(r.id, .down) }.foregroundStyle(Theme.amber)
                        }
                        Button("DELETE") { onDelete(r) }.foregroundStyle(Theme.red)
                    }
                    .buttonStyle(.plain).font(Theme.mono(12)).foregroundStyle(Theme.secondary)
                }
                .padding(20)
            }
            .onAppear { notes = r.notes }
            .onChange(of: r.id) { _, _ in notes = r.notes }
        } else {
            VStack { Caption("SELECT A RECORD") }.frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private func row(_ k: String, _ v: String) -> some View {
        GridRow {
            Text(k).foregroundStyle(Theme.muted)
            Text(v.isEmpty ? "—" : v).lineLimit(2)
        }.font(Theme.mono(13))
    }
}

struct PhotoStrip: View {
    let photos: [ScanPhoto]
    let coverArt: String?
    /// When set, the strip is a picker: the selected shot gets a ring and taps report back.
    var selected: UUID? = nil
    var onSelect: ((ScanPhoto) -> Void)? = nil
    var body: some View {
        ScrollView(.horizontal) {
            HStack(spacing: 8) {
                ForEach(photos) { p in
                    VStack(spacing: 4) {
                        AsyncImage(url: p.url) { img in img.resizable().aspectRatio(contentMode: .fill) } placeholder: { Theme.raised }
                            .frame(width: 84, height: 84).clipped()
                            .overlay(Rectangle().stroke(selected == p.id ? Theme.green : .clear, lineWidth: 2))
                        Caption(p.kind.hud).lineLimit(1)
                    }
                    .frame(width: 84)
                    .contentShape(Rectangle())
                    .onTapGesture { onSelect?(p) }
                }
                if let c = coverArt, let url = URL(string: c) {
                    VStack(spacing: 4) {
                        AsyncImage(url: url) { img in img.resizable().aspectRatio(contentMode: .fill) } placeholder: { Theme.raised }
                            .frame(width: 84, height: 84).clipped().opacity(0.7)
                        Caption("DISCOGS")
                    }
                }
            }
        }
    }
}
