import Foundation
import Testing
@testable import Jib

/// A `get_sysinfo` reply for a dimmable white bulb, on or off.
private func sampleInfo(on: Bool, brightness: Int = 50) throws -> BulbInfo {
    let light: [String: Any] = on
        ? ["on_off": 1, "mode": "normal", "hue": 0, "saturation": 0, "color_temp": 2700, "brightness": brightness]
        : ["on_off": 0, "dft_on_state": ["mode": "normal", "hue": 0, "saturation": 0, "color_temp": 2700, "brightness": brightness]]
    return try BulbInfo(sysInfo: ["alias": "Lamp", "model": "KL125(US)", "is_dimmable": 1, "is_color": 0,
                                  "is_variable_color_temp": 1, "light_state": light, "err_code": 0])
}

private func freshDefaults() -> UserDefaults {
    let name = "BulbStoreTests-\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: name)!
    defaults.removePersistentDomain(forName: name)
    return defaults
}

@MainActor
struct BulbStoreTests {
    private let bulb = Bulb(name: "Lamp", host: "10.0.0.9")

    private func makeStore(defaults: UserDefaults = freshDefaults(), runner: @escaping BulbCommandRunner) -> BulbStore {
        BulbStorage.saveBulbs([bulb], to: defaults)
        return BulbStore(defaults: defaults, runner: runner)
    }

    @Test func anOlderRequestFailingAfterANewerOneSucceededIsNotAnError() async throws {
        let gate = Gate()
        let store = makeStore { action, _ in
            switch action {
            case .status:
                return .info(try sampleInfo(on: true))
            case .brightness(10):
                await gate.wait()
                throw BulbError.timeout(lastKnown: nil)
            default:
                return .state(LightState(isOn: true, brightness: 20, colorTemp: 2700, hue: 0, saturation: 0))
            }
        }
        await store.refresh(bulb)
        #expect(store.infos[bulb.id]?.state.brightness == 50)

        let older = Task { await store.perform(.brightness(10), on: bulb) }
        await until { await gate.waiting == 1 }
        #expect(await store.perform(.brightness(20), on: bulb))
        #expect(store.infos[bulb.id]?.state.brightness == 20)

        await gate.open()
        #expect(await older.value == false)
        #expect(store.errors[bulb.id] == nil)
        #expect(store.infos[bulb.id]?.state.brightness == 20)
        #expect(!store.busy.contains(bulb.id))
    }

    @Test func aCancelledRequestIsNotAnError() async throws {
        let store = makeStore { action, _ in
            guard case .status = action else {
                // What the TCP client used to surface when its task was cancelled mid-reply.
                do { try await Task.sleep(for: .seconds(5)) } catch {
                    throw BulbError.badResponse("connection closed after 0 of 4 bytes")
                }
                return .state(LightState(isOn: true, brightness: 1, colorTemp: 2700, hue: 0, saturation: 0))
            }
            return .info(try sampleInfo(on: true))
        }
        await store.refresh(bulb)
        let request = Task { await store.perform(.brightness(10), on: bulb) }
        await until { store.busy.contains(bulb.id) }
        request.cancel()
        #expect(await request.value == false)
        #expect(store.errors[bulb.id] == nil)
        #expect(!store.busy.contains(bulb.id))
        #expect(store.infos[bulb.id]?.state.brightness == 50)
    }

    @Test func theLatestRequestFailingIsAnError() async throws {
        let store = makeStore { action, _ in
            guard case .status = action else { throw BulbError.timeout(lastKnown: "receiving") }
            return .info(try sampleInfo(on: true))
        }
        await store.refresh(bulb)
        #expect(await store.perform(.brightness(10), on: bulb) == false)
        #expect(store.errors[bulb.id]?.contains("Timed out") == true)
        await store.refresh(bulb)
        #expect(store.errors[bulb.id] == nil)
    }

    @Test func aChangeTheExtensionAlreadyStoredStillReachesTheWatch() async throws {
        let defaults = freshDefaults()
        let on = LightState(isOn: true, brightness: 50, colorTemp: 2700, hue: 0, saturation: 0)
        // The phone last told the watch the bulb was on …
        defaults.set(try JSONEncoder().encode([bulb.id: on]), forKey: BulbStore.sharedKey)
        // … then the Control Center extension switched it off and wrote that to the shared store.
        BulbStorage.setState(try sampleInfo(on: false).state, for: bulb.id, in: defaults)

        var pushes: [(states: [UUID: LightState], powerChanged: Bool)] = []
        let store = makeStore(defaults: defaults) { _, _ in .info(try sampleInfo(on: false)) }
        store.onStateChanged = { states, powerChanged in pushes.append((states, powerChanged)) }

        await store.refresh(bulb)
        #expect(pushes.count == 1)
        #expect(pushes.first?.powerChanged == true)
        #expect(pushes.first?.states[bulb.id]?.isOn == false)

        // Seeing the same state again is not news for the watch.
        await store.refresh(bulb)
        #expect(pushes.count == 1)

        // What was handed over is remembered across launches.
        let again = BulbStore(defaults: defaults) { _, _ in .info(try sampleInfo(on: false)) }
        var later = 0
        again.onStateChanged = { _, _ in later += 1 }
        await again.refresh(bulb)
        #expect(later == 0)
    }
}
