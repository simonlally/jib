import Foundation
import Network

enum BulbError: LocalizedError, Sendable {
    case invalidHost(String)
    case connection(String)
    case timeout(lastKnown: String?)
    case badResponse(String)
    case device(code: Int, message: String)

    var errorDescription: String? {
        switch self {
        case .invalidHost(let host):
            return "“\(host)” is not a valid address."
        case .connection(let message):
            return "Couldn’t connect: \(message)"
        case .timeout(let lastKnown):
            if let lastKnown { return "Timed out while \(lastKnown). Check the bulb is powered and Local Network access is allowed in Settings." }
            return "The bulb didn’t answer in time."
        case .badResponse(let message):
            return "Unexpected reply from bulb: \(message)"
        case .device(let code, let message):
            return "Bulb refused the command (\(code): \(message))"
        }
    }
}

/// One request/response round trip over the bulbs’ local TCP protocol (port 9999).
/// Frame format in both directions: 4-byte big-endian length, then autokey-XOR'd JSON.
enum BulbClient {
    static let port: NWEndpoint.Port = 9999

    /// - Parameters:
    ///   - timeout: Bound for the whole exchange. Bulbs waking from Wi‑Fi power save can take a few
    ///     seconds to answer their first request, so keep this generous.
    ///   - connectTimeout: Shorter bound for the TCP handshake alone, so sweeps give up quickly on
    ///     addresses where nothing lives. Defaults to `timeout`.
    static func send(_ command: [String: Any], to host: String, timeout: TimeInterval = 6,
                     connectTimeout: TimeInterval? = nil) async throws -> [String: Any] {
        // The demo bulb lives inside the app and answers here; nothing below runs for it.
        if DemoBulb.isHost(host) { return DemoBulb.reply(to: command) }

        let body = try JSONSerialization.data(withJSONObject: command)
        let encrypted = FrameCipher.encrypt(body)
        var frame = Data(capacity: 4 + encrypted.count)
        frame.append(UInt32(encrypted.count).bigEndianBytes)
        frame.append(encrypted)

        let session = try TCPSession(host: host, port: port, timeout: timeout,
                                     connectTimeout: min(connectTimeout ?? timeout, timeout))
        defer { session.cancel() }
        do {
            try await session.connect()
            try await session.send(frame)
            let header = try await session.receive(exactly: 4)
            let length = Int(UInt32(bigEndianBytes: header))
            guard length > 0, length < 1_000_000 else { throw BulbError.badResponse("bad frame length \(length)") }
            let payload = try await session.receive(exactly: length)
            let json = try JSONSerialization.jsonObject(with: FrameCipher.decrypt(payload))
            guard let dict = json as? [String: Any] else { throw BulbError.badResponse("not a JSON object") }
            return dict
        } catch {
            // Cancelling the task tears the connection down, which the callbacks report as a closed
            // or failed connection. Report the cancellation itself so callers can stay quiet about it.
            if Task.isCancelled { throw CancellationError() }
            throw error
        }
    }
}

/// Minimal async wrapper around NWConnection with a hard deadline for the whole exchange.
final class TCPSession: @unchecked Sendable {
    /// How many sessions have been opened in this process. Tests use it to prove a path never
    /// reached the network.
    static let opened = SessionCounter()

    private let connection: NWConnection
    private let queue = DispatchQueue(label: "dev.simonlally.jib.tcp")
    private let lock = NSLock()
    private var timedOut = false
    private var finished = false
    private var lastWaitingReason: String?
    private var phase = "connecting"

    init(host: String, port: NWEndpoint.Port, timeout: TimeInterval, connectTimeout: TimeInterval) throws {
        let trimmed = host.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !trimmed.contains(" ") else { throw BulbError.invalidHost(host) }

        let tcp = NWProtocolTCP.Options()
        tcp.connectionTimeout = max(1, Int(connectTimeout.rounded(.up)))
        tcp.noDelay = true
        let parameters = NWParameters(tls: nil, tcp: tcp)
        parameters.preferNoProxies = true
        connection = NWConnection(host: NWEndpoint.Host(trimmed), port: port, using: parameters)
        Self.opened.increment()

        // Two deadlines: give up fast if the handshake stalls, but allow a slow first reply.
        queue.asyncAfter(deadline: .now() + connectTimeout) { [weak self] in
            self?.expire(onlyIfStillConnecting: true)
        }
        queue.asyncAfter(deadline: .now() + timeout) { [weak self] in
            self?.expire(onlyIfStillConnecting: false)
        }
    }

    private func expire(onlyIfStillConnecting: Bool) {
        let shouldCancel: Bool = lock.withLock {
            guard !finished, !timedOut else { return false }
            if onlyIfStillConnecting && phase != "connecting" { return false }
            timedOut = true
            return true
        }
        if shouldCancel { connection.cancel() }
    }

    func connect() async throws {
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                let once = Once(continuation)
                connection.stateUpdateHandler = { [weak self] state in
                    guard let self else { return }
                    switch state {
                    case .ready:
                        once.resume(.success(()))
                    case .waiting(let error):
                        // Usually a transient "no route" while Wi‑Fi / Local Network permission settles.
                        // Give up immediately only when there is no network at all.
                        self.lock.withLock { self.lastWaitingReason = error.localizedDescription }
                        if case .posix(let code) = error,
                           code == .ENETDOWN || code == .ENETUNREACH || code == .ECONNREFUSED {
                            once.resume(.failure(BulbError.connection(error.localizedDescription)))
                            self.connection.cancel()
                        }
                    case .failed(let error):
                        once.resume(.failure(self.terminalError(error)))
                    case .cancelled:
                        once.resume(.failure(self.terminalError(nil)))
                    default:
                        break
                    }
                }
                connection.start(queue: queue)
            }
        } onCancel: {
            connection.cancel()
        }
    }

    func send(_ data: Data) async throws {
        lock.withLock { phase = "sending" }
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                let once = Once(continuation)
                connection.send(content: data, completion: .contentProcessed { [weak self] error in
                    if let error {
                        once.resume(.failure(self?.terminalError(error) ?? BulbError.connection(error.localizedDescription)))
                    } else {
                        once.resume(.success(()))
                    }
                })
            }
        } onCancel: {
            connection.cancel()
        }
    }

    func receive(exactly count: Int) async throws -> Data {
        lock.withLock { phase = "receiving" }
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Data, Error>) in
                let once = Once(continuation)
                connection.receive(minimumIncompleteLength: count, maximumLength: count) { [weak self] data, _, _, error in
                    if let data, data.count == count {
                        once.resume(.success(data))
                    } else if let self, self.lock.withLock({ self.timedOut }) {
                        once.resume(.failure(self.terminalError(error)))
                    } else if let error {
                        once.resume(.failure(self?.terminalError(error) ?? BulbError.connection(error.localizedDescription)))
                    } else {
                        once.resume(.failure(BulbError.badResponse("connection closed after \(data?.count ?? 0) of \(count) bytes")))
                    }
                }
            }
        } onCancel: {
            connection.cancel()
        }
    }

    func cancel() {
        lock.withLock { finished = true }
        connection.cancel()
    }

    private func terminalError(_ error: NWError?) -> BulbError {
        let (didTimeOut, reason, phase) = lock.withLock { (timedOut, lastWaitingReason, phase) }
        if didTimeOut { return .timeout(lastKnown: reason.map { "\(phase): \($0)" } ?? phase) }
        return .connection(error?.localizedDescription ?? reason ?? "cancelled")
    }
}

final class SessionCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0

    var value: Int { lock.withLock { count } }
    func increment() { lock.withLock { count += 1 } }
}

/// Resumes a continuation at most once, no matter how many callbacks fire.
private final class Once<T>: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<T, Error>?

    init(_ continuation: CheckedContinuation<T, Error>) { self.continuation = continuation }

    func resume(_ result: Result<T, Error>) {
        lock.lock()
        let pending = continuation
        continuation = nil
        lock.unlock()
        pending?.resume(with: result)
    }
}

extension UInt32 {
    var bigEndianBytes: Data { withUnsafeBytes(of: bigEndian) { Data($0) } }

    init(bigEndianBytes data: Data) {
        self = data.prefix(4).reduce(0) { ($0 << 8) | UInt32($1) }
    }
}
