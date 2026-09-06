import CoreGraphics
import Foundation

/// Google Gemini generateContent with Gemini 3.8 Flash and a response schema.
struct GeminiReader: SleeveReader {
    let name = "Gemini 3.8 Flash"
    var model = "gemini-3.8-flash"
    var pricing = (input: 0.75, output: 3.75)

    func read(_ image: CGImage, hints: ReadHints) async throws -> ReaderResult {
        guard let key = Keychain.get(.gemini) else { throw ReaderError.missingKey(name) }
        guard let jpeg = image.jpegData() else { throw ReaderError.badResponse("could not encode image") }
        // Gemini's schema dialect: no "additionalProperties", nullable via "nullable": true.
        let schema = geminiSchema(from: SleeveReading.jsonSchema)
        let body: [String: Any] = [
            "systemInstruction": ["parts": [["text": ReaderPrompt.system]]],
            "contents": [[
                "role": "user",
                "parts": [
                    ["text": ReaderPrompt.user(hints: hints)],
                    ["inlineData": ["mimeType": "image/jpeg", "data": jpeg.base64EncodedString()]],
                ],
            ]],
            "generationConfig": [
                "responseMimeType": "application/json",
                "responseSchema": schema,
                "maxOutputTokens": 600,
                "temperature": 0.1,
            ],
        ]
        var req = URLRequest(url: URL(string: "https://generativelanguage.googleapis.com/v1beta/models/\(model):generateContent")!)
        req.httpMethod = "POST"
        req.setValue(key, forHTTPHeaderField: "x-goog-api-key")
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try JSONSerialization.data(withJSONObject: body)
        req.timeoutInterval = 45
        let (data, resp) = try await URLSession.shared.data(for: req)
        let code = (resp as? HTTPURLResponse)?.statusCode ?? 0
        guard (200..<300).contains(code) else { throw ReaderError.http(code, String(data: data, encoding: .utf8) ?? "") }
        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let cands = json["candidates"] as? [[String: Any]],
              let parts = (cands.first?["content"] as? [String: Any])?["parts"] as? [[String: Any]],
              let text = parts.compactMap({ $0["text"] as? String }).first,
              let td = text.data(using: .utf8) else { throw ReaderError.badResponse("no candidate text") }
        let reading = try JSONDecoder().decode(SleeveReading.self, from: td).normalized()
        let usage = json["usageMetadata"] as? [String: Any] ?? [:]
        let inTok = usage["promptTokenCount"] as? Int ?? 0, outTok = usage["candidatesTokenCount"] as? Int ?? 0
        let cost = Double(inTok) / 1e6 * pricing.input + Double(outTok) / 1e6 * pricing.output
        return ReaderResult(reading: reading, usage: ReaderUsage(inputTokens: inTok, outputTokens: outTok, costUSD: cost), provider: name)
    }

    private func geminiSchema(from s: [String: Any]) -> [String: Any] {
        var out: [String: Any] = [:]
        for (k, v) in s {
            switch k {
            case "additionalProperties", "required": continue
            case "type":
                if let arr = v as? [String] {
                    out["type"] = arr.first { $0 != "null" } ?? "string"
                    if arr.contains("null") { out["nullable"] = true }
                } else { out["type"] = v }
            case "enum":
                out["enum"] = (v as? [Any])?.compactMap { $0 as? String }
            case "properties":
                out["properties"] = (v as? [String: [String: Any]])?.mapValues { geminiSchema(from: $0) }
            case "items":
                out["items"] = geminiSchema(from: v as? [String: Any] ?? [:])
            default: out[k] = v
            }
        }
        return out
    }
}
