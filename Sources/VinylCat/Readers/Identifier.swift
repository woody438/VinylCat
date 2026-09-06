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
    /// True once a scan ran without any model key — the HUD nudges the user to add one.
    private(set) var modelSkippedForMissingKey = false
    var hasAnyKey: Bool { Keychain.get(.openAI) != nil || Keychain.get(.gemini) != nil }

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
        let r: ReaderResult
        do { r = try await provider.reader.read(image, hints: hints) } catch ReaderError.missingKey {
            // No model key yet: OCR-only guess (catalogue number does most of the work anyway).
            onStep("no model key — OCR only")
            modelSkippedForMissingKey = true
            merged.isLabelShot = expectLabel || local.lines.contains { $0.uppercased().contains("RPM") || $0.uppercased().hasPrefix("SIDE") }
            let words = local.lines.filter { $0.count > 4 && !$0.contains(where: \.isNumber) && !$0.hasPrefix("(") && !$0.uppercased().hasPrefix("SIDE") }
            merged.title = words.dropFirst().first ?? words.first
            merged.artist = words.dropFirst(2).first ?? words.first
            merged.label = words.first
            merged.confidence = 0.3
            return Outcome(local: local, model: nil, provider: nil, reading: merged)
        }
        sessionCostUSD += r.usage.costUSD
        reads += 1
        var m = r.reading
        if m.catalogNumber == nil { m.catalogNumber = local.catalogueCandidates.first }
        if m.barcode == nil { m.barcode = local.barcodes.first }
        return Outcome(local: local, model: r.reading, provider: r.provider, reading: m)
    }
}
