import CoreGraphics
import Foundation
import Observation

/// Which provider to use; persisted in UserDefaults.
enum ReaderProvider: String, CaseIterable, Identifiable {
    case luna, gemini, claude
    var id: String { rawValue }

    /// Claude's title follows the model picker, so the HUD step and any error name the rung.
    var title: String {
        switch self {
        case .luna: "GPT-5.6 Luna"
        case .gemini: "Gemini 3.8 Flash"
        case .claude: "Claude \(ClaudeModel.current.short)"
        }
    }

    var reader: any SleeveReader {
        switch self {
        case .luna: LunaReader()
        case .gemini: GeminiReader()
        case .claude: ClaudeReader()
        }
    }

    var key: Secrets.Key {
        switch self {
        case .luna: .openAI
        case .gemini: .gemini
        case .claude: .anthropic
        }
    }

    var keyLabel: String {
        switch self {
        case .luna: "OpenAI API key"
        case .gemini: "Google AI key"
        case .claude: "Anthropic API key"
        }
    }

    var keyPlaceholder: String {
        switch self {
        case .luna: "sk-…"
        case .gemini: "AIza…"
        case .claude: "sk-ant-…"
        }
    }

    var keysURL: URL {
        switch self {
        case .luna: URL(string: "https://platform.openai.com/api-keys")!
        case .gemini: URL(string: "https://aistudio.google.com/apikey")!
        case .claude: URL(string: "https://platform.claude.com/settings/keys")!
        }
    }

    /// One line under the picker: roughly what a photo costs on this provider.
    var costNote: String {
        switch self {
        case .luna: "about $0.001 per photo"
        case .gemini: "about $0.002 per photo"
        // No price here: the rung's own `note` states it just above this line, and repeating it as
        // dollars beside the cents read as two different figures.
        case .claude: "billed to your Anthropic account, or its monthly credits"
        }
    }
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
    /// Month-to-date and all-time spend, kept across launches (`SpendLedger`).
    private(set) var spend = SpendLedger.load()
    /// Monthly spend past which the LLM COST meter turns amber. A warning only; 0 switches it off.
    var monthlyBudgetUSD: Double {
        didSet { UserDefaults.standard.set(monthlyBudgetUSD, forKey: "llmBudget") }
    }
    var overBudget: Bool { spend.isOver(budgetUSD: monthlyBudgetUSD) }
    /// True once a scan ran without any model key — the HUD nudges the user to add one.
    private(set) var modelSkippedForMissingKey = false
    /// Cached: the HUD reads this on every frame, and each Keychain query is a round trip to
    /// securityd. Settings calls `refreshKeys()` after a save.
    private(set) var hasAnyKey = false

    init() {
        provider = ReaderProvider(rawValue: UserDefaults.standard.string(forKey: "readerProvider") ?? "") ?? .luna
        monthlyBudgetUSD = UserDefaults.standard.object(forKey: "llmBudget") as? Double ?? 5.0
        refreshKeys()
    }

    /// The Claude reader also works with no stored key at all when the `ant` CLI can hand over a
    /// short-lived token, so the presence of the CLI counts here — a sync filesystem probe, not a
    /// token mint, so the HUD can call this without waiting on a subprocess.
    func refreshKeys() {
        hasAnyKey = Keychain.get(.openAI) != nil || Keychain.get(.gemini) != nil
            || Keychain.get(.anthropic) != nil || AnthropicCredential.cliURL != nil
    }

    struct Outcome: Sendable {
        var local: LocalReading
        var model: SleeveReading?
        var provider: String?
        /// Best merged view of what's on the record.
        var reading: SleeveReading
        /// Set when the model was asked and failed; the scan carried on with OCR alone.
        var modelError: String?

        /// One line for the HUD and the review queue: what the record was read as, and by whom.
        /// The model's reading is what the search actually ran on, so it comes first; the OCR
        /// lines only show when that is all there was.
        var readSummary: String {
            if let m = model {
                let who = [m.artist, m.title].compactMap { $0 }.joined(separator: " — ")
                let what = [m.label, m.catalogNumber].compactMap { $0 }.joined(separator: " ")
                let parts = [who, what, m.year.map(String.init) ?? ""].filter { !$0.isEmpty }
                return "Model read: " + (parts.isEmpty ? "nothing it was sure of" : parts.joined(separator: " · "))
            }
            let ocr = local.lines.prefix(4).joined(separator: " · ")
            var s = ocr.isEmpty ? "Nothing readable in that shot" : "OCR read: \(ocr)"
            if let e = modelError { s = "Model failed (\(e)) · " + s }
            return s
        }
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
        let hints = ReadHints(ocrText: local.text, barcodes: local.barcodes, sessionFormat: sessionFormat, expectLabel: expectLabel, closeUps: local.closeUps)
        let r: ReaderResult
        do { r = try await provider.reader.read(image, hints: hints) } catch {
            // The model is the stronger reader, but a failed call must not cost the scan: carry on
            // with OCR alone, say so, and let the HUD show why (the review queue keeps the note).
            var reason: String?
            if case ReaderError.missingKey = error {
                onStep("no model key — OCR only")
                modelSkippedForMissingKey = true
            } else {
                reason = FriendlyError.describe(error, context: provider.title)
                Log.scan.error("model failed: \(error) — \(reason ?? "")")
                onStep("model failed — OCR only")
            }
            // Without a model we can't see the shape; singles are nearly always label shots, and label-ish words settle the rest.
            let labelWords = ["RPM", "SIDE A", "SIDE B", "SIDE 1", "SIDE 2", "SIDE ONE", "SIDE TWO", "MADE IN", "℗", "(P)"]
            merged.isLabelShot = expectLabel || sessionFormat.contains("seven") || sessionFormat.contains("twelve")
                || local.lines.contains { l in labelWords.contains { l.uppercased().contains($0) } }
            let words = local.lines.filter { $0.count > 4 && !$0.contains(where: \.isNumber) && !$0.hasPrefix("(") && !$0.uppercased().hasPrefix("SIDE") }
            merged.title = words.dropFirst().first ?? words.first
            merged.artist = words.dropFirst(2).first ?? words.first
            merged.label = words.first
            merged.confidence = 0.3
            return Outcome(local: local, model: nil, provider: nil, reading: merged, modelError: reason)
        }
        sessionCostUSD += r.usage.costUSD
        reads += 1
        spend.add(costUSD: r.usage.costUSD); spend.save()
        var m = r.reading
        if m.catalogNumber == nil { m.catalogNumber = local.catalogueCandidates.first }
        if m.barcode == nil { m.barcode = local.barcodes.first }
        return Outcome(local: local, model: r.reading, provider: r.provider, reading: m)
    }
}
