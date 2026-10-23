import Foundation
import Testing
@testable import Jib

/// A bulb's schedule service in memory, with a switch to make writes fail.
private final class FakeScheduleService: @unchecked Sendable {
    var rules: [ScheduleRule]
    var writeError: Error?
    var loads = 0

    init(rules: [ScheduleRule]) { self.rules = rules }

    var transport: ScheduleTransport {
        ScheduleTransport(
            load: { _ in
                self.loads += 1
                return BulbSchedule(rules: self.rules, isEnabled: true, next: nil, clock: nil, fetchedAt: .now)
            },
            add: { rule, _ in
                if let error = self.writeError { throw error }
                var stored = rule
                stored.id = UUID().uuidString
                self.rules.append(stored)
                return stored.id
            },
            edit: { rule, _ in
                if let error = self.writeError { throw error }
                guard let index = self.rules.firstIndex(where: { $0.id == rule.id }) else {
                    throw BulbError.device(code: -14, message: "rule not found")
                }
                self.rules[index] = rule
            },
            delete: { id, _ in
                if let error = self.writeError { throw error }
                self.rules.removeAll { $0.id == id }
            },
            setEnabled: { _, _ in if let error = self.writeError { throw error } },
            setClock: { _ in if let error = self.writeError { throw error } })
    }
}

@MainActor
struct ScheduleModelTests {
    private let bulb = Bulb(name: "Lamp", host: "10.0.0.9")
    private let bedtime = ScheduleRule(id: "R1", trigger: .time(minutes: 22 * 60), action: .off)

    @Test func aRefusedWriteKeepsItsErrorThroughTheReloadThatFollows() async {
        let service = FakeScheduleService(rules: [bedtime])
        let model = ScheduleModel(bulb: bulb, transport: service.transport)
        await model.load()
        #expect(model.rules.first?.isEnabled == true)

        service.writeError = BulbError.device(code: -3, message: "invalid argument")
        let accepted = await model.setEnabled(false, for: model.rules[0])
        #expect(!accepted)
        #expect(model.writeError?.contains("invalid argument") == true)
        #expect(model.loadError == nil)
        #expect(service.loads == 2)
        #expect(model.rules.first?.isEnabled == true, "the optimistic flip snapped back")
    }

    @Test func aRefusedDeleteKeepsTheRule() async {
        let service = FakeScheduleService(rules: [bedtime])
        let model = ScheduleModel(bulb: bulb, transport: service.transport)
        await model.load()

        service.writeError = BulbError.timeout(lastKnown: "sending")
        #expect(await model.delete(bedtime) == false)
        #expect(model.writeError?.contains("Timed out") == true)
        #expect(model.rules.map(\.id) == ["R1"])
    }

    @Test func theNextSuccessfulWriteClearsAnOldWriteError() async {
        let service = FakeScheduleService(rules: [bedtime])
        let model = ScheduleModel(bulb: bulb, transport: service.transport)
        await model.load()

        service.writeError = BulbError.device(code: -3, message: "invalid argument")
        await model.setEnabled(false, for: bedtime)
        #expect(model.writeError != nil)

        service.writeError = nil
        #expect(await model.setEnabled(false, for: bedtime))
        #expect(model.writeError == nil)
        #expect(model.rules.first?.isEnabled == false)
    }

    @Test func aFailedReadIsReportedSeparately() async {
        let service = FakeScheduleService(rules: [bedtime])
        var transport = service.transport
        transport.load = { _ in throw BulbError.timeout(lastKnown: nil) }
        let model = ScheduleModel(bulb: bulb, transport: transport)
        await model.load()
        #expect(model.schedule == nil)
        #expect(model.loadError != nil)
        #expect(model.writeError == nil)
    }
}
