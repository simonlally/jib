import Foundation

/// Wire format between the watch and the phone over WatchConnectivity.
/// watchOS blocks raw TCP for ordinary apps (Apple TN3135), so the watch asks the phone to talk to the bulb.
enum Relay {
    static let requestKey = "request"
    static let responseKey = "response"
    static let bulbsKey = "bulbs"
    static let statesKey = "states"
}

struct RelayRequest: Codable, Sendable {
    var host: String
    var action: BulbAction
}

struct RelayResponse: Codable, Sendable {
    var result: ActionResult?
    var error: String?
}

enum RelayError: LocalizedError {
    case notActivated
    case phoneUnreachable
    case badReply
    case remote(String)

    var errorDescription: String? {
        switch self {
        case .notActivated: return "Connecting to iPhone…"
        case .phoneUnreachable: return "iPhone not reachable"
        case .badReply: return "Bad reply from iPhone"
        case .remote(let message): return message
        }
    }
}
