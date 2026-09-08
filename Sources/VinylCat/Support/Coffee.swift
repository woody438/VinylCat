import AppKit
import SwiftUI

/// The tip jar. VinylCat is free and runs on the user's own keys, so the ask is for the developer's
/// coffee, not for infrastructure. It grows with the catalogue: a line at 25 scanned records, a card
/// at 100 and 250, a sheet on launch from 500 and every 500 after. It never appears inside the scan
/// HUD and never blocks a capture. "I've bought one" is honour-system: one cheeky confirm, then the
/// app believes the answer forever.
@MainActor
@Observable
final class Coffee {
    static let url = URL(string: "https://ko-fi.com/woody438?amount=5")!
    static let handle = "ko-fi.com/woody438"

    /// Set once the user says they have bought one. Everything goes quiet after this.
    var supporter: Bool = UserDefaults.standard.bool(forKey: "coffeeBought") {
        didSet { UserDefaults.standard.set(supporter, forKey: "coffeeBought") }
    }
    /// The milestone last waved away with "Later": the ask stays hidden until the next one.
    var dismissedAt: Int = UserDefaults.standard.integer(forKey: "coffeeDismissedAt") {
        didSet { UserDefaults.standard.set(dismissedAt, forKey: "coffeeDismissedAt") }
    }
    /// The launch sheet shows once per launch at most, whatever happens to the count meanwhile.
    var sheetOfferedThisLaunch = false
    /// `--render-ui` forces a record count so every size of the ask can be drawn without a catalogue.
    var previewCount: Int?

    enum Size { case line, card, sheet }

    /// The highest milestone at or below `count`: 25, 100, 250, 500, then every 500. Nil below 25.
    static func milestone(reached count: Int) -> Int? {
        if count >= 500 { return count / 500 * 500 }
        return [250, 100, 25].first { count >= $0 }
    }

    static func size(for milestone: Int) -> Size {
        switch milestone {
        case ..<100: .line
        case ..<500: .card
        default: .sheet
        }
    }

    /// The pitch, one per rung. Value is the Library's estimate, e.g. "GBP 1,240", when there is one.
    static func line(for milestone: Int, count: Int, value: String?) -> String {
        switch milestone {
        case ..<100: return "Enjoying it? Buy me a coffee."
        case ..<250:
            if let value { return "\(count) records, worth \(value). That's a lot of coffee." }
            return "\(count) records catalogued. That's a lot of coffee."
        case ..<500: return "\(count) records. Zero coffees. I'm not saying anything."
        case ..<1000: return "You've catalogued \(count) records for free. The developer has had no coffee at all."
        default: return "\(count). Fine. You win. Buy me a coffee anyway."
        }
    }

    /// The Later button gets ruder as the count climbs.
    static func laterLabel(for milestone: Int) -> String {
        switch milestone {
        case ..<100: "Not now"
        case ..<250: "Still not now"
        case ..<500: "Maybe after the next crate"
        default: "I am a monster"
        }
    }

    /// Records the camera actually catalogued: live, with a photo. Discogs pulls and typed-in
    /// records do not count, so a 2,000-record import does not open with "You win".
    func count(in store: Store) -> Int { previewCount ?? store.scannedCount() }

    /// The milestone that is due right now, or nil when there is nothing to show.
    func due(in store: Store) -> Int? {
        guard !supporter, let m = Self.milestone(reached: count(in: store)), m > dismissedAt else { return nil }
        return m
    }

    /// The sheet is a launch-time thing: mid-session the 500th record only ever gets the card.
    func sheetDue(in store: Store) -> Bool {
        guard !sheetOfferedThisLaunch, let m = due(in: store), Self.size(for: m) == .sheet else { return false }
        return true
    }

    func later(_ milestone: Int) { dismissedAt = milestone }
    func open() { NSWorkspace.shared.open(Self.url) }

    /// The Library's estimate, formatted like its footer: "GBP 1,240". Nil when nothing is priced.
    static func valueText(in store: Store, fallbackCurrency: String) -> String? {
        let live = store.all().filter(\.isLive)
        let total = live.compactMap { $0.valueMedian ?? $0.valueLow }.reduce(0, +)
        guard total > 0 else { return nil }
        let cur = live.first?.currency ?? fallbackCurrency
        return "\(cur) \(Int(total).formatted(.number.grouping(.automatic)))"
    }
}

// MARK: - Views

/// The ask at whatever size is due: a footer line, or a card. Draws nothing when nothing is due, so
/// it can sit permanently in a layout. `sizes` limits what this placement is willing to show;
/// `narrow` stacks the card for the 340-point scan rail.
struct CoffeeAsk: View {
    @Environment(AppState.self) private var state
    var sizes: Set<Coffee.Size> = [.line, .card, .sheet]
    var narrow = false
    var body: some View {
        let store = Store.shared
        let _ = store.revision
        if let m = state.coffee.due(in: store), sizes.contains(Coffee.size(for: m)) {
            let count = state.coffee.count(in: store)
            let value = Coffee.valueText(in: store, fallbackCurrency: state.discogs.currency)
            switch Coffee.size(for: m) {
            case .line: CoffeeLine(milestone: m, text: Coffee.line(for: m, count: count, value: value))
            case .card, .sheet: CoffeeCard(milestone: m, text: Coffee.line(for: m, count: count, value: value), narrow: narrow)
            }
        }
    }
}

/// Rung one: a slim strip, one line of mono text and the compact buttons.
struct CoffeeLine: View {
    let milestone: Int
    let text: String
    var body: some View {
        HStack(spacing: 14) {
            Text("☕").font(.system(size: 13))
            Text(text.uppercased()).font(Theme.mono(12)).tracking(1).foregroundStyle(Theme.amber).lineLimit(1).fixedSize()
            Spacer(minLength: 12)
            CoffeeButtons(milestone: milestone, compact: true)
        }
        .padding(.horizontal, 24).padding(.vertical, 8)
        .background(Theme.panel)
        .overlay(alignment: .leading) { Rectangle().fill(Theme.amber).frame(width: 4) }
    }
}

/// Rungs two and three: a card with the pitch and the two buttons.
struct CoffeeCard: View {
    let milestone: Int
    let text: String
    var narrow = false
    var body: some View {
        Group {
            if narrow {
                VStack(alignment: .leading, spacing: 12) {
                    pitch
                    CoffeeButtons(milestone: milestone, compact: true, stacked: true)
                }
            } else {
                HStack(alignment: .center, spacing: 20) {
                    Text("☕").font(.system(size: 30))
                    pitch
                    Spacer(minLength: 12)
                    CoffeeButtons(milestone: milestone, compact: false)
                }
            }
        }
        .padding(.horizontal, narrow ? 16 : 24).padding(.vertical, 16)
        .background(Theme.amberBg)
        .overlay(alignment: .leading) { Rectangle().fill(Theme.amber).frame(width: 4) }
    }

    private var pitch: some View {
        VStack(alignment: .leading, spacing: 4) {
            Caption("☕ BUY ME A COFFEE", color: Theme.amber)
            Text(text).font(Theme.display(narrow ? 20 : 24, weight: .semibold)).foregroundStyle(Theme.text)
                .lineLimit(narrow ? 4 : 2).minimumScaleFactor(0.7).fixedSize(horizontal: false, vertical: true)
        }
    }
}

/// Rung four: the launch sheet, from 500 records. Presented from `RootView`; also rendered flat by `--render-ui`.
struct CoffeeSheet: View {
    @Environment(AppState.self) private var state
    let milestone: Int
    let count: Int
    let value: String?
    var onClose: () -> Void = {}
    var body: some View {
        VStack(alignment: .leading, spacing: 22) {
            HStack(spacing: 14) {
                LogoMark(disc: Theme.raised).frame(width: 34, height: 34)
                Caption("VINYLCAT · BUY ME A COFFEE", color: Theme.amber)
            }
            Text("\(count)").font(Theme.display(120)).foregroundStyle(Theme.amber).lineLimit(1).minimumScaleFactor(0.5)
            Text(Coffee.line(for: milestone, count: count, value: value))
                .font(Theme.display(30, weight: .semibold)).foregroundStyle(Theme.text)
                .fixedSize(horizontal: false, vertical: true)
            Text("VinylCat is free and runs on your own Discogs and model keys. Nothing here pays for servers — there aren't any. The coffee is for the developer" + (value.map { ", who just told you your records are worth \($0)." } ?? "."))
                .font(Theme.mono(13)).foregroundStyle(Theme.secondary).fixedSize(horizontal: false, vertical: true)
            CoffeeButtons(milestone: milestone, compact: false, afterwards: onClose)
        }
        .padding(36)
        .frame(width: 620, alignment: .leading)
        .background(Theme.bg)
        .overlay(alignment: .top) { Rectangle().fill(Theme.amber).frame(height: 4) }
        .foregroundStyle(Theme.text)
        .preferredColorScheme(.dark)
    }
}

/// The three actions every rung shares: open Ko-fi, "I've bought one" (with the hand-on-heart
/// check), and Later, whose label climbs with the milestone. `stacked` puts Later on its own line
/// for the narrow rail, where three-in-a-row crushed it to nothing.
struct CoffeeButtons: View {
    @Environment(AppState.self) private var state
    let milestone: Int
    var compact: Bool
    var stacked = false
    var afterwards: () -> Void = {}
    @State private var checking = false

    var body: some View {
        let coffee = state.coffee
        Group {
            if stacked {
                VStack(alignment: .leading, spacing: 10) {
                    HStack(spacing: 10) { pills }
                    later
                }
            } else {
                HStack(spacing: compact ? 12 : 10) { pills; later }
            }
        }
        .alert("Hand on heart, coffee actually bought?", isPresented: $checking) {
            Button("Hand on heart") { coffee.supporter = true; afterwards() }
            Button("…fine, take me to Ko-fi") { coffee.open() }
        } message: {
            Text("The app can't check. It just trusts you. Which is more than Discogs does.")
        }
    }

    @ViewBuilder private var pills: some View {
        pill("BUY ME A COFFEE", fill: true) { state.coffee.open() }
        pill("I'VE BOUGHT ONE", fill: false) { checking = true }
    }

    private var later: some View {
        Button(Coffee.laterLabel(for: milestone).uppercased()) { state.coffee.later(milestone); afterwards() }
            .buttonStyle(.plain).font(Theme.mono(11)).tracking(1).foregroundStyle(Theme.muted).lineLimit(1).fixedSize()
            .help("Ask again at the next milestone")
    }

    private func pill(_ title: String, fill: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title).font(Theme.mono(compact ? 11 : 12)).tracking(1).lineLimit(1).fixedSize()
                .foregroundStyle(fill ? Theme.bg : Theme.amber)
                .padding(.horizontal, compact ? 10 : 14).frame(height: compact ? 24 : 30)
                .background(fill ? Theme.amber : .clear)
                .overlay(Rectangle().stroke(Theme.amber, lineWidth: 1))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

/// Settings → SUPPORT. Always available, whatever the count: the way in for anyone who wants to
/// donate early, and the way back for anyone who pressed "Hand on heart" by mistake.
struct CoffeeSettings: View {
    @Environment(AppState.self) private var state
    @State private var checking = false
    var body: some View {
        let coffee = state.coffee
        VStack(alignment: .leading, spacing: 10) {
            Text("VinylCat is free and runs on your own keys. If it has saved you an afternoon, buy the developer a coffee — \(Coffee.handle).")
                .font(Theme.mono(11)).foregroundStyle(Theme.muted).fixedSize(horizontal: false, vertical: true)
            HStack(spacing: 12) {
                Button("Open Ko-fi") { coffee.open() }
                if coffee.supporter {
                    Text("☕ COFFEE BOUGHT · THANK YOU").font(Theme.mono(12)).tracking(1).foregroundStyle(Theme.green)
                    Button("Undo") { coffee.supporter = false }.buttonStyle(.plain).font(Theme.mono(11)).foregroundStyle(Theme.muted)
                } else {
                    Button("I've bought one") { checking = true }
                    Text("Scanned: \(coffee.count(in: Store.shared))").font(Theme.mono(11)).foregroundStyle(Theme.muted)
                }
            }
        }
        .alert("Hand on heart, coffee actually bought?", isPresented: $checking) {
            Button("Hand on heart") { coffee.supporter = true }
            Button("…fine, take me to Ko-fi") { coffee.open() }
        } message: {
            Text("The app can't check. It just trusts you. Which is more than Discogs does.")
        }
    }
}
