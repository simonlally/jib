import Foundation
import Observation

/// The schedule of one bulb as the phone last read it, plus the writes the schedule screen makes.
/// Every write is followed by a fresh read so the list shows what the bulb actually stored.
@MainActor
@Observable
final class ScheduleModel {
    let bulb: Bulb
    private(set) var schedule: BulbSchedule?
    private(set) var error: String?
    private(set) var isLoading = false
    private(set) var isSaving = false

    init(bulb: Bulb) {
        self.bulb = bulb
    }

    var rules: [ScheduleRule] { schedule?.sortedRules ?? [] }

    func load() async {
        isLoading = true
        defer { isLoading = false }
        do {
            schedule = try await BulbCommands.schedule(host: bulb.host)
            error = nil
        } catch {
            self.error = error.localizedDescription
        }
    }

    /// Adds a new rule or rewrites an existing one. Returns whether the bulb accepted it.
    @discardableResult
    func save(_ rule: ScheduleRule) async -> Bool {
        await write {
            if rule.isNew {
                _ = try await BulbCommands.addRule(rule, host: self.bulb.host)
            } else {
                try await BulbCommands.editRule(rule, host: self.bulb.host)
            }
        }
    }

    func setEnabled(_ enabled: Bool, for rule: ScheduleRule) async {
        var updated = rule
        updated.isEnabled = enabled
        // Show the flip at once; the read after the write settles it.
        if let index = schedule?.rules.firstIndex(where: { $0.id == rule.id }) {
            schedule?.rules[index].isEnabled = enabled
        }
        await save(updated)
    }

    func delete(_ rule: ScheduleRule) async {
        schedule?.rules.removeAll { $0.id == rule.id }
        await write { try await BulbCommands.deleteRule(id: rule.id, host: self.bulb.host) }
    }

    func setAllEnabled(_ enabled: Bool) async {
        schedule?.isEnabled = enabled
        await write { try await BulbCommands.setScheduleEnabled(enabled, host: self.bulb.host) }
    }

    /// Copies the phone's time to the bulb.
    func syncClock() async {
        await write { try await BulbCommands.setClock(host: self.bulb.host) }
    }

    /// Runs a write, then re-reads the schedule. Reports whether the write itself succeeded.
    private func write(_ operation: () async throws -> Void) async -> Bool {
        isSaving = true
        defer { isSaving = false }
        do {
            try await operation()
        } catch {
            self.error = error.localizedDescription
            await load()
            return false
        }
        await load()
        return true
    }
}
