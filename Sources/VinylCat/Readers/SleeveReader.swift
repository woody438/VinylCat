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
    /// "7\"", "10\"", "12\"", "LP" or null
    var formatGuess: String?
    var isLabelShot: Bool?
    var side: String?
    var visibleTracks: [String]?
    /// 0…1 — how sure the model is about artist+title
    var confidence: Double?
    var notes: String?

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
            "formatGuess": ["type": ["string", "null"], "enum": ["7\"", "10\"", "12\"", "LP", NSNull()]],
            "isLabelShot": ["type": ["boolean", "null"]],
            "side": ["type": ["string", "null"]],
            "visibleTracks": ["type": ["array", "null"], "items": ["type": "string"]],
            "confidence": ["type": ["number", "null"]],
            "notes": ["type": ["string", "null"]],
        ],
        "required": ["artist", "title", "label", "catalogNumber", "barcode", "year", "country", "formatGuess",
                     "isLabelShot", "side", "visibleTracks", "confidence", "notes"],
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
}

enum ReaderPrompt {
    static let system = """
    You identify vinyl records from a photo of a sleeve (cover) or the paper label in the centre of the disc. \
    Extract only what is visible or can be inferred with high confidence. Catalogue numbers matter most: \
    copy them exactly as printed (e.g. "POSP 113", "FAC 73", "7N 17241"). Do not guess a year unless printed. \
    Set isLabelShot true when the photo shows the round centre label. formatGuess: 7" for a small single label \
    or 45 RPM marking, 12" for a 45/33 RPM maxi, LP for an album. confidence is your certainty that artist and \
    title are right (0–1). Return JSON matching the schema; use null for unknown fields.
    """

    static func user(hints: ReadHints) -> String {
        var s = "Read this record photo."
        if !hints.sessionFormat.isEmpty { s += " The operator is currently scanning \(hints.sessionFormat)." }
        if hints.expectLabel { s += " This should be the centre label." }
        if !hints.barcodes.isEmpty { s += " Barcode detected locally: \(hints.barcodes.joined(separator: ", "))." }
        if !hints.ocrText.isEmpty { s += "\nLocal OCR lines (may contain errors):\n\(hints.ocrText)" }
        return s
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
