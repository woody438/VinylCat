import AppKit
import SwiftUI

struct LibraryView: View {
    @Environment(AppState.self) private var state
    @State private var search = ""
    @State private var filter: Filter = .all
    @State private var selected: UUID?
    @State private var exportMessage = ""
    private let store = Store.shared

    enum Filter: String, CaseIterable, Identifiable {
        case all = "ALL", seven = "7\"", twelve = "12\"", lp = "LP", incomplete = "INCOMPLETE", review = "REVIEW"
        var id: String { rawValue }
    }

    var body: some View {
        let _ = store.revision
        let all = store.all()
        let rows = filtered(all)
        HStack(spacing: 0) {
            VStack(spacing: 0) {
                HStack(spacing: 12) {
                    HStack(spacing: 8) {
                        Image(systemName: "magnifyingglass").foregroundStyle(Theme.muted)
                        TextField("Search artist, title, label, cat no…", text: $search).textFieldStyle(.plain).font(Theme.mono(13))
                    }
                    .padding(8).frame(width: 300).overlay(Rectangle().stroke(Theme.raised, lineWidth: 1))
                    ForEach(Filter.allCases) { f in
                        let n = count(f, in: all)
                        Text("\(f.rawValue) · \(n)").font(Theme.mono(12)).tracking(1)
                            .foregroundStyle(filter == f ? Theme.green : Theme.secondary)
                            .padding(.horizontal, 12).padding(.vertical, 6)
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
                            LibraryRow(record: r, selected: selected == r.id).onTapGesture { selected = r.id }
                        }
                    }
                }
                Rectangle().fill(Theme.line).frame(height: 1)
                HStack(spacing: 28) {
                    Text("\(all.count) RECORDS · EST. VALUE \(estValue(all))")
                    Text(exportMessage).foregroundStyle(Theme.green)
                    Spacer()
                    Button("EXPORT CSV") { export() }.buttonStyle(.plain).foregroundStyle(Theme.secondary)
                    Button("OPEN PHOTOS FOLDER") { NSWorkspace.shared.open(PhotoStore.shared.root) }.buttonStyle(.plain).foregroundStyle(Theme.secondary)
                }
                .font(Theme.mono(12)).foregroundStyle(Theme.muted).padding(.horizontal, 24).frame(height: 44)
            }
            Rectangle().fill(Theme.line).frame(width: 1)
            RecordDetail(record: rows.first { $0.id == selected } ?? all.first { $0.id == selected })
                .frame(width: 400)
        }
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
        }
        .font(Theme.mono(11)).tracking(1.5).foregroundStyle(Theme.muted)
        .padding(.horizontal, 16).padding(.vertical, 10)
    }

    private func filtered(_ all: [VinylRecord]) -> [VinylRecord] {
        let q = search.lowercased().trimmingCharacters(in: .whitespaces)
        return all.filter { r in
            switch filter {
            case .all: true
            case .seven: r.format == "7\""
            case .twelve: r.format == "12\""
            case .lp: r.format == "LP"
            case .incomplete: !r.isComplete && r.status != .needsReview
            case .review: r.status == .needsReview
            }
        }.filter { r in
            q.isEmpty || [r.artist, r.title, r.label ?? "", r.catalogNumber ?? "", r.year.map(String.init) ?? "", r.notes]
                .contains { $0.lowercased().contains(q) }
        }
    }

    private func count(_ f: Filter, in all: [VinylRecord]) -> Int {
        let keep = filter; defer { _ = keep }
        return all.filter { r in
            switch f {
            case .all: true
            case .seven: r.format == "7\""
            case .twelve: r.format == "12\""
            case .lp: r.format == "LP"
            case .incomplete: !r.isComplete && r.status != .needsReview
            case .review: r.status == .needsReview
            }
        }.count
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
    var body: some View {
        let r = record
        let sync: (String, Color) = switch r.status {
        case .needsReview: ("REVIEW", Theme.red)
        case .duplicate: ("DUP", Theme.amber)
        default: r.sync == .synced ? ("SYNCED", Theme.green) : r.sync == .failed ? ("FAILED", Theme.red) : r.sync == .pending ? ("PENDING", Theme.muted) : ("—", Theme.muted)
        }
        HStack(spacing: 12) {
            Text(r.artist).frame(width: 170, alignment: .leading).lineLimit(1)
            Text(r.title).frame(maxWidth: .infinity, alignment: .leading).lineLimit(1)
            Text(r.year.map(String.init) ?? "—").foregroundStyle(Theme.muted).frame(width: 50, alignment: .leading)
            Text(r.discCount > 1 ? "\(r.discCount)×\(r.format)" : r.format).frame(width: 50, alignment: .leading)
            Text([r.label, r.catalogNumber].compactMap { $0 }.joined(separator: " · ")).foregroundStyle(Theme.secondary).frame(maxWidth: .infinity, alignment: .leading).lineLimit(1)
            Text(r.valueLow.map { "\($0 < 10 ? String(format: "%.2f", $0) : String(Int($0)))" } ?? "—").frame(width: 70, alignment: .leading)
            Text("\(r.photos.count)/\(max(r.expectedShots.count, r.photos.count))").foregroundStyle(r.isComplete ? Theme.muted : Theme.amber).frame(width: 50, alignment: .leading)
            Text(sync.0).foregroundStyle(sync.1).frame(width: 80, alignment: .leading)
        }
        .font(Theme.mono(13)).foregroundStyle(Theme.text)
        .padding(.horizontal, 16).padding(.vertical, 10)
        .background(selected ? Theme.greenBg : .clear)
        .overlay(alignment: .bottom) { Rectangle().fill(Theme.line).frame(height: 1) }
        .contentShape(Rectangle())
    }
}

struct RecordDetail: View {
    @Environment(AppState.self) private var state
    let record: VinylRecord?
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
                        row("Status", "\(r.status.rawValue) · \(r.photos.count)/\(r.expectedShots.count) shots" + (r.isComplete ? "" : " · missing \(r.missingShots.map(\.title).joined(separator: ", "))"))
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
                        Button("RE-VALUE") { state.scan.enrich(r.id) }
                        Button("DELETE") { Store.shared.delete(r.id); state.reviewCount = Store.shared.reviewCount() }.foregroundStyle(Theme.red)
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
    var body: some View {
        ScrollView(.horizontal) {
            HStack(spacing: 8) {
                ForEach(photos) { p in
                    VStack(spacing: 4) {
                        AsyncImage(url: p.url) { img in img.resizable().aspectRatio(contentMode: .fill) } placeholder: { Theme.raised }
                            .frame(width: 84, height: 84).clipped()
                        Caption(p.kind.hud).lineLimit(1)
                    }
                    .frame(width: 84)
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
