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

/// Thumbs up / down on a match, or `fixed`: a scan the loop couldn't finish (not found, wrong
/// record, or an error) that the operator then resolved by hand in Review or the Library.
enum Verdict: String, Codable, Sendable { case up, down, fixed }

/// What it took to fix a scan by hand — the other half of the tuning signal. The evidence saved at
/// scan time says what the readers and the ranker saw; this says what the operator had to add and
/// which release was right.
struct CorrectionNote: Codable, Sendable {
    /// "review" (the queue), "library" (typed in from scratch), "manual" (saved without Discogs).
    var source: String
    /// What the operator typed to find it.
    var typed: String = ""
    /// The release chosen, and the one the scan had picked (if it had picked one).
    var chosenReleaseID: Int?
    var previousReleaseID: Int?
    var previousStatus: String?
    /// How the record was found on Discogs in the end, e.g. "catno", "barcode", "artist+title", "text".
    var foundBy: String?
}

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
    var correction: CorrectionNote?
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
    /// One record, one identifying photo; anything more is asked for by hand (F, P, "back cover", "disc two").
    var photos: [ScanPhoto] = []

    var takenKinds: Set<ShotKind> { Set(photos.map(\.kind)) }
    var sortedPhotos: [ScanPhoto] { photos.sorted { $0.order < $1.order } }
    var displayTitle: String { "\(artist) — \(title)" }
    /// In the catalogue (not thumbed down).
    var isLive: Bool { status != .rejected }
}
