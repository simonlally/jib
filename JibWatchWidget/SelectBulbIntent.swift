import AppIntents

/// Which bulb a complication shows. Chosen when the complication is added to a watch face or the Smart Stack.
struct SelectBulbIntent: WidgetConfigurationIntent {
    static let title: LocalizedStringResource = "Choose Bulb"
    static let description = IntentDescription("Pick which bulb this widget shows.")

    @Parameter(title: "Bulb")
    var bulb: BulbEntity?

    init() {}

    init(bulb: BulbEntity) {
        self.bulb = bulb
    }
}
