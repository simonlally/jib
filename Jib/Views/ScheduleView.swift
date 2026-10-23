import SwiftUI

/// The rules stored on one bulb, its clock, and what it will do next.
struct ScheduleView: View {
    @Environment(BulbStore.self) private var store
    let bulb: Bulb
    @State private var model: ScheduleModel
    @State private var isAdding = false
    @State private var editing: ScheduleRule?

    init(bulb: Bulb) {
        self.bulb = bulb
        _model = State(initialValue: ScheduleModel(bulb: bulb))
    }

    var body: some View {
        List {
            if let schedule = model.schedule {
                rulesSection(schedule)
                bulbSection(schedule)
            } else if model.isLoading {
                Section {
                    HStack(spacing: 10) {
                        ProgressView()
                        Text("Reading the bulb’s schedule…").foregroundStyle(.secondary)
                    }
                }
            }

            if let error = model.writeError {
                Section {
                    Label("The bulb didn’t accept the change. \(error)", systemImage: "exclamationmark.triangle.fill")
                        .font(.footnote)
                        .foregroundStyle(.red)
                }
            }

            if let error = model.loadError {
                Section {
                    Label(error, systemImage: "exclamationmark.triangle.fill")
                        .font(.footnote)
                        .foregroundStyle(.red)
                }
            }
        }
        .navigationTitle("Schedule")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                HStack {
                    if model.isSaving { ProgressView().controlSize(.small) }
                    Button { isAdding = true } label: { Image(systemName: "plus") }
                        .disabled(model.schedule == nil)
                }
            }
        }
        .refreshable { await model.load() }
        .task { await model.load() }
        .sheet(isPresented: $isAdding) {
            ScheduleRuleFormView(model: model, info: store.infos[bulb.id],
                                 rule: ScheduleView.template(for: store.infos[bulb.id]))
        }
        .sheet(item: $editing) { rule in
            ScheduleRuleFormView(model: model, info: store.infos[bulb.id], rule: rule)
        }
    }

    @ViewBuilder
    private func rulesSection(_ schedule: BulbSchedule) -> some View {
        if schedule.rules.isEmpty {
            Section {
                ContentUnavailableView {
                    Label("No Schedules", systemImage: "clock.badge.questionmark")
                } description: {
                    Text("Turn the bulb on or off at set times. Schedules are stored on the bulb itself.")
                } actions: {
                    Button("Add Schedule") { isAdding = true }
                        .buttonStyle(.borderedProminent)
                }
            }
            .listRowBackground(Color.clear)
        } else {
            Section {
                ForEach(model.rules) { rule in
                    ScheduleRuleRow(rule: rule,
                                    onEdit: { editing = rule },
                                    onToggle: { on in Task { await model.setEnabled(on, for: rule) } })
                }
                .onDelete { offsets in
                    let doomed = offsets.map { model.rules[$0] }
                    Task { for rule in doomed { await model.delete(rule) } }
                }
            } footer: {
                Text("Schedules run on the bulb from its own clock, so they keep working when your iPhone is away.")
            }
        }
    }

    @ViewBuilder
    private func bulbSection(_ schedule: BulbSchedule) -> some View {
        Section("Bulb") {
            Toggle("Schedules Enabled", isOn: Binding(
                get: { schedule.isEnabled },
                set: { on in Task { await model.setAllEnabled(on) } }
            ))

            if let next = schedule.next, schedule.isEnabled {
                LabeledContent("Next", value: nextLabel(next))
            }

            if let clock = schedule.clock, let bulbTime = clock.date() {
                LabeledContent("Bulb Clock", value: bulbTime.formatted(date: .omitted, time: .standard))
                if let drift = clock.drift(from: schedule.fetchedAt), abs(drift) > 90 {
                    VStack(alignment: .leading, spacing: 8) {
                        Label(driftLabel(drift), systemImage: "exclamationmark.triangle.fill")
                            .font(.footnote)
                            .foregroundStyle(.orange)
                        Button("Set to iPhone Time") {
                            Task { await model.syncClock() }
                        }
                        .font(.footnote.weight(.semibold))
                    }
                }
            } else {
                Text("The bulb didn’t report its clock.").foregroundStyle(.secondary)
            }
        }
    }

    private func nextLabel(_ next: NextScheduledAction) -> String {
        switch next.turnsOn {
        case true?: return "On at \(next.timeLabel)"
        case false?: return "Off at \(next.timeLabel)"
        case nil: return next.timeLabel
        }
    }

    private func driftLabel(_ drift: TimeInterval) -> String {
        let minutes = Int((abs(drift) / 60).rounded())
        let amount = minutes < 1 ? "\(Int(abs(drift))) s" : "\(minutes) min"
        return "The bulb’s clock is \(amount) \(drift > 0 ? "ahead of" : "behind") your iPhone, so schedules will fire at the wrong time."
    }

    /// A fresh rule: the next whole hour, every day, turning the bulb on as it last looked.
    static func template(for info: BulbInfo?, now: Date = .now, calendar: Calendar = .current) -> ScheduleRule {
        var light = info?.state ?? LightState(isOn: true, brightness: 100, colorTemp: 2700, hue: 0, saturation: 0)
        light.isOn = true
        let hour = calendar.component(.hour, from: now)
        return ScheduleRule(trigger: .time(minutes: (hour + 1) % 24 * 60), action: .on(light))
    }
}

/// One rule. The toggle sits beside, not inside, the edit button so both get their own taps.
struct ScheduleRuleRow: View {
    let rule: ScheduleRule
    let onEdit: () -> Void
    let onToggle: (Bool) -> Void

    var body: some View {
        HStack(spacing: 14) {
            Button(action: onEdit) {
                HStack(spacing: 14) {
                    ZStack {
                        Circle().fill(rule.action.light?.displayColor.opacity(0.3) ?? Color.gray.opacity(0.15))
                        Image(systemName: rule.action.turnsOn ? "lightbulb.fill" : "lightbulb.slash")
                            .font(.system(size: 16, weight: .medium))
                            .foregroundStyle(rule.action.light?.displayColor ?? Color.secondary)
                    }
                    .frame(width: 36, height: 36)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(rule.trigger.label).font(.headline)
                        Text(rule.action.label)
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                        Text(rule.daysSummary)
                            .font(.footnote)
                            .foregroundStyle(.tertiary)
                            .lineLimit(1)
                    }
                    Spacer(minLength: 8)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            Toggle("Enabled", isOn: Binding(get: { rule.isEnabled }, set: onToggle))
                .labelsHidden()
        }
        .padding(.vertical, 2)
        .opacity(rule.isEnabled ? 1 : 0.55)
    }
}
