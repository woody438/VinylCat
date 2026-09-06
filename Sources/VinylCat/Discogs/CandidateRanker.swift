import Foundation

struct Candidate: Identifiable, Sendable {
    var result: DiscogsClient.SearchResult
    var score: Double
    var reasons: [String]
    var id: Int { result.id }
    /// "POLYDOR POSP 113 · UK · 1980 · 7\""
    var summary: String {
        var parts: [String] = []
        if let l = result.label?.first { parts.append(l.uppercased()) }
        if let c = result.catno, c != "none" { parts.append(c.uppercased()) }
        if let c = result.country { parts.append(c.uppercased()) }
        if let y = result.year, !y.isEmpty { parts.append(y) }
        if let f = result.format?.first { parts.append(f) }
        return parts.joined(separator: " · ")
    }
}

/// Scores Discogs search hits against what was read from the record.
enum CandidateRanker {
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
            let readTitle = [reading.artist, reading.title].compactMap { $0 }.joined(separator: " - ")
            if !readTitle.isEmpty {
                let sim = similarity(readTitle, r.title)
                if sim > 0.6 { score += 0.25 * sim; why.append(String(format: "title %.2f", sim)) }
            } else if let t = reading.title, similarity(t, r.title.components(separatedBy: " - ").last ?? r.title) > 0.8 {
                score += 0.15; why.append("title")
            }
            if let wanted = sessionFormat?.discogsFormat ?? reading.formatGuess, let fmts = r.format {
                if fmts.contains(where: { $0.caseInsensitiveCompare(wanted) == .orderedSame }) { score += 0.1; why.append("format") }
                else { score -= 0.15; why.append("format✗") }
            }
            if let y = reading.year, let ry = Int(r.year ?? ""), abs(y - ry) <= 1 { score += 0.05; why.append("year") }
            return Candidate(result: r, score: min(1, max(0, score)), reasons: why)
        }
        return out.sorted { $0.score > $1.score }
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
