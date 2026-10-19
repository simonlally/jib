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
