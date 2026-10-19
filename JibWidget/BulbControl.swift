import AppIntents
import SwiftUI
import WidgetKit

/// Control Center / Lock Screen toggle for one saved bulb. It runs in the widget extension and
/// talks to the bulb directly over Wi‑Fi, so the app doesn't need to be open.
struct BulbControl: ControlWidget {
    var body: some ControlWidgetConfiguration {
        AppIntentControlConfiguration(kind: BulbStorage.controlKind, provider: BulbControlProvider()) { value in
            ControlWidgetToggle(isOn: value.isOn, action: SetBulbPowerIntent(bulb: value.bulb)) {
                Label(value.bulb.name, systemImage: "lightbulb")
            } valueLabel: { isOn in
                Label(isOn ? "On" : "Off", systemImage: isOn ? "lightbulb.fill" : "lightbulb")
            }
            .tint(.yellow)
        }
        .displayName("Bulb")
        .description("Turn a bulb on or off.")
        .promptsForUserConfiguration()
    }
}

struct BulbControlValue {
    var bulb: BulbEntity
    var isOn: Bool
}

/// Supplies the bulb and its power state each time Control Center draws the control.
struct BulbControlProvider: AppIntentControlValueProvider {
    func previewValue(configuration: BulbControlConfiguration) -> BulbControlValue {
        BulbControlValue(bulb: configuration.bulb ?? Self.fallbackBulb, isOn: true)
    }

    func currentValue(configuration: BulbControlConfiguration) async throws -> BulbControlValue {
        let bulb = configuration.bulb ?? Self.fallbackBulb
        guard !bulb.host.isEmpty else { return BulbControlValue(bulb: bulb, isOn: false) }
        // Ask the bulb itself, briefly; otherwise show the last state the app or control saw.
        if let info = try? await BulbCommands.sysInfo(host: bulb.host, timeout: 3, connectTimeout: 1.5) {
            BulbStorage.setState(info.state, for: bulb.id)
            return BulbControlValue(bulb: bulb, isOn: info.state.isOn)
        }
        return BulbControlValue(bulb: bulb, isOn: BulbStorage.state(for: bulb.id)?.isOn ?? false)
    }

    /// The first saved bulb, or a stand-in when nothing has been added yet.
    private static var fallbackBulb: BulbEntity {
        BulbEntity(BulbStorage.loadBulbs().first ?? Bulb(name: "Bulb", host: ""))
    }
}
