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

/// `rejected` = the operator gave the match a thumbs-down: out of the catalogue, the value total, the
/// export and Discogs, but kept (with its photos and evidence) for tuning the reader and ranker, and
/// queued in the Review tab so the right release can be picked by hand.
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
    /// Once a release is matched, Discogs already knows the tracklist, the sleeve and the disc count — so by default every
    /// format needs just the one identifying shot. The B-side is only asked for when a match is ambiguous; the extras
    /// below are opt-in and can always be asked for by voice ("back cover", "gatefold", "disc two", "add photo").
    var seven: [ShotKind] = []
    var twelve: [ShotKind] = []
    var lp: [ShotKind] = []
    /// Front cover on albums (when the identifying shot was the label).
    var frontOnLP = false
    /// Back cover on albums, plus the gatefold when Discogs says there is one.
    var coversOnLP = false
    /// A label on albums, one per disc when Discogs says there are several.
    var labelsOnLP = false

    static func load() -> CaptureProfile {
        var p = CaptureProfile()
        let d = UserDefaults.standard
        p.frontOnLP = d.object(forKey: "askForFrontOnLP") as? Bool == true
        p.coversOnLP = d.object(forKey: "askForCoversOnLP") as? Bool == true
        p.labelsOnLP = d.object(forKey: "askForLabelsOnLP") as? Bool == true
        if d.object(forKey: "askForBSide") as? Bool == true { p.seven = [.labelA, .labelB]; p.twelve = [.labelA, .labelB] }
        return p
    }

    func expected(format: String, discCount: Int, descriptors: [String], hadPictureSleeve: Bool) -> [ShotKind] {
        var shots: [ShotKind]
        switch format {
        case "7\"": shots = seven; if hadPictureSleeve, !shots.isEmpty { shots.insert(.coverFront, at: 0) }
        case "12\"": shots = twelve
        default:
            shots = lp
            if frontOnLP { shots.append(.coverFront) }
            if coversOnLP {
                shots.append(.coverBack)
                if descriptors.contains(where: { $0.localizedCaseInsensitiveContains("gatefold") }) { shots.append(.gatefold) }
            }
            if labelsOnLP {
                shots.append(.labelA)
                if discCount >= 2 { shots.append(.labelC) }
            }
        }
        return shots
    }
}
