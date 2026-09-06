import CoreGraphics
import Foundation
import ImageIO

/// Structured reading of a cover or label, as returned by the vision model.
struct SleeveReading: Codable, Sendable, Equatable {
    var artist: String?
    var title: String?
    var label: String?
    var catalogNumber: String?
    var barcode: String?
    var year: Int?
    var country: String?
    /// Model returns "7in" / "10in" / "12in" / "LP"; `normalized()` maps to the app's "7\"" style.
    var formatGuess: String?
    var isLabelShot: Bool?
    var side: String?
    var visibleTracks: [String]?
    /// 0…1 — how sure the model is about artist+title
    var confidence: Double?
    var notes: String?
    /// Every other code printed on the label that could be a catalogue number — matrix numbers, the
    /// album a single was taken from, distributor codes — exactly as printed. The Discogs search tries
    /// these when `catalogNumber` finds nothing.
    var otherNumbers: [String]?

    /// Maps model-side values to the app's conventions (format strings, trimmed text).
    func normalized() -> SleeveReading {
        var r = self
        switch r.formatGuess?.lowercased().replacingOccurrences(of: " ", with: "") {
        case "7in", "7\"", "7inch", "7": r.formatGuess = "7\""
        case "10in", "10\"", "10inch", "10": r.formatGuess = "10\""
        case "12in", "12\"", "12inch", "12": r.formatGuess = "12\""
        case "lp", "album": r.formatGuess = "LP"
        default: break
        }
        for kp in [\SleeveReading.artist, \.title, \.label, \.catalogNumber, \.barcode, \.country] {
            if let v = r[keyPath: kp]?.trimmingCharacters(in: .whitespacesAndNewlines) { r[keyPath: kp] = v.isEmpty ? nil : v }
        }
        if let others = r.otherNumbers {
            let main = CatalogueNumber.normalize(r.catalogNumber ?? "")
            var seen = Set<String>()
            let kept = others.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { !$0.isEmpty && $0.contains(where: \.isNumber) && CatalogueNumber.normalize($0) != main && seen.insert(CatalogueNumber.normalize($0)).inserted }
            r.otherNumbers = kept.isEmpty ? nil : Array(kept.prefix(6))
        }
        return r
    }

    static var jsonSchema: [String: Any] { [
        "type": "object",
        "additionalProperties": false,
        "properties": [
            "artist": ["type": ["string", "null"]],
            "title": ["type": ["string", "null"]],
            "label": ["type": ["string", "null"]],
            "catalogNumber": ["type": ["string", "null"]],
            "barcode": ["type": ["string", "null"]],
            "year": ["type": ["integer", "null"]],
            "country": ["type": ["string", "null"]],
            "formatGuess": ["type": ["string", "null"], "enum": ["7in", "10in", "12in", "LP", NSNull()]],
            "isLabelShot": ["type": ["boolean", "null"]],
            "side": ["type": ["string", "null"]],
            "visibleTracks": ["type": ["array", "null"], "items": ["type": "string"]],
            "confidence": ["type": ["number", "null"]],
            "notes": ["type": ["string", "null"]],
            "otherNumbers": ["type": ["array", "null"], "items": ["type": "string"]],
        ],
        "required": ["artist", "title", "label", "catalogNumber", "barcode", "year", "country", "formatGuess",
                     "isLabelShot", "side", "visibleTracks", "confidence", "notes", "otherNumbers"],
    ] }
}

struct ReaderUsage: Sendable {
    var inputTokens = 0
    var outputTokens = 0
    var costUSD = 0.0
}

struct ReaderResult: Sendable {
    var reading: SleeveReading
    var usage: ReaderUsage
    var provider: String
}

enum ReaderError: LocalizedError {
    case missingKey(String)
    case http(Int, String)
    case badResponse(String)
    var errorDescription: String? {
        switch self {
        case .missingKey(let p): "No API key set for \(p) — add it in Settings."
        case .http(let c, let m): "\(c): \(m)"
        case .badResponse(let m): "Unexpected reply: \(m)"
        }
    }
}

/// A vision model that reads a sleeve/label image into `SleeveReading`.
protocol SleeveReader: Sendable {
    var name: String { get }
    func read(_ image: CGImage, hints: ReadHints) async throws -> ReaderResult
}

struct ReadHints: Sendable {
    var ocrText: String = ""
    var barcodes: [String] = []
    var sessionFormat: String = ""
    var expectLabel = false
    /// Magnified crops of the smallest print (from `LocalReading.closeUps`), sent after the frame.
    var closeUps: [CGImage] = []
}

enum ReaderPrompt {
    /// The frame goes up near its native size: at 1024px the catalogue number on a label is ~6px tall,
    /// too small for any model. Costs a few hundred extra image tokens, a fraction of a cent.
    static let frameMaxSide = 1600
    static let closeUpMaxSide = 1024

    static let system = """
    You identify vinyl records from a photo of a sleeve (cover) or the paper label in the centre of the disc. \
    Extract only what is visible or can be inferred with high confidence. Catalogue numbers matter most: \
    copy them exactly as printed (e.g. "POSP 113", "FAC 73", "7N 17241", "38-06611"). The catalogue number is \
    the label's own issue number, usually the small print near the edge or beside the spindle hole; it is not \
    the matrix/stamper number (e.g. "ZSS 175774"), not the album a single is "from", and not a publisher or \
    ℗ year. Put every other printed code that could be a catalogue number — matrix numbers, the album number, \
    distributor codes — in otherNumbers, exactly as printed. Do not guess a year unless printed. \
    Set isLabelShot true when the photo shows the round centre label. formatGuess: "7in" for a small single label \
    or 45 RPM marking, "12in" for a 45/33 RPM maxi single, "LP" for an album, "10in" for a ten-inch. confidence is \
    your certainty that artist and title are right (0–1). Return JSON matching the schema; use null for unknown fields.
    """

    static func user(hints: ReadHints) -> String {
        var s = "Read this record photo."
        if !hints.sessionFormat.isEmpty { s += " The operator is currently scanning \(hints.sessionFormat)." }
        if hints.expectLabel { s += " This should be the centre label." }
        if !hints.barcodes.isEmpty { s += " Barcode detected locally: \(hints.barcodes.joined(separator: ", "))." }
        if !hints.closeUps.isEmpty, ProcessInfo.processInfo.environment["VINYLCAT_MODEL_PLAIN"] == nil {
            s += " After the photo come \(hints.closeUps.count) magnified close-ups of its smallest print; read catalogue and matrix numbers from those, they are sharper than the photo."
        }
        if !hints.ocrText.isEmpty { s += "\nLocal OCR lines (may contain errors):\n\(hints.ocrText)" }
        return s
    }

    /// JPEGs to attach, frame first then the close-ups. VINYLCAT_MODEL_PLAIN=1 sends the old single
    /// 1024px frame instead, so `--ocr-eval --model` can measure what the close-ups are worth.
    static func images(_ image: CGImage, hints: ReadHints) throws -> [Data] {
        let plain = ProcessInfo.processInfo.environment["VINYLCAT_MODEL_PLAIN"] != nil
        guard let frame = image.jpegData(maxSide: plain ? 1024 : frameMaxSide) else { throw ReaderError.badResponse("could not encode image") }
        return [frame] + (plain ? [] : hints.closeUps.compactMap { $0.jpegData(maxSide: closeUpMaxSide, quality: 0.85) })
    }
}

extension CGImage {
    /// JPEG data for API upload, longest side capped to keep tokens and cost down.
    func jpegData(maxSide: Int = 1024, quality: Double = 0.8) -> Data? {
        let img = PhotoStore.shared.downscale(self, maxSide: maxSide) ?? self
        let data = NSMutableData()
        guard let dest = CGImageDestinationCreateWithData(data, "public.jpeg" as CFString, 1, nil) else { return nil }
        CGImageDestinationAddImage(dest, img, [kCGImageDestinationLossyCompressionQuality: quality] as CFDictionary)
        guard CGImageDestinationFinalize(dest) else { return nil }
        return data as Data
    }
}
