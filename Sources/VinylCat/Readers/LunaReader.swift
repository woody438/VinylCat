import CoreGraphics
import Foundation

/// OpenAI Responses API with GPT-5.6 Luna and a strict JSON schema.
struct LunaReader: SleeveReader {
    let name = "GPT-5.6 Luna"
    var model = "gpt-5.6-luna"
    /// $ per 1M tokens (input, output) — verified 2026-09.
    var pricing = (input: 0.20, output: 1.20)

    private func post(_ body: [String: Any], key: String) async throws -> (Data, Int) {
        var req = URLRequest(url: URL(string: "https://api.openai.com/v1/responses")!)
        req.httpMethod = "POST"
        req.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try JSONSerialization.data(withJSONObject: body)
        req.timeoutInterval = 45
        let (data, resp) = try await URLSession.shared.data(for: req)
        return (data, (resp as? HTTPURLResponse)?.statusCode ?? 0)
    }

    func read(_ image: CGImage, hints: ReadHints) async throws -> ReaderResult {
        guard let key = Keychain.get(.openAI) else { throw ReaderError.missingKey(name) }
        let jpegs = try ReaderPrompt.images(image, hints: hints)
        let body: [String: Any] = [
            "model": model,
            "instructions": ReaderPrompt.system,
            "input": [[
                "role": "user",
                "content": [["type": "input_text", "text": ReaderPrompt.user(hints: hints)] as [String: Any]]
                    + jpegs.map { ["type": "input_image", "image_url": "data:image/jpeg;base64," + $0.base64EncodedString(), "detail": "high"] as [String: Any] },
            ]],
            "text": ["format": [
                "type": "json_schema", "name": "sleeve_reading", "strict": true, "schema": SleeveReading.jsonSchema,
            ]],
            "reasoning": ["effort": "low"],
            // Reasoning tokens count against this budget. At 600 the model sometimes ran out mid-JSON
            // — "no output_text", or a cut-off reply Foundation reported as "data in the wrong
            // format" — so the cap is generous; what is billed is what gets used, not the cap.
            "max_output_tokens": 2500,
        ]
        var (data, code) = try await post(body, key: key)
        if code == 400, let msg = String(data: data, encoding: .utf8), msg.contains("reasoning") || msg.contains("detail") {
            // Older/newer parameter surface — drop the optional knobs and try once more.
            var slim = body
            slim["reasoning"] = nil
            if var input = slim["input"] as? [[String: Any]], var content = input[0]["content"] as? [[String: Any]], content.count > 1 {
                for i in content.indices { content[i]["detail"] = nil }
                input[0]["content"] = content; slim["input"] = input
            }
            (data, code) = try await post(slim, key: key)
        }
        guard (200..<300).contains(code) else { throw ReaderError.http(code, String(data: data, encoding: .utf8) ?? "") }
        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] else { throw ReaderError.badResponse("not JSON") }
        if json["status"] as? String == "incomplete" {
            let why = ((json["incomplete_details"] as? [String: Any])?["reason"] as? String) ?? "cut off"
            throw ReaderError.badResponse("reply \(why)")
        }

        // Find the first output_text in output[].content[].
        var text: String?
        for item in json["output"] as? [[String: Any]] ?? [] {
            for c in item["content"] as? [[String: Any]] ?? [] where c["type"] as? String == "output_text" {
                text = c["text"] as? String; break
            }
            if text != nil { break }
        }
        guard let text, let td = text.data(using: .utf8) else { throw ReaderError.badResponse("no output_text") }
        let reading: SleeveReading
        do { reading = try JSONDecoder().decode(SleeveReading.self, from: td).normalized() } catch {
            Log.scan.error("model JSON unreadable: \(text.prefix(200))")
            throw ReaderError.badResponse("unreadable JSON: \(text.prefix(60))")
        }
        let usage = json["usage"] as? [String: Any] ?? [:]
        let inTok = usage["input_tokens"] as? Int ?? 0, outTok = usage["output_tokens"] as? Int ?? 0
        let cost = Double(inTok) / 1e6 * pricing.input + Double(outTok) / 1e6 * pricing.output
        return ReaderResult(reading: reading, usage: ReaderUsage(inputTokens: inTok, outputTokens: outTok, costUSD: cost), provider: name)
    }
}
