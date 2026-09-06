import CoreGraphics
import Foundation
import Observation

/// Which provider to use; persisted in UserDefaults.
enum ReaderProvider: String, CaseIterable, Identifiable {
    case luna, gemini
    var id: String { rawValue }
    var title: String { self == .luna ? "GPT-5.6 Luna" : "Gemini 3.8 Flash" }
    var reader: any SleeveReader { self == .luna ? LunaReader() : GeminiReader() }
}

/// Runs the local pass then (if needed) the model, and keeps the running cost.
@MainActor
@Observable
final class Identifier {
    var provider: ReaderProvider {
        didSet { UserDefaults.standard.set(provider.rawValue, forKey: "readerProvider") }
    }
    var skipModelWhenBarcode = true
    private(set) var sessionCostUSD = 0.0
    private(set) var reads = 0

    init() {
        provider = ReaderProvider(rawValue: UserDefaults.standard.string(forKey: "readerProvider") ?? "") ?? .luna
    }

    struct Outcome: Sendable {
        var local: LocalReading
        var model: SleeveReading?
        var provider: String?
        /// Best merged view of what's on the record.
        var reading: SleeveReading
    }

    func identify(_ image: CGImage, sessionFormat: String, expectLabel: Bool, onStep: @MainActor (String) -> Void) async throws -> Outcome {
        onStep("local OCR + barcode")
        let local = try await LocalReader.read(image)
        var merged = SleeveReading()
        merged.barcode = local.barcodes.first
        merged.catalogNumber = local.catalogueCandidates.first

        if skipModelWhenBarcode, let b = local.barcodes.first, b.count >= 8 {
            onStep("barcode \(b) — model skipped")
            merged.confidence = 0.5
            return Outcome(local: local, model: nil, provider: nil, reading: merged)
        }

        onStep("\(provider.title) reading")
        let hints = ReadHints(ocrText: local.text, barcodes: local.barcodes, sessionFormat: sessionFormat, expectLabel: expectLabel)
        let r = try await provider.reader.read(image, hints: hints)
        sessionCostUSD += r.usage.costUSD
        reads += 1
        var m = r.reading
        if m.catalogNumber == nil { m.catalogNumber = local.catalogueCandidates.first }
        if m.barcode == nil { m.barcode = local.barcodes.first }
        return Outcome(local: local, model: r.reading, provider: r.provider, reading: m)
    }
}
