import Foundation
import os

/// Logging to both the unified log and a plain file, because `log show` isn't always reachable:
///   tail -f ~/Library/Application\ Support/VinylCat/vinylcat.log
enum Log {
    static let camera = Channel("camera")
    static let capture = Channel("capture")
    static let scan = Channel("scan")
    static let voice = Channel("voice")
    static let discogs = Channel("discogs")
    static let app = Channel("app")

    static let fileURL: URL = PhotoStore.shared.root.deletingLastPathComponent().appendingPathComponent("vinylcat.log")
    private static let queue = DispatchQueue(label: "com.woodall.vinylcat.log")
    private static let stamp: DateFormatter = { let f = DateFormatter(); f.dateFormat = "HH:mm:ss.SSS"; return f }()

    struct Channel: Sendable {
        let name: String
        let logger: Logger
        init(_ name: String) { self.name = name; logger = Logger(subsystem: "com.woodall.vinylcat", category: name) }
        func info(_ msg: String) { logger.info("\(msg, privacy: .public)"); Log.write("I", name, msg) }
        func debug(_ msg: String) { logger.debug("\(msg, privacy: .public)"); Log.write("D", name, msg) }
        func error(_ msg: String) { logger.error("\(msg, privacy: .public)"); Log.write("E", name, msg) }
    }

    private static func write(_ level: String, _ channel: String, _ msg: String) {
        let line = "\(stamp.string(from: Date())) \(level) \(channel) · \(msg)\n"
        queue.async {
            if let h = try? FileHandle(forWritingTo: fileURL) {
                h.seekToEndOfFile(); h.write(Data(line.utf8)); try? h.close()
            } else {
                try? line.write(to: fileURL, atomically: true, encoding: .utf8)
            }
        }
    }

    /// Trim the file when it grows past ~2 MB (called at launch).
    static func rotate() {
        if let size = try? FileManager.default.attributesOfItem(atPath: fileURL.path)[.size] as? Int, size > 2_000_000 {
            try? FileManager.default.removeItem(at: fileURL)
        }
        write("I", "app", "launch \(Bundle.main.infoDictionary?["CFBundleShortVersionString"] ?? "?") · \(ProcessInfo.processInfo.operatingSystemVersionString)")
    }
}
