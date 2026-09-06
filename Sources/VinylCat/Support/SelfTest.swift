import Foundation

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

        print("\(passed) passed, \(failures) failed")
        return failures == 0 ? 0 : 1
    }
}
