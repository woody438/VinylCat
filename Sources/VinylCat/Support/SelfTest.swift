import CoreVideo
import Foundation
import SwiftUI

/// Built-in checks, run with `VinylCat --self-test` (see scripts/test.sh). Kept here because the
/// Command Line Tools toolchain ships neither XCTest nor Swift Testing.
@MainActor
enum SelfTest {
    private static var failures = 0
    private static var passed = 0

    private static func check(_ cond: @autoclosure () -> Bool, _ label: String, file: String = #fileID, line: Int = #line) {
        if cond() { passed += 1; print("  ok   \(label)") } else { failures += 1; print("  FAIL \(label)  (\(file):\(line))") }
    }

    private static func hit(_ id: Int, _ title: String, catno: String?, label: String? = nil, year: String? = nil,
                            format: [String] = ["Vinyl", "7\""], country: String? = "UK") -> DiscogsClient.SearchResult {
        .init(id: id, type: "release", title: title, year: year, country: country, label: label.map { [$0] }, catno: catno,
              format: format, barcode: nil, thumb: nil, cover_image: nil, master_id: nil)
    }

    /// Drives the engine with synthetic BGRA frames: empty → record A (steady) → still A → empty → record B.
    private static func runEngineScenario() -> (captures: Int, doubleFire: Bool, emptyNoFire: Bool, heldNoFire: Bool, forcedWhileHeld: Bool, resumed: Bool) {
        var tuning = CaptureTuning(); tuning.steadySeconds = 0.1
        let engine = CaptureEngine(tuning: tuning)
        var cont: AsyncStream<Frame>.Continuation!
        let stream = AsyncStream<Frame>(bufferingPolicy: .unbounded) { cont = $0 }
        let runTask = Task { await engine.run(frames: stream) }
        var captures = 0, capturesAfterA = 0, capturesDuringEmpty = 0
        let collector = Task { for await _ in engine.stills { captures += 1 } }

        func frame(pattern: Int) -> Frame {
            var pb: CVPixelBuffer?
            CVPixelBufferCreate(nil, 320, 240, kCVPixelFormatType_32BGRA, nil, &pb)
            CVPixelBufferLockBaseAddress(pb!, [])
            let base = CVPixelBufferGetBaseAddress(pb!)!.assumingMemoryBound(to: UInt8.self)
            let stride = CVPixelBufferGetBytesPerRow(pb!)
            for y in 0..<240 { for x in 0..<320 {
                let p = base + y * stride + x * 4
                var v: UInt8 = 90
                if pattern == 1 { v = ((x / 8 + y / 8) % 2 == 0) ? 240 : 20 }            // checkerboard "record"
                if pattern == 2 { v = ((x / 5) % 3 == 0 || (y / 7) % 2 == 0) ? 230 : 30 }  // different record
                if pattern == 3 { v = ((x / 11) % 2 == 0 && (y / 4) % 3 != 0) ? 245 : 25 }  // a third record
                p[0] = v; p[1] = v; p[2] = v; p[3] = 255
            } }
            CVPixelBufferUnlockBaseAddress(pb!, [])
            return Frame(pixelBuffer: pb!, timestamp: .zero)
        }
        func feed(_ pattern: Int, frames n: Int) {
            for _ in 0..<n { cont.yield(frame(pattern: pattern)); Thread.sleep(forTimeInterval: 0.03) }
            Thread.sleep(forTimeInterval: 0.05)
        }
        // Pump the main run loop so the actor + collector tasks make progress between feeds.
        func pump(_ s: TimeInterval) { RunLoop.main.run(until: Date().addingTimeInterval(s)) }

        feed(0, frames: 10); pump(0.2)                        // learn baseline
        let before = captures
        feed(1, frames: 12); pump(0.3)                        // record A held steady → capture
        capturesAfterA = captures
        feed(1, frames: 12); pump(0.3)                        // still holding A → no second capture
        let doubleFire = captures > capturesAfterA
        feed(0, frames: 8); pump(0.2)                         // removed → cooldown clears
        capturesDuringEmpty = captures
        feed(2, frames: 12); pump(0.3)                        // record B → capture
        let afterB = captures

        // Waiting for an answer (an ambiguous match on screen): nothing fires on its own, but
        // "capture" / space still does, and releasing the hold puts it back to normal.
        Task { await engine.setHold(true) }; pump(0.2)
        feed(0, frames: 6); feed(3, frames: 14); pump(0.3)
        let heldNoFire = captures == afterB
        Task { await engine.forceCapture() }; pump(0.2)
        feed(3, frames: 4); pump(0.3)
        let forcedWhileHeld = captures == afterB + 1
        Task { await engine.setHold(false) }; pump(0.2)
        feed(0, frames: 8); feed(1, frames: 14); pump(0.3)
        let resumed = captures == afterB + 2

        cont.finish(); runTask.cancel(); collector.cancel()
        return (afterB - before, doubleFire, capturesDuringEmpty == capturesAfterA, heldNoFire, forcedWhileHeld, resumed)
    }

    /// Holds a record steady, then throws in one bad frame. The ring should dent, not reset —
    /// that flicker was what made lining a record up feel so jumpy.
    private static func runSteadinessScenario() -> (rose: Bool, heldThroughWobble: Bool, lowest: Double) {
        var tuning = CaptureTuning(); tuning.steadySeconds = 2   // long enough that it never fires
        let engine = CaptureEngine(tuning: tuning)
        var cont: AsyncStream<Frame>.Continuation!
        let stream = AsyncStream<Frame>(bufferingPolicy: .unbounded) { cont = $0 }
        let runTask = Task { await engine.run(frames: stream) }
        var series: [Double] = []
        let watcher = Task { for await s in engine.signals { series.append(s.steadyProgress) } }

        func frame(_ pattern: Int, shift: Int = 0, gain: Int = 0) -> Frame {
            var pb: CVPixelBuffer?
            CVPixelBufferCreate(nil, 320, 240, kCVPixelFormatType_32BGRA, nil, &pb)
            CVPixelBufferLockBaseAddress(pb!, [])
            let base = CVPixelBufferGetBaseAddress(pb!)!.assumingMemoryBound(to: UInt8.self)
            let stride = CVPixelBufferGetBytesPerRow(pb!)
            for y in 0..<240 { for x in 0..<320 {
                let p = base + y * stride + x * 4
                var v = 90
                if pattern == 1 { v = (((x + shift) / 8 + y / 8) % 2 == 0) ? 240 : 20 }
                // A softer "sleeve": broad stripes, so a slow slide reads as still frame-to-frame.
                if pattern == 2 { v = 120 + (((x + shift) / 40 + y / 30) % 2 == 0 ? 60 : -60) }
                let u = UInt8(clamping: v + gain)
                p[0] = u; p[1] = u; p[2] = u; p[3] = 255
            } }
            CVPixelBufferUnlockBaseAddress(pb!, [])
            return Frame(pixelBuffer: pb!, timestamp: .zero)
        }
        // Pump between frames so the signal watcher sees each one (the stream keeps only the newest).
        func feed(_ pattern: Int, shift: Int = 0, gain: Int = 0, frames n: Int) {
            for _ in 0..<n { cont.yield(frame(pattern, shift: shift, gain: gain)); RunLoop.main.run(until: Date().addingTimeInterval(0.035)) }
        }

        feed(0, frames: 10)                       // learn the empty scene
        feed(1, frames: 12)                       // hold a record: the ring fills
        let beforeWobble = series.last ?? 0
        feed(1, shift: 4, frames: 1)              // one jolted frame
        let afterWobble = series.last ?? 0
        feed(1, frames: 6)                        // back to holding it
        let recovered = series.last ?? 0
        cont.finish(); runTask.cancel(); watcher.cancel()
        return (beforeWobble > 0.1, afterWobble > 0 && recovered > beforeWobble, afterWobble)
    }

    /// The hold compares against the picture it started from. Easing a sleeve into place, or the
    /// phone's exposure settling on it, must dent the ring rather than restart it; a record that
    /// keeps sliding through must never fill it.
    private static func runDriftScenario() -> (exposureHeld: Bool, exposureDip: Double, nudgeDented: Bool, nudgeBefore: Double, nudgeLow: Double, slideNeverFired: Bool) {
        var tuning = CaptureTuning(); tuning.steadySeconds = 1.5   // long enough that nothing fires mid-test
        let engine = CaptureEngine(tuning: tuning)
        var cont: AsyncStream<Frame>.Continuation!
        let stream = AsyncStream<Frame>(bufferingPolicy: .unbounded) { cont = $0 }
        let runTask = Task { await engine.run(frames: stream) }
        var series: [Double] = []
        var captures = 0
        let watcher = Task { for await s in engine.signals { series.append(s.steadyProgress) } }
        let collector = Task { for await _ in engine.stills { captures += 1 } }

        func frame(_ pattern: Int, shift: Int = 0, gain: Int = 0) -> Frame {
            var pb: CVPixelBuffer?
            CVPixelBufferCreate(nil, 320, 240, kCVPixelFormatType_32BGRA, nil, &pb)
            CVPixelBufferLockBaseAddress(pb!, [])
            let base = CVPixelBufferGetBaseAddress(pb!)!.assumingMemoryBound(to: UInt8.self)
            let stride = CVPixelBufferGetBytesPerRow(pb!)
            for y in 0..<240 { for x in 0..<320 {
                let p = base + y * stride + x * 4
                var v = 90
                if pattern == 1 { v = (((x + shift) / 8 + y / 8) % 2 == 0) ? 240 : 20 }
                if pattern == 2 { v = 120 + (((x + shift) / 40 + y / 30) % 2 == 0 ? 60 : -60) }
                let u = UInt8(clamping: v + gain)
                p[0] = u; p[1] = u; p[2] = u; p[3] = 255
            } }
            CVPixelBufferUnlockBaseAddress(pb!, [])
            return Frame(pixelBuffer: pb!, timestamp: .zero)
        }
        func feed(_ pattern: Int, shift: Int = 0, gain: Int = 0, frames n: Int) {
            for _ in 0..<n { cont.yield(frame(pattern, shift: shift, gain: gain)); RunLoop.main.run(until: Date().addingTimeInterval(0.035)) }
        }
        func settle() { Task { await engine.setHold(true) }; RunLoop.main.run(until: Date().addingTimeInterval(0.1)); Task { await engine.setHold(false) }; RunLoop.main.run(until: Date().addingTimeInterval(0.1)) }

        feed(0, frames: 10)                                            // learn the empty scene
        // 1. Exposure settling: the same sleeve, every pixel brightening together by ~70 levels
        //    over a second. The ring must keep climbing — the biggest frame-to-frame drop tells.
        var ramp: [Double] = []
        for i in 0..<24 { feed(2, gain: i * 3, frames: 1); ramp.append(series.last ?? 0) }
        let dip = zip(ramp, ramp.dropFirst()).map { $1 - $0 }.min() ?? 0
        let exposureHeld = (ramp.max() ?? 0) > 0.5 && dip > -0.15
        settle(); captures = 0; series.removeAll()

        // 2. A nudge: held, then eased 6 px sideways and held there. Half a ring, not none.
        //    20 frames, not 12: the ring fills against the wall clock (0.035s a frame against
        //    steadySeconds 1.5), so 12 left it at ~0.28 — right on the `beforeNudge > 0.3` guard
        //    below. It held on a Mac at ~0.38 and flaked on CI, which is slower per frame (seen
        //    at 0.37 and 0.25 on consecutive runs of the same commit). 20 frames reach ~0.47, so
        //    the sleeve really is held before it's nudged, which is what this is meant to test.
        feed(0, frames: 6); feed(2, frames: 20)
        let beforeNudge = series.last ?? 0
        feed(2, shift: 6, frames: 5)
        let low = series.suffix(5).min() ?? 0
        let nudgeDented = beforeNudge > 0.3 && low > beforeNudge * 0.4
        settle(); captures = 0; series.removeAll()

        // 3. Sliding through: never steady enough to fire, however long it goes on.
        feed(0, frames: 6)
        for i in 0..<45 { feed(2, shift: i * 3, frames: 1) }
        let slideNeverFired = captures == 0

        cont.finish(); runTask.cancel(); watcher.cancel(); collector.cancel()
        return (exposureHeld, dip, nudgeDented, beforeNudge, low, slideNeverFired)
    }

    static func run() -> Int32 {
        print("VinylCat self-test")

        print("ranker")
        var r = SleeveReading()
        r.artist = "The Jam"; r.title = "Going Underground"; r.catalogNumber = "POSP 113"; r.label = "Polydor"
        let hits = [
            hit(1, "The Jam - Going Underground", catno: "2059 227", label: "Polydor", year: "1980", country: "Germany"),
            hit(2, "The Jam - Going Underground", catno: "POSP 113", label: "Polydor", year: "1980"),
            hit(3, "The Jam - Going Underground", catno: "POSPX 113", label: "Polydor", year: "1980", format: ["Vinyl", "12\""]),
        ]
        let ranked = CandidateRanker.rank(hits, reading: r, sessionFormat: .seven)
        check(ranked.first?.id == 2, "exact catno ranks first")
        check((ranked.first?.score ?? 0) >= 0.85, "exact catno + title + format auto-accepts (\(ranked.first?.score ?? 0))")
        check(ranked.last?.id == 3, "wrong format ranks last")
        check(ranked.first?.headline == "THE JAM — GOING UNDERGROUND", "headline is artist — title (\(ranked.first?.headline ?? ""))")
        check(Candidate(result: hit(9, "New Order (2) - Blue Monday", catno: "FAC 73"), score: 0, reasons: []).headline == "NEW ORDER — BLUE MONDAY", "headline drops Discogs disambiguation numbers")
        check(CandidateRanker.similarity("The Jam - Going Underground", "the jam – going underground") > 0.95, "similarity ignores case/punctuation")
        check(CandidateRanker.similarity("Blondie", "Kraftwerk") < 0.6, "dissimilar strings score low")

        print("catalogue numbers")
        let lines = ["POLYDOR", "POSP 113", "45 RPM", "1980", "GOING UNDERGROUND", "2059 227", "SIDE A", "7N 17241"]
        let c = CatalogueNumber.candidates(in: lines)
        check(c.first == "POSP 113", "letter+digit combo first (\(c))")
        check(c.contains("2059 227"), "numeric pair kept")
        check(c.contains("7N 17241"), "digit-letter prefix kept")
        check(!c.contains("1980") && !c.contains("45"), "years and RPM dropped")
        check(CatalogueNumber.normalize("posp-113") == CatalogueNumber.normalize("POSP 113"), "normalize strips spacing")
        // The rank list from --ocr-eval, 2026-09-06: what used to sit ahead of the catalogue number.
        let cbs = CatalogueNumber.candidates(in: ["COLUMBIA", "38-06611", "ZSS 175774", "STEREO", "45 RPM"])
        check(cbs.first == "38-06611", "CBS single number outranks its ZSS matrix number (\(cbs))")
        let polygram = CatalogueNumber.candidates(in: ["885 518-7", "LEVEL 42", "℗ 1985 POLYDOR"])
        check(polygram.first == "885 518-7", "PolyGram 3-3-1 number outranks the artist name (\(polygram))")
        let album = CatalogueNumber.candidates(in: ["PB 12243", "FROM THE ALBUM AFL1-3962", "P1980 RCA"])
        check(album.first == "PB 12243", "number quoted from the album ranks below the single's own (\(album))")
        check((album.firstIndex(of: "P1980") ?? 0) > (album.firstIndex(of: "PB 12243") ?? 9), "℗ year token ranks below the catalogue number (\(album))")
        let bare = CatalogueNumber.candidates(in: ["EMI AMERICA", "8071", "(X500511)", "1981"])
        check(bare.contains("8071") && !bare.contains("1981"), "bare four-digit number kept unless it is a year (\(bare))")
        check(bare.last == "8071", "bare four-digit number ranks last (\(bare))")
        check(CatalogueNumber.compare("OS 13001", "OS 13061") == .near, "0/6 read as near in small print")
        // Vision reports boxes in the rotated (upright-text) frame; the crop has to come from the still.
        let box = CGRect(x: 0.1, y: 0.2, width: 0.3, height: 0.05)   // Vision: origin bottom-left
        func same(_ a: CGRect, _ b: CGRect) -> Bool { abs(a.minX - b.minX) < 0.01 && abs(a.minY - b.minY) < 0.01 && abs(a.width - b.width) < 0.01 && abs(a.height - b.height) < 0.01 }
        let rightRect = LocalReader.Zoom.pixelRect(box, orientation: .right, width: 1600, height: 900)
        let leftRect = LocalReader.Zoom.pixelRect(box, orientation: .left, width: 1600, height: 900)
        check(same(LocalReader.Zoom.pixelRect(box, orientation: .up, width: 1600, height: 900), CGRect(x: 160, y: 675, width: 480, height: 45)), "upright box maps to pixels top-left")
        check(same(rightRect, CGRect(x: 1200, y: 540, width: 80, height: 270)), "box read at 90° maps back through the rotation (\(rightRect))")
        check(same(leftRect, CGRect(x: 320, y: 90, width: 80, height: 270)), "box read at -90° maps back through the rotation (\(leftRect))")
        check(same(LocalReader.Zoom.pixelRect(box, orientation: .down, width: 1600, height: 900), CGRect(x: 960, y: 180, width: 480, height: 45)), "upside-down box maps back")

        print("frame analysis")
        check(FrameAnalyzer.hammingDistance(0, 0) == 0 && FrameAnalyzer.hammingDistance(0b1111, 0) == 4, "hamming distance")
        let fa = FrameAnalyzer()
        let flat = [UInt8](repeating: 128, count: fa.width * fa.height)
        var noisy = flat
        for i in stride(from: 0, to: noisy.count, by: 2) { noisy[i] = 200 }
        let m1 = fa.analyze(flat)
        let m2 = fa.analyze(noisy)
        check(m1.sharpness < 1, "flat frame has ~zero sharpness")
        check(m2.sharpness > m1.sharpness + 100, "high-frequency frame is sharper")
        check(m2.motion > 30, "changed frame reports motion (\(m2.motion))")

        print("launch counter")
        check(LaunchPing.shouldSend(channel: "release", enabled: true, forced: false), "release build counts")
        check(!LaunchPing.shouldSend(channel: "debug", enabled: true, forced: false), "debug build never counts")
        check(!LaunchPing.shouldSend(channel: nil, enabled: true, forced: false), "bare binary never counts")
        check(LaunchPing.shouldSend(channel: nil, enabled: true, forced: true), "VINYLCAT_PING=1 forces it")
        check(!LaunchPing.shouldSend(channel: "release", enabled: false, forced: true), "the Settings switch wins over everything")
        check(String(decoding: LaunchPing.body(event: "launch", version: "0.1.0"), as: UTF8.self) == #"{"event":"launch","version":"0.1.0"}"#, "the body is the event and the version, nothing else")

        print("updates")
        let mainRel = Updates.Release(build: 40, version: "0.2.2", commit: "a", channel: "latest", notes: nil)
        let previewRel = Updates.Release(build: 43, version: "0.2.2", commit: "b", channel: "preview", notes: nil)
        let relJSON = #"{"build": 41, "version": "0.2.2", "commit": "a677f40", "channel": "preview", "notes": "x"}"#
        check(Updates.decode(Data(relJSON.utf8)) == Updates.Release(build: 41, version: "0.2.2", commit: "a677f40", channel: "preview", notes: "x"),
              "reads VinylCat.json")
        check(Updates.decode(Data(#"{"build":7,"version":"0.2.2","commit":"c","channel":"latest"}"#.utf8))?.notes == nil,
              "a release without notes still decodes")
        check(Updates.decode(Data("not json".utf8)) == nil, "rubbish isn't a release")
        check(Updates.url("latest", "VinylCat.zip").absoluteString
              == "https://github.com/woody438/VinylCat/releases/download/latest/VinylCat.zip", "download URL")
        check(Updates.channels(previews: false) == ["latest"], "previews off: main only")
        check(Updates.channels(previews: true) == ["preview", "latest"], "previews on: the preview, then main")
        check(Updates.newest([mainRel, previewRel], after: 41) == previewRel, "the newest of two")
        check(Updates.newest([mainRel], after: 41) == nil, "an older build isn't an update")
        check(Updates.newest([mainRel], after: 40) == nil, "the same build isn't an update")
        check(Updates.newest([], after: 2) == nil, "nothing found")
        // Back to main from a preview: main's build, lower by number, once previews are off.
        check(Updates.backToMain([mainRel], running: 43, channel: "preview", previews: false) == mainRel,
              "a preview with previews off: main's build to go back to")
        check(Updates.backToMain([mainRel], running: 43, channel: "preview", previews: true) == nil, "previews on: stay")
        check(Updates.backToMain([mainRel], running: 43, channel: "latest", previews: false) == nil,
              "main's own build: nowhere to go back to")
        check(Updates.backToMain([Updates.Release(build: 44, version: "0.2.2", commit: "c", channel: "latest", notes: nil)],
                                 running: 43, channel: "preview", previews: false) == nil, "main's newer: an ordinary update")
        check(Updates.backToMain([], running: 43, channel: "preview", previews: false) == nil, "main not found")
        // A build made on the Mac has a date for a version and no update channel, so it never swaps itself.
        let updater = Updater()
        check(!updater.enabled, "a local build takes no part in updates")
        check(updater.statusLine.contains("local build"), "and says so in Settings")
        check(updater.shown == nil, "and shows no chip")

        print("bug report")
        check(BugReport.title("Camera shows black\nafter waking") == "Camera shows black", "title is the first line")
        check(BugReport.title("   ") == "Problem report", "empty description gets a stock title")
        check(BugReport.title(String(repeating: "x", count: 120)).count <= 80, "title is capped at 80")
        check(BugReport.title("wrong match", record: "The Jam — Going Underground") == "The Jam — Going Underground: wrong match", "record name leads the title")
        check(!BugReport.scrub("my key is sk-proj-abcdefghijklmnopqrstuvwxyz0123").contains("sk-proj-abc"), "OpenAI-shaped key is masked")
        check(!BugReport.scrub("AIzaSyA1234567890abcdefghijklmnop").contains("AIzaSyA12"), "Google-shaped key is masked")
        check(!BugReport.scrub("token=abcdefghij1234567890ABCDEFGHIJ").contains("abcdefghij1234"), "token=… is masked")
        check(BugReport.scrub("POSP 113 · 0.94 · r2413807") == "POSP 113 · 0.94 · r2413807", "ordinary text is untouched")
        let md = BugReport.markdown(description: "It froze", email: "a@b.c", version: "VinylCat 0.2.0", build: "b", macOS: "26.0",
                                    record: nil, evidenceJSON: "{}", log: "12:00 I app · launch")
        check(md.hasPrefix("## What went wrong\n\nIt froze") && md.contains("Reply to: a@b.c") && md.contains("- Version: VinylCat 0.2.0"), "markdown carries the note, email and version")
        check(md.contains("## Scan evidence") && md.contains("## Log (last 150 lines)"), "markdown carries the evidence and the log when given")
        let mdBare = BugReport.markdown(description: "x", email: "", version: "v", build: "b", macOS: "m", record: nil, evidenceJSON: nil, log: nil)
        check(!mdBare.contains("Reply to") && !mdBare.contains("## Log") && !mdBare.contains("## Scan evidence"), "nothing optional appears unasked")
        let sentBody = (try? JSONSerialization.jsonObject(with: BugReport.body(title: "t", markdown: "m", version: "v")) as? [String: String]) ?? [:]
        check(sentBody == ["title": "t", "body": "m", "version": "v"], "the request is title, body and version, nothing else")

        print("formats")
        check(VinylFormat.allCases.count == 3 && VinylFormat.seven.discogsFormat == "7\"", "format mapping")

        print("voice phrases")
        check(VoiceCommand.match(trailing: "ok capture") == .capture, "trailing word matches")
        check(VoiceCommand.match(trailing: "flip it") == .flip, "multi-word phrase")
        check(VoiceCommand.match(trailing: "number two") == .two, "longest phrase wins")
        check(VoiceCommand.match(trailing: "forty fives") == .sevens, "format switch")
        check(VoiceCommand.match(trailing: "capturing") == nil, "no partial-word matches")
        check(VoiceCommand.match(trailing: "back cover") == .backCover && VoiceCommand.match(trailing: "back") == .backCover, "back cover")
        check(VoiceCommand.match(trailing: "that's the wrong record") == .wrong && VoiceCommand.match(trailing: "not that one") == .wrong && VoiceCommand.match(trailing: "no") == .no, "wrong record")

        print("matcher — variant collapsing")
        let twins = [
            hit(10, "The Jam - Going Underground", catno: "POSP 113", label: "Polydor", year: "1980"),
            hit(11, "The Jam - Going Underground", catno: "POSP 113", label: "Polydor", year: "1980"),
            hit(12, "The Jam - Going Underground", catno: "POSP 113", label: "Polydor", year: "1980", country: "Ireland"),
        ]
        let rk = CandidateRanker.rank(twins, reading: r, sessionFormat: .seven)
        var keys = Set<String>()
        let distinct = rk.filter { keys.insert($0.variantKey).inserted }
        check(distinct.count == 2, "identical pressings collapse (\(distinct.count))")
        check(rk.first?.isStrong == true, "catno + title is a strong match")
        check(CandidateRanker.titleSimilarity(reading: { var x = SleeveReading(); x.artist = "Blue Monday"; x.title = "Factory"; return x }(), resultTitle: "New Order - Blue Monday") > 0.6, "swapped artist/title still matches")

        print("first-run tour")
        let win = CGSize(width: 1440, height: 900)
        check(Set(TourStep.all.map(\.anchor)).count == TourStep.all.count, "one callout per anchor")
        check(Set(TourStep.all.map(\.tab)) == Set(AppTab.allCases), "tour visits every tab")
        let below = TourLayout.place(anchor: CGRect(x: 1380, y: 14, width: 50, height: 30), placement: .below, in: win)
        check(below.container.maxX <= win.width - TourLayout.margin && below.placement == .below, "bubble under a right-edge control stays on screen (\(below.container))")
        check(below.arrow > TourLayout.bubbleWidth / 2 && below.arrow <= TourLayout.bubbleWidth - 20, "arrow slides toward the anchor when the bubble is clamped (\(below.arrow))")
        let above = TourLayout.place(anchor: CGRect(x: 0, y: 856, width: 1440, height: 44), placement: .above, in: win)
        check(above.placement == .above && above.container.maxY <= 856 - TourLayout.gap, "bubble above the bottom bar sits clear of it")
        let flipped = TourLayout.place(anchor: CGRect(x: 0, y: 800, width: 600, height: 100), placement: .below, in: win)
        check(flipped.placement == .above, "no room below → flips above")
        let noRoomLeft = TourLayout.place(anchor: CGRect(x: 40, y: 100, width: 400, height: 300), placement: .leading, in: win)
        check(noRoomLeft.placement == .trailing && noRoomLeft.container.minX >= 440 + TourLayout.gap, "no room to the left → goes right")
        let rail = TourLayout.place(anchor: CGRect(x: 1100, y: 57, width: 340, height: 800), placement: .leading, in: win)
        check(rail.placement == .leading && rail.container.maxX <= 1100 - TourLayout.gap && rail.arrow <= 80, "rail callout sits left of the rail, arrow near its top")
        let inside = TourLayout.place(anchor: CGRect(x: 0, y: 57, width: 1100, height: 800), placement: .inside, in: win)
        check(inside.container == CGRect(x: 0, y: 57, width: 1100, height: 800) && inside.alignment == .center, "inside placement centres on the region")

        print("store round-trip")
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("vinylcat-selftest-\(UUID().uuidString).sqlite")
        let store = Store(url: tmp)
        var rec = VinylRecord(artist: "The Jam", title: "Going Underground", format: "7\"", sessionID: UUID())
        rec.discogsReleaseID = 2413807; rec.year = 1980; rec.genres = ["Rock"]; rec.tracks = [Track(position: "A", title: "Going Underground", duration: "2:58")]
        rec.photos = [ScanPhoto(recordID: rec.id, fileName: "x.jpg", kind: .labelA, order: 0)]
        store.insert(rec)
        let back = store.fetch(rec.id)
        check(back != nil, "fetch after insert")
        check(back?.discogsReleaseID == 2413807 && back?.tracks.first?.duration == "2:58" && back?.genres == ["Rock"], "fields and JSON columns survive")
        check(back?.photos.count == 1 && back?.photos.first?.kind == .labelA, "photo survives")
        check(store.existing(discogsReleaseID: 2413807)?.id == rec.id, "duplicate lookup by release id")
        rec.photos.append(ScanPhoto(recordID: rec.id, fileName: "y.jpg", kind: .labelB, order: 1)); store.update(rec)
        check(store.fetch(rec.id)?.photos.count == 2, "update adds photo")
        check(store.count() == 1, "count")
        let csv = try? store.exportCSV(to: tmp.deletingLastPathComponent())
        check(csv != nil && ((try? String(contentsOf: csv!, encoding: .utf8))?.contains("Going Underground") ?? false), "csv export")
        store.delete(rec.id)
        check(store.count() == 0, "delete cascades")
        try? FileManager.default.removeItem(at: tmp); if let csv { try? FileManager.default.removeItem(at: csv) }

        print("capture engine — synthetic frames")
        let engineOK = runEngineScenario()
        check(engineOK.captures == 2, "two distinct records → two captures (got \(engineOK.captures))")
        check(engineOK.doubleFire == false, "same record held still does not re-fire")
        check(engineOK.emptyNoFire, "empty scene never fires")
        check(engineOK.heldNoFire, "waiting for an answer → a new record does not fire on its own")
        check(engineOK.forcedWhileHeld, "“capture” still forces a shot while waiting")
        check(engineOK.resumed, "releasing the hold scans again")
        let steady = runSteadinessScenario()
        check(steady.rose, "the ring fills while a record is held")
        check(steady.heldThroughWobble, "one bad frame dents the ring (\(String(format: "%.2f", steady.lowest))) instead of resetting it")
        let drift = runDriftScenario()
        check(drift.exposureHeld, "exposure settling on a sleeve does not restart the hold (worst dip \(String(format: "%.2f", drift.exposureDip)))")
        check(drift.nudgeDented, "easing the sleeve sideways costs half the ring, not all of it (\(String(format: "%.2f → %.2f", drift.nudgeBefore, drift.nudgeLow)))")
        check(drift.slideNeverFired, "a record sliding through never fires")

        print("photo import — folder walk")
        let walkDir = FileManager.default.temporaryDirectory.appendingPathComponent("vinylcat-walk-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: walkDir.appendingPathComponent("sub"), withIntermediateDirectories: true)
        try? FileManager.default.createDirectory(at: walkDir.appendingPathComponent(".git"), withIntermediateDirectories: true)
        for f in ["b.JPG", "a.jpeg", "c.png", "d.heic", ".e.jpg", "f.txt", "g.HEIC.bak", "sub/h.jpg", ".git/i.png", "IMG_10.jpg", "IMG_9.jpg"] {
            try? Data().write(to: walkDir.appendingPathComponent(f))
        }
        let root = walkDir.resolvingSymlinksInPath().path + "/"   // the temp dir is reached through /private
        let walked = PhotoImporter.walk([walkDir]).map { $0.resolvingSymlinksInPath().path.replacingOccurrences(of: root, with: "") }
        check(walked == ["a.jpeg", "b.JPG", "c.png", "d.heic", "IMG_9.jpg", "IMG_10.jpg", "sub/h.jpg"], "sorted, jpg/jpeg/png/heic in any case, dotfiles and hidden folders skipped, numbers in natural order (\(walked))")
        check(PhotoImporter.walk([walkDir.appendingPathComponent("b.JPG"), walkDir.appendingPathComponent("f.txt")]).map(\.lastPathComponent) == ["b.JPG"], "files given directly: images kept, the rest dropped")
        check(PhotoImporter.walk([walkDir.appendingPathComponent("missing")]).isEmpty, "a path that doesn't exist walks to nothing")
        try? FileManager.default.removeItem(at: walkDir)

        print("discogs collection sync — the pref")
        let saved = UserDefaults.standard.object(forKey: "discogsSync")
        UserDefaults.standard.removeObject(forKey: "discogsSync")
        check(CollectionSync.enabledByUser == false, "a fresh install writes nothing to Discogs until asked")
        UserDefaults.standard.set(true, forKey: "discogsSync")
        check(CollectionSync.enabledByUser, "the wizard/Settings toggle switches it on")
        UserDefaults.standard.set(false, forKey: "discogsSync")
        check(CollectionSync.enabledByUser == false, "and off again")
        if let saved { UserDefaults.standard.set(saved, forKey: "discogsSync") } else { UserDefaults.standard.removeObject(forKey: "discogsSync") }

        print("spend ledger")
        let cal = Calendar(identifier: .gregorian)
        let sep = cal.date(from: DateComponents(year: 2026, month: 9, day: 14))!, oct = cal.date(from: DateComponents(year: 2026, month: 10, day: 1))!
        var ledger = SpendLedger()
        ledger.add(costUSD: 0.4, at: sep); ledger.add(costUSD: 0.6, at: sep)
        check(ledger.monthKey == "2026-09" && abs(ledger.monthCostUSD - 1.0) < 1e-9 && ledger.monthReads == 2, "reads in one month add up")
        ledger.add(costUSD: 0.25, at: oct)
        check(ledger.monthKey == "2026-10" && abs(ledger.monthCostUSD - 0.25) < 1e-9 && ledger.monthReads == 1, "a new month starts from zero")
        check(abs(ledger.totalCostUSD - 1.25) < 1e-9 && ledger.totalReads == 3, "the all-time total survives the roll")
        check(!ledger.isOver(budgetUSD: 5) && ledger.isOver(budgetUSD: 0.25) && !ledger.isOver(budgetUSD: 0), "budget: under, reached, switched off")
        let suite = UserDefaults(suiteName: "vinylcat-selftest-spend")!
        suite.removePersistentDomain(forName: "vinylcat-selftest-spend")
        ledger.save(to: suite)
        check(SpendLedger.load(from: suite, now: oct) == ledger, "ledger round-trips through UserDefaults")
        let rolled = SpendLedger.load(from: suite, now: cal.date(from: DateComponents(year: 2026, month: 11, day: 3))!)
        check(rolled.monthCostUSD == 0 && rolled.monthKey == "2026-11" && rolled.totalReads == 3, "loading in a later month rolls the month, keeps the total")
        suite.removePersistentDomain(forName: "vinylcat-selftest-spend")
        print("claude reader — model picker and credentials")
        let savedModel = UserDefaults.standard.object(forKey: "claudeModel")
        UserDefaults.standard.removeObject(forKey: "claudeModel")
        check(ClaudeModel.current == .opus, "no choice stored yet → the best reader, not the cheapest")
        check(ReaderProvider.claude.title == "Claude Opus 5.5", "the provider title follows the picker")
        UserDefaults.standard.set("haiku", forKey: "claudeModel")
        check(ClaudeModel.current == .haiku, "the picker switches the rung")
        check(ReaderProvider.claude.title == "Claude Haiku 5.5", "and the title with it")
        if let savedModel { UserDefaults.standard.set(savedModel, forKey: "claudeModel") } else { UserDefaults.standard.removeObject(forKey: "claudeModel") }
        check(ClaudeModel.allCases.allSatisfy { $0.apiName.hasPrefix("claude-") && $0.apiName.hasSuffix("-5-5") }, "every rung names a current model id")
        check(ClaudeModel.haiku.perPhotoUSD < ClaudeModel.sonnet.perPhotoUSD
            && ClaudeModel.sonnet.perPhotoUSD < ClaudeModel.opus.perPhotoUSD, "cost rises with the rung")
        check(ClaudeModel.opus.perPhotoUSD < 0.05, "even the dearest rung is pennies a photo")
        check(ReaderProvider.claude.key == .anthropic && ReaderProvider.luna.key == .openAI
            && ReaderProvider.gemini.key == .gemini, "each provider reads its own key")
        // The schema-constrained reply is bare JSON; the prompt-only fallback can arrive fenced.
        check(ClaudeReader.jsonBody(of: "{\"artist\":\"a\"}") == "{\"artist\":\"a\"}", "bare JSON passes through")
        check(ClaudeReader.jsonBody(of: "```json\n{\"artist\":\"a\"}\n```") == "{\"artist\":\"a\"}", "a fenced reply is unwrapped")
        check(ClaudeReader.jsonBody(of: "  ```\n{\"a\":1}\n```  ") == "{\"a\":1}", "fences survive surrounding space")
        check(ClaudeReader.schemaText?.contains("catalogNumber") == true, "the schema serialises for the fallback prompt")
        // An enum property must not also declare a type union, or the API rejects the whole schema.
        let claudeProps = ClaudeReader.schema["properties"] as? [String: [String: Any]] ?? [:]
        check(claudeProps["formatGuess"]?["enum"] != nil && claudeProps["formatGuess"]?["type"] == nil,
              "formatGuess keeps its enum and loses the type union")
        check(claudeProps["artist"]?["type"] as? [String] == ["string", "null"], "plain nullable unions are left alone")
        check((SleeveReading.jsonSchema["properties"] as? [String: [String: Any]])?["formatGuess"]?["type"] != nil,
              "the shared schema is untouched — only Claude's copy is adjusted")
        // Federation needs all four env vars; a partial set must not count as configured.
        check(AnthropicCredential.federationConfigured == false, "no federation env vars here → not configured")
        check(AnthropicCredential.Source.federation.label.contains("federation")
            && AnthropicCredential.Source.storedKey.label.contains("stored"), "each credential source names itself")
        check(!AnthropicCredential.statusLine().isEmpty, "Settings always has a credential line to show")

        print("coffee")
        check(Coffee.milestone(reached: 24) == nil, "no ask below 25 scanned records")
        check(Coffee.milestone(reached: 25) == 25 && Coffee.milestone(reached: 99) == 25, "25–99 → the 25 rung")
        check(Coffee.milestone(reached: 100) == 100 && Coffee.milestone(reached: 249) == 100, "100–249 → the 100 rung")
        check(Coffee.milestone(reached: 250) == 250 && Coffee.milestone(reached: 499) == 250, "250–499 → the 250 rung")
        check(Coffee.milestone(reached: 500) == 500 && Coffee.milestone(reached: 999) == 500, "500–999 → the 500 rung")
        check(Coffee.milestone(reached: 1000) == 1000 && Coffee.milestone(reached: 1499) == 1000 && Coffee.milestone(reached: 1500) == 1500, "then every 500")
        check(Coffee.size(for: 25) == .line && Coffee.size(for: 100) == .card && Coffee.size(for: 250) == .card && Coffee.size(for: 500) == .sheet && Coffee.size(for: 2000) == .sheet, "line at 25, card at 100/250, sheet from 500")
        check(Coffee.laterLabel(for: 25) == "Not now" && Coffee.laterLabel(for: 500) == "I am a monster", "the Later button gets ruder")
        check(Coffee.line(for: 100, count: 112, value: "GBP 1,240").contains("GBP 1,240"), "the 100 rung quotes the collection value")
        check(Coffee.line(for: 1000, count: 1043, value: nil).hasPrefix("1043."), "the 1000 rung concedes")

        print("\(passed) passed, \(failures) failed")
        return failures == 0 ? 0 : 1
    }
}
