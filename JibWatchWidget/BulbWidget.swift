import AppIntents
import SwiftUI
import WidgetKit

/// Complication / Smart Stack widget showing one bulb's last-seen state. Tapping it opens the
/// watch app, which flips the bulb through the iPhone: the widget extension itself can't use
/// WatchConnectivity, and watchOS doesn't let apps open raw TCP connections anyway.
struct BulbWidget: Widget {
    var body: some WidgetConfiguration {
        AppIntentConfiguration(kind: BulbStorage.watchWidgetKind, intent: SelectBulbIntent.self,
                               provider: BulbTimelineProvider()) { entry in
            BulbWidgetView(entry: entry)
        }
        .configurationDisplayName("Bulb")
        .description("Shows a bulb. Tap to turn it on or off through your iPhone.")
        .supportedFamilies([.accessoryRectangular, .accessoryCircular, .accessoryCorner, .accessoryInline])
    }
}

struct BulbEntry: TimelineEntry {
    var date: Date
    var bulb: Bulb?
    var state: LightState?
}

struct BulbTimelineProvider: AppIntentTimelineProvider {
    /// One entry per saved bulb in the complication picker.
    func recommendations() -> [AppIntentRecommendation<SelectBulbIntent>] {
        BulbStorage.loadBulbs().map { bulb in
            AppIntentRecommendation(intent: SelectBulbIntent(bulb: BulbEntity(bulb)), description: Text(bulb.name))
        }
    }

    func placeholder(in context: Context) -> BulbEntry {
        BulbEntry(date: .now, bulb: Bulb(name: "Lamp", host: ""),
                  state: LightState(isOn: true, brightness: 80, colorTemp: 2700, hue: 0, saturation: 0))
    }

    func snapshot(for configuration: SelectBulbIntent, in context: Context) async -> BulbEntry {
        context.isPreview ? placeholder(in: context) : entry(for: configuration)
    }

    func timeline(for configuration: SelectBulbIntent, in context: Context) async -> Timeline<BulbEntry> {
        // The watch app reloads this whenever it learns a new state, so no timed refresh is needed.
        Timeline(entries: [entry(for: configuration)], policy: .never)
    }

    private func entry(for configuration: SelectBulbIntent) -> BulbEntry {
        let bulbs = BulbStorage.loadBulbs()
        let bulb: Bulb? = if let chosen = configuration.bulb {
            bulbs.first { $0.id == chosen.id }
        } else {
            bulbs.first
        }
        return BulbEntry(date: .now, bulb: bulb, state: bulb.flatMap { BulbStorage.state(for: $0.id) })
    }
}

struct BulbWidgetView: View {
    @Environment(\.widgetFamily) private var family
    let entry: BulbEntry

    private var isOn: Bool { entry.state?.isOn ?? false }
    private var name: String { entry.bulb?.name ?? "No Bulb" }
    private var status: String {
        guard entry.bulb != nil else { return "Open Jib" }
        return entry.state?.statusText ?? "Tap to toggle"
    }
    private var symbol: some View {
        Image(systemName: isOn ? "lightbulb.fill" : "lightbulb")
            .widgetAccentable(isOn)
    }

    var body: some View {
        Group {
            switch family {
            case .accessoryInline:
                Label("\(name) · \(status)", systemImage: isOn ? "lightbulb.fill" : "lightbulb")
            case .accessoryCircular:
                ZStack {
                    AccessoryWidgetBackground()
                    symbol.font(.title2)
                }
            case .accessoryCorner:
                symbol
                    .font(.title2)
                    .widgetLabel { Text(status) }
            default:
                HStack(spacing: 8) {
                    symbol.font(.title)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(name).font(.headline).lineLimit(1)
                        Text(status).font(.caption2).foregroundStyle(.secondary).lineLimit(1)
                    }
                    Spacer(minLength: 0)
                }
            }
        }
        .widgetURL(entry.bulb.map { JibLink.toggleURL(for: $0.id) })
        .containerBackground(.fill.tertiary, for: .widget)
    }
}
