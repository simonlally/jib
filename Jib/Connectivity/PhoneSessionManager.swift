import Foundation
import WatchConnectivity

/// Phone side of the watch link: mirrors the bulb list and last-seen states to the watch,
/// and runs relayed commands.
final class PhoneSessionManager: NSObject, WCSessionDelegate {
    static let shared = PhoneSessionManager()

    private var store: BulbStore?

    @MainActor
    func activate(store: BulbStore) {
        self.store = store
        store.onBulbsChanged = { [weak self] bulbs in self?.push(bulbs: bulbs, states: BulbStorage.loadStates()) }
        store.onStateChanged = { [weak self] states, wakeComplication in
            guard let self, let bulbs = self.store?.bulbs else { return }
            self.push(bulbs: bulbs, states: states)
            if wakeComplication { self.pushComplicationUpdate(states) }
        }
        guard WCSession.isSupported() else { return }
        let session = WCSession.default
        session.delegate = self
        session.activate()
    }

    private func push(bulbs: [Bulb], states: [UUID: LightState]) {
        guard WCSession.isSupported() else { return }
        let session = WCSession.default
        guard session.activationState == .activated, session.isPaired, session.isWatchAppInstalled,
              let bulbData = try? JSONEncoder().encode(bulbs),
              let stateData = try? JSONEncoder().encode(states) else { return }
        do {
            try session.updateApplicationContext([Relay.bulbsKey: bulbData, Relay.statesKey: stateData])
        } catch {
            NSLog("Jib: could not push bulbs to watch: \(error.localizedDescription)")
        }
    }

    /// Wakes the watch app in the background so the complication can show the new state.
    /// The system budgets these transfers (roughly 50 a day), so only on/off changes use them.
    private func pushComplicationUpdate(_ states: [UUID: LightState]) {
        guard WCSession.isSupported() else { return }
        let session = WCSession.default
        guard session.activationState == .activated, session.isComplicationEnabled,
              let data = try? JSONEncoder().encode(states) else { return }
        session.transferCurrentComplicationUserInfo([Relay.statesKey: data])
    }

    private func pushCurrentList() {
        Task { @MainActor in
            if let bulbs = store?.bulbs { push(bulbs: bulbs, states: BulbStorage.loadStates()) }
        }
    }

    private static func encode(_ response: RelayResponse) -> [String: Any] {
        [Relay.responseKey: (try? JSONEncoder().encode(response)) ?? Data()]
    }

    // MARK: WCSessionDelegate

    func session(_ session: WCSession, activationDidCompleteWith activationState: WCSessionActivationState, error: Error?) {
        if activationState == .activated { pushCurrentList() }
    }

    func sessionDidBecomeInactive(_ session: WCSession) {}

    func sessionDidDeactivate(_ session: WCSession) {
        session.activate()
    }

    func sessionWatchStateDidChange(_ session: WCSession) {
        pushCurrentList()
    }

    func session(_ session: WCSession, didReceiveMessage message: [String: Any], replyHandler: @escaping ([String: Any]) -> Void) {
        guard let data = message[Relay.requestKey] as? Data,
              let request = try? JSONDecoder().decode(RelayRequest.self, from: data) else {
            replyHandler(Self.encode(RelayResponse(result: nil, error: "Malformed request")))
            return
        }
        Task { @MainActor in
            let response: RelayResponse
            if let store {
                response = await store.handleRelay(request)
            } else {
                do {
                    response = RelayResponse(result: try await BulbCommands.perform(request.action, host: request.host), error: nil)
                } catch {
                    response = RelayResponse(result: nil, error: error.localizedDescription)
                }
            }
            replyHandler(Self.encode(response))
        }
    }
}
