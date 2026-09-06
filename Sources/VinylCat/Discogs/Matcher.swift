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
    func find(reading: SleeveReading, sessionFormat: VinylFormat?) async throws -> (Verdict, [Candidate]) {
        var pool: [DiscogsClient.SearchResult] = []
        let fmt = sessionFormat?.discogsFormat ?? reading.formatGuess

        if let b = reading.barcode, b.filter(\.isNumber).count >= 8 {
            pool += try await discogs.search(barcode: b.filter(\.isNumber))
        }
        if pool.isEmpty, let c = reading.catalogNumber, !c.isEmpty {
            pool += try await discogs.search(label: reading.label, catno: c, format: fmt)
            if pool.isEmpty { pool += try await discogs.search(catno: c) }
        }
        if pool.count < 3, reading.artist != nil || reading.title != nil {
            pool += try await discogs.search(artist: reading.artist, releaseTitle: reading.title, format: fmt)
            if pool.isEmpty, let q = [reading.artist, reading.title].compactMap({ $0 }).joined(separator: " ").nilIfEmpty {
                pool += try await discogs.search(query: q)
            }
        }
        let ranked = CandidateRanker.rank(pool, reading: reading, sessionFormat: sessionFormat)
        guard let top = ranked.first else { return (.none, ranked) }
        if top.score >= autoAccept, ranked.count == 1 || ranked[1].score < top.score - 0.1 { return (.match(top), ranked) }
        if top.score >= askAbove { return (.ambiguous(Array(ranked.prefix(3))), ranked) }
        return (.none, ranked)
    }
}

extension String {
    var nilIfEmpty: String? { isEmpty ? nil : self }
}
