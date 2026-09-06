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
