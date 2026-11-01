import SwiftUI

extension LightState {
    /// Approximate on-screen color of what the bulb is emitting.
    var displayColor: Color {
        isWhite ? .whiteLight(kelvin: colorTemp)
                : Color(hue: Double(hue) / 360, saturation: Double(saturation) / 100, brightness: 1)
    }

    var statusText: String {
        isOn ? "On · \(brightness)%" : "Off"
    }
}

extension LightPreset {
    var displayColor: Color {
        colorTemp > 0 ? .whiteLight(kelvin: colorTemp)
                      : Color(hue: Double(hue) / 360, saturation: Double(saturation) / 100, brightness: 1)
    }

    var label: String {
        colorTemp > 0 ? "\(colorTemp) K · \(brightness)%" : "Color · \(brightness)%"
    }
}

extension Color {
    /// Rough sRGB appearance of a white LED at a given color temperature.
    static func whiteLight(kelvin: Int) -> Color {
        let anchors: [(k: Double, r: Double, g: Double, b: Double)] = [
            (2000, 1.00, 0.55, 0.15), (2500, 1.00, 0.64, 0.28), (2700, 1.00, 0.70, 0.42),
            (3000, 1.00, 0.76, 0.53), (3500, 1.00, 0.83, 0.65), (4000, 1.00, 0.88, 0.75),
            (4500, 1.00, 0.92, 0.84), (5000, 1.00, 0.96, 0.92), (5500, 1.00, 0.98, 0.97),
            (6500, 0.93, 0.95, 1.00), (7500, 0.86, 0.91, 1.00), (9000, 0.78, 0.86, 1.00),
        ]
        let k = Double(kelvin).clamped(to: anchors[0].k...anchors[anchors.count - 1].k)
        guard let upper = anchors.firstIndex(where: { $0.k >= k }), upper > 0 else {
            return Color(red: anchors[0].r, green: anchors[0].g, blue: anchors[0].b)
        }
        let lo = anchors[upper - 1], hi = anchors[upper]
        let t = (k - lo.k) / (hi.k - lo.k)
        return Color(red: lo.r + (hi.r - lo.r) * t,
                     green: lo.g + (hi.g - lo.g) * t,
                     blue: lo.b + (hi.b - lo.b) * t)
    }
}

/// Marks the in-app demo bulb wherever a bulb is shown, so it can't be taken for hardware.
struct DemoBadge: View {
    var body: some View {
        Text("DEMO")
            .font(.caption2.weight(.bold))
            .padding(.horizontal, 5)
            .padding(.vertical, 1)
            .foregroundStyle(.orange)
            .background(Capsule().fill(.orange.opacity(0.18)))
            .accessibilityLabel("Demo bulb")
    }
}

/// Lightbulb icon tinted with the bulb's current light. Shared by phone and watch.
struct BulbGlyph: View {
    let state: LightState?
    var size: CGFloat = 40

    var body: some View {
        let on = state?.isOn ?? false
        let color = state?.displayColor ?? .gray
        ZStack {
            Circle().fill(on ? color.opacity(0.25) : Color.gray.opacity(0.15))
            Image(systemName: on ? "lightbulb.fill" : "lightbulb")
                .font(.system(size: size * 0.5, weight: .medium))
                .foregroundStyle(on ? color : Color.secondary)
                .shadow(color: on ? color.opacity(0.8) : .clear, radius: size * 0.15)
        }
        .frame(width: size, height: size)
        .animation(.easeInOut(duration: 0.25), value: state)
    }
}
