import CoreGraphics
import Foundation

/// Which Claude model the Anthropic reader uses. Persisted in UserDefaults under `claudeModel`;
/// read it through `ClaudeModel.current` so the default stays in one place.
///
/// The default is Opus — the best reader of small worn print, and at one photo per record the
/// difference between the rungs is pennies (see `perPhotoUSD`). Max and Team plans come with
/// monthly Claude API credits that expire at the end of each billing cycle, so for a personal
/// collection the cheap rung mostly saves money that was going to evaporate anyway.
enum ClaudeModel: String, CaseIterable, Identifiable {
    case haiku, sonnet, opus
    var id: String { rawValue }

    var apiName: String {
        switch self {
        case .haiku: "claude-haiku-5-5"
        case .sonnet: "claude-sonnet-5-5"
        case .opus: "claude-opus-5-5"
        }
    }

    var short: String {
        switch self {
        case .haiku: "Haiku 5.5"
        case .sonnet: "Sonnet 5.5"
        case .opus: "Opus 5.5"
        }
    }

    /// $ per 1M tokens (input, output) — verified 2026-10-24.
    var pricing: (input: Double, output: Double) {
        switch self {
        case .haiku: (0.10, 0.50)
        case .sonnet: (2.00, 10.00)
        case .opus: (4.00, 20.00)
        }
    }

    /// Rough cost of one photo. The token counts are fitted to the 2026-10-25 eval rather than
    /// guessed: ~2,600 input (a 1600px frame, its close-ups and the prompt) and ~500 output once
    /// the adaptive reasoning at low effort is counted. That lands within 3% of what the runs
    /// actually billed — $0.00052 measured on Haiku against $0.00051 here, $0.01995 on Opus
    /// against $0.0204. The earlier 3,000/800 guess ran ~40% high. What actually got spent shows
    /// in Settings → "Spend this session" after the first scan.
    var perPhotoUSD: Double { 2_600 / 1e6 * pricing.input + 500 / 1e6 * pricing.output }

    /// What the picker says about this rung.
    var note: String {
        let cents = String(format: "%.2f", perPhotoUSD * 100)
        switch self {
        case .haiku: return "≈\(cents)¢ a photo · catalogue number right first time on 94% · fastest"
        case .sonnet: return "≈\(cents)¢ a photo · middle rung, not measured"
        case .opus: return "≈\(cents)¢ a photo · right first time on 97% · the best reader"
        }
    }

    static var current: ClaudeModel {
        ClaudeModel(rawValue: UserDefaults.standard.string(forKey: "claudeModel") ?? "") ?? .opus
    }

    /// Why the picker usually does not matter, stated in the app at Woody's request. One photo per
    /// record keeps every rung in fractions of a cent, so the choice only starts to bite at volume.
    static var costAdvice: String {
        let cheap = String(format: "%.2f¢", haiku.perPhotoUSD * 100)
        let best = String(format: "%.1f¢", opus.perPhotoUSD * 100)
        let thousand = String(format: "$%.0f", opus.perPhotoUSD * 1000)
        return "One photo per record, so the rungs sit about two cents apart — \(cheap) against \(best) a photo, about "
            + "\(thousand) for a thousand records on the dearest. Measured over the same 100 records, Opus read the catalogue "
            + "number correctly first time on 97% and Haiku on 94%; counting the other numbers it also returns — which the "
            + "Discogs search tries too — they are 98% and 97%, near enough a tie. Take the best reader unless you are "
            + "scanning at real volume: Max and Team plans come with monthly API credits that expire at the end of each "
            + "billing cycle, so if yours are going unspent, saving pennies here only loses money you had already paid for."
    }
}

/// Anthropic Messages API with a JSON-schema response format. One reader covers all three rungs —
/// the model comes from the Settings picker, so switching is a UserDefaults write, not a new type.
struct ClaudeReader: SleeveReader {
    var model = ClaudeModel.current
    var name: String { "Claude \(model.short)" }

    private func post(_ body: [String: Any], auth: AnthropicCredential.Auth) async throws -> (Data, Int) {
        var req = URLRequest(url: URL(string: "https://api.anthropic.com/v1/messages")!)
        req.httpMethod = "POST"
        switch auth {
        case .apiKey(let key):
            req.setValue(key, forHTTPHeaderField: "x-api-key")
        case .bearer(let token):
            // A federated or OAuth token goes on Authorization, and /v1/messages rejects it
            // without the oauth beta header — it is a header change, not a key swap.
            req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
            req.setValue("oauth-2025-04-20", forHTTPHeaderField: "anthropic-beta")
        }
        req.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try JSONSerialization.data(withJSONObject: body)
        // Opus still reasons before it answers even at low effort, so this is longer than the 45s
        // the other two readers use.
        req.timeoutInterval = 60
        let (data, resp) = try await URLSession.shared.data(for: req)
        return (data, (resp as? HTTPURLResponse)?.statusCode ?? 0)
    }

    func read(_ image: CGImage, hints: ReadHints) async throws -> ReaderResult {
        guard let cred = await AnthropicCredential.resolve() else { throw ReaderError.missingKey(name) }
        var auth = cred.auth
        let jpegs = try ReaderPrompt.images(image, hints: hints)
        let content: [[String: Any]] = [["type": "text", "text": ReaderPrompt.user(hints: hints)]]
            + jpegs.map { ["type": "image", "source": ["type": "base64", "media_type": "image/jpeg", "data": $0.base64EncodedString()]] as [String: Any] }
        var body: [String: Any] = [
            "model": model.apiName,
            "system": ReaderPrompt.system,
            "messages": [["role": "user", "content": content] as [String: Any]],
            // Thinking is adaptive on every current model and cannot be switched off on Opus 5.5 or
            // Sonnet 5.5 (`thinking: {type: "disabled"}` is a 400 there), so effort is the only
            // lever. Low is plenty for reading print off a label and keeps the reasoning tokens —
            // billed as output — small.
            "output_config": [
                "effort": "low",
                "format": ["type": "json_schema", "schema": Self.schema],
            ],
            // Reasoning tokens come out of this budget too, and Claude thinks before the
            // schema-constrained reply, so there is more headroom here than the 2500 the other
            // readers use. What is billed is what gets used, not the cap.
            "max_tokens": 4000,
        ]
        var (data, code) = try await post(body, auth: auth)
        if code == 401, case .bearer = auth {
            // A short-lived token that expired between resolve and send: mint a fresh one once.
            await AnthropicCredential.invalidate()
            if let again = await AnthropicCredential.resolve() {
                auth = again.auth
                (data, code) = try await post(body, auth: auth)
            }
        }
        if code == 400, let msg = String(data: data, encoding: .utf8),
           msg.contains("output_config") || msg.contains("schema") || msg.contains("format") {
            // The shared schema leans on ["string","null"] unions and a null in the format enum.
            // If this API build won't constrain output to it, ask for the same JSON in the prompt
            // and parse it out of the text block instead.
            body["output_config"] = ["effort": "low"]
            if var msgs = body["messages"] as? [[String: Any]], var c = msgs[0]["content"] as? [[String: Any]] {
                c[0]["text"] = (c[0]["text"] as? String ?? "") + "\n\nReply with JSON only — no prose, no code fences — matching this schema:\n" + (Self.schemaText ?? "")
                msgs[0]["content"] = c
                body["messages"] = msgs
            }
            (data, code) = try await post(body, auth: auth)
        }
        guard (200..<300).contains(code) else { throw ReaderError.http(code, String(data: data, encoding: .utf8) ?? "") }
        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] else { throw ReaderError.badResponse("not JSON") }
        switch json["stop_reason"] as? String {
        case "refusal":
            // Only populated on a refusal; every other stop reason leaves stop_details null.
            let why = (json["stop_details"] as? [String: Any])?["explanation"] as? String
            throw ReaderError.badResponse("declined" + (why.map { ": \($0)" } ?? ""))
        case "max_tokens":
            throw ReaderError.badResponse("reply cut off at max_tokens")
        default: break
        }
        // content[] can carry thinking blocks ahead of the answer; the JSON is in the first text one.
        guard let blocks = json["content"] as? [[String: Any]],
              let text = blocks.first(where: { $0["type"] as? String == "text" })?["text"] as? String,
              let td = Self.jsonBody(of: text).data(using: .utf8) else { throw ReaderError.badResponse("no text block") }
        let reading: SleeveReading
        do { reading = try JSONDecoder().decode(SleeveReading.self, from: td).normalized() } catch {
            Log.scan.error("model JSON unreadable: \(text.prefix(200))")
            throw ReaderError.badResponse("unreadable JSON: \(text.prefix(60))")
        }
        let usage = json["usage"] as? [String: Any] ?? [:]
        let inTok = usage["input_tokens"] as? Int ?? 0, outTok = usage["output_tokens"] as? Int ?? 0
        let cost = Double(inTok) / 1e6 * model.pricing.input + Double(outTok) / 1e6 * model.pricing.output
        return ReaderResult(reading: reading, usage: ReaderUsage(inputTokens: inTok, outputTokens: outTok, costUSD: cost), provider: name)
    }

    /// `SleeveReading.jsonSchema` with one change, the only one Anthropic needs: a property that
    /// carries an `enum` must not also declare a type union. `formatGuess` is
    /// `["string","null"]` + an enum, which is rejected outright —
    /// *"Enum value '7in' does not match declared type '['string', 'null']'"*. Dropping `type` and
    /// leaving the null in the enum keeps both the constraint and the nullability (verified
    /// 2026-10-25 against claude-haiku-5-5). The `["string","null"]` unions on every other
    /// property are accepted as they stand, so unlike Gemini this is not a dialect rewrite.
    static var schema: [String: Any] {
        var s = SleeveReading.jsonSchema
        guard var props = s["properties"] as? [String: [String: Any]] else { return s }
        for (name, p) in props where p["enum"] != nil {
            var fixed = p
            fixed["type"] = nil
            props[name] = fixed
        }
        s["properties"] = props
        return s
    }

    static var schemaText: String? {
        (try? JSONSerialization.data(withJSONObject: schema)).flatMap { String(data: $0, encoding: .utf8) }
    }

    /// The schema-constrained reply is bare JSON, but the prompt-only fallback can arrive fenced.
    static func jsonBody(of text: String) -> String {
        let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard t.hasPrefix("```") else { return t }
        let inner = t.drop(while: { $0 != "\n" }).dropLast(3)
        return inner.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
