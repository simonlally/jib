import Foundation
import Testing
@testable import Jib

struct BulbParsingTests {
    /// Trimmed from a real KL125 `get_sysinfo` reply.
    private func sysInfo(on: Bool) -> [String: Any] {
        let lightState: [String: Any] = on
            ? ["on_off": 1, "mode": "normal", "hue": 0, "saturation": 100, "color_temp": 2700, "brightness": 14]
            : ["on_off": 0, "dft_on_state": ["mode": "normal", "hue": 120, "saturation": 100, "color_temp": 0, "brightness": 80]]
        return [
            "sw_ver": "1.0.9 Build 230210 Rel.135933",
            "hw_ver": "2.0",
            "model": "KL125(US)",
            "rssi": -43,
            "alias": "Bedroom Lamp",
            "mic_type": "IOT.SMARTBULB",
            "is_dimmable": 1,
            "is_color": 1,
            "is_variable_color_temp": 1,
            "light_state": lightState,
            "preferred_state": [
                ["index": 0, "hue": 0, "saturation": 0, "color_temp": 2700, "brightness": 50],
                ["index": 1, "hue": 0, "saturation": 100, "color_temp": 2700, "brightness": 14],
                ["index": 2, "hue": 120, "saturation": 100, "color_temp": 0, "brightness": 100],
                ["index": 3, "hue": 240, "saturation": 100, "color_temp": 0, "brightness": 100],
            ],
            "err_code": 0,
        ]
    }

    @Test func parsesBulbThatIsOn() throws {
        let info = try BulbInfo(sysInfo: sysInfo(on: true))
        #expect(info.alias == "Bedroom Lamp")
        #expect(info.model == "KL125(US)")
        #expect(info.rssi == -43)
        #expect(info.isDimmable && info.isColor && info.isVariableColorTemp)
        #expect(info.state == LightState(isOn: true, brightness: 14, colorTemp: 2700, hue: 0, saturation: 100))
        #expect(info.state.isWhite)
        #expect(info.presets.count == 4)
        #expect(info.presets[2].hue == 120)
        #expect(info.colorTempRange == 2500...6500)
    }

    @Test func offBulbReadsRememberedStateFromDefaultOnState() throws {
        let info = try BulbInfo(sysInfo: sysInfo(on: false))
        #expect(!info.state.isOn)
        #expect(info.state.brightness == 80)
        #expect(info.state.hue == 120)
        #expect(!info.state.isWhite)
    }

    @Test func nonBulbIsRejected() {
        #expect(throws: BulbError.self) {
            _ = try BulbInfo(sysInfo: ["alias": "Plug", "relay_state": 1])
        }
    }

    @Test func deviceErrorsSurface() {
        #expect(throws: BulbError.self) {
            try BulbCommands.checkError(["err_code": -3, "err_msg": "invalid argument"])
        }
        #expect(throws: Never.self) {
            try BulbCommands.checkError(["err_code": 0])
        }
    }

    @Test func actionParameters() {
        #expect(BulbAction.power(false).transitionParameters["on_off"] as? Int == 0)
        #expect(BulbAction.brightness(150).transitionParameters["brightness"] as? Int == 100)
        #expect(BulbAction.brightness(0).transitionParameters["brightness"] as? Int == 1)
        let color = BulbAction.color(hue: 400, saturation: 50).transitionParameters
        #expect(color["hue"] as? Int == 360)
        #expect(color["color_temp"] as? Int == 0)
        #expect(color["on_off"] as? Int == 1)
    }

    @Test func actionsRoundTripThroughJSON() throws {
        let actions: [BulbAction] = [.status, .power(true), .brightness(30), .colorTemp(4000), .color(hue: 200, saturation: 70)]
        let data = try JSONEncoder().encode(actions)
        #expect(try JSONDecoder().decode([BulbAction].self, from: data) == actions)
    }

    @Test func onlyWiFiInterfacesAreSwept() {
        #expect(BulbDiscovery.preferredAddress(among: [("pdp_ip0", "10.1.2.3")]) == nil)
        #expect(BulbDiscovery.preferredAddress(among: [("utun3", "10.8.0.2"), ("bridge100", "192.168.64.1")]) == nil)
        #expect(BulbDiscovery.preferredAddress(among: [("utun3", "10.8.0.2"), ("en1", "192.168.5.9"), ("en0", "192.168.1.4")]) == "192.168.1.4")
        #expect(BulbDiscovery.preferredAddress(among: [("pdp_ip0", "10.1.2.3"), ("en1", "192.168.5.9")]) == "192.168.5.9")
        #expect(BulbDiscovery.preferredAddress(among: []) == nil)
    }

    @Test func subnetPrefixValidation() {
        #expect(BulbDiscovery.isValidPrefix("192.168.1"))
        #expect(!BulbDiscovery.isValidPrefix("192.168"))
        #expect(!BulbDiscovery.isValidPrefix("192.168.300"))
        #expect(!BulbDiscovery.isValidPrefix("192.168.1.5"))
    }
}
