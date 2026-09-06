import Foundation

struct Candidate: Identifiable, Sendable {
    var result: DiscogsClient.SearchResult
    var score: Double
    var reasons: [String]
    var id: Int { result.id }
    /// Exact catalogue number (or barcode) plus a title match — enough to accept even below the score threshold.
    var isStrong: Bool { (reasons.contains("catno") || reasons.contains("barcode")) && reasons.contains(where: { $0.hasPrefix("title") }) }
    /// Same label + catno + country + year ⇒ indistinguishable from a photo; treated as one candidate.
    var variantKey: String {
        [result.label?.first, result.catno, result.country, result.year].map { ($0 ?? "").uppercased() }.joined(separator: "|")
    }
    var sameMaster: (Candidate) -> Bool { { other in self.result.master_id != nil && self.result.master_id == other.result.master_id } }
    /// "NEW ORDER — BLUE MONDAY", from Discogs' "New Order (2) - Blue Monday" search title.
    var headline: String {
        let t = result.title.replacingOccurrences(of: #" \(\d+\)"#, with: "", options: .regularExpression)
        let parts = t.components(separatedBy: " - ").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        return parts.joined(separator: " — ").uppercased()
    }
    /// "POLYDOR POSP 113 · UK · 1980 · 7\""
    var summary: String {
        var parts: [String] = []
        if let l = result.label?.first { parts.append(l.uppercased()) }
        if let c = result.catno, c != "none" { parts.append(c.uppercased()) }
        if let c = result.country { parts.append(c.uppercased()) }
        if let y = result.year, !y.isEmpty { parts.append(y) }
        if let f = result.format?.first(where: { ["7\"", "10\"", "12\"", "LP"].contains($0) }) ?? result.format?.first { parts.append(f) }
        return parts.joined(separator: " · ")
    }
    /// Same, but readable aloud.
    var spoken: String {
        summary.replacingOccurrences(of: " · ", with: ", ").replacingOccurrences(of: "7\"", with: "seven inch")
            .replacingOccurrences(of: "12\"", with: "twelve inch").replacingOccurrences(of: "10\"", with: "ten inch").replacingOccurrences(of: "LP", with: "album")
    }
}

/// Scores Discogs search hits against what was read from the record.
enum CandidateRanker {
    /// Country preferred on ties, from the valuation currency (GBP → UK, USD → US, …).
    static var preferredCountry: String {
        switch UserDefaults.standard.string(forKey: "currency") ?? "GBP" {
        case "GBP": "UK"; case "USD": "US"; case "CAD": "Canada"; case "EUR": "Europe"; default: ""
        }
    }

    static func rank(_ results: [DiscogsClient.SearchResult], reading: SleeveReading, sessionFormat: VinylFormat?) -> [Candidate] {
        var seen = Set<Int>()
        let out: [Candidate] = results.compactMap { r in
            guard seen.insert(r.id).inserted else { return nil }
            var score = 0.0
            var why: [String] = []

            if let cat = reading.catalogNumber, let rc = r.catno, !rc.isEmpty {
                let a = CatalogueNumber.normalize(cat), b = CatalogueNumber.normalize(rc)
                if a == b { score += 0.5; why.append("catno") }
                else if a.count >= 4 && (a.hasSuffix(b) || b.hasSuffix(a) || a.contains(b) || b.contains(a)) { score += 0.3; why.append("catno≈") }
            }
            if let bc = reading.barcode, let rb = r.barcode, rb.contains(where: { $0.filter(\.isNumber) == bc.filter(\.isNumber) }) {
                score += 0.5; why.append("barcode")
            }
            if let label = reading.label, let rl = r.label?.first, similarity(label, rl) > 0.85 {
                score += 0.15; why.append("label")
            }
            let sim = titleSimilarity(reading: reading, resultTitle: r.title)
            if sim > 0.6 { score += 0.25 * sim; why.append(String(format: "title %.2f", sim)) }
            if let pc = preferredCountry.nilIfEmpty, r.country?.caseInsensitiveCompare(pc) == .orderedSame { score += 0.03 }
            if let wanted = sessionFormat?.discogsFormat ?? reading.formatGuess, let fmts = r.format {
                if fmts.contains(where: { $0.caseInsensitiveCompare(wanted) == .orderedSame }) { score += 0.1; why.append("format") }
                else { score -= 0.15; why.append("format✗") }
            }
            if let y = reading.year, let ry = Int(r.year ?? ""), abs(y - ry) <= 1 { score += 0.05; why.append("year") }
            return Candidate(result: r, score: min(1, max(0, score)), reasons: why)
        }
        return out.sorted { $0.score > $1.score }
    }

    /// Best of: whole "Artist - Title" vs result, or per-part matching that tolerates artist/title being swapped.
    static func titleSimilarity(reading: SleeveReading, resultTitle: String) -> Double {
        let parts = resultTitle.components(separatedBy: " - ")
        let rArtist = parts.count > 1 ? parts[0] : ""
        let rTitle = parts.count > 1 ? parts.dropFirst().joined(separator: " - ") : resultTitle
        let a = reading.artist ?? "", t = reading.title ?? ""
        if a.isEmpty && t.isEmpty { return 0 }
        var best = 0.0
        if !a.isEmpty && !t.isEmpty { best = similarity("\(a) - \(t)", resultTitle) }
        let titlePart = max(t.isEmpty ? 0 : similarity(t, rTitle), a.isEmpty ? 0 : similarity(a, rTitle))
        let artistPart = rArtist.isEmpty ? titlePart : max(a.isEmpty ? 0 : similarity(a, rArtist), t.isEmpty ? 0 : similarity(t, rArtist))
        let partial = (a.isEmpty || t.isEmpty) ? max(titlePart, artistPart) : (titlePart + artistPart) / 2
        return max(best, partial)
    }

    /// Jaro–Winkler similarity on lower-cased, punctuation-stripped strings (0…1).
    static func similarity(_ a: String, _ b: String) -> Double {
        let s1 = Array(clean(a)), s2 = Array(clean(b))
        if s1.isEmpty || s2.isEmpty { return 0 }
        if s1 == s2 { return 1 }
        let window = max(s1.count, s2.count) / 2 - 1
        var m1 = [Bool](repeating: false, count: s1.count), m2 = [Bool](repeating: false, count: s2.count)
        var matches = 0
        for i in 0..<s1.count {
            let lo = max(0, i - window), hi = min(s2.count - 1, i + window)
            if lo > hi { continue }
            for j in lo...hi where !m2[j] && s1[i] == s2[j] { m1[i] = true; m2[j] = true; matches += 1; break }
        }
        if matches == 0 { return 0 }
        var t = 0, k = 0
        for i in 0..<s1.count where m1[i] {
            while !m2[k] { k += 1 }
            if s1[i] != s2[k] { t += 1 }
            k += 1
        }
        let m = Double(matches)
        let jaro = (m / Double(s1.count) + m / Double(s2.count) + (m - Double(t) / 2) / m) / 3
        var prefix = 0
        for (x, y) in zip(s1, s2) where x == y && prefix < 4 { prefix += 1 }
        return jaro + Double(prefix) * 0.1 * (1 - jaro)
    }

    private static func clean(_ s: String) -> String {
        s.lowercased().replacingOccurrences(of: #"^the "#, with: "", options: .regularExpression)
            .filter { $0.isLetter || $0.isNumber || $0 == " " }
            .replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespaces)
    }
}

extension VinylFormat {
    var discogsFormat: String {
        switch self { case .seven: "7\""; case .twelve: "12\""; case .lp: "LP" }
    }
    var spoken: String {
        switch self { case .seven: "seven inch"; case .twelve: "twelve inch"; case .lp: "album" }
    }
}
