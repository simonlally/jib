import Foundation

/// What the bulb is currently emitting. `colorTemp == 0` means the bulb is in hue/saturation mode.
struct LightState: Codable, Hashable, Sendable {
    var isOn: Bool
    var brightness: Int      // 1...100
    var colorTemp: Int       // Kelvin; 0 when showing a color
    var hue: Int             // 0...360
    var saturation: Int      // 0...100

    var isWhite: Bool { colorTemp > 0 }

    /// Parses a `light_state` (or `transition_light_state` reply) dictionary.
    /// When the bulb is off, the bulb nests the remembered color in `dft_on_state`.
    init(lightState dict: [String: Any]) {
        let on = (dict["on_off"] as? Int ?? 0) == 1
        let source = on ? dict : (dict["dft_on_state"] as? [String: Any] ?? dict)
        isOn = on
        brightness = source["brightness"] as? Int ?? 100
        colorTemp = source["color_temp"] as? Int ?? 0
        hue = source["hue"] as? Int ?? 0
        saturation = source["saturation"] as? Int ?? 0
    }

    init(isOn: Bool, brightness: Int, colorTemp: Int, hue: Int, saturation: Int) {
        self.isOn = isOn
        self.brightness = brightness
        self.colorTemp = colorTemp
        self.hue = hue
        self.saturation = saturation
    }
}

/// One of the four "preferred states" stored on the bulb (the four presets the bulb remembers).
struct LightPreset: Codable, Hashable, Sendable, Identifiable {
    var index: Int
    var brightness: Int
    var colorTemp: Int
    var hue: Int
    var saturation: Int

    var id: Int { index }

    init?(dict: [String: Any]) {
        guard let index = dict["index"] as? Int else { return nil }
        self.index = index
        brightness = dict["brightness"] as? Int ?? 100
        colorTemp = dict["color_temp"] as? Int ?? 0
        hue = dict["hue"] as? Int ?? 0
        saturation = dict["saturation"] as? Int ?? 0
    }
}

/// Everything useful from `get_sysinfo`.
struct BulbInfo: Codable, Hashable, Sendable {
    var alias: String
    var model: String
    var description: String?
    var softwareVersion: String?
    var hardwareVersion: String?
    var rssi: Int?
    var isDimmable: Bool
    var isColor: Bool
    var isVariableColorTemp: Bool
    var presets: [LightPreset]
    var state: LightState

    init(sysInfo si: [String: Any]) throws {
        guard let lightState = si["light_state"] as? [String: Any] else {
            throw BulbError.badResponse("no light_state – is this a bulb?")
        }
        alias = si["alias"] as? String ?? ""
        model = si["model"] as? String ?? "Unknown"
        description = si["description"] as? String
        softwareVersion = si["sw_ver"] as? String
        hardwareVersion = si["hw_ver"] as? String
        rssi = si["rssi"] as? Int
        isDimmable = (si["is_dimmable"] as? Int ?? 0) == 1
        isColor = (si["is_color"] as? Int ?? 0) == 1
        isVariableColorTemp = (si["is_variable_color_temp"] as? Int ?? 0) == 1
        presets = (si["preferred_state"] as? [[String: Any]] ?? []).compactMap(LightPreset.init(dict:))
        state = LightState(lightState: lightState)
    }

    /// Supported white range. The bulb doesn't report it, so this is a per-model table.
    var colorTempRange: ClosedRange<Int> {
        let m = model.uppercased()
        if m.hasPrefix("KL120") { return 2700...5000 }
        if m.hasPrefix("LB120") { return 2700...6500 }
        if m.hasPrefix("KL125") { return 2500...6500 }
        if m.hasPrefix("KL130") || m.hasPrefix("KL135") || m.hasPrefix("LB130")
            || m.hasPrefix("LB230") || m.hasPrefix("KL430") { return 2500...9000 }
        return 2500...6500
    }
}

/// A command the apps can run against a bulb. Shared by the phone UI, the watch UI and the relay.
enum BulbAction: Codable, Hashable, Sendable {
    case status
    case power(Bool)
    case brightness(Int)
    case colorTemp(Int)
    case color(hue: Int, saturation: Int)
    case preset(LightPreset)

    /// Parameters for `transition_light_state`. Any adjustment also turns the bulb on.
    var transitionParameters: [String: Any] {
        switch self {
        case .status:
            return [:]
        case .power(let on):
            return ["on_off": on ? 1 : 0]
        case .brightness(let value):
            return ["on_off": 1, "brightness": value.clamped(to: 1...100)]
        case .colorTemp(let kelvin):
            return ["on_off": 1, "color_temp": kelvin]
        case .color(let hue, let saturation):
            return ["on_off": 1, "hue": hue.clamped(to: 0...360),
                    "saturation": saturation.clamped(to: 0...100), "color_temp": 0]
        case .preset(let p):
            return ["on_off": 1, "brightness": p.brightness, "color_temp": p.colorTemp,
                    "hue": p.hue, "saturation": p.saturation]
        }
    }
}

/// What an action produced: a full refresh, or just the new light state (which set commands echo back).
enum ActionResult: Codable, Hashable, Sendable {
    case info(BulbInfo)
    case state(LightState)
}

extension Comparable {
    func clamped(to range: ClosedRange<Self>) -> Self {
        min(max(self, range.lowerBound), range.upperBound)
    }
}
