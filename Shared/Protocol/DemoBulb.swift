import Foundation

/// A bulb that lives inside the app, for trying Jib without any hardware (App Review has none).
/// It answers the same requests a real bulb does and keeps its state in the App Group container,
/// so the app, the Control Center control and the watch (through the phone's relay) all see one
/// bulb. `BulbClient` hands requests for `host` here instead of opening a connection; nothing about
/// it ever touches the network. Its behaviour follows `Tools/mockbulb.rb`.
enum DemoBulb {
    /// The address saved for the demo bulb. Not a hostname: `BulbClient` answers it in-process.
    static let host = "demo"
    static let defaultName = "Demo Bulb"
    static let storageKey = "demo.v1"

    static func isHost(_ host: String) -> Bool {
        host.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() == Self.host
    }

    private static let lock = NSLock()

    /// Answers one request, reading the bulb's state from `store` and writing the result back.
    static func reply(to command: [String: Any], in store: UserDefaults = BulbStorage.defaults,
                      now: Date = .now) -> [String: Any] {
        lock.withLock {
            var state = load(from: store)
            let reply = state.reply(to: command, now: now)
            save(state, to: store)
            return reply
        }
    }

    static func load(from store: UserDefaults = BulbStorage.defaults) -> DemoBulbState {
        store.data(forKey: storageKey).flatMap { try? JSONDecoder().decode(DemoBulbState.self, from: $0) } ?? DemoBulbState()
    }

    static func save(_ state: DemoBulbState, to store: UserDefaults = BulbStorage.defaults) {
        store.set(try? JSONEncoder().encode(state), forKey: storageKey)
    }

    /// Forgets the bulb's state, so the next demo bulb added starts fresh.
    static func reset(in store: UserDefaults = BulbStorage.defaults) {
        store.removeObject(forKey: storageKey)
    }
}

extension Bulb {
    /// Whether this is the in-app demo bulb rather than hardware.
    var isDemo: Bool { DemoBulb.isHost(host) }

    static func demo() -> Bulb { Bulb(name: DemoBulb.defaultName, host: DemoBulb.host) }
}

/// The demo bulb's memory: its light, its schedule rules and its clock. `reply` is the firmware.
struct DemoBulbState: Codable, Hashable, Sendable {
    var light = LightState(isOn: false, brightness: 50, colorTemp: 2700, hue: 0, saturation: 0)
    var rules: [ScheduleRule] = []
    var rulesEnabled = true
    /// Seconds the bulb's clock runs ahead of the device's. `set_time` moves it.
    var clockOffset: TimeInterval = 0
    /// The bulb's clock at the last request. Rules that came due since then fire on the next one.
    var lastRuleCheck: Date?

    static let model = "Demo"
    /// The default range `BulbInfo.colorTempRange` gives a model it doesn't know.
    static let colorTempRange = 2500...6500
    static let presets: [[String: Any]] = [
        ["index": 0, "hue": 0, "saturation": 0, "color_temp": 2700, "brightness": 50],
        ["index": 1, "hue": 0, "saturation": 100, "color_temp": 2700, "brightness": 14],
        ["index": 2, "hue": 120, "saturation": 100, "color_temp": 0, "brightness": 100],
        ["index": 3, "hue": 240, "saturation": 100, "color_temp": 0, "brightness": 100],
    ]

    private static let moduleNotSupported: [String: Any] = ["err_code": -1, "err_msg": "module not support"]
    private static let memberNotSupported: [String: Any] = ["err_code": -2, "err_msg": "member not support"]
    private static let invalidArgument: [String: Any] = ["err_code": -3, "err_msg": "invalid argument"]
    private static let ok: [String: Any] = ["err_code": 0]

    func clock(now: Date) -> Date { now.addingTimeInterval(clockOffset) }

    /// Answers a request frame: one entry per service, each holding one reply per command, the way
    /// the bulbs do. Unknown services and commands get the firmware's own error codes.
    mutating func reply(to command: [String: Any], now: Date = .now, calendar: Calendar = .current) -> [String: Any] {
        fireDueRules(now: now, calendar: calendar)
        var reply: [String: Any] = [:]
        for (service, requests) in command {
            let requests = requests as? [String: Any] ?? [:]
            switch service {
            case "system":
                reply[service] = answer(requests) { state, name, _ in
                    name == "get_sysinfo" ? state.sysInfo : Self.memberNotSupported
                }
            case BulbCommands.lightingService:
                reply[service] = answer(requests) { state, name, params in
                    name == "transition_light_state" ? state.transition(params) : Self.memberNotSupported
                }
            case BulbCommands.scheduleService:
                reply[service] = answer(requests) { state, name, params in
                    state.schedule(name, params, now: now, calendar: calendar)
                }
            case BulbCommands.timeService:
                reply[service] = answer(requests) { state, name, params in
                    state.time(name, params, now: now, calendar: calendar)
                }
            default:
                reply[service] = Self.moduleNotSupported
            }
        }
        return reply
    }

    private mutating func answer(_ requests: [String: Any],
                                 _ handle: (inout Self, String, [String: Any]) -> [String: Any]) -> [String: Any] {
        var out: [String: Any] = [:]
        for name in requests.keys.sorted() {
            out[name] = handle(&self, name, requests[name] as? [String: Any] ?? [:])
        }
        return out
    }

    // MARK: system

    var sysInfo: [String: Any] {
        ["alias": DemoBulb.defaultName, "model": Self.model, "description": "A bulb that runs inside Jib",
         "is_dimmable": 1, "is_color": 1, "is_variable_color_temp": 1,
         "light_state": lightState, "preferred_state": Self.presets, "err_code": 0]
    }

    /// `light_state` as the bulb reports it: the remembered colour moves under `dft_on_state` when off.
    var lightState: [String: Any] {
        let color: [String: Any] = ["mode": "normal", "hue": light.hue, "saturation": light.saturation,
                                    "color_temp": light.colorTemp, "brightness": light.brightness]
        return light.isOn ? color.merging(["on_off": 1]) { $1 } : ["on_off": 0, "dft_on_state": color]
    }

    // MARK: lighting service

    private mutating func transition(_ params: [String: Any]) -> [String: Any] {
        var next = light
        if let on = params["on_off"] as? Int { next.isOn = on == 1 }
        if let value = params["brightness"] as? Int { next.brightness = value }
        if let value = params["color_temp"] as? Int { next.colorTemp = value }
        if let value = params["hue"] as? Int { next.hue = value }
        if let value = params["saturation"] as? Int { next.saturation = value }
        guard (1...100).contains(next.brightness), (0...360).contains(next.hue), (0...100).contains(next.saturation),
              next.colorTemp == 0 || Self.colorTempRange.contains(next.colorTemp) else { return Self.invalidArgument }
        light = next
        return lightState.merging(Self.ok) { $1 }
    }

    // MARK: schedule service

    private mutating func schedule(_ name: String, _ params: [String: Any], now: Date, calendar: Calendar) -> [String: Any] {
        switch name {
        case "get_rules":
            return ["rule_list": rules.map(\.parameters), "version": 2, "enable": rulesEnabled ? 1 : 0, "err_code": 0]
        case "add_rule":
            guard let rule = Self.rule(from: params, id: Self.newRuleID()) else { return Self.invalidArgument }
            rules.append(rule)
            return ["id": rule.id, "err_code": 0]
        case "edit_rule":
            guard let id = params["id"] as? String, let rule = Self.rule(from: params, id: id) else { return Self.invalidArgument }
            guard let index = rules.firstIndex(where: { $0.id == id }) else { return ["err_code": -14, "err_msg": "rule not found"] }
            rules[index] = rule
            return Self.ok
        case "delete_rule":
            guard let id = params["id"] as? String else { return Self.invalidArgument }
            rules.removeAll { $0.id == id }
            return Self.ok
        case "set_overall_enable":
            guard let enable = params["enable"] as? Int else { return Self.invalidArgument }
            rulesEnabled = enable == 1
            return Self.ok
        case "get_next_action":
            return nextAction(now: now, calendar: calendar)
        default:
            return Self.memberNotSupported
        }
    }

    /// Parses a rule as `add_rule` and `edit_rule` send it. Like the firmware, refuses one with no
    /// name or no days, so the apps' failure path can be exercised.
    private static func rule(from params: [String: Any], id: String) -> ScheduleRule? {
        var dict = params
        dict["id"] = id
        guard let rule = ScheduleRule(dict: dict), !rule.name.isEmpty,
              (params["wday"] as? [Int])?.contains(1) == true else { return nil }
        return rule
    }

    private static func newRuleID() -> String {
        UUID().uuidString.replacingOccurrences(of: "-", with: "")
    }

    /// The next enabled fixed-time rule, looking from the current minute through the coming week.
    private func nextAction(now: Date, calendar: Calendar) -> [String: Any] {
        let clock = clock(now: now)
        let today = ScheduleTrigger.minutes(from: clock, calendar: calendar)
        let weekday = calendar.component(.weekday, from: clock) - 1
        for ahead in 0...7 {
            let day = (weekday + ahead) % 7
            let due = rules.filter { rule in
                guard rule.isEnabled, rule.days[day], case .time(let minutes) = rule.trigger else { return false }
                return ahead > 0 || minutes > today
            }
            if let rule = due.min(by: { $0.trigger.sortKey < $1.trigger.sortKey }) {
                return ["type": 1, "id": rule.id, "schd_time": rule.trigger.sortKey * 60, "action": 2,
                        "light": rule.parameters["s_light"] ?? [:], "err_code": 0]
            }
        }
        return ["type": -1, "err_code": 0]
    }

    /// Fires fixed-time rules whose minute passed since the last request, as the bulb's own clock
    /// would have, so a rule set a minute ahead has visibly switched the bulb when the app next asks.
    /// Catches up at most a day; a clock set backwards just starts counting again.
    private mutating func fireDueRules(now: Date, calendar: Calendar) {
        let clock = clock(now: now)
        defer { lastRuleCheck = clock }
        guard rulesEnabled, let since = lastRuleCheck, clock > since else { return }
        var boundary = calendar.dateInterval(of: .minute, for: max(since, clock.addingTimeInterval(-86400)))?.end ?? clock
        while boundary <= clock {
            let minutes = ScheduleTrigger.minutes(from: boundary, calendar: calendar)
            let day = calendar.component(.weekday, from: boundary) - 1
            for rule in rules where rule.isEnabled && rule.days[day] && rule.trigger == .time(minutes: minutes) {
                switch rule.action {
                case .off: light.isOn = false
                case .on(let state): light = state
                }
            }
            boundary.addTimeInterval(60)
        }
    }

    // MARK: time service

    private mutating func time(_ name: String, _ params: [String: Any], now: Date, calendar: Calendar) -> [String: Any] {
        switch name {
        case "get_time":
            let c = calendar.dateComponents([.year, .month, .day, .hour, .minute, .second], from: clock(now: now))
            return ["year": c.year ?? 0, "month": c.month ?? 0, "mday": c.day ?? 0,
                    "hour": c.hour ?? 0, "min": c.minute ?? 0, "sec": c.second ?? 0, "err_code": 0]
        case "get_timezone":
            return ["index": 0, "err_code": 0]
        case "set_time", "set_timezone":
            if params["year"] != nil {
                let components = DateComponents(year: params["year"] as? Int, month: params["month"] as? Int,
                                                day: params["mday"] as? Int, hour: params["hour"] as? Int,
                                                minute: params["min"] as? Int, second: params["sec"] as? Int)
                guard let date = calendar.date(from: components) else { return Self.invalidArgument }
                clockOffset = date.timeIntervalSince(now).rounded()
            }
            return Self.ok
        default:
            return Self.memberNotSupported
        }
    }
}
