import Foundation

/// The saved bulb list and the last state seen for each bulb, kept in the App Group container so
/// the widget extensions can read what the apps know. Each platform has its own container: on the
/// phone it is shared by Jib and its Control Center extension, on the watch by the watch app and
/// its complication.
enum BulbStorage {
    static let appGroup = "group.dev.simonlally.Jib"
    static let bulbsKey = "bulbs.v1"
    static let statesKey = "states.v1"

    /// Kind of the Control Center / Lock Screen control on the phone.
    static let controlKind = "dev.simonlally.Jib.BulbControl"
    /// Kind of the Smart Stack widget / complication on the watch.
    static let watchWidgetKind = "dev.simonlally.Jib.BulbWidget"

    /// The group container. Falls back to the app's own defaults if the entitlement is missing.
    static let defaults: UserDefaults = UserDefaults(suiteName: appGroup) ?? .standard

    // MARK: Bulb list

    static func loadBulbs(from store: UserDefaults = BulbStorage.defaults) -> [Bulb] {
        guard let data = store.data(forKey: bulbsKey) else { return [] }
        return (try? JSONDecoder().decode([Bulb].self, from: data)) ?? []
    }

    static func saveBulbs(_ bulbs: [Bulb], to store: UserDefaults = BulbStorage.defaults) {
        store.set(try? JSONEncoder().encode(bulbs), forKey: bulbsKey)
    }

    /// Moves a list saved by an earlier version in the app's own defaults into the group container.
    /// Does nothing once the group container has a list of its own.
    static func migrateIfNeeded(from legacy: UserDefaults = .standard, to store: UserDefaults = BulbStorage.defaults) {
        guard legacy !== store, store.data(forKey: bulbsKey) == nil,
              let data = legacy.data(forKey: bulbsKey) else { return }
        store.set(data, forKey: bulbsKey)
        legacy.removeObject(forKey: bulbsKey)
    }

    // MARK: Last state seen per bulb

    static func loadStates(from store: UserDefaults = BulbStorage.defaults) -> [UUID: LightState] {
        guard let data = store.data(forKey: statesKey) else { return [:] }
        return (try? JSONDecoder().decode([UUID: LightState].self, from: data)) ?? [:]
    }

    static func saveStates(_ states: [UUID: LightState], to store: UserDefaults = BulbStorage.defaults) {
        store.set(try? JSONEncoder().encode(states), forKey: statesKey)
    }

    static func state(for id: UUID, in store: UserDefaults = BulbStorage.defaults) -> LightState? {
        loadStates(from: store)[id]
    }

    /// Records a bulb's state (`nil` forgets it) and reports whether anything actually changed.
    @discardableResult
    static func setState(_ state: LightState?, for id: UUID, in store: UserDefaults = BulbStorage.defaults) -> Bool {
        var states = loadStates(from: store)
        guard states[id] != state else { return false }
        states[id] = state
        saveStates(states, to: store)
        return true
    }
}

/// URLs that open the apps. The watch complication uses one because a widget extension can't talk
/// to the phone itself; the watch app does the relaying once it is open.
enum JibLink {
    static let scheme = "jib"

    /// `jib://toggle/<bulb id>`: flip the bulb's power.
    static func toggleURL(for id: UUID) -> URL {
        URL(string: "\(scheme)://toggle/\(id.uuidString)")!
    }

    static func bulbID(fromToggleURL url: URL) -> UUID? {
        guard url.scheme == scheme, url.host == "toggle" else { return nil }
        return UUID(uuidString: url.lastPathComponent)
    }
}
