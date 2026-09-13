import Foundation

/// Vision-model spend kept across launches: the month to date (rolls over on the first read, or launch, in a
/// new calendar month) and the all-time total. The session figure stays in `Identifier`, in memory, and is
/// the rail's headline; this is the number that matches the provider's monthly bill. Stored as one JSON blob
/// in UserDefaults (`llmSpend`), so `--render-ui` and the self-test can point it at a throwaway suite.
struct SpendLedger: Codable, Equatable, Sendable {
    var monthKey = ""          // "2026-09"
    var monthCostUSD = 0.0
    var monthReads = 0
    var totalCostUSD = 0.0
    var totalReads = 0

    static let defaultsKey = "llmSpend"

    static func key(for date: Date, calendar: Calendar = .current) -> String {
        let c = calendar.dateComponents([.year, .month], from: date)
        return String(format: "%04d-%02d", c.year ?? 0, c.month ?? 0)
    }

    /// Starts a fresh month when `date` is in a different one from the last entry. The total is untouched.
    mutating func roll(to date: Date = Date()) {
        let k = Self.key(for: date)
        if k != monthKey { monthKey = k; monthCostUSD = 0; monthReads = 0 }
    }

    mutating func add(costUSD: Double, at date: Date = Date()) {
        roll(to: date)
        monthCostUSD += costUSD; monthReads += 1
        totalCostUSD += costUSD; totalReads += 1
    }

    /// A warning, never a stop: 0 means no warning.
    func isOver(budgetUSD: Double) -> Bool { budgetUSD > 0 && monthCostUSD >= budgetUSD }

    static func load(from defaults: UserDefaults = .standard, now: Date = Date()) -> SpendLedger {
        var l = defaults.data(forKey: defaultsKey).flatMap { try? JSONDecoder().decode(SpendLedger.self, from: $0) } ?? SpendLedger()
        l.roll(to: now)
        return l
    }

    func save(to defaults: UserDefaults = .standard) {
        if let d = try? JSONEncoder().encode(self) { defaults.set(d, forKey: Self.defaultsKey) }
    }
}
