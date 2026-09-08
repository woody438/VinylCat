import Foundation
import Observation

/// The Discogs side of two-way sync. Scans push to the collection as they are saved (`ScanController.enrich`);
/// this pulls the collection back: anything in Discogs that isn't in the Library becomes a record
/// (no photos, no valuation yet), a local record whose instance was linked by hand gets its instance
/// id, and a local record whose instance has gone from Discogs is unlinked — never deleted, its
/// photos and evidence are worth keeping.
@MainActor
@Observable
final class CollectionSync {
    private(set) var running = false
    private(set) var valuing = false
    private(set) var status = ""
    /// A folder import sets this: pricing waits between records so the import keeps the Discogs rate limit.
    var paused = false
    private(set) var lastRun: Date?
    /// Records created by a pull share one session id so they can be told apart from scans.
    static let importSession = UUID(uuidString: "00000000-0000-0000-0000-00000000D15C")!

    struct Summary: Sendable {
        var seen = 0, imported = 0, relinked = 0, unlinked = 0
        var text: String {
            var parts = ["\(seen) in Discogs"]
            if imported > 0 { parts.append("\(imported) imported") }
            if relinked > 0 { parts.append("\(relinked) linked") }
            if unlinked > 0 { parts.append("\(unlinked) no longer in Discogs") }
            return parts.joined(separator: " · ")
        }
    }

    /// Returns nil when there was nothing to do (no token or username).
    @discardableResult
    func pull(discogs: DiscogsClient, store: Store) async -> Summary? {
        guard !running else { return nil }
        guard Keychain.get(.discogsToken)?.nilIfEmpty != nil else { status = "No Discogs token — add one in Settings"; return nil }
        var user = UserDefaults.standard.string(forKey: "discogsUsername") ?? ""
        if user.isEmpty, let me = try? await discogs.identity() { user = me.username; UserDefaults.standard.set(user, forKey: "discogsUsername") }
        guard !user.isEmpty else { status = "No Discogs username — add one in Settings"; return nil }
        running = true; defer { running = false }
        status = "Pulling the collection…"
        let started = Date()
        do {
            let instances = try await discogs.collection(username: user) { [weak self] p, n in self?.status = "Pulling the collection… page \(p) of \(n)" }
            var summary = Summary(seen: instances.count)
            var seenInstances = Set<Int>()
            for inst in instances {
                seenInstances.insert(inst.instance_id)
                if store.existing(discogsInstanceID: inst.instance_id) != nil { continue }
                // Same release already catalogued but never linked (sync off at the time, or it failed): adopt the instance.
                if var local = store.existing(discogsReleaseID: inst.id), local.discogsInstanceID == nil {
                    local.discogsInstanceID = inst.instance_id; local.sync = .synced
                    store.update(local); summary.relinked += 1
                    continue
                }
                store.insert(Self.record(from: inst))
                summary.imported += 1
            }
            // A record scanned while the listing was in flight isn't in it yet: leave anything under ten minutes old alone.
            for var local in store.all() where local.sync == .synced && local.createdAt < started.addingTimeInterval(-600)
                && local.discogsInstanceID.map({ !seenInstances.contains($0) }) == true {
                local.sync = .off; local.discogsInstanceID = nil
                store.update(local); summary.unlinked += 1
            }
            status = summary.text
            lastRun = Date()
            Log.discogs.info("pull: \(summary.text)")
            Task { await valueUnvalued(discogs: discogs, store: store) }
            return summary
        } catch {
            status = "Pull failed: \(FriendlyError.describe(error, context: "Discogs"))"
            Log.discogs.error("pull failed: \(error)")
            return nil
        }
    }

    /// Prices for every catalogue record that has none yet (imports, and scans whose price call failed).
    /// One Discogs call per record, spaced out to leave the scan loop most of the rate limit.
    func valueUnvalued(discogs: DiscogsClient, store: Store) async {
        guard !valuing else { return }
        let todo = store.live().filter { $0.discogsReleaseID != nil && $0.valuedAt == nil }
        guard !todo.isEmpty else { return }
        valuing = true; defer { valuing = false }
        var done = 0
        for r in todo {
            while paused { status = "Valuing paused while photos import"; try? await Task.sleep(for: .seconds(1)) }
            status = "Valuing \(done + 1) of \(todo.count)…"
            guard var rec = store.fetch(r.id), let rid = rec.discogsReleaseID else { continue }
            if let stats = try? await discogs.priceStats(rid) {
                rec.valueLow = stats.lowest_price?.value
                rec.numForSale = stats.num_for_sale
                rec.currency = stats.lowest_price?.currency ?? discogs.currency
                rec.valuedAt = Date()          // set even with nothing for sale, so it isn't asked again
                store.update(rec)
                done += 1
            }
            try? await Task.sleep(for: .seconds(2.2))   // ~27/min, leaving room for scans
        }
        status = "Valued \(done) of \(todo.count) records"
        Log.discogs.info("valued \(done)/\(todo.count)")
    }

    static func record(from inst: DiscogsClient.CollectionInstance) -> VinylRecord {
        let b = inst.basic_information
        let fmt = b.formats?.first
        let descs = fmt?.descriptions ?? []
        let format = descs.first(where: { ["7\"", "10\"", "12\"", "LP"].contains($0) }) ?? (fmt?.name == "Vinyl" ? "LP" : fmt?.name ?? "LP")
        let artist = (b.artists ?? []).map { $0.name.replacingOccurrences(of: #" \(\d+\)$"#, with: "", options: .regularExpression) }.joined(separator: ", ")
        var rec = VinylRecord(artist: artist, title: b.title, format: format, sessionID: importSession)
        rec.discogsReleaseID = b.id
        rec.discogsMasterID = b.master_id
        rec.discogsURI = "https://www.discogs.com/release/\(b.id)"
        rec.label = b.labels?.first?.name.replacingOccurrences(of: #" \(\d+\)$"#, with: "", options: .regularExpression)
        rec.catalogNumber = b.labels?.first?.catno
        rec.formatDescriptors = descs
        rec.discCount = Int(fmt?.qty ?? "1") ?? 1
        rec.year = b.year == 0 ? nil : b.year
        rec.genres = b.genres ?? []
        rec.styles = b.styles ?? []
        rec.coverArtURL = b.cover_image ?? b.thumb
        rec.status = .matched
        rec.confidence = 1
        rec.sync = .synced
        rec.discogsInstanceID = inst.instance_id
        if let d = inst.date_added, let date = ISO8601DateFormatter().date(from: d) { rec.createdAt = date }
        rec.notes = ""
        return rec
    }
}
