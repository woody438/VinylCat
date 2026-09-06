import Foundation

/// Which photo of a record this is.
enum ShotKind: String, Codable, CaseIterable, Sendable {
    case coverFront, coverBack, gatefold, insert, labelA, labelB, labelC, labelD, other

    var title: String {
        switch self {
        case .coverFront: "Front cover"; case .coverBack: "Back cover"; case .gatefold: "Gatefold inside"
        case .insert: "Insert"; case .labelA: "Label side A"; case .labelB: "Label side B"
        case .labelC: "Label side C"; case .labelD: "Label side D"; case .other: "Extra photo"
        }
    }
    /// What the app says when asking for this shot.
    var prompt: String {
        switch self {
        case .coverFront: "Show me the front cover"; case .coverBack: "Show me the back cover"
        case .gatefold: "Open it up. Show me the gatefold"; case .insert: "Show me the insert"
        case .labelA: "Show me the label, side A"; case .labelB: "Now the B-side"
        case .labelC: "Disc two, side C"; case .labelD: "Disc two, side D"; case .other: "Show me the extra photo"
        }
    }
    var hud: String {
        switch self {
        case .labelB: "B-SIDE LABEL"; case .labelC: "DISC 2 · SIDE C"; case .labelD: "DISC 2 · SIDE D"
        default: title.uppercased()
        }
    }
}

/// `rejected` = the operator gave the match a thumbs-down: kept (with its photos and evidence) for
/// tuning the reader and ranker, but out of the catalogue, the value total, the export and Discogs.
enum RecordStatus: String, Codable, Sendable { case matched, needsReview, manual, duplicate, rejected }
enum SyncState: String, Codable, Sendable { case off, pending, synced, failed }

/// Thumbs up / down on a match.
enum Verdict: String, Codable, Sendable { case up, down }

/// What the identifier and matcher saw when a record was saved — the training signal behind a verdict.
struct ScanEvidence: Codable, Sendable {
    struct CandidateSnapshot: Codable, Sendable {
        var releaseID: Int
        var title: String
        var label: String?
        var catno: String?
        var year: String?
        var country: String?
        var score: Double
        var reasons: [String]
    }
    var recordID: UUID
    var provider: String?
    var ocrLines: [String] = []
    var barcodes: [String] = []
    var catalogueCandidates: [String] = []
    var modelReading: SleeveReading?
    var mergedReading: SleeveReading
    var candidates: [CandidateSnapshot] = []
    var chosenReleaseID: Int?
    var createdAt = Date()
}

/// One thumbs-up / thumbs-down, as exported to feedback JSONL.
struct FeedbackEntry: Codable, Sendable {
    var recordID: UUID
    var verdict: Verdict
    var createdAt: Date
    var artist: String
    var title: String
    var format: String
    var label: String?
    var catalogNumber: String?
    var discogsReleaseID: Int?
    var confidence: Double
    var photos: [String]
    var evidence: ScanEvidence?
}

struct Track: Codable, Sendable, Equatable { var position: String; var title: String; var duration: String? }

struct ScanPhoto: Identifiable, Sendable, Equatable {
    var id = UUID()
    var recordID: UUID
    /// File name inside PhotoStore.root.
    var fileName: String
    var kind: ShotKind
    var discNumber = 1
    var order: Int
    var capturedAt = Date()
    var url: URL { PhotoStore.shared.root.appendingPathComponent(fileName) }
}

struct VinylRecord: Identifiable, Sendable, Equatable {
    var id = UUID()
    var discogsReleaseID: Int?
    var discogsMasterID: Int?
    var discogsURI: String?
    var artist: String
    var title: String
    var label: String?
    var catalogNumber: String?
    var barcode: String?
    /// "7\"", "10\"", "12\"", "LP"
    var format: String
    var formatDescriptors: [String] = []
    var discCount = 1
    var year: Int?
    var country: String?
    var genres: [String] = []
    var styles: [String] = []
    var tracks: [Track] = []
    var coverArtURL: String?
    var status: RecordStatus = .matched
    var confidence = 0.0
    var valueLow: Double?
    var valueMedian: Double?
    var valueHigh: Double?
    var numForSale: Int?
    var currency: String?
    var valuedAt: Date?
    var sync: SyncState = .off
    var discogsInstanceID: Int?
    /// Thumbs-up from the operator.
    var verified = false
    var notes = ""
    /// What the local OCR / model read, kept for the review queue.
    var readText = ""
    var createdAt = Date()
    var sessionID: UUID
    var expectedShots: [ShotKind] = []
    var photos: [ScanPhoto] = []

    var takenKinds: Set<ShotKind> { Set(photos.map(\.kind)) }
    var missingShots: [ShotKind] { expectedShots.filter { !takenKinds.contains($0) } }
    var isComplete: Bool { missingShots.isEmpty }
    var sortedPhotos: [ScanPhoto] { photos.sorted { $0.order < $1.order } }
    var displayTitle: String { "\(artist) — \(title)" }
    /// In the catalogue (not thumbed down).
    var isLive: Bool { status != .rejected }
}

/// Which shots to ask for per format. Discogs metadata (2×LP, gatefold) extends the list.
struct CaptureProfile: Sendable {
    /// Once a release is matched, Discogs already knows the tracklist — so by default singles need no extra shots
    /// (the B-side is only asked for when a match is ambiguous), and albums get front + back covers.
    var seven: [ShotKind] = []
    var twelve: [ShotKind] = []
    var lp: [ShotKind] = [.coverFront, .coverBack]

    static func load() -> CaptureProfile {
        var p = CaptureProfile()
        let d = UserDefaults.standard
        if d.object(forKey: "askForLabelsOnLP") as? Bool == true { p.lp.append(.labelA) }
        if d.object(forKey: "askForBSide") as? Bool == true { p.seven = [.labelA, .labelB]; p.twelve = [.labelA, .labelB] }
        return p
    }

    func expected(format: String, discCount: Int, descriptors: [String], hadPictureSleeve: Bool) -> [ShotKind] {
        var shots: [ShotKind]
        switch format {
        case "7\"": shots = seven; if hadPictureSleeve, !shots.isEmpty { shots.insert(.coverFront, at: 0) }
        case "12\"": shots = twelve
        default: shots = lp
        }
        if descriptors.contains(where: { $0.localizedCaseInsensitiveContains("gatefold") }) && !shots.contains(.gatefold) {
            shots.append(.gatefold)
        }
        if discCount >= 2 {
            for k in [ShotKind.labelA, .labelB, .labelC, .labelD] where !shots.contains(k) { shots.append(k) }
        }
        return shots
    }
}
