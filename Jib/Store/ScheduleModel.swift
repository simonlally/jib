import Foundation
import Observation

/// The bulb calls the schedule model makes. Injected so tests can stand in for the network.
struct ScheduleTransport {
    var load: (_ host: String) async throws -> BulbSchedule
    var add: (_ rule: ScheduleRule, _ host: String) async throws -> String
    var edit: (_ rule: ScheduleRule, _ host: String) async throws -> Void
    var delete: (_ id: String, _ host: String) async throws -> Void
    var setEnabled: (_ enabled: Bool, _ host: String) async throws -> Void
    var setClock: (_ host: String) async throws -> Void

    static let live = ScheduleTransport(
        load: { try await BulbCommands.schedule(host: $0) },
        add: { try await BulbCommands.addRule($0, host: $1) },
        edit: { try await BulbCommands.editRule($0, host: $1) },
        delete: { try await BulbCommands.deleteRule(id: $0, host: $1) },
        setEnabled: { try await BulbCommands.setScheduleEnabled($0, host: $1) },
        setClock: { try await BulbCommands.setClock(host: $0) })
}

/// The schedule of one bulb as the phone last read it, plus the writes the schedule screen makes.
/// Every write is followed by a fresh read so the list shows what the bulb actually stored.
@MainActor
@Observable
final class ScheduleModel {
    let bulb: Bulb
    private(set) var schedule: BulbSchedule?
    /// Why the last read failed. Cleared by a read that succeeds.
    private(set) var loadError: String?
    /// Why the last write failed. Cleared when the next write starts, not by the read after it.
    private(set) var writeError: String?
    private(set) var isLoading = false
    private(set) var isSaving = false

    private let transport: ScheduleTransport

    init(bulb: Bulb, transport: ScheduleTransport = .live) {
        self.bulb = bulb
        self.transport = transport
    }

    var rules: [ScheduleRule] { schedule?.sortedRules ?? [] }

    func load() async {
        isLoading = true
        defer { isLoading = false }
        do {
            schedule = try await transport.load(bulb.host)
            loadError = nil
        } catch {
            loadError = error.localizedDescription
        }
    }

    /// Adds a new rule or rewrites an existing one. Returns whether the bulb accepted it.
    @discardableResult
    func save(_ rule: ScheduleRule) async -> Bool {
        await write {
            if rule.isNew {
                _ = try await transport.add(rule, bulb.host)
            } else {
                try await transport.edit(rule, bulb.host)
            }
        }
    }

    /// Flips one rule. The list shows the flip at once; the read after the write settles it,
    /// so a rejected flip snaps back and `writeError` says why.
    @discardableResult
    func setEnabled(_ enabled: Bool, for rule: ScheduleRule) async -> Bool {
        var updated = rule
        updated.isEnabled = enabled
        if let index = schedule?.rules.firstIndex(where: { $0.id == rule.id }) {
            schedule?.rules[index].isEnabled = enabled
        }
        return await save(updated)
    }

    @discardableResult
    func delete(_ rule: ScheduleRule) async -> Bool {
        schedule?.rules.removeAll { $0.id == rule.id }
        return await write { try await transport.delete(rule.id, bulb.host) }
    }

    @discardableResult
    func setAllEnabled(_ enabled: Bool) async -> Bool {
        schedule?.isEnabled = enabled
        return await write { try await transport.setEnabled(enabled, bulb.host) }
    }

    /// Copies the phone's time to the bulb.
    @discardableResult
    func syncClock() async -> Bool {
        await write { try await transport.setClock(bulb.host) }
    }

    /// Runs a write, then re-reads the schedule. Reports whether the write itself succeeded; the
    /// read's own outcome lands in `loadError` and never hides a write failure.
    private func write(_ operation: () async throws -> Void) async -> Bool {
        isSaving = true
        writeError = nil
        defer { isSaving = false }
        do {
            try await operation()
        } catch {
            writeError = error.localizedDescription
            await load()
            return false
        }
        await load()
        return true
    }
}
