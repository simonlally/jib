import SwiftUI

/// Power, crown-driven brightness, and the bulb's stored presets.
struct WatchBulbDetailView: View {
    @Environment(WatchStore.self) private var store
    let bulbID: UUID

    @State private var brightness: Double = 50
    @State private var queue: CommitQueue<Int>?

    var body: some View {
        if let bulb = store.bulb(id: bulbID) {
            content(for: bulb)
        } else {
            Text("Bulb removed").foregroundStyle(.secondary)
        }
    }

    @ViewBuilder
    private func content(for bulb: Bulb) -> some View {
        let info = store.infos[bulb.id]
        let state = info?.state
        let on = state?.isOn ?? false
        let color = state?.displayColor ?? .yellow

        ScrollView {
            VStack(spacing: 10) {
                Button {
                    Task { await store.togglePower(bulb) }
                } label: {
                    ZStack {
                        Circle().fill(on ? color.opacity(0.3) : Color.gray.opacity(0.2))
                        Image(systemName: "power")
                            .font(.system(size: 28, weight: .semibold))
                            .foregroundStyle(on ? color : Color.secondary)
                    }
                    .frame(width: 72, height: 72)
                    .shadow(color: on ? color.opacity(0.6) : .clear, radius: 12)
                }
                .buttonStyle(.plain)
                .disabled(info == nil)

                HStack(spacing: 4) {
                    if store.busy.contains(bulb.id) { ProgressView().controlSize(.mini) }
                    Text(state?.statusText ?? "…")
                }
                .font(.footnote)
                .foregroundStyle(.secondary)

                if info?.isDimmable ?? true {
                    VStack(spacing: 4) {
                        Gauge(value: brightness, in: 1...100) {
                            Text("Brightness")
                        } currentValueLabel: {
                            Text("\(Int(brightness))%")
                        }
                        .gaugeStyle(.accessoryLinearCapacity)
                        .tint(color)
                        Text("Turn the crown")
                            .font(.caption2)
                            .foregroundStyle(.tertiary)
                    }
                    .focusable()
                    .digitalCrownRotation($brightness, from: 1, through: 100, by: 1,
                                          sensitivity: .medium, isContinuous: false, isHapticFeedbackEnabled: true)
                    .onChange(of: brightness) { _, newValue in
                        send(Int(newValue), for: bulb)
                    }
                }

                if let info, !info.presets.isEmpty {
                    HStack(spacing: 10) {
                        ForEach(info.presets) { preset in
                            Button {
                                Task { await store.perform(.preset(preset), on: bulb) }
                            } label: {
                                Circle()
                                    .fill(preset.displayColor)
                                    .frame(width: 26, height: 26)
                                    .overlay(Circle().strokeBorder(.white.opacity(0.3)))
                            }
                            .buttonStyle(.plain)
                            .accessibilityLabel("Preset \(preset.label)")
                        }
                    }
                    .padding(.top, 4)
                }

                if let error = store.errors[bulb.id] {
                    Text(error)
                        .font(.caption2)
                        .foregroundStyle(.red)
                        .multilineTextAlignment(.center)
                }
            }
            .padding(.horizontal, 4)
        }
        .navigationTitle(bulb.name)
        .onAppear { brightness = Double(state?.brightness ?? 50) }
        .onChange(of: state?.brightness) { _, newValue in
            if let newValue, !(queue?.isBusy ?? false) { brightness = Double(newValue) }
        }
        .task { await store.perform(.status, on: bulb) }
    }

    /// Crown rotation fires continuously. Values go out one at a time through the phone; a request in
    /// flight is never cancelled, and the newest value follows once it completes.
    private func send(_ value: Int, for bulb: Bulb) {
        guard value != store.infos[bulb.id]?.state.brightness else { return }
        if queue == nil {
            queue = CommitQueue { value in await store.perform(.brightness(value), on: bulb) }
        }
        queue?.send(value)
    }
}
