import Foundation
import Testing
@testable import Jib

private func freshDefaults() -> UserDefaults {
    let name = "DemoBulbTests-\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: name)!
    defaults.removePersistentDomain(forName: name)
    return defaults
}

/// Pulls one command's reply out of a demo reply, checking its error code like the client does.
private func section(_ reply: [String: Any], _ service: String, _ command: String) throws -> [String: Any] {
    try BulbCommands.section(reply, service, command)
}

/// Ten in the morning today: a moment with a whole day of minutes ahead of it.
private let tenAM = Calendar.current.date(bySettingHour: 10, minute: 0, second: 0, of: .now)!

struct DemoBulbTests {
    private let lighting = BulbCommands.lightingService
    private let scheduling = BulbCommands.scheduleService
    private let timing = BulbCommands.timeService

    private func transition(_ state: inout DemoBulbState, _ action: BulbAction) throws -> LightState {
        let reply = state.reply(to: [lighting: ["transition_light_state": action.transitionParameters]])
        return LightState(lightState: try section(reply, lighting, "transition_light_state"))
    }

    // MARK: Through the client

    @Test func theDemoHostIsAnsweredWithoutOpeningAConnection() async throws {
        let opened = TCPSession.opened.value
        let info = try await BulbCommands.sysInfo(host: DemoBulb.host, timeout: 0.2, connectTimeout: 0.2)
        #expect(info.alias == DemoBulb.defaultName)
        #expect(info.model == DemoBulbState.model)
        #expect(info.isColor && info.isDimmable && info.isVariableColorTemp)
        #expect(info.presets.count == 4)

        // The round trip the Control Center control and the watch relay make.
        guard case .state(let on) = try await BulbCommands.perform(.power(true), host: DemoBulb.host) else {
            Issue.record("a set command echoes the light state"); return
        }
        #expect(on.isOn)
        guard case .state(let off) = try await BulbCommands.perform(.power(false), host: DemoBulb.host) else {
            Issue.record("a set command echoes the light state"); return
        }
        #expect(!off.isOn)
        #expect(TCPSession.opened.value == opened, "the demo bulb must never reach the network")
    }

    @Test func demoBulbsAreRecognisedByAddressAlone() {
        #expect(Bulb.demo().isDemo)
        #expect(Bulb(name: "Kitchen", host: " Demo ").isDemo, "renaming it changes nothing")
        #expect(!Bulb(name: "Demo Bulb", host: "192.168.1.23").isDemo)
    }

    // MARK: Light

    @Test func startsOffAndRemembersItsColourWhileOff() throws {
        var state = DemoBulbState()
        let info = try BulbInfo(sysInfo: try section(state.reply(to: ["system": ["get_sysinfo": [:]]]), "system", "get_sysinfo"))
        #expect(!info.state.isOn)
        #expect(info.state.brightness == 50)
        #expect(info.state.colorTemp == 2700)
        #expect(info.colorTempRange == DemoBulbState.colorTempRange)

        #expect(try transition(&state, .brightness(30)).brightness == 30)
        let colour = try transition(&state, .color(hue: 120, saturation: 100))
        #expect(colour.isOn && !colour.isWhite && colour.hue == 120 && colour.brightness == 30)
        let off = try transition(&state, .power(false))
        #expect(!off.isOn)
        #expect(off.hue == 120 && off.brightness == 30, "the colour comes back under dft_on_state")

        let white = try transition(&state, .colorTemp(4000))
        #expect(white.isOn && white.isWhite && white.colorTemp == 4000)
    }

    @Test func presetsApply() throws {
        var state = DemoBulbState()
        let info = try BulbInfo(sysInfo: state.sysInfo)
        let blue = try #require(info.presets.first { $0.index == 3 })
        let lit = try transition(&state, .preset(blue))
        #expect(lit == LightState(isOn: true, brightness: 100, colorTemp: 0, hue: 240, saturation: 100))
    }

    @Test func valuesOutOfRangeAreRefusedLikeTheFirmware() throws {
        var state = DemoBulbState()
        let reply = state.reply(to: [lighting: ["transition_light_state": ["on_off": 1, "brightness": 0]]])
        #expect(throws: BulbError.self) { try section(reply, lighting, "transition_light_state") }
        #expect(!state.light.isOn, "a refused command changes nothing")

        let unknown = state.reply(to: ["smartlife.iot.common.cloud": ["get_info": [:]]])
        #expect(throws: BulbError.self) { try section(unknown, "smartlife.iot.common.cloud", "get_info") }
    }

    // MARK: Schedule

    @Test func rulesRoundTripThroughTheScheduleService() throws {
        var state = DemoBulbState()
        // An "off" rule carries no fade, so it comes back with a zero transition like a real bulb's.
        var bedtime = ScheduleRule(name: "Bedtime", days: [false, true, true, true, true, true, false],
                                   trigger: .time(minutes: 22 * 60), action: .off, transitionMillis: 0)
        let added = try section(state.reply(to: [scheduling: ["add_rule": bedtime.parameters]]), scheduling, "add_rule")
        bedtime.id = try #require(added["id"] as? String)
        #expect(!bedtime.id.isEmpty)

        func stored() throws -> [ScheduleRule] {
            let rules = try section(state.reply(to: [scheduling: ["get_rules": [:]]]), scheduling, "get_rules")
            return (rules["rule_list"] as? [[String: Any]] ?? []).compactMap(ScheduleRule.init(dict:))
        }
        #expect(try stored() == [bedtime])

        bedtime.isEnabled = false
        _ = try section(state.reply(to: [scheduling: ["edit_rule": bedtime.parameters]]), scheduling, "edit_rule")
        #expect(try stored().first?.isEnabled == false)

        _ = try section(state.reply(to: [scheduling: ["delete_rule": ["id": bedtime.id]]]), scheduling, "delete_rule")
        #expect(try stored().isEmpty)

        let nameless = ScheduleRule(trigger: .time(minutes: 60), action: .off).parameters.merging(["name": ""]) { $1 }
        let refused = state.reply(to: [scheduling: ["add_rule": nameless]])
        #expect(throws: BulbError.self) { try section(refused, scheduling, "add_rule") }
        var stranger = bedtime
        stranger.id = "NOPE"
        let missing = state.reply(to: [scheduling: ["edit_rule": stranger.parameters]])
        #expect(throws: BulbError.self) { try section(missing, scheduling, "edit_rule") }
    }

    @Test func aRuleDueSinceTheLastRequestHasFired() throws {
        var state = DemoBulbState()
        state.light.isOn = true
        let inOneMinute = ScheduleTrigger.minutes(from: tenAM) + 1
        _ = state.reply(to: [scheduling: ["add_rule": ScheduleRule(name: "Off", trigger: .time(minutes: inOneMinute), action: .off).parameters]],
                        now: tenAM)
        #expect(state.light.isOn)

        _ = state.reply(to: ["system": ["get_sysinfo": [:]]], now: tenAM.addingTimeInterval(30))
        #expect(state.light.isOn, "not due yet")

        _ = state.reply(to: ["system": ["get_sysinfo": [:]]], now: tenAM.addingTimeInterval(150))
        #expect(!state.light.isOn, "fired between the two requests")

        // The master switch holds rules back.
        let dim = LightState(isOn: true, brightness: 10, colorTemp: 2700, hue: 0, saturation: 0)
        _ = state.reply(to: [scheduling: ["add_rule": ScheduleRule(name: "Dim", trigger: .time(minutes: inOneMinute + 3), action: .on(dim)).parameters,
                                          "set_overall_enable": ["enable": 0]]],
                        now: tenAM.addingTimeInterval(160))
        _ = state.reply(to: ["system": ["get_sysinfo": [:]]], now: tenAM.addingTimeInterval(300))
        #expect(!state.light.isOn)
        _ = state.reply(to: [scheduling: ["set_overall_enable": ["enable": 1]]], now: tenAM.addingTimeInterval(310))
        _ = state.reply(to: [scheduling: ["add_rule": ScheduleRule(name: "Dim", trigger: .time(minutes: inOneMinute + 6), action: .on(dim)).parameters]],
                        now: tenAM.addingTimeInterval(320))
        _ = state.reply(to: ["system": ["get_sysinfo": [:]]], now: tenAM.addingTimeInterval(500))
        #expect(state.light == dim)
    }

    @Test func reportsTheNextRuleAndItsClock() throws {
        var state = DemoBulbState()
        let later = ScheduleTrigger.minutes(from: tenAM) + 90
        _ = state.reply(to: [scheduling: ["add_rule": ScheduleRule(name: "Lamp", trigger: .time(minutes: later), action: .off).parameters]], now: tenAM)
        let evening = try section(state.reply(to: [scheduling: ["add_rule": ScheduleRule(name: "Lamp", trigger: .time(minutes: later + 30), action: .off).parameters]], now: tenAM),
                                  scheduling, "add_rule")["id"] as? String
        let schedule = state.reply(to: [scheduling: ["get_next_action": [:]], timing: ["get_time": [:], "get_timezone": [:]]], now: tenAM)
        let next = try #require(NextScheduledAction(dict: try section(schedule, scheduling, "get_next_action")))
        #expect(next.secondsAfterMidnight == later * 60)
        #expect(next.turnsOn == false)
        let clock = try #require(BulbClock(dict: try section(schedule, timing, "get_time")))
        #expect(clock.date() == tenAM)
        #expect((try section(schedule, timing, "get_timezone"))["index"] is Int)

        // Setting the time moves the bulb's clock, and the schedule follows it.
        let ahead = tenAM.addingTimeInterval(3600)
        _ = try section(state.reply(to: [timing: ["set_time": BulbClock.parameters(for: ahead)]], now: tenAM), timing, "set_time")
        let moved = try #require(BulbClock(dict: try section(state.reply(to: [timing: ["get_time": [:]]], now: tenAM), timing, "get_time")))
        #expect(moved.drift(from: tenAM) == 3600)
        let afterwards = try section(state.reply(to: [scheduling: ["get_next_action": [:]]], now: tenAM.addingTimeInterval(1800)), scheduling, "get_next_action")
        #expect(NextScheduledAction(dict: afterwards)?.ruleID == evening, "the first rule is now in the bulb's past")
    }

    // MARK: Storage

    @Test func stateLivesInTheSharedStoreUntilReset() throws {
        let defaults = freshDefaults()
        _ = DemoBulb.reply(to: [lighting: ["transition_light_state": ["on_off": 1, "brightness": 77]]], in: defaults)
        let again = try section(DemoBulb.reply(to: ["system": ["get_sysinfo": [:]]], in: defaults), "system", "get_sysinfo")
        #expect(try BulbInfo(sysInfo: again).state == LightState(isOn: true, brightness: 77, colorTemp: 2700, hue: 0, saturation: 0))

        DemoBulb.reset(in: defaults)
        #expect(DemoBulb.load(from: defaults) == DemoBulbState())
    }

    @MainActor
    @Test func theStoreAddsOneDemoBulbAndForgetsItsStateOnRemoval() async throws {
        let defaults = freshDefaults()
        let store = BulbStore(defaults: defaults) { _, _ in .info(try BulbInfo(sysInfo: DemoBulbState().sysInfo)) }
        store.addDemoBulb()
        store.addDemoBulb()
        #expect(store.bulbs.count == 1)
        #expect(store.hasDemoBulb)
        #expect(BulbStorage.loadBulbs(from: defaults).first?.isDemo == true, "it survives relaunch like any bulb")

        _ = DemoBulb.reply(to: [lighting: ["transition_light_state": ["on_off": 1]]], in: defaults)
        #expect(DemoBulb.load(from: defaults).light.isOn)
        store.remove(store.bulbs[0])
        #expect(!store.hasDemoBulb)
        #expect(defaults.data(forKey: DemoBulb.storageKey) == nil)
    }
}
