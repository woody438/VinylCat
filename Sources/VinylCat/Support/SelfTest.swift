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
        feed(0, frames: 6); feed(2, frames: 12)
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

        print("formats")
        check(VinylFormat.allCases.count == 3 && VinylFormat.seven.discogsFormat == "7\"", "format mapping")

        print("voice phrases")
        check(VoiceCommand.match(trailing: "ok capture") == .capture, "trailing word matches")
        check(VoiceCommand.match(trailing: "flip it") == .flip, "multi-word phrase")
        check(VoiceCommand.match(trailing: "number two") == .two, "longest phrase wins")
        check(VoiceCommand.match(trailing: "forty fives") == .sevens, "format switch")
        check(VoiceCommand.match(trailing: "capturing") == nil, "no partial-word matches")
        check(VoiceCommand.match(trailing: "back cover") == .backCover && VoiceCommand.match(trailing: "back") == .backCover, "back cover")

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
        rec.expectedShots = [.labelA, .labelB]
        rec.photos = [ScanPhoto(recordID: rec.id, fileName: "x.jpg", kind: .labelA, order: 0)]
        store.insert(rec)
        let back = store.fetch(rec.id)
        check(back != nil, "fetch after insert")
        check(back?.discogsReleaseID == 2413807 && back?.tracks.first?.duration == "2:58" && back?.genres == ["Rock"], "fields and JSON columns survive")
        check(back?.photos.count == 1 && back?.missingShots == [.labelB] && back?.isComplete == false, "photos + expected shots")
        check(store.existing(discogsReleaseID: 2413807)?.id == rec.id, "duplicate lookup by release id")
        rec.photos.append(ScanPhoto(recordID: rec.id, fileName: "y.jpg", kind: .labelB, order: 1)); store.update(rec)
        check(store.fetch(rec.id)?.isComplete == true, "update adds photo → complete")
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

        print("\(passed) passed, \(failures) failed")
        return failures == 0 ? 0 : 1
    }
}
