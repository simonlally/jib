import Foundation

/// Feeds values to an asynchronous commit one at a time. A commit that has started is never
/// cancelled; when it finishes, the newest value that arrived meanwhile is committed next, and any
/// values that arrived in between are dropped. The sliders use it so a bulb never has more than one
/// request from a slider in flight and always ends up on the last value.
@MainActor
final class CommitQueue<Value> {
    private let commit: (Value) async -> Void
    private var queued: Value?
    private var worker: Task<Void, Never>?

    init(commit: @escaping (Value) async -> Void) {
        self.commit = commit
    }

    /// Whether a commit is running.
    var isBusy: Bool { worker != nil }

    func send(_ value: Value) {
        queued = value
        guard worker == nil else { return }
        worker = Task { [weak self] in
            while let self, let next = self.take() {
                await self.commit(next)
            }
            self?.worker = nil
        }
    }

    private func take() -> Value? {
        defer { queued = nil }
        return queued
    }
}
