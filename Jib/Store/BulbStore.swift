import Foundation
import Observation
import WidgetKit

/// Source of truth on the phone: the saved bulb list plus live state per bulb.
@MainActor
@Observable
final class BulbStore {
    private(set) var bulbs: [Bulb] = []
    private(set) var infos: [UUID: BulbInfo] = [:]
    private(set) var errors: [UUID: String] = [:]
    private(set) var busy: Set<UUID> = []

    /// Fires whenever the saved list changes; the watch mirror hooks in here.
    var onBulbsChanged: (([Bulb]) -> Void)?
    /// Fires whenever a bulb's last-seen state changes. `powerChanged` tells an on/off flip apart
    /// from a brightness or colour step.
    var onStateChanged: (@MainActor (_ states: [UUID: LightState], _ powerChanged: Bool) -> Void)?

    private let defaults: UserDefaults
    private var operationCounter = 0
    private var latestOperation: [UUID: Int] = [:]

    /// The list lives in the App Group container so the Control Center extension can read it too.
    /// A list saved by an earlier version in the app's own defaults is moved over on first launch.
    init(defaults: UserDefaults = BulbStorage.defaults) {
        self.defaults = defaults
        if defaults === BulbStorage.defaults { BulbStorage.migrateIfNeeded(to: defaults) }
        bulbs = BulbStorage.loadBulbs(from: defaults)
    }

    // MARK: List management

    func bulb(id: UUID) -> Bulb? { bulbs.first { $0.id == id } }
    func bulb(host: String) -> Bulb? { bulbs.first { $0.host == host } }
    func hasBulb(host: String) -> Bool { bulb(host: host) != nil }

    func add(_ bulb: Bulb) {
        bulbs.append(bulb)
        persist()
        Task { await refresh(bulb) }
    }

    func update(_ bulb: Bulb) {
        guard let index = bulbs.firstIndex(where: { $0.id == bulb.id }) else { return }
        let hostChanged = bulbs[index].host != bulb.host
        bulbs[index] = bulb
        persist()
        if hostChanged {
            infos[bulb.id] = nil
            Task { await refresh(bulb) }
        }
    }

    func remove(_ bulb: Bulb) {
        bulbs.removeAll { $0.id == bulb.id }
        forget(bulb.id)
        persist()
    }

    func remove(atOffsets offsets: IndexSet) {
        for index in offsets { forget(bulbs[index].id) }
        bulbs.remove(atOffsets: offsets)
        persist()
    }

    func move(fromOffsets source: IndexSet, toOffset destination: Int) {
        bulbs.move(fromOffsets: source, toOffset: destination)
        persist()
    }

    private func forget(_ id: UUID) {
        infos[id] = nil
        errors[id] = nil
        BulbStorage.setState(nil, for: id, in: defaults)
    }

    private func persist() {
        BulbStorage.saveBulbs(bulbs, to: defaults)
        onBulbsChanged?(bulbs)
        reloadControls()
    }

    // MARK: Talking to bulbs

    func refresh(_ bulb: Bulb) async {
        await perform(.status, on: bulb)
    }

    func refreshAll() async {
        await withTaskGroup(of: Void.self) { group in
            for bulb in bulbs {
                group.addTask { await self.perform(.status, on: bulb) }
            }
        }
    }

    func togglePower(_ bulb: Bulb) async {
        let isOn = infos[bulb.id]?.state.isOn ?? false
        await perform(.power(!isOn), on: bulb)
    }

    @discardableResult
    func perform(_ action: BulbAction, on bulb: Bulb) async -> Bool {
        operationCounter += 1
        let ticket = operationCounter
        latestOperation[bulb.id] = ticket
        busy.insert(bulb.id)
        defer { if latestOperation[bulb.id] == ticket { busy.remove(bulb.id) } }
        do {
            let result = try await BulbCommands.perform(action, host: bulb.host)
            apply(result, to: bulb, ticket: ticket)
            return true
        } catch {
            errors[bulb.id] = error.localizedDescription
            return false
        }
    }

    /// Runs a command that arrived from the watch, keeping the phone's view in sync.
    func handleRelay(_ request: RelayRequest) async -> RelayResponse {
        do {
            let result = try await BulbCommands.perform(request.action, host: request.host)
            if let bulb = bulb(host: request.host) { apply(result, to: bulb, ticket: nil) }
            return RelayResponse(result: result, error: nil)
        } catch {
            return RelayResponse(result: nil, error: error.localizedDescription)
        }
    }

    /// Applies a result unless a newer operation on the same bulb has since started
    /// (slider drags fire several commands in flight at once).
    private func apply(_ result: ActionResult, to bulb: Bulb, ticket: Int?) {
        if let ticket, let latest = latestOperation[bulb.id], ticket < latest { return }
        errors[bulb.id] = nil
        let state: LightState
        switch result {
        case .info(let info):
            infos[bulb.id] = info
            state = info.state
        case .state(let newState):
            state = newState
            if infos[bulb.id] != nil {
                infos[bulb.id]?.state = newState
            } else {
                Task { await refresh(bulb) }
            }
        }
        share(state, for: bulb)
    }

    /// Records the state where the control and the watch can see it.
    private func share(_ state: LightState, for bulb: Bulb) {
        let powerChanged = BulbStorage.state(for: bulb.id, in: defaults)?.isOn != state.isOn
        guard BulbStorage.setState(state, for: bulb.id, in: defaults) else { return }
        if powerChanged { reloadControls() }
        onStateChanged?(BulbStorage.loadStates(from: defaults), powerChanged)
    }

    /// Control Center keeps each control's last value; ask it to read the bulb again.
    private func reloadControls() {
        if #available(iOS 18.0, *) {
            ControlCenter.shared.reloadControls(ofKind: BulbStorage.controlKind)
        }
    }
}
