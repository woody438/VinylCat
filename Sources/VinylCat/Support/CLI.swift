import AppKit
import AVFoundation
import Foundation
import Speech
import SwiftUI

/// Headless entry points for testing without a screen:
///   VinylCat --diagnose                 permissions, devices, keys, Discogs, store
///   VinylCat --render-ui <dir>          renders every screen/state to PNG
///   VinylCat --make-test-images <dir>   synthetic label/cover photos
///   VinylCat --pipeline-test <image>…   local OCR → Discogs → rank (no vision model)
///   VinylCat --discogs-test <catno>…    what each catalogue number actually finds on Discogs
///   VinylCat --export-feedback [dir]    thumbs-up/down verdicts with their evidence → output/vinylcat_feedback_vN_date.jsonl
@MainActor
enum CLI {
    static func run(_ args: [String]) -> Int32? {
        guard let flag = args.first(where: { $0.hasPrefix("--") }), flag != "--self-test" else { return nil }
        let rest = Array(args.drop(while: { $0 != flag }).dropFirst())
        switch flag {
        case "--diagnose": return diagnose()
        case "--render-ui": return renderUI(dir: rest.first ?? "ui-renders")
        case "--make-test-images": return makeTestImages(dir: rest.first ?? "test-images")
        case "--pipeline-test": return runBlocking { await pipelineTest(paths: rest) }
        case "--scenario": return runBlocking { await scenario(dir: rest.first ?? "test-images") }
        case "--discogs-test": return runBlocking { await discogsTest(terms: rest) }
        case "--ocr-eval": return runBlocking { await ocrEval(limit: Int(rest.first(where: { Int($0) != nil }) ?? "") ?? 0, model: rest.contains("--model")) }
        case "--export-feedback":
            do {
                let url = try Store.shared.exportFeedback(to: URL(fileURLWithPath: rest.first ?? "output"))
                print("\(Store.shared.feedbackCount()) verdicts → \(url.path)"); return 0
            } catch { print("export failed: \(error.localizedDescription)"); return 1 }
        case "--camera-test": return runBlocking { await cameraTest(name: rest.first ?? "iPhone", seconds: Double(rest.dropFirst().first ?? "8") ?? 8, out: rest.dropFirst(2).first ?? "camera-test") }
        case "--model-test": return runBlocking {
            guard let img = SetupWizard.testLabelImage() else { return 1 }
            let provider = Identifier().provider
            do {
                let r = try await provider.reader.read(img, hints: .init(sessionFormat: "seven inch singles", expectLabel: true))
                print("OK \(r.provider): \(r.reading) · $\(String(format: "%.5f", r.usage.costUSD)) · \(r.usage.inputTokens)+\(r.usage.outputTokens) tokens")
                return 0
            } catch { print("FAILED \(error.localizedDescription)"); return 1 }
        }
        default: return nil
        }
    }

    private static func runBlocking(_ body: @escaping @MainActor () async -> Int32) -> Int32 {
        var result: Int32 = 1
        let sem = DispatchSemaphore(value: 0)
        Task { @MainActor in result = await body(); sem.signal() }
        while sem.wait(timeout: .now()) != .success { RunLoop.main.run(until: Date().addingTimeInterval(0.05)) }
        return result
    }

    // MARK: diagnose

    static func diagnose() -> Int32 {
        func auth(_ s: AVAuthorizationStatus) -> String { ["notDetermined", "restricted", "denied", "authorized"][Int(s.rawValue)] }
        print("VinylCat diagnose")
        print("camera      \(auth(AVCaptureDevice.authorizationStatus(for: .video)))")
        print("microphone  \(auth(AVCaptureDevice.authorizationStatus(for: .audio)))")
        let sp = SFSpeechRecognizer.authorizationStatus()
        print("speech      \(["notDetermined", "denied", "restricted", "authorized"][Int(sp.rawValue)])")
        let d = AVCaptureDevice.DiscoverySession(deviceTypes: [.builtInWideAngleCamera, .continuityCamera, .external], mediaType: .video, position: .unspecified)
        print("cameras     \(d.devices.map { "\($0.localizedName) [\($0.deviceType.rawValue)] \($0.uniqueID)" }.joined(separator: "\n            "))")
        let rec = SFSpeechRecognizer(locale: Locale(identifier: "en-GB"))
        print("recogniser  available=\(rec?.isAvailable ?? false) onDevice=\(rec?.supportsOnDeviceRecognition ?? false)")
        print("mics        \(AudioInputs.list().map(\.name))")
        print("voices(en)  \(Speaker.availableVoices.count)  e.g. \(Speaker.availableVoices.prefix(3).map(\.name))")
        for k in Keychain.Key.allCases { print("key         \(k.rawValue): \(Keychain.get(k) == nil ? "missing" : "set") ") }
        print("provider    \(Identifier().provider.title)")
        let store = Store.shared
        print("store       \(store.url.path) · \(store.count()) records · \(store.reviewCount()) in review")
        print("photos      \(PhotoStore.shared.root.path) · \((try? FileManager.default.contentsOfDirectory(atPath: PhotoStore.shared.root.path))?.count ?? 0) files")
        return runBlocking {
            let dc = DiscogsClient()
            do {
                let r = try await dc.search(catno: "POSP 113", format: "7\"")
                print("discogs     reachable · \(r.count) hits for POSP 113 · \(dc.rateText)\(Keychain.get(.discogsToken) == nil ? " (no token: read-only, 25/min)" : "")")
            } catch { print("discogs     FAILED \(error.localizedDescription)") }
            return 0
        }
    }

    // MARK: render UI

    static func renderUI(dir: String) -> Int32 {
        let out = URL(fileURLWithPath: dir)
        try? FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
        UserDefaults.standard.set(true, forKey: "setupCompleted")
        let state = AppState()
        state.scan.appState = state
        state.tour.suppressAutoStart = true
        state.reviewCount = Store.shared.reviewCount()   // so the REVIEW tab badge renders
        let phases: [(String, ScanPhase)] = [
            ("scan-1-armed", .armed(reason: "empty")),
            ("scan-2-reading", .reading(step: "GPT-5.6 Luna reading")),
            ("scan-3-matched", .matched(title: "THE JAM — GOING UNDERGROUND", detail: "1980 · 7\" · POLYDOR POSP 113 · UK", meta: "0.94 · r2413807 · catno title format")),
            ("scan-4-ambiguous", .ambiguous(candidates: [
                ScanChoice(title: "THE JAM — GOING UNDERGROUND", detail: "POLYDOR POSP 113 · UK · 1980 · 7\""),
                ScanChoice(title: "THE JAM — GOING UNDERGROUND", detail: "POLYDOR 2059 227 · GERMANY · 1980 · 7\""),
                ScanChoice(title: "THE JAM — GOING UNDERGROUND / DREAMS OF CHILDREN", detail: "POLYDOR POSPX 113 · UK · 1980 · 12\""),
            ])),
            ("scan-5-needlabel", .needLabel(guess: "THE FALL — ?")),
            ("scan-5b-retry", .retry(guess: "THE FALL — ?", detail: "Read: ROUGH TRADE · RT 0?? · TOTALE'S TURNS")),
            ("scan-6-awaiting", .awaitingShot(kind: "DISC 2 · SIDE C", index: 5, total: 6, header: "The Clash — London Calling · 2×LP")),
            ("scan-7-notfound", .notFound(guess: "SUNSHINE SUPERMAN — DONOVAN?", detail: "Read: PYE · 7N.1?9?? · SUNSHINE SUPERMAN · DONOVAN")),
            ("scan-8-duplicate", .duplicate(title: "THE SPECIALS — GHOST TOWN")),
        ]
        var written = 0
        for (name, phase) in phases {
            let view = RootView().environment(state).frame(width: 1440, height: 900).background(Theme.bg).preferredColorScheme(.dark)
                .environment(\.previewPhase, phase)
            if render(view, to: out.appendingPathComponent("\(name).png")) { written += 1 }
        }
        for i in 0..<6 {
            let view = RootView().environment(state).frame(width: 1440, height: 900).background(Theme.bg).preferredColorScheme(.dark)
                .environment(\.previewSetupStep, i)
            if render(view, to: out.appendingPathComponent("setup-\(i + 1).png")) { written += 1 }
        }
        for (name, tab) in [("library", AppTab.library), ("review", .review), ("settings", .settings)] {
            state.tab = tab
            let view = RootView().environment(state).frame(width: 1440, height: 900).background(Theme.bg).preferredColorScheme(.dark)
                .environment(\.staticRender, true)
            if render(view, to: out.appendingPathComponent("\(name).png")) { written += 1 }
        }
        // Every callout of the first-run tour, on the tab it belongs to.
        for i in TourStep.all.indices {
            state.tour.show(i)
            let view = RootView().environment(state).frame(width: 1440, height: 900).background(Theme.bg).preferredColorScheme(.dark)
                .environment(\.previewPhase, .armed(reason: "empty"))
            if render(view, to: out.appendingPathComponent(String(format: "tour-%02d-%@.png", i + 1, TourStep.all[i].anchor.rawValue))) { written += 1 }
        }
        state.tour.hide()
        // Every rung of the coffee ladder: the footer line at 25, the card at 100 and 250, the card
        // again at 500 (the launch sheet is drawn flat below), and the narrow card on the paused rail.
        // The setters persist, so keep the real answers and put them back afterwards.
        let (savedDismissed, savedSupporter) = (state.coffee.dismissedAt, state.coffee.supporter)
        state.coffee.dismissedAt = 0
        state.coffee.supporter = false
        for n in [25, 100, 250, 512] {
            state.coffee.previewCount = n
            state.tab = .library
            let view = RootView().environment(state).frame(width: 1440, height: 900).background(Theme.bg).preferredColorScheme(.dark)
                .environment(\.staticRender, true)
            if render(view, to: out.appendingPathComponent("coffee-library-\(n).png")) { written += 1 }
        }
        state.coffee.previewCount = 250
        state.tab = .scan
        if render(RootView().environment(state).frame(width: 1440, height: 900).background(Theme.bg).preferredColorScheme(.dark)
                    .environment(\.previewPhase, .paused), to: out.appendingPathComponent("coffee-scan-paused.png")) { written += 1 }
        if render(CoffeeSheet(milestone: 500, count: 512, value: "GBP 4,180").environment(state), to: out.appendingPathComponent("coffee-sheet-500.png")) { written += 1 }
        if render(CoffeeSheet(milestone: 1000, count: 1043, value: nil).environment(state), to: out.appendingPathComponent("coffee-sheet-1000.png")) { written += 1 }
        state.coffee.previewCount = nil
        state.coffee.dismissedAt = savedDismissed
        state.coffee.supporter = savedSupporter
        state.tab = .scan
        // Rows live in a ScrollView, which ImageRenderer leaves blank; render a few directly.
        let rows = Array(Store.shared.all().prefix(4))
        if !rows.isEmpty {
            let view = VStack(spacing: 0) {
                ForEach(Array(rows.enumerated()), id: \.element.id) { i, r in LibraryRow(record: r, selected: i == 1) }
            }
            .frame(width: 1040).background(Theme.bg).preferredColorScheme(.dark)
            if render(view, to: out.appendingPathComponent("library-rows.png")) { written += 1 }
        }
        // The Library's typed-entry panel (its results list scrolls, so only the form renders).
        if render(ManualEntryView(onSaved: { _ in }, onCancel: {}).frame(width: 400, height: 640).background(Theme.bg).environment(state).preferredColorScheme(.dark),
                  to: out.appendingPathComponent("library-add.png")) { written += 1 }
        // Three separate items: SessionItem's id is fixed at init, so copies would collapse in a ForEach.
        let thumbs = Store.shared.all().first.map { r -> [SessionItem] in [
            SessionItem(recordID: r.id, thumbnail: nil, title: "The Jam — Going Underground", meta: "1980 · 7\" · POLYDOR POSP 113 · 1 shot", tone: .normal),
            SessionItem(recordID: r.id, thumbnail: nil, title: "The Specials — Ghost Town", meta: "1981 · 7\" · 2 TONE CHS TT 17 · 2 shots", tone: .normal, verdict: .up),
            SessionItem(recordID: r.id, thumbnail: nil, title: "Station C — The Way To Paradise", meta: "wrong record · REVIEW QUEUE", tone: .rejected, verdict: .down),
        ] } ?? []
        if !thumbs.isEmpty {
            let view = VStack(alignment: .leading, spacing: 10) { ForEach(thumbs) { SessionRow(item: $0) } }
                .padding(20).frame(width: 360).background(Theme.bg).environment(state).preferredColorScheme(.dark)
            if render(view, to: out.appendingPathComponent("session-rows.png")) { written += 1 }
        }
        print("rendered \(written) screens to \(out.path)")
        return written > 0 ? 0 : 1
    }

    private static func render<V: View>(_ view: V, to url: URL) -> Bool {
        let renderer = ImageRenderer(content: view)
        renderer.scale = 1
        guard let cg = renderer.cgImage else { print("render failed: \(url.lastPathComponent)"); return false }
        let rep = NSBitmapImageRep(cgImage: cg)
        guard let data = rep.representation(using: .png, properties: [:]) else { return false }
        do { try data.write(to: url); return true } catch { print("write failed: \(error)"); return false }
    }

    // MARK: OCR evaluation

    /// Runs LocalReader over the real photos in the store and scores it against what the record ended
    /// up as: did the catalogue number (or barcode) come out of the OCR? Prints per-photo misses.
    /// `--model` also sends each photo (with its close-ups) to the configured vision model and scores
    /// its catalogNumber / otherNumbers the same way; costs real money, a fraction of a cent a photo.
    /// Env: VINYLCAT_EVAL_VERBOSE=1 prints the OCR lines for ranked misses too; VINYLCAT_EVAL_DUMP=<dir>
    /// writes every close-up crop as PNG, for checking what the zoom pass is looking at.
    static func ocrEval(limit: Int, model useModel: Bool) async -> Int32 {
        let records = Store.shared.live().filter { $0.discogsReleaseID != nil && !$0.photos.isEmpty && ($0.catalogNumber ?? "").count > 1 }
        let subset = limit > 0 ? Array(records.prefix(limit)) : records
        let verbose = ProcessInfo.processInfo.environment["VINYLCAT_EVAL_VERBOSE"] != nil
        let dump = ProcessInfo.processInfo.environment["VINYLCAT_EVAL_DUMP"].map { URL(fileURLWithPath: $0) }
        if let dump { try? FileManager.default.createDirectory(at: dump, withIntermediateDirectories: true) }
        var photosSeen = 0, catnoHits = 0, catnoExact = 0, catnoFirst = 0, barcodeHits = 0, barcodeExpected = 0, lines = 0, unreadable = 0, crops = 0, closeUps = 0
        var total = 0.0
        var recordHit = 0
        var modelSeen = 0, modelFirst = 0, modelAny = 0, modelCost = 0.0, modelTime = 0.0, eitherFirst = 0
        let reader = useModel ? (ReaderProvider(rawValue: UserDefaults.standard.string(forKey: "readerProvider") ?? "") ?? .luna).reader : nil
        for r in subset {
            let want = CatalogueNumber.normalize(r.catalogNumber ?? "")
            var anyHit = false
            for p in r.sortedPhotos {
                guard let img = NSImage(contentsOf: p.url)?.cgImage(forProposedRect: nil, context: nil, hints: nil) else { continue }
                photosSeen += 1
                let t0 = Date()
                guard let local = try? await LocalReader.read(img) else { continue }
                total += Date().timeIntervalSince(t0)
                lines += local.lines.count
                crops += local.zoomCrops
                closeUps += local.closeUps.count
                if local.lines.isEmpty { unreadable += 1 }
                if let dump {
                    for (i, c) in local.closeUps.enumerated() {
                        let rep = NSBitmapImageRep(cgImage: c)
                        try? rep.representation(using: .png, properties: [:])?.write(to: dump.appendingPathComponent("\(p.fileName.replacingOccurrences(of: ".jpg", with: ""))-\(i + 1).png"))
                    }
                }
                let cands = local.catalogueCandidates
                let exact = cands.contains { CatalogueNumber.compare($0, want) == .exact }
                let hit = exact || cands.contains { [.near, .partial].contains(CatalogueNumber.compare($0, want)) }
                if exact { catnoExact += 1 }
                if hit { catnoHits += 1; anyHit = true }
                var localFirst = false
                if let f = cands.first, CatalogueNumber.compare(f, want) != .none { catnoFirst += 1; localFirst = true }
                else if hit, let at = cands.firstIndex(where: { CatalogueNumber.compare($0, want) != .none }) {
                    print("  rank \(at + 1)  want \(want)  ahead: \(cands.prefix(at).joined(separator: ", "))")
                    if verbose { print("        ocr: \(local.lines.prefix(8).joined(separator: " | ").prefix(200))") }
                }
                if let b = r.barcode, b.count >= 8 { barcodeExpected += 1; if local.barcodes.contains(b) { barcodeHits += 1 } }
                if !hit {
                    print(String(format: "  miss  %-28@ want %-10@ got %@  · %@", "\(r.artist) — \(r.title)".prefix(28) as NSString, want as NSString,
                                 local.catalogueCandidates.prefix(4).joined(separator: ", ") as NSString, p.kind.rawValue as NSString))
                    print("        ocr: \(local.lines.prefix(6).joined(separator: " | ").prefix(150))")
                }
                if let reader {
                    let hints = ReadHints(ocrText: local.text, barcodes: local.barcodes, sessionFormat: ScanController.spoken(format: r.format, discs: r.discCount), expectLabel: p.kind != .coverFront && p.kind != .coverBack, closeUps: local.closeUps)
                    let t1 = Date()
                    do {
                        let res = try await reader.read(img, hints: hints)
                        modelTime += Date().timeIntervalSince(t1)
                        modelSeen += 1
                        modelCost += res.usage.costUSD
                        let m = res.reading
                        let first = m.catalogNumber.map { CatalogueNumber.compare($0, want) != .none } ?? false
                        let any = first || (m.otherNumbers ?? []).contains { CatalogueNumber.compare($0, want) != .none }
                        if first { modelFirst += 1 }
                        if any { modelAny += 1 }
                        if first || localFirst { eitherFirst += 1 }
                        if !first {
                            print("  model \(any ? "rank>1" : "miss  ") want \(want)  said \(m.catalogNumber ?? "nil")  others: \((m.otherNumbers ?? []).joined(separator: ", "))  · \(p.kind.rawValue)\(localFirst ? "  (ocr had it)" : "")")
                        }
                    } catch {
                        print("  model error: \(error.localizedDescription)")
                    }
                }
            }
            if anyHit { recordHit += 1 }
        }
        print("\nocr-eval · \(subset.count) records · \(photosSeen) photos")
        print(String(format: "  catno in candidates  %3d / %3d photos  (%.0f%%)   exact %3d (%.0f%%)   first candidate usable %3d (%.0f%%)", catnoHits, photosSeen, 100.0 * Double(catnoHits) / Double(max(1, photosSeen)), catnoExact, 100.0 * Double(catnoExact) / Double(max(1, photosSeen)), catnoFirst, 100.0 * Double(catnoFirst) / Double(max(1, photosSeen))))
        print(String(format: "  catno per record     %3d / %3d records (%.0f%%)", recordHit, subset.count, 100.0 * Double(recordHit) / Double(max(1, subset.count))))
        print(String(format: "  barcode read         %3d / %3d photos with one", barcodeHits, barcodeExpected))
        print(String(format: "  lines/photo %.1f · unreadable %d · %.2fs per photo · zoom crops/photo %.1f · close-ups/photo %.1f", Double(lines) / Double(max(1, photosSeen)), unreadable, total / Double(max(1, photosSeen)), Double(crops) / Double(max(1, photosSeen)), Double(closeUps) / Double(max(1, photosSeen))))
        if useModel {
            print(String(format: "  model catno usable   %3d / %3d photos  (%.0f%%)   in catno+others %3d (%.0f%%)   model or OCR first %3d (%.0f%%)", modelFirst, modelSeen, 100.0 * Double(modelFirst) / Double(max(1, modelSeen)), modelAny, 100.0 * Double(modelAny) / Double(max(1, modelSeen)), eitherFirst, 100.0 * Double(eitherFirst) / Double(max(1, modelSeen))))
            print(String(format: "  model cost $%.4f total · $%.5f per photo · %.1fs per photo", modelCost, modelCost / Double(max(1, modelSeen)), modelTime / Double(max(1, modelSeen))))
        }
        return 0
    }

    // MARK: synthetic test images

    static func makeTestImages(dir: String) -> Int32 {
        let out = URL(fileURLWithPath: dir)
        try? FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
        let labels: [(String, [String], NSColor)] = [
            ("label-jam-posp113", ["POLYDOR", "POSP 113", "45 RPM", "GOING UNDERGROUND", "(Weller)", "THE JAM", "SIDE A", "1980"], NSColor(red: 0.85, green: 0.1, blue: 0.1, alpha: 1)),
            ("label-specials-chstt17", ["2 TONE", "CHS TT 17", "45 RPM", "GHOST TOWN", "(Dammers)", "THE SPECIALS", "A"], NSColor(white: 0.15, alpha: 1)),
            ("label-neworder-fac73", ["FACTORY", "FAC 73", "33 RPM", "BLUE MONDAY", "NEW ORDER", "SIDE ONE", "1983"], NSColor(red: 0.1, green: 0.2, blue: 0.6, alpha: 1)),
            ("cover-clash-clash3", ["THE CLASH", "LONDON CALLING", "CBS CLASH 3", "STEREO"], NSColor(white: 0.05, alpha: 1)),
            // Album label: the scenario scans an LP from its label to prove the identifying shot alone closes the record.
            ("label-jam-pold5008", ["POLYDOR", "POLD 5008", "33 RPM", "ALL MOD CONS", "(Weller)", "THE JAM", "SIDE ONE", "1978"], NSColor(red: 0.85, green: 0.1, blue: 0.1, alpha: 1)),
        ]
        var n = 0
        for (name, lines, colour) in labels {
            let size = NSSize(width: 1400, height: 1000)
            let img = NSImage(size: size)
            img.lockFocus()
            NSColor(white: 0.35, alpha: 1).setFill(); NSRect(origin: .zero, size: size).fill()
            let isCover = name.hasPrefix("cover")
            if isCover {
                colour.setFill(); NSRect(x: 250, y: 50, width: 900, height: 900).fill()
            } else {
                NSColor.black.setFill(); NSBezierPath(ovalIn: NSRect(x: 220, y: 20, width: 960, height: 960)).fill()
                colour.setFill(); NSBezierPath(ovalIn: NSRect(x: 460, y: 260, width: 480, height: 480)).fill()
                NSColor(white: 0.35, alpha: 1).setFill(); NSBezierPath(ovalIn: NSRect(x: 685, y: 485, width: 30, height: 30)).fill()
            }
            let para = NSMutableParagraphStyle(); para.alignment = .center
            var y: CGFloat = isCover ? 780 : 640
            for (i, line) in lines.enumerated() {
                let big = isCover ? i < 2 : i == 3 || i == 5
                let attrs: [NSAttributedString.Key: Any] = [
                    .font: NSFont.systemFont(ofSize: big ? (isCover ? 72 : 30) : 22, weight: big ? .heavy : .medium),
                    .foregroundColor: NSColor.white, .paragraphStyle: para,
                ]
                let h: CGFloat = big ? (isCover ? 90 : 40) : 30
                if !isCover, i == 4 { y -= 8 }
                (line as NSString).draw(in: NSRect(x: 300, y: y, width: 800, height: h), withAttributes: attrs)
                y -= h + (isCover ? 20 : 4)
                if !isCover, i == 2 { y -= 100 }   // leave the spindle hole area clear
            }
            img.unlockFocus()
            guard let tiff = img.tiffRepresentation, let rep = NSBitmapImageRep(data: tiff), let png = rep.representation(using: .png, properties: [:]) else { continue }
            try? png.write(to: out.appendingPathComponent("\(name).png"))
            n += 1
        }
        print("wrote \(n) test images to \(out.path)")
        return 0
    }

    // MARK: pipeline test

    static func pipelineTest(paths: [String]) async -> Int32 {
        let dc = DiscogsClient()
        var failures = 0
        for p in paths {
            guard let img = NSImage(contentsOfFile: p)?.cgImage(forProposedRect: nil, context: nil, hints: nil) else { print("cannot load \(p)"); failures += 1; continue }
            print("\n== \(p)")
            do {
                let t0 = Date()
                let local = try await LocalReader.read(img)
                print("  ocr \(String(format: "%.2fs", Date().timeIntervalSince(t0))): \(local.lines.joined(separator: " | "))")
                print("  barcodes: \(local.barcodes)  catno candidates: \(local.catalogueCandidates)")
                var reading = SleeveReading()
                reading.catalogNumber = local.catalogueCandidates.first
                reading.barcode = local.barcodes.first
                // Without a vision model, take the longest OCR lines as title/artist hints.
                let words = local.lines.filter { $0.count > 5 && !$0.contains(where: \.isNumber) && !$0.hasPrefix("(") }
                reading.title = words.dropFirst().first ?? words.first; reading.artist = words.dropFirst(2).first ?? words.first
                let fmt: VinylFormat? = p.contains("cover") || p.contains("pold5008") ? .lp : p.contains("fac73") ? .twelve : .seven
                let t1 = Date()
                let (verdict, ranked) = try await Matcher(discogs: dc).find(reading: reading, sessionFormat: fmt, catalogueAlternates: local.catalogueCandidates)
                print("  discogs \(String(format: "%.2fs", Date().timeIntervalSince(t1))) · \(ranked.count) candidates · \(dc.rateText)")
                for c in ranked.prefix(3) { print(String(format: "    %.2f  %@  [%@]  %@", c.score, c.result.title, c.reasons.joined(separator: " "), c.summary)) }
                switch verdict {
                case .match(let c): print("  → MATCH r\(c.result.id) \(c.result.title)")
                case .ambiguous(let cs): print("  → AMBIGUOUS (\(cs.count))")
                case .none: print("  → NOT FOUND"); failures += 1
                }
            } catch { print("  FAILED \(error.localizedDescription)"); failures += 1 }
        }
        return failures == 0 ? 0 : 1
    }
}

extension CLI {
    /// Reports what Discogs returns for each catalogue number, as catno= and as a plain query.
    static func discogsTest(terms: [String]) async -> Int32 {
        let dc = DiscogsClient()
        for term in terms {
            for (label, run) in [("catno=", { try await dc.search(catno: term) }),
                                 ("q=", { try await dc.search(query: term) })] as [(String, () async throws -> [DiscogsClient.SearchResult])] {
                do {
                    let hits = try await run()
                    print("\(label)\(term)  → \(hits.count) hits")
                    for h in hits.prefix(3) { print("     \(h.title) · \(h.catno ?? "—") · \(h.year ?? "—") · \(h.format?.joined(separator: "/") ?? "—")") }
                } catch { print("\(label)\(term)  → FAILED \(error.localizedDescription)") }
            }
        }
        return 0
    }

    /// Opens a camera by (partial) name, reports its state, streams for a few seconds and saves a frame.
    static func cameraTest(name: String, seconds: Double, out: String) async -> Int32 {
        let d = AVCaptureDevice.DiscoverySession(deviceTypes: [.builtInWideAngleCamera, .continuityCamera, .external], mediaType: .video, position: .unspecified)
        guard let dev = d.devices.first(where: { $0.localizedName.localizedCaseInsensitiveContains(name) }) else {
            print("no camera matching “\(name)”: \(d.devices.map(\.localizedName))"); return 1
        }
        print("device      \(dev.localizedName) · type \(dev.deviceType.rawValue) · connected \(dev.isConnected) · suspended \(dev.isSuspended) · inUse \(dev.isInUseByAnotherApplication)")
        print("format      \(dev.activeFormat.formatDescription) · \(dev.formats.count) formats · fps \(dev.activeVideoMinFrameDuration.timescale)/\(dev.activeVideoMinFrameDuration.value)")
        let cam = CameraSession()
        cam.selectedDeviceID = dev.uniqueID
        await cam.start()
        let engine = FrameAnalyzer()
        var n = 0, saved = false
        let deadline = Date().addingTimeInterval(seconds)
        let outURL = URL(fileURLWithPath: out)
        try? FileManager.default.createDirectory(at: outURL, withIntermediateDirectories: true)
        for await frame in cam.frames {
            n += 1
            let g = engine.greyscale(frame.pixelBuffer)
            let m = engine.analyze(g)
            let mean = g.reduce(0) { $0 + Int($1) } / max(1, g.count)
            if n % 10 == 1 { print(String(format: "frame %3d  %dx%d  mean %3d  sharp %.0f  motion %.1f", n, CVPixelBufferGetWidth(frame.pixelBuffer), CVPixelBufferGetHeight(frame.pixelBuffer), mean, m.sharpness, m.motion)) }
            if !saved, n >= 20, let ci = Optional(CIImage(cvPixelBuffer: frame.pixelBuffer)), let cg = CIContext().createCGImage(ci, from: ci.extent) {
                if let u = try? PhotoStore(root: outURL).save(cg, name: dev.localizedName.replacingOccurrences(of: " ", with: "-"), maxSide: 800) { print("saved       \(u.path)"); saved = true }
            }
            if Date() > deadline { break }
        }
        print("status      \(cam.status) · \(n) frames in \(Int(seconds)) s")
        cam.stop()
        return n > 0 ? 0 : 1
    }

    /// End-to-end run of the real ScanController against a temp store with synthetic stills (live Discogs, no model).
    static func scenario(dir: String) async -> Int32 {
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("vinylcat-scenario-\(UUID().uuidString)")
        let store = Store(url: tmp.appendingPathComponent("db.sqlite"))
        let photos = PhotoStore(root: tmp.appendingPathComponent("photos"))
        let state = AppState(store: store, photos: photos)
        state.scan.appState = state
        state.scan.speaker.enabled = false
        state.scan.syncToCollection = false   // fixtures must not land in the real Discogs collection
        var failures = 0
        func check(_ c: Bool, _ label: String) { print("  \(c ? "ok  " : "FAIL") \(label)"); if !c { failures += 1 } }
        func still(_ name: String) -> CapturedStill? {
            let p = URL(fileURLWithPath: dir).appendingPathComponent("\(name).png").path
            guard let img = NSImage(contentsOfFile: p)?.cgImage(forProposedRect: nil, context: nil, hints: nil) else { print("missing \(p)"); return nil }
            return CapturedStill(image: img, capturedAt: Date(), metrics: FrameMetrics(sharpness: 200, motion: 0, sceneDelta: 50, hash: 0), forced: false)
        }
        func phaseName(_ p: ScanPhase) -> String { "\(p)".components(separatedBy: "(").first ?? "\(p)" }
        let scan = state.scan
        print("scenario · 7\" single: match → done (no extra shots) → “flip” reopens for the B-side")
        state.format = .seven
        guard let jam = still("label-jam-posp113"), let specials = still("label-specials-chstt17"), let clash = still("cover-clash-clash3"),
              let allModCons = still("label-jam-pold5008") else { return 1 }
        await scan.inject(still: jam)
        check(scan.current == nil && store.count() == 1, "confident match closes the record immediately (phase \(phaseName(scan.phase)))")
        check(store.all().first?.discogsReleaseID != nil && store.all().first?.photos.count == 1, "record saved with Discogs id \(store.all().first?.discogsReleaseID ?? 0), one photo")
        scan.handle(command: .flip)
        check({ if case .awaitingShot(let k, _, _, _) = scan.phase { return k == "B-SIDE LABEL" } else { return false } }(), "“flip” reopens the last record and asks for the B-side (phase \(phaseName(scan.phase)))")
        await scan.inject(still: jam)
        check(scan.current == nil, "after B-side: record closed again (phase \(phaseName(scan.phase)))")
        let r1 = store.all().first
        check(r1?.photos.count == 2 && r1?.photos.map(\.kind) == [.labelA, .labelB], "2 photos tagged A/B")
        check(r1?.artist == "The Jam" && r1?.format == "7\"" && r1?.catalogNumber?.uppercased() == "POSP 113", "fields: \(r1?.artist ?? "") · \(r1?.format ?? "") · \(r1?.catalogNumber ?? "")")

        print("scenario · duplicate → add anyway")
        await scan.inject(still: jam)
        check({ if case .duplicate = scan.phase { return true } else { return false } }(), "same record again → duplicate (phase \(phaseName(scan.phase)))")
        scan.handle(command: .addAnyway)
        for _ in 0..<40 where store.count() < 2 { try? await Task.sleep(for: .milliseconds(250)) }
        check(store.count() == 2 && scan.current == nil, "add anyway creates a second copy and closes it (count \(store.count()))")

        print("scenario · second single, then manual extra photo")
        await scan.inject(still: specials)
        check(store.all().first?.artist == "The Specials" && scan.current == nil, "matched The Specials, closed (got \(store.all().first?.artist ?? "nil"))")
        if let sp = store.all().first {
            let ev = store.evidence(for: sp.id)
            check(ev?.chosenReleaseID == sp.discogsReleaseID && !(ev?.candidates.isEmpty ?? true) && !(ev?.ocrLines.isEmpty ?? true), "evidence saved with the match: \(ev?.candidates.count ?? 0) candidates, \(ev?.ocrLines.count ?? 0) OCR lines")
        }
        scan.handle(command: .addPhoto)
        await scan.inject(still: specials)
        check(store.all().first?.photos.count == 2 && store.all().first?.photos.last?.kind == .other, "“add photo” attaches an extra shot to the last record")
        scan.handle(command: .done)

        print("scenario · album → one shot closes the record")
        state.format = .lp
        await scan.inject(still: clash)
        let clashRec0 = store.all().first
        check(scan.current == nil && clashRec0?.format == "LP" && clashRec0?.photos.map(\.kind) == [.coverFront],
              "LP from its cover: the identifying shot only, closed (phase \(phaseName(scan.phase)), photos \(clashRec0?.photos.map(\.kind.rawValue) ?? []))")
        if let r = clashRec0 { await scan.delete(r.id) }
        await scan.inject(still: allModCons)
        let amc = store.all().first
        check(scan.current == nil && amc?.title == "All Mod Cons" && amc?.format == "LP" && amc?.photos.map(\.kind) == [.labelA],
              "LP identified from its label: no front cover asked, closed (phase \(phaseName(scan.phase)), got \(amc?.title ?? "nil"))")
        if let r = amc { await scan.delete(r.id) }

        print("scenario · album, then “back cover” by hand → undo → done")
        await scan.inject(still: clash)
        let clashRec = store.all().first
        print("scenario · thumbs-down on a just-scanned record")
        if let open = clashRec {
            let before = store.count()
            scan.handle(command: .wrong)
            let rej = store.fetch(open.id)
            check(rej?.status == .rejected && scan.current == nil && store.count() == before - 1, "“wrong record” rejects it, closes it, drops it from the count (\(before) → \(store.count()))")
            check(scan.items.first?.tone == .rejected && scan.items.first?.verdict == .down, "session row shows the thumbs-down")
            check(store.reviewCount() == 1 && store.all().filter({ $0.status == .needsReview || $0.status == .rejected }).map(\.id) == [open.id],
                  "it lands in the review queue (review \(store.reviewCount()))")
            check(store.live().allSatisfy { $0.id != open.id } && (store.fetch(open.id)?.photos.count ?? 0) == 1, "kept out of the catalogue but photos retained")
            check(store.feedbackCount() == 1 && store.feedback().first?.evidence != nil, "feedback logged with evidence")
            scan.verdict(open.id, .up)
            check(store.fetch(open.id)?.status == .matched && store.fetch(open.id)?.verified == true && store.reviewCount() == 0, "thumbs-up restores it as verified and clears the queue")
            check(scan.items.first?.verdict == .up, "session row flips to thumbs-up")
            _ = try? FileManager.default.removeItem(at: tmp.appendingPathComponent("fb"))
            let fb = try? store.exportFeedback(to: tmp.appendingPathComponent("fb"))
            check(fb.map { (try? String(contentsOf: $0, encoding: .utf8))?.contains("\"verdict\":\"up\"") ?? false } ?? false, "feedback JSONL exports the latest verdict")
            await scan.delete(open.id)
            check(store.fetch(open.id) == nil && !scan.items.contains { $0.recordID == open.id }, "delete removes the record and its session row")
        }
        await scan.inject(still: clash)
        let clashRec2 = store.all().first
        print("  info phase after Clash: \(phaseName(scan.phase)) · last candidates \(scan.lastCandidates.prefix(2).map { "\($0.result.title) \($0.score)" })")
        check(clashRec2?.title == "London Calling" && clashRec2?.format == "LP" && scan.current == nil, "LP matched and closed")
        scan.handle(command: .backCover)
        check({ if case .awaitingShot(let k, _, _, _) = scan.phase { return k == "BACK COVER" } else { return false } }() && scan.current?.id == clashRec2?.id, "“back cover” reopens it and asks for the back cover")
        await scan.inject(still: clash)
        check(scan.current == nil && clashRec2.map { store.fetch($0.id)?.photos.map(\.kind) } == [.coverFront, .coverBack], "back cover attached, record closed again")
        scan.handle(command: .undo)
        check(clashRec2.map { store.fetch($0.id)?.photos.count } == 1 && clashRec2.map { store.fetch($0.id) != nil } == true, "undo removes that photo, keeps the record")

        print("scenario · unreadable → label → try again → review")
        state.format = .seven
        let blank = CapturedStill(image: photos.downscale(jam.image, maxSide: 8)!, capturedAt: Date(), metrics: jam.metrics, forced: false)
        await scan.inject(still: blank)
        check({ if case .needLabel = scan.phase { return true } else { return false } }(), "nothing readable on a cover → asks for label (phase \(phaseName(scan.phase)))")
        await scan.inject(still: blank)
        check({ if case .retry = scan.phase { return true } else { return false } }() && store.reviewCount() == 0, "still nothing → offers one retry before the queue (phase \(phaseName(scan.phase)), review \(store.reviewCount()))")
        await scan.inject(still: blank)
        check({ if case .notFound = scan.phase { return true } else { return false } }() && store.reviewCount() == 1, "retry failed too → parked for review (review \(store.reviewCount()))")

        print("scenario · ambiguity by voice")
        // Force an ambiguous verdict: Blue Monday has many FAC 73 variants; pick with "one".
        state.format = .twelve
        if let no = still("label-neworder-fac73") {
            await scan.inject(still: no)
            print("  info phase after New Order: \(phaseName(scan.phase))")
            if case .ambiguous = scan.phase { scan.handle(command: .one); for _ in 0..<40 where scan.current == nil { try? await Task.sleep(for: .milliseconds(250)) }; check(scan.current?.artist == "New Order", "one → chosen") }
            else { check(scan.current?.artist == "New Order" || store.all().contains { $0.artist == "New Order" }, "New Order saved") }
            scan.handle(command: .done)
        }

        print("scenario · export")
        let csv = try? store.exportCSV(to: tmp)
        check(csv != nil, "csv written: \(csv?.lastPathComponent ?? "-")")
        let files = (try? FileManager.default.contentsOfDirectory(atPath: photos.root.path))?.count ?? 0
        check(files >= 7, "photos on disk: \(files)")
        print("records: \(store.count()) · review: \(store.reviewCount()) · discogs \(state.discogs.rateText)")
        try? FileManager.default.removeItem(at: tmp)
        return failures == 0 ? 0 : 1
    }
}

/// True under `--render-ui`: ImageRenderer draws nothing inside a ScrollView, so views that scroll
/// in the app lay themselves out flat for the renderer.
struct StaticRenderKey: EnvironmentKey { static let defaultValue = false }
extension EnvironmentValues {
    var staticRender: Bool {
        get { self[StaticRenderKey.self] }
        set { self[StaticRenderKey.self] = newValue }
    }
}

/// Lets `--render-ui` force a HUD phase without a camera.
struct PreviewPhaseKey: EnvironmentKey { static let defaultValue: ScanPhase? = nil }
extension EnvironmentValues {
    var previewPhase: ScanPhase? {
        get { self[PreviewPhaseKey.self] }
        set { self[PreviewPhaseKey.self] = newValue }
    }
}
