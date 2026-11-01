import Foundation
import Observation
import WatchConnectivity
import WidgetKit
import os

/// Watch-side state. The bulb list arrives from the phone; every command is relayed through it.
@MainActor
@Observable
final class WatchStore {
    private(set) var bulbs: [Bulb] = []
    private(set) var infos: [UUID: BulbInfo] = [:]
    private(set) var errors: [UUID: String] = [:]
    private(set) var busy: Set<UUID> = []
    private(set) var isPhoneReachable = false

    private let connector = WatchConnector()
    private let defaults = BulbStorage.defaults
    private var operationCounter = 0
    private var latestOperation: [UUID: Int] = [:]
    /// A toggle the complication asked for that hasn't reached the phone yet.
    private var pendingToggle: (id: UUID, requested: Date)?
    private var pendingToggleInFlight = false
    private let log = Logger(subsystem: "dev.simonlally.jib", category: "watch")

    /// The list lives in the App Group container so the complication can read it too.
    init() {
        BulbStorage.migrateIfNeeded(to: defaults)
        bulbs = BulbStorage.loadBulbs(from: defaults)
        connector.onSync = { [weak self] bulbs, states in
            Task { @MainActor in self?.sync(bulbs: bulbs, states: states) }
        }
        connector.onReachability = { [weak self] reachable in
            Task { @MainActor in self?.setReachable(reachable) }
        }
        connector.activate()
    }

    func bulb(id: UUID) -> Bulb? { bulbs.first { $0.id == id } }

    /// Last state seen for a bulb, here or on the phone.
    func lastState(for id: UUID) -> LightState? {
        infos[id]?.state ?? BulbStorage.state(for: id, in: defaults)
    }

    // MARK: From the phone

    private func sync(bulbs newBulbs: [Bulb]?, states: [UUID: LightState]?) {
        var widgetNeedsReload = false
        if let newBulbs, newBulbs != bulbs {
            let previous = bulbs
            bulbs = newBulbs
            BulbStorage.saveBulbs(newBulbs, to: defaults)
            let ids = Set(newBulbs.map(\.id))
            infos = infos.filter { ids.contains($0.key) }
            errors = errors.filter { ids.contains($0.key) }
            BulbStorage.saveStates(BulbStorage.loadStates(from: defaults).filter { ids.contains($0.key) }, to: defaults)
            widgetNeedsReload = true
            // Fetch state for anything new or re-addressed as soon as the phone can answer.
            let changed = newBulbs.filter { bulb in !previous.contains(bulb) }
            if isPhoneReachable, !changed.isEmpty {
                Task {
                    for bulb in changed { await perform(.status, on: bulb) }
                }
            }
        }
        // The phone runs every command, including ours, so its view of each bulb is the latest.
        for (id, state) in states ?? [:] where bulbs.contains(where: { $0.id == id }) {
            if infos[id] != nil { infos[id]?.state = state }
            if BulbStorage.setState(state, for: id, in: defaults) { widgetNeedsReload = true }
        }
        if widgetNeedsReload { reloadWidget() }
    }

    private func setReachable(_ reachable: Bool) {
        let wasReachable = isPhoneReachable
        isPhoneReachable = reachable
        if reachable, !wasReachable {
            Task { await refreshAll() }
        }
        runPendingToggle()
    }

    // MARK: Complication

    /// `jib://toggle/<id>`: the complication was tapped. Runs as soon as the phone can answer.
    func handle(_ url: URL) {
        guard let id = JibLink.bulbID(fromToggleURL: url) else {
            log.error("ignoring url \(url.absoluteString, privacy: .private)")
            return
        }
        log.info("complication tap for \(id, privacy: .private); phone reachable: \(self.isPhoneReachable)")
        pendingToggle = (id, Date())
        runPendingToggle()
    }

    /// Reachability flickers while the app comes to the foreground, so a tap stays pending until the
    /// phone actually answers, for up to 20 seconds. Other failures (the bulb refusing, say) are final.
    private func runPendingToggle() {
        guard let pending = pendingToggle, isPhoneReachable, !pendingToggleInFlight else { return }
        guard Date().timeIntervalSince(pending.requested) < 20, let bulb = bulb(id: pending.id) else {
            log.error("dropping stale or unknown complication toggle for \(pending.id, privacy: .private)")
            pendingToggle = nil
            return
        }
        pendingToggleInFlight = true
        Task {
            let error = await togglePower(bulb)
            pendingToggleInFlight = false
            if let error, Self.isReachabilityError(error) {
                log.error("phone link dropped mid-toggle; keeping the complication tap pending")
                try? await Task.sleep(for: .seconds(1))
                runPendingToggle()
            } else {
                pendingToggle = nil
            }
        }
    }

    private static func isReachabilityError(_ error: Error) -> Bool {
        if let relay = error as? RelayError {
            switch relay {
            case .notActivated, .phoneUnreachable: return true
            case .badReply, .remote: return false
            }
        }
        if let wc = error as? WCError {
            return [.notReachable, .sessionNotActivated, .sessionInactive].contains(wc.code)
        }
        return false
    }

    private func reloadWidget() {
        WidgetCenter.shared.reloadTimelines(ofKind: BulbStorage.watchWidgetKind)
    }

    // MARK: Talking to bulbs (through the phone)

    func refreshAll() async {
        await withTaskGroup(of: Void.self) { group in
            for bulb in bulbs {
                group.addTask { await self.perform(.status, on: bulb) }
            }
        }
    }

    @discardableResult
    func togglePower(_ bulb: Bulb) async -> Error? {
        let isOn = lastState(for: bulb.id)?.isOn ?? false
        return await perform(.power(!isOn), on: bulb)
    }

    /// Returns the error when the command failed; the row shows it too.
    @discardableResult
    func perform(_ action: BulbAction, on bulb: Bulb) async -> Error? {
        operationCounter += 1
        let ticket = operationCounter
        latestOperation[bulb.id] = ticket
        busy.insert(bulb.id)
        defer { if latestOperation[bulb.id] == ticket { busy.remove(bulb.id) } }
        do {
            let result = try await connector.send(RelayRequest(host: bulb.host, action: action))
            guard latestOperation[bulb.id] == ticket else { return nil }
            errors[bulb.id] = nil
            switch result {
            case .info(let info):
                infos[bulb.id] = info
                share(info.state, for: bulb)
            case .state(let state):
                share(state, for: bulb)
                if infos[bulb.id] != nil {
                    infos[bulb.id]?.state = state
                } else {
                    await perform(.status, on: bulb)
                }
            }
            return nil
        } catch {
            log.error("\(bulb.name, privacy: .private): \(error.localizedDescription, privacy: .private)")
            // The list's footer already says when the phone is out of reach; a per-bulb error would
            // only paint every row red while the link comes up. A superseded request is old news.
            if !Self.isReachabilityError(error), latestOperation[bulb.id] == ticket {
                errors[bulb.id] = error.localizedDescription
            }
            return error
        }
    }

    /// Records the state where the complication can see it.
    private func share(_ state: LightState, for bulb: Bulb) {
        if BulbStorage.setState(state, for: bulb.id, in: defaults) { reloadWidget() }
    }
}

/// Thin WCSession wrapper. Delegate callbacks arrive on a background queue.
final class WatchConnector: NSObject, WCSessionDelegate {
    /// Bulb list and/or last-seen states pushed by the phone; either may be absent.
    var onSync: ((_ bulbs: [Bulb]?, _ states: [UUID: LightState]?) -> Void)?
    var onReachability: ((Bool) -> Void)?

    func activate() {
        guard WCSession.isSupported() else { return }
        let session = WCSession.default
        session.delegate = self
        session.activate()
    }

    func send(_ request: RelayRequest) async throws -> ActionResult {
        let session = WCSession.default
        guard session.activationState == .activated else { throw RelayError.notActivated }
        guard session.isReachable else { throw RelayError.phoneUnreachable }
        let data = try JSONEncoder().encode(request)
        return try await withCheckedThrowingContinuation { continuation in
            session.sendMessage([Relay.requestKey: data]) { reply in
                guard let payload = reply[Relay.responseKey] as? Data,
                      let response = try? JSONDecoder().decode(RelayResponse.self, from: payload) else {
                    continuation.resume(throwing: RelayError.badReply)
                    return
                }
                if let error = response.error {
                    continuation.resume(throwing: RelayError.remote(error))
                } else if let result = response.result {
                    continuation.resume(returning: result)
                } else {
                    continuation.resume(throwing: RelayError.badReply)
                }
            } errorHandler: { error in
                continuation.resume(throwing: error)
            }
        }
    }

    private func readPayload(_ payload: [String: Any]) {
        let bulbs = (payload[Relay.bulbsKey] as? Data).flatMap { try? JSONDecoder().decode([Bulb].self, from: $0) }
        let states = (payload[Relay.statesKey] as? Data).flatMap { try? JSONDecoder().decode([UUID: LightState].self, from: $0) }
        guard bulbs != nil || states != nil else { return }
        onSync?(bulbs, states)
    }

    // MARK: WCSessionDelegate

    func session(_ session: WCSession, activationDidCompleteWith activationState: WCSessionActivationState, error: Error?) {
        guard activationState == .activated else { return }
        readPayload(session.receivedApplicationContext)
        onReachability?(session.isReachable)
    }

    func session(_ session: WCSession, didReceiveApplicationContext applicationContext: [String: Any]) {
        readPayload(applicationContext)
    }

    /// Carries `transferCurrentComplicationUserInfo` from the phone, which may wake this app in the background.
    func session(_ session: WCSession, didReceiveUserInfo userInfo: [String: Any] = [:]) {
        readPayload(userInfo)
    }

    func sessionReachabilityDidChange(_ session: WCSession) {
        onReachability?(session.isReachable)
    }
}
