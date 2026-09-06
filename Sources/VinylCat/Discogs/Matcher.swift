import Foundation

/// Search strategy: strongest keys first, merge, rank.
struct Matcher {
    let discogs: DiscogsClient
    var autoAccept = 0.85
    var askAbove = 0.60

    enum Verdict: Sendable {
        case match(Candidate)
        case ambiguous([Candidate])
        case none
    }

    @MainActor
    /// `catalogueAlternates` are the other catalogue-number-shaped tokens OCR found, best first.
    /// A label prints more than the catalogue number — matrix and side suffixes, publisher codes —
    /// and the first-ranked token is not always the one Discogs catalogues the release under.
    func find(reading: SleeveReading, sessionFormat: VinylFormat?, catalogueAlternates: [String] = []) async throws -> (Verdict, [Candidate]) {
        var pool: [DiscogsClient.SearchResult] = []
        let fmt = sessionFormat?.discogsFormat ?? reading.formatGuess

        if let b = reading.barcode, b.filter(\.isNumber).count >= 8 {
            pool += try await discogs.search(barcode: b.filter(\.isNumber))
        }
        var catnos = ([reading.catalogNumber].compactMap { $0 } + catalogueAlternates).filter { !$0.isEmpty }
        catnos = catnos.reduce(into: []) { acc, c in if !acc.contains(c) { acc.append(c) } }
        var matchedCatno: String?
        for c in catnos {
            pool += try await discogs.search(label: reading.label, catno: c, format: fmt)
            if pool.isEmpty { pool += try await discogs.search(catno: c) }
            if !pool.isEmpty { matchedCatno = c; break }
        }
        // catno= wants the number exactly as catalogued, and none of the tokens matched one. Free text
        // is looser and does find these — "ZS8 3592-3" carries a side suffix that catno= rejects — so
        // fall back to it and let the ranker sort out what comes back.
        if pool.isEmpty, let c = catnos.first { pool += try await discogs.search(query: c, format: fmt) }
        if pool.count < 3, reading.artist != nil || reading.title != nil {
            pool += try await discogs.search(artist: reading.artist, releaseTitle: reading.title, format: fmt)
            if pool.isEmpty, let q = [reading.artist, reading.title].compactMap({ $0 }).joined(separator: " ").nilIfEmpty {
                pool += try await discogs.search(query: q)
            }
        }
        // Rank against the catalogue number that actually found the release. Scoring the release's
        // "ZS8 3592" against the "ZS8 3592-3" first read off the label only ever scores an approximate
        // match, which is not enough to accept a record we located by its exact catalogue number.
        var forRanking = reading
        if let matchedCatno { forRanking.catalogNumber = matchedCatno }
        let ranked = CandidateRanker.rank(pool, reading: forRanking, sessionFormat: sessionFormat)
        // Collapse pressings that look identical from a photo (same label/catno/country/year).
        var keys = Set<String>()
        let distinct = ranked.filter { keys.insert($0.variantKey).inserted }
        guard let top = distinct.first else { return (.none, ranked) }
        let runnerUp = distinct.dropFirst().first
        let clearWinner = runnerUp.map { $0.score < top.score - 0.1 || (top.sameMaster($0) && top.isStrong) } ?? true
        if (top.score >= autoAccept || top.isStrong) && clearWinner { return (.match(top), distinct) }
        if top.score >= askAbove || top.isStrong { return (.ambiguous(Array(distinct.prefix(3))), distinct) }
        return (.none, distinct)
    }
}

extension String {
    var nilIfEmpty: String? { isEmpty ? nil : self }
}
