import AppIntents
import Foundation
import WidgetKit

/// Which bulb a control toggles. Chosen when the control is added to Control Center or the Lock Screen.
struct BulbControlConfiguration: ControlConfigurationIntent {
    static let title: LocalizedStringResource = "Choose Bulb"
    static let description = IntentDescription("Pick which bulb this control toggles.")

    @Parameter(title: "Bulb")
    var bulb: BulbEntity?
}

/// Turns a bulb on or off. Run by the control's toggle, and available in Shortcuts as "Set Bulb Power".
struct SetBulbPowerIntent: SetValueIntent {
    static let title: LocalizedStringResource = "Set Bulb Power"
    static let description = IntentDescription("Turns a bulb on or off over Wi‑Fi.")

    @Parameter(title: "Bulb")
    var bulb: BulbEntity

    @Parameter(title: "On")
    var value: Bool

    init() {}

    init(bulb: BulbEntity) {
        self.bulb = bulb
    }

    func perform() async throws -> some IntentResult {
        guard !bulb.host.isEmpty else { throw BulbIntentError.noBulb }
        let result = try await BulbCommands.perform(.power(value), host: bulb.host)
        if case .state(let state) = result {
            BulbStorage.setState(state, for: bulb.id)
        }
        ControlCenter.shared.reloadControls(ofKind: BulbStorage.controlKind)
        return .result()
    }
}

enum BulbIntentError: LocalizedError {
    case noBulb

    var errorDescription: String? {
        switch self {
        case .noBulb: return "Add a bulb in Jib first."
        }
    }
}
