import Foundation

/// Turns the errors the scan loop can hit into one plain sentence the HUD can show and the speaker
/// can say. "The data couldn't be read because it isn't in the correct format" is Foundation's
/// wording for a JSON decode failure — it says nothing about *whose* data, which is what the operator
/// needs to know to do anything about it.
enum FriendlyError {
    static func describe(_ error: Error, context: String = "") -> String {
        let who = context.isEmpty ? "The service" : context
        switch error {
        case let e as ReaderError:
            switch e {
            case .missingKey: return e.localizedDescription
            case .http(let code, let body):
                switch code {
                case 401, 403: return "\(who) rejected the API key — check it in Settings"
                case 429: return "\(who) rate limit hit — wait a moment and try again"
                case 500...599: return "\(who) is having trouble (HTTP \(code)) — try again"
                default: return "\(who) returned HTTP \(code): \(body.prefix(120))"
                }
            case .badResponse(let m): return "\(who) sent a reply I couldn't use (\(m)) — try again"
            }
        case let e as DiscogsClient.DiscogsError:
            switch e {
            case .noToken: return e.localizedDescription
            case .http(let code, let body):
                switch code {
                case 401, 403: return "Discogs rejected the token — check it in Settings"
                case 404: return "Discogs has no such release"
                case 429: return "Discogs rate limit hit — it clears within a minute"
                case 500...599: return "Discogs is having trouble (HTTP \(code)) — try again"
                default: return "Discogs returned HTTP \(code): \(body.prefix(120))"
                }
            }
        case is DecodingError:
            return "\(who) sent a reply in an unexpected format — try again"
        case let e as URLError:
            switch e.code {
            case .notConnectedToInternet, .networkConnectionLost: return "No internet connection"
            case .timedOut: return "Timed out waiting for \(who.lowercased() == "the service" ? "the network" : who)"
            case .cannotFindHost, .cannotConnectToHost, .dnsLookupFailed: return "Can't reach \(who) — check the network"
            default: return "Network error: \(e.localizedDescription)"
            }
        default:
            return error.localizedDescription
        }
    }
}
