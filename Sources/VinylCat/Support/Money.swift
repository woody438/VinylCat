import Foundation

/// Prices with their currency, compact enough for a table column: "£16", "$2.23", "CAD 6.79".
enum Money {
    static let symbols: [String: String] = ["GBP": "£", "USD": "$", "EUR": "€", "JPY": "¥", "AUD": "A$", "CAD": "CA$", "NZD": "NZ$", "MXN": "MX$", "BRL": "R$", "ZAR": "R", "CHF": "CHF ", "SEK": "SEK "]

    /// Whole units from 10 up, pennies below — unless `decimals` forces two places.
    static func format(_ amount: Double, _ currency: String, decimals: Bool = false) -> String {
        let code = currency.uppercased()
        let prefix = symbols[code] ?? "\(code) "
        let number = decimals || amount < 10 ? String(format: "%.2f", amount) : String(Int(amount.rounded()))
        return prefix + number
    }
}
