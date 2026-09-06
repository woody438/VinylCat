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
        print("cameras     \(d.devices.map { "\($0.localizedName) [\($0.deviceType.rawValue)]" })")
        let rec = SFSpeechRecognizer(locale: Locale(identifier: "en-GB"))
        print("recogniser  available=\(rec?.isAvailable ?? false) onDevice=\(rec?.supportsOnDeviceRecognition ?? false)")
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
        let state = AppState()
        state.scan.appState = state
        let phases: [(String, ScanPhase)] = [
            ("scan-1-armed", .armed(reason: "empty")),
            ("scan-2-reading", .reading(step: "GPT-5.6 Luna reading")),
            ("scan-3-matched", .matched(title: "THE JAM — GOING UNDERGROUND", detail: "1980 · 7\" · POLYDOR POSP 113 · UK", meta: "0.94 · r2413807 · catno title format")),
            ("scan-4-ambiguous", .ambiguous(candidates: ["POLYDOR POSP 113 · UK · 1980 · 7\"", "POLYDOR 2059 227 · GERMANY · 1980 · 7\"", "POLYDOR POSPX 113 · UK · 1980 · 12\""])),
            ("scan-5-needlabel", .needLabel(guess: "THE FALL — ?")),
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
        for (name, tab) in [("library", AppTab.library), ("review", .review), ("settings", .settings)] {
            state.tab = tab
            let view = RootView().environment(state).frame(width: 1440, height: 900).background(Theme.bg).preferredColorScheme(.dark)
            if render(view, to: out.appendingPathComponent("\(name).png")) { written += 1 }
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

    // MARK: synthetic test images

    static func makeTestImages(dir: String) -> Int32 {
        let out = URL(fileURLWithPath: dir)
        try? FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
        let labels: [(String, [String], NSColor)] = [
            ("label-jam-posp113", ["POLYDOR", "POSP 113", "45 RPM", "GOING UNDERGROUND", "(Weller)", "THE JAM", "SIDE A", "1980"], NSColor(red: 0.85, green: 0.1, blue: 0.1, alpha: 1)),
            ("label-specials-chstt17", ["2 TONE", "CHS TT 17", "45 RPM", "GHOST TOWN", "(Dammers)", "THE SPECIALS", "A"], NSColor(white: 0.15, alpha: 1)),
            ("label-neworder-fac73", ["FACTORY", "FAC 73", "33 RPM", "BLUE MONDAY", "NEW ORDER", "SIDE ONE", "1983"], NSColor(red: 0.1, green: 0.2, blue: 0.6, alpha: 1)),
            ("cover-clash-clash3", ["THE CLASH", "LONDON CALLING", "CBS CLASH 3", "STEREO"], NSColor(white: 0.05, alpha: 1)),
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
                let fmt: VinylFormat? = p.contains("cover") ? .lp : p.contains("fac73") ? .twelve : .seven
                let t1 = Date()
                let (verdict, ranked) = try await Matcher(discogs: dc).find(reading: reading, sessionFormat: fmt)
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
    /// End-to-end run of the real ScanController against a temp store with synthetic stills (live Discogs, no model).
    static func scenario(dir: String) async -> Int32 {
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("vinylcat-scenario-\(UUID().uuidString)")
        let store = Store(url: tmp.appendingPathComponent("db.sqlite"))
        let photos = PhotoStore(root: tmp.appendingPathComponent("photos"))
        let state = AppState(store: store, photos: photos)
        state.scan.appState = state
        state.scan.speaker.enabled = false
        var failures = 0
        func check(_ c: Bool, _ label: String) { print("  \(c ? "ok  " : "FAIL") \(label)"); if !c { failures += 1 } }
        func still(_ name: String) -> CapturedStill? {
            let p = URL(fileURLWithPath: dir).appendingPathComponent("\(name).png").path
            guard let img = NSImage(contentsOfFile: p)?.cgImage(forProposedRect: nil, context: nil, hints: nil) else { print("missing \(p)"); return nil }
            return CapturedStill(image: img, capturedAt: Date(), metrics: FrameMetrics(sharpness: 200, motion: 0, sceneDelta: 50, hash: 0), forced: false)
        }
        func phaseName(_ p: ScanPhase) -> String { "\(p)".components(separatedBy: "(").first ?? "\(p)" }
        let scan = state.scan
        print("scenario · 7\" single: match → B-side → done")
        state.format = .seven
        guard let jam = still("label-jam-posp113"), let specials = still("label-specials-chstt17"), let clash = still("cover-clash-clash3") else { return 1 }
        await scan.inject(still: jam)
        check({ if case .awaitingShot(let k, _, _, _) = scan.phase { return k == "B-SIDE LABEL" } else { return false } }(), "after side A: asks for B-side (phase \(phaseName(scan.phase)))")
        check(scan.current?.discogsReleaseID != nil && store.count() == 1, "record saved with Discogs id \(scan.current?.discogsReleaseID ?? 0)")
        await scan.inject(still: jam)
        check(scan.current == nil, "after B-side: record closed (phase \(phaseName(scan.phase)))")
        let r1 = store.all().first
        check(r1?.photos.count == 2 && r1?.isComplete == true && r1?.photos.map(\.kind) == [.labelA, .labelB], "2 photos tagged A/B, complete")
        check(r1?.artist == "The Jam" && r1?.format == "7\"" && r1?.catalogNumber?.uppercased() == "POSP 113", "fields: \(r1?.artist ?? "") · \(r1?.format ?? "") · \(r1?.catalogNumber ?? "")")

        print("scenario · duplicate → add anyway")
        await scan.inject(still: jam)
        check({ if case .duplicate = scan.phase { return true } else { return false } }(), "same record again → duplicate (phase \(phaseName(scan.phase)))")
        scan.handle(command: .addAnyway)
        for _ in 0..<40 where scan.current == nil { try? await Task.sleep(for: .milliseconds(250)) }
        check(store.count() == 2 && scan.current != nil, "add anyway creates a second copy (count \(store.count()))")
        scan.handle(command: .done)
        check(scan.current == nil, "done closes it")

        print("scenario · skip a shot")
        await scan.inject(still: specials)
        check(scan.current?.artist == "The Specials", "matched The Specials (got \(scan.current?.artist ?? "nil"))")
        let pendingBefore = scan.pending.count
        check(pendingBefore == 1 && scan.pending.first == .labelB, "single label shot → only the B-side is pending (\(scan.pending.map(\.rawValue)))")
        scan.handle(command: .skip)
        let newest = store.all().first
        check(scan.current == nil && newest?.isComplete == false, "skip closes record as incomplete (current \(scan.current?.artist ?? "nil") · newest \(newest?.artist ?? "nil") \(newest?.photos.map(\.kind.rawValue) ?? []) of \(newest?.expectedShots.map(\.rawValue) ?? []) · phase \(phaseName(scan.phase)))")

        print("scenario · album → front/back/label → undo → done")
        state.format = .lp
        await scan.inject(still: clash)
        let clashRec = scan.current
        print("  info phase after Clash: \(scan.phase) · current \(clashRec?.displayTitle ?? "nil") · last candidates \(scan.lastCandidates.prefix(2).map { "\($0.result.title) \($0.score)" })")
        check(clashRec?.title == "London Calling" && clashRec?.format == "LP" && (clashRec?.expectedShots.contains(.coverBack) ?? false), "LP profile: \(clashRec?.expectedShots.map(\.rawValue) ?? [])")
        check({ if case .awaitingShot(let k, _, _, _) = scan.phase { return k == "BACK COVER" } else { return false } }(), "asks for the back cover")
        await scan.inject(still: clash)
        check(scan.current?.photos.count == 2, "back cover attached")
        scan.handle(command: .undo)
        check(scan.current?.photos.count == 1, "undo removes it and re-asks")
        scan.handle(command: .done)
        check(scan.current == nil, "done")

        print("scenario · unreadable → label → review")
        state.format = .seven
        let blank = CapturedStill(image: photos.downscale(jam.image, maxSide: 8)!, capturedAt: Date(), metrics: jam.metrics, forced: false)
        await scan.inject(still: blank)
        check({ if case .needLabel = scan.phase { return true } else { return false } }(), "nothing readable on a cover → asks for label (phase \(phaseName(scan.phase)))")
        await scan.inject(still: blank)
        check({ if case .notFound = scan.phase { return true } else { return false } }() && store.reviewCount() == 1, "still nothing → parked for review (review \(store.reviewCount()))")

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

/// Lets `--render-ui` force a HUD phase without a camera.
struct PreviewPhaseKey: EnvironmentKey { static let defaultValue: ScanPhase? = nil }
extension EnvironmentValues {
    var previewPhase: ScanPhase? {
        get { self[PreviewPhaseKey.self] }
        set { self[PreviewPhaseKey.self] = newValue }
    }
}
