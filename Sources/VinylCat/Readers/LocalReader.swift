import CoreGraphics
import Foundation
@preconcurrency import Vision

/// What Apple Vision found on a still: barcodes + OCR lines. Free and on-device.
struct LocalReading: Sendable {
    var barcodes: [String] = []
    var lines: [String] = []
    /// Catalogue-number-looking tokens pulled from the OCR text, best first.
    var catalogueCandidates: [String] = []
    var text: String { lines.joined(separator: "\n") }
}

enum LocalReader {
    static func read(_ image: CGImage) async throws -> LocalReading {
        try await withCheckedThrowingContinuation { cont in
            let barcode = VNDetectBarcodesRequest()
            barcode.symbologies = [.ean13, .ean8, .upce, .code128, .code39]
            let text = VNRecognizeTextRequest()
            text.recognitionLevel = .accurate
            text.usesLanguageCorrection = false
            text.recognitionLanguages = ["en-GB", "en-US", "fr-FR", "de-DE"]
            let handler = VNImageRequestHandler(cgImage: image, options: [:])
            DispatchQueue.global(qos: .userInitiated).async {
                do {
                    try handler.perform([barcode, text])
                    var r = LocalReading()
                    r.barcodes = (barcode.results ?? []).compactMap { $0.payloadStringValue }
                    r.lines = (text.results ?? []).compactMap { $0.topCandidates(1).first?.string }
                    r.catalogueCandidates = CatalogueNumber.candidates(in: r.lines)
                    cont.resume(returning: r)
                } catch {
                    cont.resume(throwing: error)
                }
            }
        }
    }
}

/// Heuristics for record catalogue numbers: "POSP 113", "CHS TT 17", "FAC 73", "2059 227", "7N 17241", "SRK 6095".
enum CatalogueNumber {
    private static let pattern = try! NSRegularExpression(
        pattern: #"\b(?:[A-Z0-9]{1,6}[ .\-]?){0,2}\d{1,7}(?:[ .\-]\d{2,5})?\b"#)

    static func candidates(in lines: [String]) -> [String] {
        var seen = Set<String>()
        var out: [String] = []
        for line in lines {
            let u = line.uppercased()
            let ns = u as NSString
            for m in pattern.matches(in: u, range: NSRange(location: 0, length: ns.length)) {
                let s = ns.substring(with: m.range).trimmingCharacters(in: .whitespaces)
                let digits = s.filter(\.isNumber).count
                let letters = s.filter(\.isLetter).count
                // Skip years, RPMs and bare numbers; prefer letter+digit combos.
                if letters == 0 && (digits == 4 || s == "45" || s == "33") { continue }
                if letters == 0 && digits < 5 { continue }
                if letters > 0 && digits == 1 && letters < 3 { continue }   // "A1", "B2" side markers
                let key = s.replacingOccurrences(of: " ", with: "")
                if seen.insert(key).inserted { out.append(s) }
            }
        }
        // Letter+digit combos first, then longer strings.
        return out.sorted { a, b in
            let la = a.contains { $0.isLetter }, lb = b.contains { $0.isLetter }
            if la != lb { return la }
            return a.count > b.count
        }
    }

    /// Normalise for comparison: uppercase, drop spaces/punctuation, strip leading zeros in numeric runs.
    static func normalize(_ s: String) -> String {
        s.uppercased().filter { $0.isLetter || $0.isNumber }
    }
}
