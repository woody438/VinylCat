import Foundation
import Observation

/// Discogs REST client with a token-bucket limiter that tracks the X-Discogs-Ratelimit headers.
@MainActor
@Observable
final class DiscogsClient {
    private(set) var limit = 60
    private(set) var used = 0
    private(set) var remaining = 60
    private(set) var lastError: String?
    var rateText: String { "\(used) / \(limit) per minute" }

    private let base = URL(string: "https://api.discogs.com")!
    private let userAgent = "VinylCat/0.1 +https://github.com/woodall/vinylcat"
    private var windowStart = Date()
    private var windowCount = 0
    /// Clears the meter a minute after the last response. `used` is whatever Discogs' header said last time;
    /// with no further calls it would sit at "23/60" for ever, though Discogs itself has forgotten those calls.
    private var meterReset: Task<Void, Never>?

    struct SearchResult: Decodable, Sendable {
        var id: Int
        var type: String?
        var title: String
        var year: String?
        var country: String?
        var label: [String]?
        var catno: String?
        var format: [String]?
        var barcode: [String]?
        var thumb: String?
        var cover_image: String?
        var master_id: Int?
    }
    private struct SearchPage: Decodable { var results: [SearchResult] }

    struct Release: Decodable, Sendable {
        struct Artist: Decodable, Sendable { var name: String }
        struct Label: Decodable, Sendable { var name: String; var catno: String? }
        struct Format: Decodable, Sendable { var name: String; var qty: String?; var descriptions: [String]? }
        struct Track: Decodable, Sendable { var position: String; var title: String; var duration: String? }
        struct Image: Decodable, Sendable { var type: String?; var uri: String?; var uri150: String? }
        var id: Int
        var title: String
        var artists: [Artist]?
        var labels: [Label]?
        var formats: [Format]?
        var year: Int?
        var country: String?
        var genres: [String]?
        var styles: [String]?
        var tracklist: [Track]?
        var images: [Image]?
        var master_id: Int?
        var uri: String?
        var lowest_price: Double?
        var num_for_sale: Int?
        var artistLine: String { (artists ?? []).map { $0.name.replacingOccurrences(of: #" \(\d+\)$"#, with: "", options: .regularExpression) }.joined(separator: ", ") }
    }

    struct PriceStats: Decodable, Sendable {
        struct Money: Decodable, Sendable { var value: Double?; var currency: String? }
        var lowest_price: Money?
        var num_for_sale: Int?
        var blocked_from_sale: Bool?
    }

    struct Identity: Decodable, Sendable { var username: String }
    /// The bits of the user profile the app cares about: the marketplace currency set on Discogs.
    struct Profile: Decodable, Sendable { var username: String; var curr_abbr: String? }

    /// One instance in the user's collection, as listed by the folder endpoint. `basic_information`
    /// carries enough to make a record without a second call per release.
    struct CollectionInstance: Decodable, Sendable {
        struct Basic: Decodable, Sendable {
            var id: Int
            var title: String
            var year: Int?
            var artists: [Release.Artist]?
            var labels: [Release.Label]?
            var formats: [Release.Format]?
            var genres: [String]?
            var styles: [String]?
            var cover_image: String?
            var thumb: String?
            var master_id: Int?
            var resource_url: String?
        }
        var instance_id: Int
        var id: Int
        var folder_id: Int?
        var date_added: String?
        var basic_information: Basic
    }
    private struct CollectionPage: Decodable {
        struct Pagination: Decodable { var pages: Int; var page: Int }
        var pagination: Pagination
        var releases: [CollectionInstance]
    }

    /// Every instance in the user's collection (folder 0 = all folders), 100 per call.
    func collection(username: String, progress: ((Int, Int) -> Void)? = nil) async throws -> [CollectionInstance] {
        var all: [CollectionInstance] = []
        var page = 1, pages = 1
        repeat {
            let p: CollectionPage = try await get("/users/\(username)/collection/folders/0/releases",
                                                  query: [.init(name: "per_page", value: "100"), .init(name: "page", value: "\(page)"), .init(name: "sort", value: "added")])
            all += p.releases
            pages = p.pagination.pages
            progress?(page, pages)
            page += 1
        } while page <= pages
        return all
    }

    enum DiscogsError: LocalizedError {
        case noToken, http(Int, String)
        var errorDescription: String? {
            switch self {
            case .noToken: "No Discogs token — add one in Settings."
            case .http(let c, let m): "Discogs \(c): \(m.prefix(200))"
            }
        }
    }

    // MARK: - Endpoints

    func search(query: String? = nil, artist: String? = nil, releaseTitle: String? = nil, label: String? = nil,
                catno: String? = nil, barcode: String? = nil, format: String? = nil, perPage: Int = 15) async throws -> [SearchResult] {
        var items: [URLQueryItem] = [.init(name: "type", value: "release"), .init(name: "per_page", value: "\(perPage)")]
        func add(_ k: String, _ v: String?) { if let v, !v.isEmpty { items.append(.init(name: k, value: v)) } }
        add("q", query); add("artist", artist); add("release_title", releaseTitle); add("label", label)
        add("catno", catno); add("barcode", barcode); add("format", format)
        let page: SearchPage = try await get("/database/search", query: items)
        return page.results
    }

    func release(_ id: Int) async throws -> Release {
        try await get("/releases/\(id)", query: [.init(name: "curr_abbr", value: currency)])
    }

    func priceStats(_ id: Int) async throws -> PriceStats {
        try await get("/marketplace/stats/\(id)", query: [.init(name: "curr_abbr", value: currency)])
    }

    func identity() async throws -> Identity { try await get("/oauth/identity", query: []) }
    func profile(username: String) async throws -> Profile { try await get("/users/\(username)", query: []) }

    /// Makes the app's valuation currency follow the Discogs profile. Returns the code it landed on.
    @discardableResult
    func adoptProfileCurrency() async -> String? {
        guard Keychain.get(.discogsToken)?.nilIfEmpty != nil else { return nil }
        var user = UserDefaults.standard.string(forKey: "discogsUsername") ?? ""
        if user.isEmpty, let me = try? await identity() { user = me.username; UserDefaults.standard.set(user, forKey: "discogsUsername") }
        guard !user.isEmpty, let p = try? await profile(username: user), let cur = p.curr_abbr?.uppercased().nilIfEmpty else { return nil }
        if cur != currency { Log.discogs.info("currency \(self.currency) → \(cur) from the Discogs profile") }
        UserDefaults.standard.set(cur, forKey: "currency")
        UserDefaults.standard.set(true, forKey: "currencyFromProfile")
        return cur
    }

    /// Adds a release to the user's collection (folder 1 = Uncategorized). Returns the instance id.
    func addToCollection(releaseID: Int, username: String, folder: Int = 1) async throws -> Int {
        struct Added: Decodable { var instance_id: Int }
        let a: Added = try await request("POST", "/users/\(username)/collection/folders/\(folder)/releases/\(releaseID)", query: [])
        return a.instance_id
    }

    /// Removes one collection instance (what `addToCollection` returned). 404 counts as gone.
    func removeFromCollection(releaseID: Int, instanceID: Int, username: String, folder: Int = 1) async throws {
        do {
            _ = try await send("DELETE", "/users/\(username)/collection/folders/\(folder)/releases/\(releaseID)/instances/\(instanceID)", query: [])
        } catch DiscogsError.http(404, _) {}
    }

    var currency: String { UserDefaults.standard.string(forKey: "currency") ?? "GBP" }

    func selfTest() async -> String {
        do {
            let me = try await identity()
            UserDefaults.standard.set(me.username, forKey: "discogsUsername")
            let r = try await search(catno: "POSP 113", format: "7\"")
            let cur = await adoptProfileCurrency()
            return "OK — signed in as \(me.username)\(cur.map { ", prices in \($0)" } ?? ""); POSP 113 → \(r.count) results, first: \(r.first?.title ?? "—") · \(rateText)"
        } catch { return "Failed: \(error.localizedDescription)" }
    }

    // MARK: - Transport

    private func get<T: Decodable>(_ path: String, query: [URLQueryItem]) async throws -> T {
        try await request("GET", path, query: query)
    }

    private func request<T: Decodable>(_ method: String, _ path: String, query: [URLQueryItem]) async throws -> T {
        try JSONDecoder().decode(T.self, from: try await send(method, path, query: query))
    }

    /// Raw call; the body comes back as data (empty for 204s).
    private func send(_ method: String, _ path: String, query: [URLQueryItem]) async throws -> Data {
        let token = Keychain.get(.discogsToken)?.nilIfEmpty
        if token == nil, method != "GET" || path.hasPrefix("/oauth") { throw DiscogsError.noToken }
        if token == nil { limit = min(limit, 25) }
        await throttle()
        var comps = URLComponents(url: base.appendingPathComponent(path), resolvingAgainstBaseURL: false)!
        if !query.isEmpty { comps.queryItems = query }
        var req = URLRequest(url: comps.url!)
        req.httpMethod = method
        if let token { req.setValue("Discogs token=\(token)", forHTTPHeaderField: "Authorization") }
        req.setValue(userAgent, forHTTPHeaderField: "User-Agent")
        req.setValue("application/json", forHTTPHeaderField: "Accept")
        req.timeoutInterval = 20
        let (data, resp) = try await URLSession.shared.data(for: req)
        let http = resp as? HTTPURLResponse
        if let http {
            if let l = http.value(forHTTPHeaderField: "X-Discogs-Ratelimit"), let v = Int(l) { limit = v }
            if let u = http.value(forHTTPHeaderField: "X-Discogs-Ratelimit-Used"), let v = Int(u) { used = v }
            if let r = http.value(forHTTPHeaderField: "X-Discogs-Ratelimit-Remaining"), let v = Int(r) { remaining = v }
            scheduleMeterReset()
        }
        let code = http?.statusCode ?? 0
        Log.discogs.info("\(method) \(path) → \(code) · \(self.used)/\(self.limit)")
        if code == 429 {
            // Back off for the rest of the window, then retry once.
            try await Task.sleep(for: .seconds(max(2, 60 - Date().timeIntervalSince(windowStart))))
            return try await send(method, path, query: query)
        }
        guard (200..<300).contains(code) else {
            let msg = String(data: data, encoding: .utf8) ?? ""
            lastError = msg
            throw DiscogsError.http(code, msg)
        }
        return data
    }

    private func scheduleMeterReset() {
        meterReset?.cancel()
        meterReset = Task { [weak self] in
            try? await Task.sleep(for: .seconds(60))
            guard !Task.isCancelled, let self else { return }
            self.used = 0; self.remaining = self.limit
        }
    }

    /// Keep a little headroom under the limit: never exceed limit-5 requests in any rolling minute.
    private func throttle() async {
        let now = Date()
        if now.timeIntervalSince(windowStart) >= 60 { windowStart = now; windowCount = 0 }
        windowCount += 1
        if windowCount > max(10, limit - 5) {
            let wait = 60 - now.timeIntervalSince(windowStart)
            if wait > 0 { try? await Task.sleep(for: .seconds(wait)) }
            windowStart = Date(); windowCount = 1
        }
    }
}
