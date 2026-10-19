import AppIntents
import Foundation

/// A saved bulb as the system sees it: the choice offered when configuring the Control Center
/// control or the watch complication, and the "Bulb" value in Shortcuts.
struct BulbEntity: AppEntity {
    static let typeDisplayRepresentation = TypeDisplayRepresentation(name: "Bulb")
    static let defaultQuery = BulbQuery()

    var id: UUID
    var name: String
    var host: String

    init(_ bulb: Bulb) {
        id = bulb.id
        name = bulb.name
        host = bulb.host
    }

    var displayRepresentation: DisplayRepresentation {
        DisplayRepresentation(title: "\(name)", subtitle: "\(host)")
    }
}

/// Resolves bulbs from the list in the App Group container.
struct BulbQuery: EntityStringQuery {
    private var all: [BulbEntity] { BulbStorage.loadBulbs().map(BulbEntity.init) }

    func entities(for identifiers: [UUID]) async throws -> [BulbEntity] {
        all.filter { identifiers.contains($0.id) }
    }

    func suggestedEntities() async throws -> [BulbEntity] {
        all
    }

    func entities(matching string: String) async throws -> [BulbEntity] {
        all.filter { $0.name.localizedCaseInsensitiveContains(string) }
    }

    /// Pre-selects the first saved bulb when a control or widget is added.
    func defaultResult() async -> BulbEntity? {
        all.first
    }
}
