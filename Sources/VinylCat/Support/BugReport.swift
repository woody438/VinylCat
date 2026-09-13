import AppKit
import SwiftUI

/// Bug reports (2026-09-14). REPORT A PROBLEM — Settings → ABOUT, or a record's detail — opens a
/// sheet: what went wrong, an optional email for a reply, and two ticks for what travels with it:
/// the last 150 lines of the app's log and, from a record, its saved scan evidence. The app builds
/// the whole report as Markdown, PREVIEW shows exactly that text, and SEND posts it to
/// vinyl-cat.com/api/report, which files it as a GitHub issue on the private repo
/// (site-b/api/report.js). Nothing leaves the machine before SEND; if the site can't take it,
/// SAVE AS FILE writes the same text to the Desktop so the report isn't lost.
enum BugReport {
    /// `VINYLCAT_REPORT_URL` points it at a local `npm run dev` of the site for testing.
    static let endpoint = ProcessInfo.processInfo.environment["VINYLCAT_REPORT_URL"].flatMap(URL.init(string:))
        ?? URL(string: "https://vinyl-cat.com/api/report")!
    static let logLines = 150

    struct Sent: Decodable, Sendable {
        var url: String?
        var number: Int?
    }

    enum Failure: LocalizedError {
        case notSetUp, server(Int, String), noBody
        var errorDescription: String? {
            switch self {
            case .notSetUp: "The site isn't taking reports right now."
            case .server(let code, let text): "vinyl-cat.com answered \(code)\(text.isEmpty ? "" : ": \(text)")."
            case .noBody: "Say what went wrong first."
            }
        }
    }

    /// The issue title: the record when there is one, then the first line typed, trimmed to 80 characters.
    static func title(_ description: String, record: String? = nil) -> String {
        let first = description.split(whereSeparator: \.isNewline).first.map { String($0).trimmingCharacters(in: .whitespaces) } ?? ""
        let head = first.isEmpty ? "Problem report" : (first.count > 80 ? String(first.prefix(77)).trimmingCharacters(in: .whitespaces) + "…" : first)
        return record.map { "\($0): \(head)" } ?? head
    }

    /// Anything shaped like an API key is masked wherever it appears — the log never carries one,
    /// but the person may paste one into the description without thinking.
    static func scrub(_ s: String) -> String {
        var out = s
        for pattern in [#"sk-[A-Za-z0-9_\-]{12,}"#, #"AIza[0-9A-Za-z_\-]{20,}"#, #"(?i)(token|key|bearer)([ =:]+)[A-Za-z0-9_\-]{20,}"#] {
            out = out.replacingOccurrences(of: pattern, with: "$1$2[redacted]", options: .regularExpression)
        }
        return out.replacingOccurrences(of: "[redacted]", with: "[key removed]")
    }

    /// The whole report, exactly as filed.
    static func markdown(description: String, email: String, version: String, build: String, macOS: String,
                         record: VinylRecord?, evidenceJSON: String?, log: String?) -> String {
        var md = "## What went wrong\n\n\(description.trimmingCharacters(in: .whitespacesAndNewlines))\n\n"
        if !email.trimmingCharacters(in: .whitespaces).isEmpty { md += "Reply to: \(email.trimmingCharacters(in: .whitespaces))\n\n" }
        md += "## App\n\n- Version: \(version)\n- Build: \(build)\n- macOS: \(macOS)\n\n"
        if let r = record {
            md += "## Record\n\n- \(r.artist) — \(r.title)\n- \(r.format) · \(r.label ?? "no label") · \(r.catalogNumber ?? "no catalogue number")"
            md += " · \(r.year.map(String.init) ?? "no year") · \(r.country ?? "no country")\n"
            md += "- Discogs: \(r.discogsReleaseID.map { "r\($0)" } ?? "none") · status \(r.status.rawValue) · confidence \(String(format: "%.2f", r.confidence))\n"
            if !r.readText.isEmpty { md += "- Read: \(r.readText.replacingOccurrences(of: "\n", with: " / "))\n" }
            md += "\n"
        }
        if let e = evidenceJSON { md += "## Scan evidence\n\n```json\n\(e)\n```\n\n" }
        if let log { md += "## Log (last \(logLines) lines)\n\n```\n\(log)\n```\n" }
        return scrub(md)
    }

    /// The request body: title, the Markdown, and the version for the site's per-version counter.
    static func body(title: String, markdown: String, version: String) -> Data {
        (try? JSONSerialization.data(withJSONObject: ["title": title, "body": markdown, "version": version])) ?? Data()
    }

    /// The tail of vinylcat.log, or nil when there is none.
    static func logTail(_ n: Int = logLines) -> String? {
        guard let text = try? String(contentsOf: Log.fileURL, encoding: .utf8) else { return nil }
        let lines = text.split(separator: "\n", omittingEmptySubsequences: false)
        return lines.suffix(n).joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty
    }

    static func evidenceJSON(_ e: ScanEvidence?) -> String? {
        guard let e else { return nil }
        let enc = JSONEncoder()
        enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        enc.dateEncodingStrategy = .iso8601
        return (try? enc.encode(e)).map { String(decoding: $0, as: UTF8.self) }
    }

    static var macOSVersion: String { ProcessInfo.processInfo.operatingSystemVersionString }

    /// One POST. 201 → the issue; 503 → the site has no token yet; anything else → the code and text.
    static func send(title: String, markdown: String, version: String) async throws -> Sent {
        var req = URLRequest(url: endpoint, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 20)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = body(title: title, markdown: markdown, version: version)
        let config = URLSessionConfiguration.ephemeral
        config.waitsForConnectivity = false
        let (data, response) = try await URLSession(configuration: config).data(for: req)
        let code = (response as? HTTPURLResponse)?.statusCode ?? 0
        Log.app.info("bug report → \(code)")
        switch code {
        case 200..<300: return (try? JSONDecoder().decode(Sent.self, from: data)) ?? Sent()
        case 503: throw Failure.notSetUp
        default:
            let text = (try? JSONSerialization.jsonObject(with: data) as? [String: Any])?["error"] as? String ?? ""
            throw Failure.server(code, text)
        }
    }

    /// The fallback: the same text as a file on the Desktop, selected in Finder.
    @discardableResult
    static func save(markdown: String) throws -> URL {
        let stamp = Date.now.formatted(.iso8601.year().month().day().time(includingFractionalSeconds: false).dateTimeSeparator(.space)).replacingOccurrences(of: ":", with: ".")
        let url = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Desktop/VinylCat report \(stamp).md")
        try markdown.write(to: url, atomically: true, encoding: .utf8)
        NSWorkspace.shared.activateFileViewerSelecting([url])
        return url
    }
}

// MARK: - Sheet

/// The form. `record` (with its evidence looked up here) comes from the Library's detail column; nil from Settings.
struct BugReportSheet: View {
    var record: VinylRecord?
    var onClose: () -> Void
    @State private var text = ""
    @State private var email = ""
    @State private var includeLog = true
    @State private var includeEvidence = true
    @State private var preview = false
    @State private var sending = false
    @State private var sent: BugReport.Sent?
    @State private var problem: String?
    @State private var savedTo: URL?
    @Environment(\.staticRender) private var staticRender

    private var evidence: ScanEvidence? { record.flatMap { Store.shared.evidence(for: $0.id) } }

    private var markdown: String {
        BugReport.markdown(description: text, email: email, version: BuildInfo.version, build: BuildInfo.build, macOS: BugReport.macOSVersion,
                           record: record, evidenceJSON: includeEvidence ? BugReport.evidenceJSON(evidence) : nil,
                           log: includeLog ? BugReport.logTail() : nil)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Caption("REPORT A PROBLEM", color: Theme.amber)
            if let sent {
                Text("Sent. Thank you.").font(Theme.display(28))
                Text(sent.number.map { "Filed as report #\($0). The developer reads every one\(email.isEmpty ? "." : " and will reply to \(email).")" }
                     ?? "The developer reads every one.")
                    .font(Theme.mono(12)).foregroundStyle(Theme.secondary).fixedSize(horizontal: false, vertical: true)
                CoffeePill("DONE", fill: true, compact: true, action: onClose)
            } else {
                Text(record.map { "\($0.artist) — \($0.title)".uppercased() } ?? "WHAT WENT WRONG?")
                    .font(Theme.display(26)).lineLimit(2).minimumScaleFactor(0.7)
                if record != nil { Caption("WHAT WENT WRONG?") }
                TextEditor(text: $text).font(Theme.mono(13)).frame(height: 110).scrollContentBackground(.hidden)
                    .padding(6).background(Theme.panel).overlay(Rectangle().stroke(Theme.line, lineWidth: 1))
                HStack(spacing: 12) {
                    Caption("EMAIL, IF YOU WANT A REPLY")
                    TextField("", text: $email).textFieldStyle(.plain).font(Theme.mono(13))
                        .padding(6).background(Theme.panel).overlay(Rectangle().stroke(Theme.line, lineWidth: 1))
                }
                VStack(alignment: .leading, spacing: 6) {
                    Toggle("Include the last \(BugReport.logLines) lines of the app's log — what the camera, the reader and Discogs did", isOn: $includeLog)
                    if record != nil {
                        Toggle("Include this record's scan evidence — what was read and the Discogs candidates", isOn: $includeEvidence)
                    }
                }
                .toggleStyle(.checkbox).font(Theme.mono(12)).foregroundStyle(Theme.secondary)
                Text("Goes to vinyl-cat.com and is filed for the developer to fix. Version, build and macOS version go with it; nothing else about you or your Mac. Keys never do. PREVIEW is the exact text.")
                    .font(Theme.mono(11)).foregroundStyle(Theme.muted).fixedSize(horizontal: false, vertical: true)
                if preview && !staticRender {
                    ScrollView {
                        Text(markdown).font(Theme.mono(10)).foregroundStyle(Theme.secondary).textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .frame(height: 200).padding(8).background(Theme.panel).overlay(Rectangle().stroke(Theme.line, lineWidth: 1))
                }
                if let problem {
                    Text(problem).font(Theme.mono(12)).foregroundStyle(Theme.amber).fixedSize(horizontal: false, vertical: true)
                }
                if let savedTo {
                    Text("Saved to \(savedTo.lastPathComponent) on the Desktop — email it, or send it later.")
                        .font(Theme.mono(12)).foregroundStyle(Theme.green).fixedSize(horizontal: false, vertical: true)
                }
                HStack(spacing: 10) {
                    CoffeePill(sending ? "SENDING…" : "SEND", fill: true, compact: true) { send() }
                    CoffeePill(preview ? "HIDE PREVIEW" : "PREVIEW", fill: false, compact: true) { preview.toggle() }
                    if problem != nil {
                        CoffeePill("SAVE AS FILE", fill: false, compact: true) {
                            do { savedTo = try BugReport.save(markdown: markdown) } catch { problem = error.localizedDescription }
                        }
                    }
                    Spacer()
                    Button("CANCEL", action: onClose).buttonStyle(.plain).font(Theme.mono(11)).tracking(1).foregroundStyle(Theme.muted)
                }
                .disabled(sending)
            }
        }
        .padding(24).frame(width: 600).background(Theme.bg).foregroundStyle(Theme.text)
    }

    private func send() {
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { problem = BugReport.Failure.noBody.errorDescription; return }
        sending = true; problem = nil; savedTo = nil
        let title = BugReport.title(text, record: record.map { "\($0.artist) — \($0.title)" })
        let md = markdown
        Task {
            do { sent = try await BugReport.send(title: title, markdown: md, version: BuildInfo.version) }
            catch { problem = "Couldn't send: \(error.localizedDescription)" }
            sending = false
        }
    }
}
