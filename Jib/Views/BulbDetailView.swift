import SwiftUI

struct BulbDetailView: View {
    @Environment(BulbStore.self) private var store
    let bulbID: UUID
    @State private var isEditing = false

    var body: some View {
        if let bulb = store.bulb(id: bulbID) {
            content(for: bulb)
        } else {
            ContentUnavailableView("Bulb Removed", systemImage: "lightbulb.slash")
        }
    }

    @ViewBuilder
    private func content(for bulb: Bulb) -> some View {
        let info = store.infos[bulb.id]
        let state = info?.state
        let accent = state?.displayColor ?? .yellow

        Form {
            Section {
                PowerControl(bulb: bulb)
            }
            .listRowBackground(Color.clear)

            if info?.isDimmable ?? true {
                Section("Brightness") {
                    LiveSlider(remote: Double(state?.brightness ?? 100), range: 1...100, step: 1,
                               gradient: Gradient(colors: [accent.opacity(0.15), accent]),
                               format: { "\(Int($0))%" }) { value in
                        await store.perform(.brightness(Int(value)), on: bulb)
                    }
                }
            }

            if let info, info.isVariableColorTemp {
                let range = info.colorTempRange
                Section("White") {
                    LiveSlider(remote: Double(state?.colorTemp ?? 2700),
                               range: Double(range.lowerBound)...Double(range.upperBound), step: 100,
                               gradient: Gradient(colors: [.whiteLight(kelvin: range.lowerBound),
                                                           .whiteLight(kelvin: (range.lowerBound + range.upperBound) / 2),
                                                           .whiteLight(kelvin: range.upperBound)]),
                               format: { "\(Int($0)) K" }) { value in
                        await store.perform(.colorTemp(Int(value)), on: bulb)
                    }
                }
            }

            if let info, info.isColor {
                let hue = state?.hue ?? 0
                let saturation = state?.saturation ?? 100
                Section("Color") {
                    LiveSlider(remote: Double(hue), range: 0...360, step: 1,
                               gradient: Gradient(colors: stride(from: 0, through: 360, by: 30).map {
                                   Color(hue: Double($0) / 360, saturation: 1, brightness: 1)
                               }),
                               format: { "Hue \(Int($0))°" }) { value in
                        await store.perform(.color(hue: Int(value), saturation: max(saturation, 1)), on: bulb)
                    }
                    LiveSlider(remote: Double(saturation), range: 0...100, step: 1,
                               gradient: Gradient(colors: [.white, Color(hue: Double(hue) / 360, saturation: 1, brightness: 1)]),
                               format: { "Saturation \(Int($0))%" }) { value in
                        await store.perform(.color(hue: hue, saturation: Int(value)), on: bulb)
                    }
                }
            }

            if let info, !info.presets.isEmpty {
                Section("Presets") {
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 12) {
                            ForEach(info.presets) { preset in
                                Button {
                                    Task { await store.perform(.preset(preset), on: bulb) }
                                } label: {
                                    VStack(spacing: 6) {
                                        Circle()
                                            .fill(preset.displayColor)
                                            .frame(width: 44, height: 44)
                                            .overlay(Circle().strokeBorder(.black.opacity(0.1)))
                                        Text(preset.label)
                                            .font(.caption2)
                                            .foregroundStyle(.secondary)
                                    }
                                }
                                .buttonStyle(.plain)
                            }
                        }
                        .padding(.vertical, 4)
                    }
                }
            }

            Section {
                NavigationLink {
                    ScheduleView(bulb: bulb)
                } label: {
                    Label("Schedule", systemImage: "clock")
                }
            }

            if let error = store.errors[bulb.id] {
                Section {
                    Label(error, systemImage: "exclamationmark.triangle.fill")
                        .font(.footnote)
                        .foregroundStyle(.red)
                }
            }

            Section("Device") {
                LabeledContent("Address", value: bulb.host)
                if let info {
                    LabeledContent("Name on Bulb", value: info.alias)
                    LabeledContent("Model", value: info.model)
                    if let firmware = info.softwareVersion { LabeledContent("Firmware", value: firmware) }
                    if let rssi = info.rssi { LabeledContent("Wi‑Fi Signal", value: "\(rssi) dBm") }
                }
            }
        }
        .navigationTitle(bulb.name)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button("Edit") { isEditing = true }
            }
        }
        .sheet(isPresented: $isEditing) { BulbFormView(mode: .edit(bulb)) }
        .task(id: bulb.id) { await store.refresh(bulb) }
    }
}

/// Large power button with the bulb's current light bleeding through.
struct PowerControl: View {
    @Environment(BulbStore.self) private var store
    let bulb: Bulb

    var body: some View {
        let info = store.infos[bulb.id]
        let state = info?.state
        let on = state?.isOn ?? false
        let color = state?.displayColor ?? .yellow

        VStack(spacing: 12) {
            Button {
                Task { await store.togglePower(bulb) }
            } label: {
                ZStack {
                    Circle().fill(on ? color.opacity(0.3) : Color(uiColor: .secondarySystemFill))
                    Image(systemName: "power")
                        .font(.system(size: 40, weight: .semibold))
                        .foregroundStyle(on ? color : Color.secondary)
                }
                .frame(width: 120, height: 120)
                .shadow(color: on ? color.opacity(0.6) : .clear, radius: 20)
            }
            .buttonStyle(.plain)
            .disabled(info == nil)

            HStack(spacing: 6) {
                if store.busy.contains(bulb.id) { ProgressView().controlSize(.mini) }
                Text(state?.statusText ?? "Connecting…")
            }
            .font(.subheadline)
            .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 8)
        .animation(.easeInOut(duration: 0.25), value: state)
    }
}
