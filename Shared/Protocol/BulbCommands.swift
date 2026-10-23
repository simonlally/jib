import Foundation

/// Bulb-level commands built on `BulbClient`.
enum BulbCommands {
    static let lightingService = "smartlife.iot.smartbulb.lightingservice"

    static func sysInfo(host: String, timeout: TimeInterval = 6, connectTimeout: TimeInterval? = nil) async throws -> BulbInfo {
        let reply = try await BulbClient.send(["system": ["get_sysinfo": [String: Any]()]], to: host,
                                              timeout: timeout, connectTimeout: connectTimeout)
        guard let system = reply["system"] as? [String: Any],
              let info = system["get_sysinfo"] as? [String: Any] else {
            throw BulbError.badResponse("missing get_sysinfo")
        }
        try checkError(info)
        return try BulbInfo(sysInfo: info)
    }

    /// Sends `transition_light_state`; the bulb echoes back its new state.
    static func transition(_ parameters: [String: Any], host: String) async throws -> LightState {
        var params = parameters
        params["ignore_default"] = 1
        let reply = try await BulbClient.send([lightingService: ["transition_light_state": params]], to: host)
        guard let service = reply[lightingService] as? [String: Any],
              let state = service["transition_light_state"] as? [String: Any] else {
            throw BulbError.badResponse("missing transition_light_state")
        }
        try checkError(state)
        return LightState(lightState: state)
    }

    static func perform(_ action: BulbAction, host: String) async throws -> ActionResult {
        switch action {
        case .status:
            return .info(try await sysInfo(host: host))
        default:
            return .state(try await transition(action.transitionParameters, host: host))
        }
    }

    static func checkError(_ dict: [String: Any]) throws {
        if let code = dict["err_code"] as? Int, code != 0 {
            throw BulbError.device(code: code, message: dict["err_msg"] as? String ?? "unknown error")
        }
    }
}

// MARK: - Schedule and clock

extension BulbCommands {
    static let scheduleService = "smartlife.iot.common.schedule"
    static let timeService = "smartlife.iot.common.timesetting"

    /// Reads the bulb's rules, the action it will fire next and its clock in one round trip.
    static func schedule(host: String) async throws -> BulbSchedule {
        let reply = try await BulbClient.send([
            scheduleService: ["get_rules": [String: Any](), "get_next_action": [String: Any]()],
            timeService: ["get_time": [String: Any](), "get_timezone": [String: Any]()],
        ], to: host)
        let rules = try section(reply, scheduleService, "get_rules")
        let list = rules["rule_list"] as? [[String: Any]] ?? []
        let next = (try? section(reply, scheduleService, "get_next_action")).flatMap(NextScheduledAction.init(dict:))
        var clock = (try? section(reply, timeService, "get_time")).flatMap(BulbClock.init(dict:))
        if let zone = try? section(reply, timeService, "get_timezone") {
            clock?.timezoneIndex = zone["index"] as? Int
        }
        return BulbSchedule(rules: list.compactMap(ScheduleRule.init(dict:)),
                            isEnabled: (rules["enable"] as? Int ?? 1) == 1,
                            next: next, clock: clock, fetchedAt: .now)
    }

    /// Adds a rule and returns the id the bulb gave it.
    static func addRule(_ rule: ScheduleRule, host: String) async throws -> String {
        let reply = try await BulbClient.send([scheduleService: ["add_rule": rule.parameters]], to: host)
        let result = try section(reply, scheduleService, "add_rule")
        guard let id = result["id"] as? String else { throw BulbError.badResponse("add_rule returned no id") }
        return id
    }

    static func editRule(_ rule: ScheduleRule, host: String) async throws {
        let reply = try await BulbClient.send([scheduleService: ["edit_rule": rule.parameters]], to: host)
        _ = try section(reply, scheduleService, "edit_rule")
    }

    static func deleteRule(id: String, host: String) async throws {
        let reply = try await BulbClient.send([scheduleService: ["delete_rule": ["id": id]]], to: host)
        _ = try section(reply, scheduleService, "delete_rule")
    }

    /// The bulb's master switch for all of its rules.
    static func setScheduleEnabled(_ enabled: Bool, host: String) async throws {
        let reply = try await BulbClient.send([scheduleService: ["set_overall_enable": ["enable": enabled ? 1 : 0]]], to: host)
        _ = try section(reply, scheduleService, "set_overall_enable")
    }

    /// Sets the bulb's clock to a moment in the phone's time zone. Leaves the bulb's time zone alone.
    static func setClock(to date: Date = .now, host: String) async throws {
        let reply = try await BulbClient.send([timeService: ["set_time": BulbClock.parameters(for: date)]], to: host)
        _ = try section(reply, timeService, "set_time")
    }

    /// Pulls one command's reply out of a (possibly multi-service) response and checks its error code.
    static func section(_ reply: [String: Any], _ service: String, _ command: String) throws -> [String: Any] {
        guard let module = reply[service] as? [String: Any] else { throw BulbError.badResponse("missing \(service)") }
        guard let result = module[command] as? [String: Any] else {
            try checkError(module)   // a bulb without the service answers with the error at this level
            throw BulbError.badResponse("missing \(command)")
        }
        try checkError(result)
        return result
    }
}
