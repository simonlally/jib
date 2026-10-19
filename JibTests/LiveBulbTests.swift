import Foundation
import Testing
@testable import Jib

/// Opt-in check against a real bulb on your network. Skipped unless a host is supplied:
///   TEST_RUNNER_TEST_BULB_HOST=192.168.1.23 xcodebuild test -scheme Jib -only-testing:JibTests/LiveBulbTests ...
struct LiveBulbTests {
    private static var host: String? { ProcessInfo.processInfo.environment["TEST_BULB_HOST"] }

    @Test(.enabled(if: host != nil))
    func readsSysInfoThreeTimes() async throws {
        let host = try #require(Self.host)
        for attempt in 1...3 {
            let started = Date()
            do {
                let info = try await BulbCommands.sysInfo(host: host, timeout: 5)
                print("LIVE attempt \(attempt): \(info.model) on=\(info.state.isOn) in \(Int(Date().timeIntervalSince(started) * 1000))ms")
                #expect(!info.model.isEmpty)
            } catch {
                print("LIVE attempt \(attempt): FAILED after \(Int(Date().timeIntervalSince(started) * 1000))ms: \(error.localizedDescription)")
                throw error
            }
            try await Task.sleep(for: .milliseconds(300))
        }
    }
}
