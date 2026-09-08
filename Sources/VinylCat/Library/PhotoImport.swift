import AppKit
import ImageIO
import Observation
import SwiftUI
import UniformTypeIdentifiers

/// Bulk import: a folder of label/cover photos taken on a phone, each one run through the scan
/// pipeline (`ScanController.process`) without the webcam. Never waits on the operator: a confident
/// match is saved (or attached to a photo-less record pulled from Discogs), an ambiguous or missing
/// match is parked in the review queue with its candidates, a duplicate is skipped and its photo
/// dropped, and any Discogs/network error parks the photo with a note and the run carries on.
/// Serial, one photo at a time, so scanning keeps most of the Discogs rate limit; valuation
/// (`CollectionSync.valueUnvalued`) is paused for the duration.
@MainActor
@Observable
final class PhotoImporter {
    enum State: Equatable { case idle, running, stopping, finished }

    struct Line: Identifiable {
        let id = UUID()
        var file: String
        var text: String
        var tone: Tone
        enum Tone { case matched, parked, duplicate, error }
    }

    private(set) var state: State = .idle
    private(set) var total = 0
    private(set) var done = 0
    private(set) var matched = 0
    private(set) var attached = 0
    private(set) var parked = 0
    private(set) var duplicates = 0
    private(set) var errors = 0
    /// Model spend for this run, from `Identifier`'s meter.
    private(set) var costUSD = 0.0
    private(set) var current = ""
    private(set) var step = ""
    private(set) var source = ""
    private(set) var lines: [Line] = []
    private(set) var stopped = false
    /// Headless runs print each line as it lands.
    var onLine: ((Line) -> Void)?
    weak var app: AppState?
    private var stopRequested = false
    private var runTask: Task<Void, Never>?
    /// Every record from one run shares a session id, as a webcam session does.
    private(set) var runID = UUID()

    var active: Bool { state != .idle }
    var running: Bool { state == .running || state == .stopping }
    /// Photos the run gave up on: what the exit code and the summary count.
    var unresolved: Int { parked + errors }

    static let extensions: Set<String> = ["jpg", "jpeg", "png", "heic"]

    /// Dropped or picked: folders are walked (sorted by path, dotfiles and hidden folders skipped),
    /// image files are taken as they are, anything else is ignored.
    static func walk(_ urls: [URL]) -> [URL] {
        var out: [URL] = []
        let fm = FileManager.default
        for u in urls {
            var isDir: ObjCBool = false
            guard fm.fileExists(atPath: u.path, isDirectory: &isDir) else { continue }
            if isDir.boolValue {
                guard let e = fm.enumerator(at: u, includingPropertiesForKeys: [.isRegularFileKey], options: [.skipsHiddenFiles, .skipsPackageDescendants]) else { continue }
                for case let f as URL in e where isImage(f) {
                    if (try? f.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true { out.append(f) }
                }
            } else if isImage(u) {
                out.append(u)
            }
        }
        return out.sorted { $0.path.localizedStandardCompare($1.path) == .orderedAscending }
    }

    static func isImage(_ u: URL) -> Bool {
        !u.lastPathComponent.hasPrefix(".") && extensions.contains(u.pathExtension.lowercased())
    }

    /// Decoded the way the phone meant it: EXIF orientation applied, longest side capped so OCR
    /// runs in reasonable time (the zoom pass still gets plenty of pixels).
    static func load(_ url: URL, maxSide: Int = 3000) -> CGImage? {
        guard let src = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
        let opts: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: maxSide,
            kCGImageSourceShouldCache: false,
        ]
        return CGImageSourceCreateThumbnailAtIndex(src, 0, opts as CFDictionary)
    }

    /// From the button or a drop: walks what was given and starts a run in the background.
    func start(_ urls: [URL]) {
        guard !running else { return }
        let files = Self.walk(urls)
        source = urls.count == 1 ? urls[0].lastPathComponent : "\(urls.count) items"
        guard !files.isEmpty else {
            reset(total: 0); state = .finished
            lines = [Line(file: source, text: "no photos found (jpg, jpeg, png, heic)", tone: .error)]
            return
        }
        runTask = Task { await run(files) }
    }

    /// Finishes the photo in hand, then stops.
    func stop() {
        guard state == .running else { return }
        stopRequested = true
        state = .stopping
    }

    /// Closes the sheet once a run has finished.
    func dismiss() {
        guard !running else { return }
        state = .idle
    }

    private func reset(total n: Int) {
        total = n; done = 0; matched = 0; attached = 0; parked = 0; duplicates = 0; errors = 0
        costUSD = 0; current = ""; step = ""; lines = []; stopped = false; stopRequested = false
        runID = UUID()
    }

    /// The run itself. Public so `--import` and `--scenario` can drive it and wait for it.
    func run(_ files: [URL]) async {
        guard !running, let app else { return }
        reset(total: files.count)
        state = .running
        app.collectionSync.paused = true
        defer { app.collectionSync.paused = false }
        let costAtStart = app.identifier.sessionCostUSD
        let stamp = Self.stamp.string(from: Date())
        let scan = app.scan
        for (i, url) in files.enumerated() {
            if stopRequested { stopped = true; break }
            current = url.lastPathComponent
            step = "loading"
            guard let img = Self.load(url) else {
                errors += 1; done += 1
                add(Line(file: url.lastPathComponent, text: "can't read this file", tone: .error)); continue
            }
            // Import names sort after the webcam's date stamps, so the photos folder stays in capture order.
            let name = "import-\(stamp)-\(String(format: "%03d", i + 1))"
            let fileName: String
            do { fileName = try scan.photos.save(img, name: name).lastPathComponent } catch {
                errors += 1; done += 1
                add(Line(file: url.lastPathComponent, text: "couldn't save the photo: \(error.localizedDescription)", tone: .error)); continue
            }
            let r = await scan.process(image: img, photo: fileName, expectLabel: false, sessionID: runID) { [weak self] s in self?.step = s }
            switch r {
            case .saved(let rec, let c, attached: true):
                matched += 1; attached += 1
                add(Line(file: url.lastPathComponent, text: "MATCH r\(c.result.id) \(rec.displayTitle) · photo added to the Discogs import", tone: .matched))
            case .saved(let rec, let c, attached: false):
                matched += 1
                add(Line(file: url.lastPathComponent, text: String(format: "MATCH r%d %@ · %.2f %@", c.result.id, rec.displayTitle, c.score, c.reasons.joined(separator: " ")), tone: .matched))
            case .duplicate(let existing, _, _):
                duplicates += 1
                try? FileManager.default.removeItem(at: scan.photos.root.appendingPathComponent(fileName))
                add(Line(file: url.lastPathComponent, text: "DUPLICATE of \(existing.displayTitle) · skipped", tone: .duplicate))
            case .ambiguous(let outcome, let close, let ranked):
                parked += 1
                scan.parkRecord(outcome: outcome, candidates: ranked, photo: fileName, expectLabel: false, sessionID: runID)
                add(Line(file: url.lastPathComponent, text: "AMBIGUOUS (\(close.count)) · parked for review: \(close.prefix(2).map(\.headline).joined(separator: " / "))", tone: .parked))
            case .notFound(let outcome, let ranked):
                parked += 1
                scan.parkRecord(outcome: outcome, candidates: ranked, photo: fileName, expectLabel: false, sessionID: runID)
                add(Line(file: url.lastPathComponent, text: "NOT FOUND · parked for review · \(outcome.readSummary)", tone: .parked))
            case .parked(_, let title, let detail):
                errors += 1
                add(Line(file: url.lastPathComponent, text: "\(title) · parked for review · \(detail)", tone: .error))
            }
            done += 1
            costUSD = app.identifier.sessionCostUSD - costAtStart
        }
        current = ""
        step = "finishing Discogs writes"
        await scan.awaitEnrichment()
        step = ""
        costUSD = app.identifier.sessionCostUSD - costAtStart
        state = .finished
        Log.scan.info("import \(stopped ? "stopped" : "finished"): \(summary)")
    }

    private func add(_ line: Line) {
        lines.append(line)
        if lines.count > 200 { lines.removeFirst(lines.count - 200) }
        onLine?(line)
    }

    var summary: String {
        var parts = ["\(matched) matched"]
        if attached > 0 { parts.append("\(attached) attached to Discogs imports") }
        parts.append("\(parked) parked")
        parts.append("\(duplicates) duplicate\(duplicates == 1 ? "" : "s")")
        parts.append("\(errors) error\(errors == 1 ? "" : "s")")
        return "\(done) of \(total) photos · " + parts.joined(separator: " · ")
    }

    private static let stamp: DateFormatter = {
        let f = DateFormatter(); f.dateFormat = "yyyyMMdd-HHmmss"; return f
    }()

    /// Fixture for `--render-ui`: a run half-way through, or a finished one.
    static func preview(finished: Bool) -> PhotoImporter {
        let p = PhotoImporter()
        p.source = "Vinyl photos"
        p.total = 40; p.done = finished ? 40 : 17; p.matched = finished ? 31 : 13; p.attached = 2
        p.parked = finished ? 5 : 2; p.duplicates = finished ? 3 : 1; p.errors = finished ? 1 : 1
        p.costUSD = finished ? 0.037 : 0.016
        p.state = finished ? .finished : .running
        p.current = finished ? "" : "IMG_4418.HEIC"
        p.step = finished ? "" : "GPT-5.6 Luna reading"
        p.lines = [
            Line(file: "IMG_4411.HEIC", text: "MATCH r2413807 The Jam — Going Underground · 0.94 catno title format", tone: .matched),
            Line(file: "IMG_4412.HEIC", text: "MATCH r1214563 The Specials — Ghost Town · photo added to the Discogs import", tone: .matched),
            Line(file: "IMG_4413.HEIC", text: "DUPLICATE of The Jam — Going Underground · skipped", tone: .duplicate),
            Line(file: "IMG_4414.HEIC", text: "AMBIGUOUS (5) · parked for review: NEW ORDER — BLUE MONDAY / NEW ORDER — BLUE MONDAY", tone: .parked),
            Line(file: "IMG_4415.HEIC", text: "DISCOGS ERROR · parked for review · Discogs is having trouble (HTTP 502) — try again", tone: .error),
            Line(file: "IMG_4416.HEIC", text: "NOT FOUND · parked for review · Model read: Donovan — Sunshine Superman · PYE 7N 17241", tone: .parked),
            Line(file: "IMG_4417.HEIC", text: "MATCH r5620127 The Clash — London Calling · 0.91 catno title", tone: .matched),
        ]
        return p
    }
}

/// The import sheet: progress, the four counts, the cost meter, the last few results, STOP while it
/// runs, and a summary that opens the Review tab when it is done. Presented from `RootView` so it
/// survives a tab change mid-run.
struct ImportSheet: View {
    @Environment(AppState.self) private var state
    let importer: PhotoImporter

    var body: some View {
        let finished = importer.state == .finished
        VStack(alignment: .leading, spacing: 18) {
            HStack(spacing: 14) {
                LogoMark(disc: Theme.raised).frame(width: 34, height: 34)
                VStack(alignment: .leading, spacing: 2) {
                    Text(finished ? (importer.stopped ? "IMPORT STOPPED" : "IMPORT FINISHED") : importer.state == .stopping ? "STOPPING AFTER THIS PHOTO" : "IMPORTING PHOTOS")
                        .font(Theme.display(30))
                    Text("\(importer.source.uppercased()) · \(state.format.rawValue) · \(state.identifier.hasAnyKey ? "OCR + \(state.identifier.provider.title.uppercased())" : "OCR ONLY — NO MODEL KEY")")
                        .font(Theme.mono(11)).tracking(1).foregroundStyle(Theme.muted).lineLimit(1)
                }
                Spacer()
                Text("\(importer.done) OF \(importer.total)").font(Theme.display(30)).foregroundStyle(finished ? Theme.green : Theme.amber)
            }
            GeometryReader { g in
                ZStack(alignment: .leading) {
                    Rectangle().fill(Theme.raised)
                    Rectangle().fill(finished ? Theme.green : Theme.amber)
                        .frame(width: g.size.width * (importer.total == 0 ? 0 : Double(importer.done) / Double(importer.total)))
                }
            }
            .frame(height: 6)
            HStack(spacing: 28) {
                meter("MATCHED", importer.matched, Theme.green)
                meter("PARKED", importer.parked, Theme.orange)
                meter("DUPLICATES", importer.duplicates, Theme.amber)
                meter("ERRORS", importer.errors, Theme.red)
                Spacer()
                VStack(alignment: .trailing, spacing: 2) {
                    Caption("LLM COST")
                    Text(String(format: "$%.3f", importer.costUSD)).font(Theme.display(26)).foregroundStyle(Theme.text)
                }
            }
            // No ScrollView here: the sheet renders under --render-ui, and the last few lines are what matter anyway.
            VStack(alignment: .leading, spacing: 5) {
                ForEach(importer.lines.suffix(7)) { l in
                    HStack(alignment: .top, spacing: 10) {
                        Text(l.file).font(Theme.mono(11)).foregroundStyle(Theme.muted).frame(width: 130, alignment: .leading).lineLimit(1)
                        Text(l.text).font(Theme.mono(11)).foregroundStyle(tone(l.tone)).lineLimit(1)
                    }
                }
                if !importer.current.isEmpty {
                    HStack(alignment: .top, spacing: 10) {
                        Text(importer.current).font(Theme.mono(11)).foregroundStyle(Theme.text).frame(width: 130, alignment: .leading).lineLimit(1)
                        Text(importer.step.isEmpty ? "…" : importer.step).font(Theme.mono(11)).foregroundStyle(Theme.amber).lineLimit(1)
                    }
                } else if !importer.step.isEmpty {
                    Text(importer.step).font(Theme.mono(11)).foregroundStyle(Theme.amber)
                }
            }
            .padding(12).frame(maxWidth: .infinity, minHeight: 150, alignment: .topLeading)
            .overlay(Rectangle().stroke(Theme.line, lineWidth: 1))
            if finished {
                Text(importer.summary + (importer.unresolved > 0 ? ". The parked photos are waiting in Review." : "."))
                    .font(Theme.mono(13)).foregroundStyle(Theme.secondary).fixedSize(horizontal: false, vertical: true)
            }
            HStack(spacing: 12) {
                if finished {
                    if importer.unresolved > 0 {
                        pill("OPEN REVIEW · \(importer.unresolved)", fill: true) { importer.dismiss(); state.tab = .review }
                    }
                    pill("DONE", fill: importer.unresolved == 0) { importer.dismiss() }
                } else {
                    pill(importer.state == .stopping ? "STOPPING…" : "STOP", fill: false) { importer.stop() }
                        .disabled(importer.state == .stopping)
                    Text("Finishes the photo in hand, then stops. Nothing already saved is undone.")
                        .font(Theme.mono(11)).foregroundStyle(Theme.muted)
                }
                Spacer()
            }
        }
        .padding(28)
        .frame(width: 720, alignment: .leading)
        .background(Theme.bg)
        .overlay(alignment: .top) { Rectangle().fill(finished ? Theme.green : Theme.amber).frame(height: 4) }
        .foregroundStyle(Theme.text)
        .preferredColorScheme(.dark)
        .interactiveDismissDisabled(!finished)
    }

    private func meter(_ title: String, _ n: Int, _ color: Color) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Caption(title)
            Text("\(n)").font(Theme.display(26)).foregroundStyle(n > 0 ? color : Theme.muted)
        }
    }

    private func tone(_ t: PhotoImporter.Line.Tone) -> Color {
        switch t { case .matched: Theme.green; case .parked: Theme.orange; case .duplicate: Theme.amber; case .error: Theme.red }
    }

    private func pill(_ title: String, fill: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title).font(Theme.mono(12)).tracking(1).lineLimit(1).fixedSize()
                .foregroundStyle(fill ? Theme.bg : Theme.green)
                .padding(.horizontal, 14).frame(height: 30)
                .background(fill ? Theme.green : .clear)
                .overlay(Rectangle().stroke(Theme.green, lineWidth: 1))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

/// The "+ IMPORT PHOTOS" picker: a folder, or the photos themselves.
enum ImportPicker {
    @MainActor static func choose(then start: @escaping ([URL]) -> Void) {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = true
        panel.allowsMultipleSelection = true
        panel.allowedContentTypes = [.folder, .jpeg, .png, .heic]
        panel.message = "Pick a folder of label or cover photos, or the photos themselves. Each one is identified and saved, or parked in Review."
        panel.prompt = "Import"
        panel.begin { resp in
            guard resp == .OK, !panel.urls.isEmpty else { return }
            start(panel.urls)
        }
    }
}
