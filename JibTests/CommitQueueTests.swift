import Foundation
import Testing
@testable import Jib

/// A gate a test opens to let one waiting commit finish.
actor Gate {
    private var waiters: [CheckedContinuation<Void, Never>] = []
    private var openings = 0

    var waiting: Int { waiters.count }

    func wait() async {
        if openings > 0 {
            openings -= 1
            return
        }
        await withCheckedContinuation { waiters.append($0) }
    }

    func open() {
        if waiters.isEmpty { openings += 1 } else { waiters.removeFirst().resume() }
    }
}

/// Polls until `condition` holds, so tests can wait on work that runs in its own task.
func until(_ condition: () async -> Bool, timeout: Duration = .seconds(3)) async {
    let deadline = ContinuousClock.now + timeout
    while ContinuousClock.now < deadline {
        if await condition() { return }
        try? await Task.sleep(for: .milliseconds(5))
    }
}

@MainActor
struct CommitQueueTests {
    @Test func commitInFlightIsNeverCancelledAndTheLatestValueFollows() async {
        let gate = Gate()
        var committed: [Int] = []
        var cancelledDuring: [Bool] = []
        let queue = CommitQueue<Int> { value in
            committed.append(value)
            await gate.wait()
            cancelledDuring.append(Task.isCancelled)
        }

        queue.send(1)
        await until { await gate.waiting == 1 }     // commit(1) is in flight
        queue.send(2)
        queue.send(3)                               // 2 is superseded before it is ever sent
        #expect(committed == [1])
        #expect(queue.isBusy)

        await gate.open()
        await until { await gate.waiting == 1 }     // commit(3) is in flight
        #expect(committed == [1, 3])

        await gate.open()
        await until { !queue.isBusy }
        #expect(committed == [1, 3])
        #expect(cancelledDuring == [false, false])
    }

    @Test func aValueSentWhileIdleStartsAFreshWorker() async {
        var committed: [Int] = []
        let queue = CommitQueue<Int> { committed.append($0) }
        queue.send(5)
        await until { !queue.isBusy }
        queue.send(6)
        await until { !queue.isBusy }
        #expect(committed == [5, 6])
    }
}
