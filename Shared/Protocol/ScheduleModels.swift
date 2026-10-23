import Foundation

/// When a schedule rule fires. Times are minutes after midnight on the bulb's own clock.
enum ScheduleTrigger: Codable, Hashable, Sendable {
    case time(minutes: Int)
    /// Minutes relative to the event; negative is before. The bulb works sunrise and sunset out
    /// from the location its original app stored on it.
    case sunrise(offset: Int)
    case sunset(offset: Int)

    /// "10:00 PM", "Sunset", "45 min before sunset".
    var label: String {
        switch self {
        case .time(let minutes): return Self.timeLabel(minutes: minutes)
        case .sunrise(let offset): return Self.sunLabel("sunrise", offset: offset)
        case .sunset(let offset): return Self.sunLabel("sunset", offset: offset)
        }
    }

    /// Minute of the day used to order rules in a list; sunrise and sunset get nominal times.
    var sortKey: Int {
        switch self {
        case .time(let minutes): return minutes
        case .sunrise(let offset): return 6 * 60 + offset
        case .sunset(let offset): return 18 * 60 + offset
        }
    }

    static func timeLabel(minutes: Int, calendar: Calendar = .current) -> String {
        let date = calendar.date(bySettingHour: minutes / 60, minute: minutes % 60, second: 0, of: .now) ?? .now
        return date.formatted(date: .omitted, time: .shortened)
    }

    static func sunLabel(_ event: String, offset: Int) -> String {
        if offset == 0 { return event.capitalized }
        return "\(abs(offset)) min \(offset < 0 ? "before" : "after") \(event)"
    }
}

/// What a rule does when it fires. `isOn` of the attached state is always true.
enum ScheduleAction: Codable, Hashable, Sendable {
    case off
    case on(LightState)

    var turnsOn: Bool {
        if case .on = self { return true } else { return false }
    }

    var light: LightState? {
        if case .on(let state) = self { return state } else { return nil }
    }

    /// "Off", "On · 50% · 2700 K", "On · 100% · Color".
    var label: String {
        switch self {
        case .off: return "Off"
        case .on(let state): return state.isWhite ? "On · \(state.brightness)% · \(state.colorTemp) K"
                                                  : "On · \(state.brightness)% · Color"
        }
    }
}

/// One entry in the bulb's own schedule. Rules are stored on the bulb and fire from its clock, so
/// they keep running when no phone is around.
struct ScheduleRule: Identifiable, Codable, Hashable, Sendable {
    /// Assigned by the bulb when the rule is added; empty until then.
    var id: String
    var name: String
    var isEnabled: Bool
    /// Seven flags, Sunday first.
    var days: [Bool]
    var trigger: ScheduleTrigger
    var action: ScheduleAction
    /// Fade length in milliseconds for an "on" rule.
    var transitionMillis: Int

    static let defaultName = "Schedule Rule"
    static let everyDay = Array(repeating: true, count: 7)

    init(id: String = "", name: String = "", isEnabled: Bool = true, days: [Bool] = ScheduleRule.everyDay,
         trigger: ScheduleTrigger, action: ScheduleAction, transitionMillis: Int = 5000) {
        self.id = id
        self.name = name
        self.isEnabled = isEnabled
        self.days = days.count == 7 ? days : ScheduleRule.everyDay
        self.trigger = trigger
        self.action = Self.normalized(action)
        self.transitionMillis = transitionMillis
    }

    var isNew: Bool { id.isEmpty }

    /// Parses one entry of `get_rules`' `rule_list`.
    init?(dict: [String: Any]) {
        guard let id = dict["id"] as? String else { return nil }
        self.id = id
        name = dict["name"] as? String ?? ""
        isEnabled = (dict["enable"] as? Int ?? 0) == 1
        let wday = (dict["wday"] as? [Int] ?? []).map { $0 == 1 }
        days = wday.count == 7 ? wday : ScheduleRule.everyDay
        let offset = dict["soffset"] as? Int ?? 0
        switch dict["stime_opt"] as? Int ?? 0 {
        case 1: trigger = .sunrise(offset: offset)
        case 2: trigger = .sunset(offset: offset)
        default: trigger = .time(minutes: dict["smin"] as? Int ?? 0)
        }
        let light = dict["s_light"] as? [String: Any] ?? [:]
        transitionMillis = light["transition_period"] as? Int ?? 0
        // Bulbs use action 2, "apply this light state", with the real on/off inside the state.
        // Plugs use 0 and 1 for off and on.
        let turnsOn: Bool
        switch dict["sact"] as? Int ?? 2 {
        case 0: turnsOn = false
        case 1: turnsOn = true
        default: turnsOn = (light["on_off"] as? Int ?? 0) == 1
        }
        action = turnsOn ? .on(LightState(isOn: true,
                                          brightness: light["brightness"] as? Int ?? 100,
                                          colorTemp: light["color_temp"] as? Int ?? 0,
                                          hue: light["hue"] as? Int ?? 0,
                                          saturation: light["saturation"] as? Int ?? 0))
                         : .off
    }

    /// The rule as `add_rule` and `edit_rule` want it. The id goes along only for edits.
    var parameters: [String: Any] {
        var params: [String: Any] = [
            "name": name.isEmpty ? ScheduleRule.defaultName : name,
            "enable": isEnabled ? 1 : 0,
            "wday": days.map { $0 ? 1 : 0 },
            "repeat": 1,
            "sact": 2,
            "s_light": lightParameters,
            "eact": -1,
            "etime_opt": -1,
            "emin": 0,
        ]
        switch trigger {
        case .time(let minutes):
            params["stime_opt"] = 0
            params["smin"] = minutes
        case .sunrise(let offset):
            params["stime_opt"] = 1
            params["smin"] = 0
            params["soffset"] = offset
        case .sunset(let offset):
            params["stime_opt"] = 2
            params["smin"] = 0
            params["soffset"] = offset
        }
        if !id.isEmpty { params["id"] = id }
        return params
    }

    private var lightParameters: [String: Any] {
        switch action {
        case .off:
            return ["on_off": 0, "mode": "last_status", "hue": 0, "saturation": 0,
                    "color_temp": 0, "brightness": 0, "transition_period": 0]
        case .on(let state):
            return ["on_off": 1, "mode": "customize_preset", "hue": state.hue, "saturation": state.saturation,
                    "color_temp": state.colorTemp, "brightness": state.brightness,
                    "transition_period": transitionMillis]
        }
    }

    /// "Every day", "Weekdays", "Weekends", "Mon, Wed, Fri" or "Never".
    var daysSummary: String { ScheduleRule.summary(of: days) }

    static func summary(of days: [Bool], calendar: Calendar = .current) -> String {
        let on = days.indices.filter { days[$0] }
        switch on {
        case []: return "Never"
        case [0, 1, 2, 3, 4, 5, 6]: return "Every day"
        case [1, 2, 3, 4, 5]: return "Weekdays"
        case [0, 6]: return "Weekends"
        default: return on.map { calendar.shortWeekdaySymbols[$0] }.joined(separator: ", ")
        }
    }

    private static func normalized(_ action: ScheduleAction) -> ScheduleAction {
        guard case .on(var state) = action else { return action }
        state.isOn = true
        return .on(state)
    }
}

/// What `get_next_action` reports: the rule the bulb will fire next and when.
struct NextScheduledAction: Hashable, Sendable {
    var ruleID: String
    var secondsAfterMidnight: Int
    var turnsOn: Bool?

    init?(dict: [String: Any]) {
        guard dict["type"] as? Int == 1, let id = dict["id"] as? String,
              let seconds = dict["schd_time"] as? Int else { return nil }
        ruleID = id
        secondsAfterMidnight = seconds
        if let light = dict["light"] as? [String: Any], let on = light["on_off"] as? Int {
            turnsOn = on == 1
        } else if let action = dict["action"] as? Int, action == 0 || action == 1 {
            turnsOn = action == 1
        } else {
            turnsOn = nil
        }
    }

    var timeLabel: String { ScheduleTrigger.timeLabel(minutes: (secondsAfterMidnight / 60) % (24 * 60)) }
}

/// The bulb's own clock, as `get_time` reports it. The bulb keeps local time; the time zone is an
/// index into the maker's own table, which the bulb's original app set once.
struct BulbClock: Hashable, Sendable {
    var year: Int
    var month: Int
    var day: Int
    var hour: Int
    var minute: Int
    var second: Int
    var timezoneIndex: Int?

    init?(dict: [String: Any]) {
        guard let year = dict["year"] as? Int, let month = dict["month"] as? Int, let day = dict["mday"] as? Int,
              let hour = dict["hour"] as? Int, let minute = dict["min"] as? Int, let second = dict["sec"] as? Int
        else { return nil }
        self.year = year
        self.month = month
        self.day = day
        self.hour = hour
        self.minute = minute
        self.second = second
    }

    /// The bulb's clock read as a moment in the phone's time zone.
    func date(in calendar: Calendar = .current) -> Date? {
        calendar.date(from: DateComponents(year: year, month: month, day: day, hour: hour, minute: minute, second: second))
    }

    /// Seconds the bulb's clock is ahead of `reference` (negative when behind).
    func drift(from reference: Date, calendar: Calendar = .current) -> TimeInterval? {
        date(in: calendar).map { $0.timeIntervalSince(reference) }
    }

    /// `set_time` parameters for a moment, in the phone's time zone.
    static func parameters(for date: Date, calendar: Calendar = .current) -> [String: Any] {
        let c = calendar.dateComponents([.year, .month, .day, .hour, .minute, .second], from: date)
        return ["year": c.year ?? 0, "month": c.month ?? 0, "mday": c.day ?? 0,
                "hour": c.hour ?? 0, "min": c.minute ?? 0, "sec": c.second ?? 0]
    }
}

/// Everything the schedule screen shows, read from the bulb in one round trip.
struct BulbSchedule: Hashable, Sendable {
    var rules: [ScheduleRule]
    /// The bulb's master switch for all rules.
    var isEnabled: Bool
    var next: NextScheduledAction?
    var clock: BulbClock?
    var fetchedAt: Date

    var sortedRules: [ScheduleRule] {
        rules.sorted { ($0.trigger.sortKey, $0.id) < ($1.trigger.sortKey, $1.id) }
    }
}
