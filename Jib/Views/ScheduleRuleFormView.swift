import SwiftUI

/// Add a rule to a bulb's schedule, or change an existing one.
struct ScheduleRuleFormView: View {
    enum TriggerKind: Hashable { case time, sunrise, sunset }

    @Environment(\.dismiss) private var dismiss
    let model: ScheduleModel
    let info: BulbInfo?
    private let original: ScheduleRule

    @State private var kind: TriggerKind
    @State private var time: Date
    @State private var offset: Int
    @State private var days: [Bool]
    @State private var turnsOn: Bool
    @State private var brightness: Double
    @State private var useWhite: Bool
    @State private var colorTemp: Double
    @State private var hue: Double
    @State private var saturation: Double
    @State private var name: String
    @State private var isSaving = false
    @State private var saveError: String?
    @State private var confirmingDelete = false

    init(model: ScheduleModel, info: BulbInfo?, rule: ScheduleRule) {
        self.model = model
        self.info = info
        original = rule
        let calendar = Calendar.current
        switch rule.trigger {
        case .time(let minutes):
            _kind = State(initialValue: .time)
            _time = State(initialValue: calendar.date(bySettingHour: minutes / 60, minute: minutes % 60, second: 0, of: .now) ?? .now)
            _offset = State(initialValue: 0)
        case .sunrise(let offset):
            _kind = State(initialValue: .sunrise)
            _time = State(initialValue: .now)
            _offset = State(initialValue: offset)
        case .sunset(let offset):
            _kind = State(initialValue: .sunset)
            _time = State(initialValue: .now)
            _offset = State(initialValue: offset)
        }
        _days = State(initialValue: rule.days)
        _turnsOn = State(initialValue: rule.action.turnsOn)
        let light = rule.action.light ?? info?.state
            ?? LightState(isOn: true, brightness: 100, colorTemp: 2700, hue: 0, saturation: 0)
        _brightness = State(initialValue: Double(light.brightness))
        _useWhite = State(initialValue: light.isWhite || !(info?.isColor ?? false))
        let range = info?.colorTempRange ?? 2500...6500
        _colorTemp = State(initialValue: Double(light.isWhite ? light.colorTemp : (range.lowerBound + range.upperBound) / 2)
                           .clamped(to: Double(range.lowerBound)...Double(range.upperBound)))
        _hue = State(initialValue: Double(light.hue))
        _saturation = State(initialValue: Double(light.isWhite ? 100 : light.saturation))
        _name = State(initialValue: rule.name == ScheduleRule.defaultName ? "" : rule.name)
    }

    private var isNew: Bool { original.isNew }
    private var hasDays: Bool { days.contains(true) }
    private var colorTempRange: ClosedRange<Double> {
        let range = info?.colorTempRange ?? 2500...6500
        return Double(range.lowerBound)...Double(range.upperBound)
    }

    private var light: LightState {
        LightState(isOn: true, brightness: Int(brightness),
                   colorTemp: useWhite ? Int(colorTemp) : 0,
                   hue: useWhite ? 0 : Int(hue),
                   saturation: useWhite ? 0 : Int(saturation))
    }

    private var rule: ScheduleRule {
        var rule = original
        switch kind {
        case .time:
            let parts = Calendar.current.dateComponents([.hour, .minute], from: time)
            rule.trigger = .time(minutes: (parts.hour ?? 0) * 60 + (parts.minute ?? 0))
        case .sunrise: rule.trigger = .sunrise(offset: offset)
        case .sunset: rule.trigger = .sunset(offset: offset)
        }
        rule.days = days
        rule.action = turnsOn ? .on(light) : .off
        rule.name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        if rule.transitionMillis == 0 { rule.transitionMillis = 5000 }
        return rule
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("When") {
                    Picker("Trigger", selection: $kind) {
                        Text("Time").tag(TriggerKind.time)
                        Text("Sunrise").tag(TriggerKind.sunrise)
                        Text("Sunset").tag(TriggerKind.sunset)
                    }
                    .pickerStyle(.segmented)
                    if kind == .time {
                        DatePicker("Time", selection: $time, displayedComponents: .hourAndMinute)
                    } else {
                        Stepper(value: $offset, in: -180...180, step: 5) {
                            Text(ScheduleTrigger.sunLabel(kind == .sunrise ? "sunrise" : "sunset", offset: offset))
                        }
                    }
                }

                Section {
                    WeekdayPicker(days: $days)
                } header: {
                    Text("Days")
                } footer: {
                    if !hasDays { Text("Pick at least one day.") }
                }

                Section("Then") {
                    Picker("Action", selection: $turnsOn) {
                        Text("Turn Off").tag(false)
                        Text("Turn On").tag(true)
                    }
                    .pickerStyle(.segmented)

                    if turnsOn {
                        if info?.isDimmable ?? true {
                            row("Brightness", value: "\(Int(brightness))%") {
                                Slider(value: $brightness, in: 1...100, step: 1)
                            }
                        }
                        if info?.isColor ?? false {
                            Picker("Light", selection: $useWhite) {
                                Text("White").tag(true)
                                Text("Color").tag(false)
                            }
                            .pickerStyle(.segmented)
                        }
                        if useWhite {
                            if info?.isVariableColorTemp ?? true {
                                row("Warmth", value: "\(Int(colorTemp)) K") {
                                    Slider(value: $colorTemp, in: colorTempRange, step: 100)
                                }
                            }
                        } else {
                            row("Hue", value: "\(Int(hue))°") {
                                Slider(value: $hue, in: 0...360, step: 1)
                            }
                            row("Saturation", value: "\(Int(saturation))%") {
                                Slider(value: $saturation, in: 0...100, step: 1)
                            }
                        }
                        HStack {
                            Text("Preview")
                            Spacer()
                            Circle()
                                .fill(light.displayColor)
                                .frame(width: 28, height: 28)
                                .overlay(Circle().strokeBorder(.black.opacity(0.1)))
                        }
                    }
                }

                Section {
                    TextField("Name (optional)", text: $name)
                } footer: {
                    if kind != .time {
                        Text("Sunrise and sunset come from the location saved on the bulb by its original app.")
                    }
                }

                if let saveError {
                    Section {
                        Label(saveError, systemImage: "exclamationmark.triangle.fill")
                            .font(.footnote)
                            .foregroundStyle(.red)
                    }
                }

                if !isNew {
                    Section {
                        Button("Delete Schedule", role: .destructive) { confirmingDelete = true }
                            .frame(maxWidth: .infinity)
                    }
                }
            }
            .navigationTitle(isNew ? "New Schedule" : "Edit Schedule")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    if isSaving {
                        ProgressView()
                    } else {
                        Button(isNew ? "Add" : "Save") { Task { await save() } }
                            .disabled(!hasDays)
                    }
                }
            }
            .confirmationDialog("Delete this schedule from the bulb?", isPresented: $confirmingDelete, titleVisibility: .visible) {
                Button("Delete", role: .destructive) { Task { await delete() } }
            }
            .interactiveDismissDisabled(isSaving)
        }
    }

    private func row<Content: View>(_ title: String, value: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(title)
                Spacer()
                Text(value).foregroundStyle(.secondary).monospacedDigit()
            }
            content()
        }
    }

    private func save() async {
        isSaving = true
        defer { isSaving = false }
        if await model.save(rule) {
            dismiss()
        } else {
            saveError = model.writeError ?? "The bulb didn’t accept the schedule."
        }
    }

    private func delete() async {
        isSaving = true
        defer { isSaving = false }
        if await model.delete(original) {
            dismiss()
        } else {
            saveError = model.writeError ?? "The bulb didn’t delete the schedule."
        }
    }
}

/// Seven round day buttons, in the order the user's calendar starts the week.
struct WeekdayPicker: View {
    @Binding var days: [Bool]
    private let calendar = Calendar.current

    private var order: [Int] {
        let first = calendar.firstWeekday - 1
        return (0..<7).map { (first + $0) % 7 }
    }

    var body: some View {
        HStack(spacing: 8) {
            ForEach(order, id: \.self) { index in
                let on = days.indices.contains(index) && days[index]
                Button {
                    if days.indices.contains(index) { days[index].toggle() }
                } label: {
                    Text(calendar.veryShortWeekdaySymbols[index])
                        .font(.subheadline.weight(.semibold))
                        .frame(width: 36, height: 36)
                        .background(Circle().fill(on ? Color.accentColor : Color(uiColor: .secondarySystemFill)))
                        .foregroundStyle(on ? Color.white : Color.primary)
                }
                .buttonStyle(.plain)
                .accessibilityLabel(calendar.weekdaySymbols[index])
                .accessibilityValue(on ? "On" : "Off")
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 4)
    }
}
