import Foundation
import Observation
import SQLite3

/// SQLite-backed store at ~/Library/Application Support/VinylCat/VinylCat.sqlite.
/// Plain structs in, plain structs out; `revision` bumps on every write so views refresh.
@MainActor
@Observable
final class Store {
    static let shared = Store(url: PhotoStore.shared.root.deletingLastPathComponent().appendingPathComponent("VinylCat.sqlite"))

    private(set) var revision = 0
    private var db: OpaquePointer?
    let url: URL

    init(url: URL) {
        self.url = url
        open()
    }

    private func open() {
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        guard sqlite3_open(url.path, &db) == SQLITE_OK else { print("sqlite open failed: \(url.path)"); return }
        exec("PRAGMA journal_mode=WAL; PRAGMA foreign_keys=ON;")
        exec("""
        CREATE TABLE IF NOT EXISTS records (
          id TEXT PRIMARY KEY, discogs_release_id INTEGER, discogs_master_id INTEGER, discogs_uri TEXT,
          artist TEXT NOT NULL, title TEXT NOT NULL, label TEXT, catalog_number TEXT, barcode TEXT,
          format TEXT NOT NULL, format_descriptors TEXT NOT NULL DEFAULT '[]', disc_count INTEGER NOT NULL DEFAULT 1,
          year INTEGER, country TEXT, genres TEXT NOT NULL DEFAULT '[]', styles TEXT NOT NULL DEFAULT '[]',
          tracks TEXT NOT NULL DEFAULT '[]', cover_art_url TEXT, status TEXT NOT NULL, confidence REAL NOT NULL DEFAULT 0,
          value_low REAL, value_median REAL, value_high REAL, num_for_sale INTEGER, currency TEXT, valued_at REAL,
          sync TEXT NOT NULL DEFAULT 'off', discogs_instance_id INTEGER, notes TEXT NOT NULL DEFAULT '',
          read_text TEXT NOT NULL DEFAULT '', created_at REAL NOT NULL, session_id TEXT NOT NULL,
          expected_shots TEXT NOT NULL DEFAULT '[]'
        );
        CREATE INDEX IF NOT EXISTS records_release ON records(discogs_release_id);
        CREATE INDEX IF NOT EXISTS records_created ON records(created_at);
        CREATE TABLE IF NOT EXISTS photos (
          id TEXT PRIMARY KEY, record_id TEXT NOT NULL REFERENCES records(id) ON DELETE CASCADE,
          file_name TEXT NOT NULL, kind TEXT NOT NULL, disc_number INTEGER NOT NULL DEFAULT 1,
          ord INTEGER NOT NULL, captured_at REAL NOT NULL
        );
        CREATE INDEX IF NOT EXISTS photos_record ON photos(record_id);
        """)
    }

    // MARK: - Public API

    func insert(_ r: VinylRecord) {
        run("""
        INSERT OR REPLACE INTO records (id, discogs_release_id, discogs_master_id, discogs_uri, artist, title, label, catalog_number, barcode,
          format, format_descriptors, disc_count, year, country, genres, styles, tracks, cover_art_url, status, confidence,
          value_low, value_median, value_high, num_for_sale, currency, valued_at, sync, discogs_instance_id, notes, read_text,
          created_at, session_id, expected_shots)
        VALUES (?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?)
        """, binds(r))
        for p in r.photos { insertPhoto(p, bump: false) }
        revision += 1
    }

    func update(_ r: VinylRecord) { insert(r) }

    func delete(_ id: UUID) {
        if let r = fetch(id) { for p in r.photos { try? FileManager.default.removeItem(at: p.url) } }
        run("DELETE FROM records WHERE id = ?", [.text(id.uuidString)])
        revision += 1
    }

    func insertPhoto(_ p: ScanPhoto, bump: Bool = true) {
        run("INSERT OR REPLACE INTO photos (id, record_id, file_name, kind, disc_number, ord, captured_at) VALUES (?,?,?,?,?,?,?)",
            [.text(p.id.uuidString), .text(p.recordID.uuidString), .text(p.fileName), .text(p.kind.rawValue),
             .int(p.discNumber), .int(p.order), .double(p.capturedAt.timeIntervalSince1970)])
        if bump { revision += 1 }
    }

    func deletePhoto(_ id: UUID) {
        if let row = query("SELECT file_name FROM photos WHERE id = ?", [.text(id.uuidString)]).first, let f = row["file_name"] as? String {
            try? FileManager.default.removeItem(at: PhotoStore.shared.root.appendingPathComponent(f))
        }
        run("DELETE FROM photos WHERE id = ?", [.text(id.uuidString)])
        revision += 1
    }

    func fetch(_ id: UUID) -> VinylRecord? {
        query("SELECT * FROM records WHERE id = ?", [.text(id.uuidString)]).compactMap(record(from:)).first
    }

    func existing(discogsReleaseID id: Int) -> VinylRecord? {
        query("SELECT * FROM records WHERE discogs_release_id = ? LIMIT 1", [.int(id)]).compactMap(record(from:)).first
    }

    func all() -> [VinylRecord] {
        query("SELECT * FROM records ORDER BY created_at DESC", []).compactMap(record(from:))
    }

    func count() -> Int { (query("SELECT COUNT(*) AS n FROM records", []).first?["n"] as? Int) ?? 0 }
    func reviewCount() -> Int { (query("SELECT COUNT(*) AS n FROM records WHERE status = 'needsReview'", []).first?["n"] as? Int) ?? 0 }

    /// Writes output/vinylcat_export_vN_YYYY-MM-DD.csv (next free N) and returns the URL.
    func exportCSV(to folder: URL) throws -> URL {
        let records = all().reversed()
        let date = ISO8601DateFormatter().string(from: Date()).prefix(10)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        var n = 1
        var url: URL
        repeat { url = folder.appendingPathComponent("vinylcat_export_v\(n)_\(date).csv"); n += 1 } while FileManager.default.fileExists(atPath: url.path)
        func q(_ s: String?) -> String { "\"" + (s ?? "").replacingOccurrences(of: "\"", with: "\"\"") + "\"" }
        var lines = ["artist,title,year,format,label,catalogue_number,barcode,country,genres,styles,discs,value_low,value_median,value_high,currency,status,discogs_release_id,discogs_url,photos,notes,added"]
        let df = ISO8601DateFormatter()
        for r in records {
            lines.append([
                q(r.artist), q(r.title), q(r.year.map(String.init)), q(r.format), q(r.label), q(r.catalogNumber), q(r.barcode), q(r.country),
                q(r.genres.joined(separator: "; ")), q(r.styles.joined(separator: "; ")), q("\(r.discCount)"),
                q(r.valueLow.map { String(format: "%.2f", $0) }), q(r.valueMedian.map { String(format: "%.2f", $0) }), q(r.valueHigh.map { String(format: "%.2f", $0) }),
                q(r.currency), q(r.status.rawValue), q(r.discogsReleaseID.map(String.init)), q(r.discogsURI),
                q(r.sortedPhotos.map(\.fileName).joined(separator: "; ")), q(r.notes), q(df.string(from: r.createdAt)),
            ].joined(separator: ","))
        }
        try lines.joined(separator: "\n").write(to: url, atomically: true, encoding: .utf8)
        return url
    }

    // MARK: - Row mapping

    private func binds(_ r: VinylRecord) -> [Value] {
        [.text(r.id.uuidString), .optInt(r.discogsReleaseID), .optInt(r.discogsMasterID), .optText(r.discogsURI),
         .text(r.artist), .text(r.title), .optText(r.label), .optText(r.catalogNumber), .optText(r.barcode),
         .text(r.format), .text(json(r.formatDescriptors)), .int(r.discCount), .optInt(r.year), .optText(r.country),
         .text(json(r.genres)), .text(json(r.styles)), .text(json(r.tracks)), .optText(r.coverArtURL), .text(r.status.rawValue), .double(r.confidence),
         .optDouble(r.valueLow), .optDouble(r.valueMedian), .optDouble(r.valueHigh), .optInt(r.numForSale), .optText(r.currency),
         .optDouble(r.valuedAt?.timeIntervalSince1970), .text(r.sync.rawValue), .optInt(r.discogsInstanceID), .text(r.notes), .text(r.readText),
         .double(r.createdAt.timeIntervalSince1970), .text(r.sessionID.uuidString), .text(json(r.expectedShots.map(\.rawValue)))]
    }

    private func record(from row: [String: Any]) -> VinylRecord? {
        guard let ids = row["id"] as? String, let id = UUID(uuidString: ids) else { return nil }
        var r = VinylRecord(id: id, artist: row["artist"] as? String ?? "", title: row["title"] as? String ?? "",
                            format: row["format"] as? String ?? "LP", sessionID: UUID(uuidString: row["session_id"] as? String ?? "") ?? UUID())
        r.discogsReleaseID = row["discogs_release_id"] as? Int
        r.discogsMasterID = row["discogs_master_id"] as? Int
        r.discogsURI = row["discogs_uri"] as? String
        r.label = row["label"] as? String
        r.catalogNumber = row["catalog_number"] as? String
        r.barcode = row["barcode"] as? String
        r.formatDescriptors = decode(row["format_descriptors"]) ?? []
        r.discCount = row["disc_count"] as? Int ?? 1
        r.year = row["year"] as? Int
        r.country = row["country"] as? String
        r.genres = decode(row["genres"]) ?? []
        r.styles = decode(row["styles"]) ?? []
        r.tracks = decode(row["tracks"]) ?? []
        r.coverArtURL = row["cover_art_url"] as? String
        r.status = RecordStatus(rawValue: row["status"] as? String ?? "") ?? .matched
        r.confidence = row["confidence"] as? Double ?? 0
        r.valueLow = row["value_low"] as? Double
        r.valueMedian = row["value_median"] as? Double
        r.valueHigh = row["value_high"] as? Double
        r.numForSale = row["num_for_sale"] as? Int
        r.currency = row["currency"] as? String
        r.valuedAt = (row["valued_at"] as? Double).map { Date(timeIntervalSince1970: $0) }
        r.sync = SyncState(rawValue: row["sync"] as? String ?? "") ?? .off
        r.discogsInstanceID = row["discogs_instance_id"] as? Int
        r.notes = row["notes"] as? String ?? ""
        r.readText = row["read_text"] as? String ?? ""
        r.createdAt = Date(timeIntervalSince1970: row["created_at"] as? Double ?? 0)
        r.expectedShots = (decode(row["expected_shots"]) as [String]?)?.compactMap(ShotKind.init) ?? []
        r.photos = query("SELECT * FROM photos WHERE record_id = ? ORDER BY ord", [.text(ids)]).compactMap { p in
            guard let pid = UUID(uuidString: p["id"] as? String ?? "") else { return nil }
            return ScanPhoto(id: pid, recordID: id, fileName: p["file_name"] as? String ?? "",
                             kind: ShotKind(rawValue: p["kind"] as? String ?? "") ?? .other,
                             discNumber: p["disc_number"] as? Int ?? 1, order: p["ord"] as? Int ?? 0,
                             capturedAt: Date(timeIntervalSince1970: p["captured_at"] as? Double ?? 0))
        }
        return r
    }

    private func json<T: Encodable>(_ v: T) -> String {
        String(data: (try? JSONEncoder().encode(v)) ?? Data("[]".utf8), encoding: .utf8) ?? "[]"
    }
    private func decode<T: Decodable>(_ v: Any?) -> T? {
        guard let s = v as? String else { return nil }
        return try? JSONDecoder().decode(T.self, from: Data(s.utf8))
    }

    // MARK: - SQLite plumbing

    enum Value { case text(String), optText(String?), int(Int), optInt(Int?), double(Double), optDouble(Double?) }

    private func exec(_ sql: String) {
        var err: UnsafeMutablePointer<CChar>?
        if sqlite3_exec(db, sql, nil, nil, &err) != SQLITE_OK { print("sqlite: \(String(cString: err!))"); sqlite3_free(err) }
    }

    private func bind(_ stmt: OpaquePointer?, _ values: [Value]) {
        let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
        for (i, v) in values.enumerated() {
            let idx = Int32(i + 1)
            switch v {
            case .text(let s): sqlite3_bind_text(stmt, idx, s, -1, transient)
            case .optText(let s): if let s { sqlite3_bind_text(stmt, idx, s, -1, transient) } else { sqlite3_bind_null(stmt, idx) }
            case .int(let n): sqlite3_bind_int64(stmt, idx, Int64(n))
            case .optInt(let n): if let n { sqlite3_bind_int64(stmt, idx, Int64(n)) } else { sqlite3_bind_null(stmt, idx) }
            case .double(let d): sqlite3_bind_double(stmt, idx, d)
            case .optDouble(let d): if let d { sqlite3_bind_double(stmt, idx, d) } else { sqlite3_bind_null(stmt, idx) }
            }
        }
    }

    private func run(_ sql: String, _ values: [Value]) {
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { print("sqlite prepare: \(String(cString: sqlite3_errmsg(db)))"); return }
        defer { sqlite3_finalize(stmt) }
        bind(stmt, values)
        if sqlite3_step(stmt) != SQLITE_DONE { print("sqlite step: \(String(cString: sqlite3_errmsg(db)))") }
    }

    private func query(_ sql: String, _ values: [Value]) -> [[String: Any]] {
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { print("sqlite prepare: \(String(cString: sqlite3_errmsg(db)))"); return [] }
        defer { sqlite3_finalize(stmt) }
        bind(stmt, values)
        var rows: [[String: Any]] = []
        let n = sqlite3_column_count(stmt)
        while sqlite3_step(stmt) == SQLITE_ROW {
            var row: [String: Any] = [:]
            for c in 0..<n {
                let name = String(cString: sqlite3_column_name(stmt, c))
                switch sqlite3_column_type(stmt, c) {
                case SQLITE_INTEGER: row[name] = Int(sqlite3_column_int64(stmt, c))
                case SQLITE_FLOAT: row[name] = sqlite3_column_double(stmt, c)
                case SQLITE_TEXT: row[name] = String(cString: sqlite3_column_text(stmt, c))
                default: break
                }
            }
            rows.append(row)
        }
        return rows
    }
}
