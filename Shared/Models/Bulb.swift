import Foundation

/// A bulb the user has added. Only the address is needed to talk to it.
struct Bulb: Identifiable, Codable, Hashable, Sendable {
    var id: UUID
    var name: String
    var host: String

    init(id: UUID = UUID(), name: String, host: String) {
        self.id = id
        self.name = name
        self.host = host
    }
}
