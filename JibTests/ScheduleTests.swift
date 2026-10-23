import Foundation
import Testing
@testable import Jib

struct ScheduleTests {
    /// Trimmed from a real KL125 `get_rules` reply: a sunset rule with an offset, a fixed-time "on",
    /// a fixed-time "off" and a disabled rule.
    private let ruleList: [[String: Any]] = [
        ["id": "D925A5F1FD2F939BF82BA6ADFA2EBD98", "name": "name", "enable": 1, "wday": [1, 1, 1, 1, 1, 1, 1],
         "stime_opt": 2, "smin": 1038, "soffset": -45, "sact": 2,
         "s_light": ["on_off": 1, "mode": "customize_preset", "hue": 0, "saturation": 0, "color_temp": 2700,
                     "brightness": 50, "transition_period": 5000],
         "eact": -1, "repeat": 1],
        ["id": "136318D72EEBC7E52AE65E3A2C623123", "name": "name", "enable": 1, "wday": [1, 1, 1, 1, 1, 1, 1],
         "stime_opt": 0, "smin": 1320, "sact": 2,
         "s_light": ["on_off": 1, "mode": "customize_preset", "hue": 0, "saturation": 100, "color_temp": 2700,
                     "brightness": 14, "transition_period": 5000],
         "eact": -1, "repeat": 1],
        ["id": "194F7D100FCA64DC0D4C82C50E4E0EA3", "name": "Schedule Rule", "enable": 1, "wday": [1, 1, 1, 1, 1, 1, 1],
         "stime_opt": 0, "smin": 1405, "sact": 2,
         "s_light": ["on_off": 0, "mode": "last_status", "hue": 0, "saturation": 0, "color_temp": 0,
                     "brightness": 0, "transition_period": 0],
         "eact": -1, "repeat": 1],
        ["id": "0892C11A0311FDE9029A0455071BDAAC", "name": "name", "enable": 0, "wday": [0, 1, 1, 1, 1, 1, 0],
         "stime_opt": 0, "smin": 1425, "sact": 2,
         "s_light": ["on_off": 0, "mode": "last_status", "hue": 0, "saturation": 0, "color_temp": 0,
                     "brightness": 0, "transition_period": 0],
         "eact": -1, "repeat": 1],
    ]

    @Test func parsesRealRuleList() throws {
        let rules = ruleList.compactMap(ScheduleRule.init(dict:))
        #expect(rules.count == 4)

        let sunset = rules[0]
        #expect(sunset.trigger == .sunset(offset: -45))
        #expect(sunset.isEnabled)
        #expect(sunset.days == ScheduleRule.everyDay)
        #expect(sunset.action == .on(LightState(isOn: true, brightness: 50, colorTemp: 2700, hue: 0, saturation: 0)))
        #expect(sunset.transitionMillis == 5000)

        let on = rules[1]
        #expect(on.trigger == .time(minutes: 22 * 60))
        #expect(on.action.turnsOn)
        #expect(on.action.light?.brightness == 14)

        let off = rules[2]
        #expect(off.trigger == .time(minutes: 23 * 60 + 25))
        #expect(off.action == .off)
        #expect(off.name == ScheduleRule.defaultName)

        let disabled = rules[3]
        #expect(!disabled.isEnabled)
        #expect(disabled.daysSummary == "Weekdays")
    }

    @Test func plugStyleActionsStillParse() throws {
        var dict = ruleList[1]
        dict["sact"] = 0
        #expect(ScheduleRule(dict: dict)?.action == .off)
        dict["sact"] = 1
        #expect(ScheduleRule(dict: dict)?.action.turnsOn == true)
        dict["id"] = nil
        #expect(ScheduleRule(dict: dict) == nil)
    }

    @Test func encodesTimeRuleForAddRule() throws {
        let rule = ScheduleRule(days: [true, false, true, false, true, false, false],
                                trigger: .time(minutes: 7 * 60 + 30),
                                action: .on(LightState(isOn: true, brightness: 80, colorTemp: 4000, hue: 0, saturation: 0)))
        let p = rule.parameters
        #expect(p["id"] == nil)
        #expect(p["name"] as? String == ScheduleRule.defaultName)
        #expect(p["enable"] as? Int == 1)
        #expect(p["wday"] as? [Int] == [1, 0, 1, 0, 1, 0, 0])
        #expect(p["stime_opt"] as? Int == 0)
        #expect(p["smin"] as? Int == 450)
        #expect(p["soffset"] == nil)
        #expect(p["sact"] as? Int == 2)
        #expect(p["repeat"] as? Int == 1)
        #expect(p["eact"] as? Int == -1)
        let light = try #require(p["s_light"] as? [String: Any])
        #expect(light["on_off"] as? Int == 1)
        #expect(light["mode"] as? String == "customize_preset")
        #expect(light["brightness"] as? Int == 80)
        #expect(light["color_temp"] as? Int == 4000)
        #expect(light["transition_period"] as? Int == 5000)
        #expect(JSONSerialization.isValidJSONObject(p))
    }

    @Test func encodesOffAndSunsetRulesForEditRule() throws {
        let rule = ScheduleRule(id: "ABC", name: "Bedtime", isEnabled: false,
                                trigger: .sunset(offset: -30), action: .off)
        let p = rule.parameters
        #expect(p["id"] as? String == "ABC")
        #expect(p["name"] as? String == "Bedtime")
        #expect(p["enable"] as? Int == 0)
        #expect(p["stime_opt"] as? Int == 2)
        #expect(p["soffset"] as? Int == -30)
        let light = try #require(p["s_light"] as? [String: Any])
        #expect(light["on_off"] as? Int == 0)
        #expect(light["mode"] as? String == "last_status")
        #expect(light["transition_period"] as? Int == 0)
    }

    @Test func rulesSurviveARoundTripThroughTheWireFormat() throws {
        for dict in ruleList {
            let rule = try #require(ScheduleRule(dict: dict))
            let again = try #require(ScheduleRule(dict: rule.parameters))
            #expect(again == rule)
        }
    }

    @Test func rulesRoundTripThroughJSON() throws {
        let rules = ruleList.compactMap(ScheduleRule.init(dict:))
        let data = try JSONEncoder().encode(rules)
        #expect(try JSONDecoder().decode([ScheduleRule].self, from: data) == rules)
    }

    @Test func daySummaries() {
        var calendar = Calendar(identifier: .gregorian)
        calendar.locale = Locale(identifier: "en_US")
        #expect(ScheduleRule.summary(of: ScheduleRule.everyDay, calendar: calendar) == "Every day")
        #expect(ScheduleRule.summary(of: [false, true, true, true, true, true, false], calendar: calendar) == "Weekdays")
        #expect(ScheduleRule.summary(of: [true, false, false, false, false, false, true], calendar: calendar) == "Weekends")
        #expect(ScheduleRule.summary(of: [false, true, false, true, false, true, false], calendar: calendar) == "Mon, Wed, Fri")
        #expect(ScheduleRule.summary(of: Array(repeating: false, count: 7), calendar: calendar) == "Never")
    }

    @Test func triggerLabelsAndOrdering() {
        #expect(ScheduleTrigger.sunLabel("sunset", offset: 0) == "Sunset")
        #expect(ScheduleTrigger.sunLabel("sunset", offset: -45) == "45 min before sunset")
        #expect(ScheduleTrigger.sunLabel("sunrise", offset: 20) == "20 min after sunrise")
        let label = ScheduleTrigger.timeLabel(minutes: 22 * 60 + 5)
        #expect(label.contains("05"))
        let rules = [ScheduleRule(id: "b", trigger: .time(minutes: 1320), action: .off),
                     ScheduleRule(id: "a", trigger: .sunset(offset: -45), action: .off),
                     ScheduleRule(id: "c", trigger: .time(minutes: 420), action: .off)]
        let schedule = BulbSchedule(rules: rules, isEnabled: true, next: nil, clock: nil, fetchedAt: .now)
        #expect(schedule.sortedRules.map(\.id) == ["c", "a", "b"])
    }

    @Test func parsesNextActionAndClock() throws {
        let next = try #require(NextScheduledAction(dict: [
            "type": 1, "id": "136318D72EEBC7E52AE65E3A2C623123", "schd_time": 79200, "action": 2,
            "light": ["on_off": 1, "mode": "normal", "hue": 0, "saturation": 100, "brightness": 14, "color_temp": 2700],
            "err_code": 0]))
        #expect(next.ruleID == "136318D72EEBC7E52AE65E3A2C623123")
        #expect(next.secondsAfterMidnight == 79200)
        #expect(next.turnsOn == true)
        #expect(NextScheduledAction(dict: ["type": -1, "err_code": 0]) == nil)

        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "America/New_York")!
        let clock = try #require(BulbClock(dict: ["year": 2026, "month": 10, "mday": 22, "hour": 18, "min": 36, "sec": 5, "err_code": 0]))
        let bulbDate = try #require(clock.date(in: calendar))
        let reference = try #require(calendar.date(from: DateComponents(year: 2026, month: 10, day: 22, hour: 18, minute: 33, second: 5)))
        #expect(clock.drift(from: reference, calendar: calendar) == 180)

        let params = BulbClock.parameters(for: bulbDate, calendar: calendar)
        #expect(params["year"] as? Int == 2026)
        #expect(params["mday"] as? Int == 22)
        #expect(params["hour"] as? Int == 18)
        #expect(params["min"] as? Int == 36)
        #expect(params["sec"] as? Int == 5)
    }

    @Test func sectionExtractionChecksErrors() throws {
        let reply: [String: Any] = [
            "smartlife.iot.common.schedule": ["get_rules": ["rule_list": [], "err_code": 0],
                                              "add_rule": ["err_code": -3, "err_msg": "invalid argument"]],
        ]
        _ = try BulbCommands.section(reply, BulbCommands.scheduleService, "get_rules")
        #expect(throws: BulbError.self) {
            _ = try BulbCommands.section(reply, BulbCommands.scheduleService, "add_rule")
        }
        #expect(throws: BulbError.self) {
            _ = try BulbCommands.section(reply, BulbCommands.timeService, "get_time")
        }
    }

    @Test func newRuleTemplateUsesNextHourAndLastLight() throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        let now = try #require(calendar.date(from: DateComponents(year: 2026, month: 10, day: 22, hour: 23, minute: 10)))
        let rule = ScheduleView.template(for: nil, now: now, calendar: calendar)
        #expect(rule.isNew)
        #expect(rule.trigger == .time(minutes: 0))
        #expect(rule.action.turnsOn)
        #expect(rule.days == ScheduleRule.everyDay)
    }
}
