import Foundation
import Observation
import WidgetKit

/// Runs one command against a bulb. Injected so tests can stand in for the network.
typealias BulbCommandRunner = @Sendable (BulbAction, String) async throws -> ActionResult

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
    /// Fires whenever a bulb's state differs from what this phone last handed to the watch.
    /// `wakeComplication` is set for an on/off flip the watch doesn't already know about: a flip
    /// the watch relayed itself reaches its complication through the reply.
    var onStateChanged: (@MainActor (_ states: [UUID: LightState], _ wakeComplication: Bool) -> Void)?

    /// Where the phone remembers what it last handed to the watch. Kept apart from the shared
    /// last-seen states, which the Control Center extension writes too: a change the extension saw
    /// still has to reach the watch when the phone next notices it.
    static let sharedKey = "watch.shared.v1"

    private let defaults: UserDefaults
    private let run: BulbCommandRunner
    private var operationCounter = 0
    private var latestOperation: [UUID: Int] = [:]
    private var lastShared: [UUID: LightState]

    /// The list lives in the App Group container so the Control Center extension can read it too.
    /// A list saved by an earlier version in the app's own defaults is moved over on first launch.
    init(defaults: UserDefaults = BulbStorage.defaults,
         runner: @escaping BulbCommandRunner = { try await BulbCommands.perform($0, host: $1) }) {
        self.defaults = defaults
        self.run = runner
        if defaults === BulbStorage.defaults { BulbStorage.migrateIfNeeded(to: defaults) }
        bulbs = BulbStorage.loadBulbs(from: defaults)
        lastShared = defaults.data(forKey: Self.sharedKey)
            .flatMap { try? JSONDecoder().decode([UUID: LightState].self, from: $0) } ?? [:]
    }

    // MARK: List management

    func bulb(id: UUID) -> Bulb? { bulbs.first { $0.id == id } }
    func bulb(host: String) -> Bulb? { bulbs.first { $0.host == host } }
    func hasBulb(host: String) -> Bool { bulb(host: host) != nil }
    var hasDemoBulb: Bool { bulbs.contains(where: \.isDemo) }

    /// Adds the in-app demo bulb, for trying Jib without hardware. There is only ever one.
    func addDemoBulb() {
        guard !hasDemoBulb else { return }
        add(.demo())
    }

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
        forget(bulb)
        persist()
    }

    func remove(atOffsets offsets: IndexSet) {
        for index in offsets { forget(bulbs[index]) }
        bulbs.remove(atOffsets: offsets)
        persist()
    }

    func move(fromOffsets source: IndexSet, toOffset destination: Int) {
        bulbs.move(fromOffsets: source, toOffset: destination)
        persist()
    }

    private func forget(_ bulb: Bulb) {
        infos[bulb.id] = nil
        errors[bulb.id] = nil
        BulbStorage.setState(nil, for: bulb.id, in: defaults)
        lastShared[bulb.id] = nil
        persistLastShared()
        // The demo bulb's light, rules and clock go with it, so the next one starts fresh.
        if bulb.isDemo { DemoBulb.reset(in: defaults) }
    }

    private func persist() {
        BulbStorage.saveBulbs(bulbs, to: defaults)
        onBulbsChanged?(bulbs)
        reloadControls()
    }

    private func persistLastShared() {
        defaults.set(try? JSONEncoder().encode(lastShared), forKey: Self.sharedKey)
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

    /// Runs a command and records the outcome. Returns whether the bulb answered. A request that was
    /// cancelled, or that a newer request on the same bulb has since superseded, is not news about
    /// the bulb, so neither its result nor its failure is recorded.
    @discardableResult
    func perform(_ action: BulbAction, on bulb: Bulb) async -> Bool {
        operationCounter += 1
        let ticket = operationCounter
        latestOperation[bulb.id] = ticket
        busy.insert(bulb.id)
        defer { if latestOperation[bulb.id] == ticket { busy.remove(bulb.id) } }
        // Show a power flip at once, so a second tap before the reply flips it back rather than again.
        var rollback: LightState?
        if case .power(let on) = action, var state = infos[bulb.id]?.state, state.isOn != on {
            rollback = state
            state.isOn = on
            infos[bulb.id]?.state = state
        }
        do {
            let result = try await run(action, bulb.host)
            apply(result, to: bulb, ticket: ticket)
            return true
        } catch {
            let superseded = latestOperation[bulb.id] != ticket
            if !superseded, let rollback { infos[bulb.id]?.state = rollback }
            if error is CancellationError || Task.isCancelled || superseded { return false }
            errors[bulb.id] = error.localizedDescription
            return false
        }
    }

    /// Runs a command that arrived from the watch, keeping the phone's view in sync.
    func handleRelay(_ request: RelayRequest) async -> RelayResponse {
        do {
            let result = try await run(request.action, request.host)
            if let bulb = bulb(host: request.host) { apply(result, to: bulb, ticket: nil, viaWatch: true) }
            return RelayResponse(result: result, error: nil)
        } catch {
            return RelayResponse(result: nil, error: error.localizedDescription)
        }
    }

    /// Applies a result unless a newer operation on the same bulb has since started
    /// (slider drags fire several commands in flight at once).
    private func apply(_ result: ActionResult, to bulb: Bulb, ticket: Int?, viaWatch: Bool = false) {
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
        share(state, for: bulb, viaWatch: viaWatch)
    }

    /// Records the state where the control and the watch can see it. The control is reloaded when
    /// the shared store changed hands; the watch is told whenever the state differs from what this
    /// phone last sent it, even if the Control Center extension already wrote it to the store. The
    /// complication is woken only for a power flip the watch didn't relay itself: those transfers
    /// are budgeted (about 50 a day), and the watch already has the reply.
    private func share(_ state: LightState, for bulb: Bulb, viaWatch: Bool) {
        let stored = BulbStorage.state(for: bulb.id, in: defaults)
        if BulbStorage.setState(state, for: bulb.id, in: defaults), stored?.isOn != state.isOn {
            reloadControls()
        }
        let previous = lastShared[bulb.id]
        guard previous != state else { return }
        lastShared[bulb.id] = state
        persistLastShared()
        onStateChanged?(BulbStorage.loadStates(from: defaults), previous?.isOn != state.isOn && !viaWatch)
    }

    /// Control Center keeps each control's last value; ask it to read the bulb again.
    private func reloadControls() {
        if #available(iOS 18.0, *) {
            ControlCenter.shared.reloadControls(ofKind: BulbStorage.controlKind)
        }
    }
}
