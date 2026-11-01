import Foundation
import os

struct DiscoveredBulb: Identifiable, Hashable, Sendable {
    let host: String
    let info: BulbInfo

    var id: String { host }
    var lastOctet: Int { Int(host.split(separator: ".").last ?? "") ?? 0 }
}

enum ScanEvent: Sendable {
    case progress(scanned: Int, total: Int)
    case found(DiscoveredBulb)
}

/// Finds bulbs by probing every host on a /24 subnet. The bulbs’ native discovery uses UDP broadcast,
/// which iOS reserves for apps holding the multicast entitlement, so a TCP sweep is used instead.
enum BulbDiscovery {
    static let hostCount = 254

    /// `connectTimeout` bounds the handshake (most addresses are empty and never answer);
    /// `timeout` bounds the full exchange so a bulb waking from power save still gets counted.
    static func scan(prefix: String, concurrency: Int = 32, connectTimeout: TimeInterval = 1.5,
                     timeout: TimeInterval = 6) -> AsyncStream<ScanEvent> {
        AsyncStream { continuation in
            let task = Task {
                await withTaskGroup(of: DiscoveredBulb?.self) { group in
                    var next = 1
                    while next <= min(concurrency, hostCount) {
                        let host = "\(prefix).\(next)"
                        group.addTask { await probe(host, connectTimeout: connectTimeout, timeout: timeout) }
                        next += 1
                    }
                    var scanned = 0
                    for await result in group {
                        scanned += 1
                        if let found = result { continuation.yield(.found(found)) }
                        continuation.yield(.progress(scanned: scanned, total: hostCount))
                        if Task.isCancelled { break }
                        if next <= hostCount {
                            let host = "\(prefix).\(next)"
                            group.addTask { await probe(host, connectTimeout: connectTimeout, timeout: timeout) }
                            next += 1
                        }
                    }
                }
                continuation.finish()
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    private static let log = Logger(subsystem: "dev.simonlally.jib", category: "discovery")

    private static func probe(_ host: String, connectTimeout: TimeInterval, timeout: TimeInterval) async -> DiscoveredBulb? {
        do {
            let info = try await BulbCommands.sysInfo(host: host, timeout: timeout, connectTimeout: connectTimeout)
            return DiscoveredBulb(host: host, info: info)
        } catch {
            log.debug("probe \(host, privacy: .private): \(error.localizedDescription, privacy: .private)")
            return nil
        }
    }

    static func isValidPrefix(_ prefix: String) -> Bool {
        let parts = prefix.split(separator: ".", omittingEmptySubsequences: false)
        return parts.count == 3 && parts.allSatisfy { Int($0).map { (0...255).contains($0) } ?? false }
    }

    /// First three octets of this device's Wi‑Fi address, e.g. "192.168.1". `nil` when the device
    /// isn't on Wi‑Fi: a sweep over a cellular or VPN subnet would never find a bulb.
    static func localSubnetPrefix() -> String? {
        guard let address = localIPv4Address() else { return nil }
        let parts = address.split(separator: ".")
        guard parts.count == 4 else { return nil }
        return parts.prefix(3).joined(separator: ".")
    }

    static func localIPv4Address() -> String? {
        var head: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&head) == 0, let first = head else { return nil }
        defer { freeifaddrs(head) }

        var candidates: [(interface: String, address: String)] = []
        for pointer in sequence(first: first, next: { $0.pointee.ifa_next }) {
            let entry = pointer.pointee
            guard let sockaddr = entry.ifa_addr, sockaddr.pointee.sa_family == sa_family_t(AF_INET) else { continue }
            let flags = Int32(bitPattern: entry.ifa_flags)
            guard flags & IFF_UP != 0, flags & IFF_LOOPBACK == 0 else { continue }
            var buffer = [CChar](repeating: 0, count: Int(NI_MAXHOST))
            guard getnameinfo(sockaddr, socklen_t(sockaddr.pointee.sa_len), &buffer, socklen_t(buffer.count),
                              nil, 0, NI_NUMERICHOST) == 0 else { continue }
            let address = String(cString: buffer)
            guard !address.hasPrefix("169.254.") else { continue }
            candidates.append((String(cString: entry.ifa_name), address))
        }
        return preferredAddress(among: candidates)
    }

    /// The Wi‑Fi address among a device's interfaces: `en0` first, then any other `en` interface.
    /// Cellular (`pdp_ip*`), VPN (`utun*`) and bridge interfaces are never swept.
    static func preferredAddress(among candidates: [(interface: String, address: String)]) -> String? {
        candidates.filter { $0.interface.hasPrefix("en") }
            .min { rank($0.interface) < rank($1.interface) }?.address
    }

    private static func rank(_ interface: String) -> Int {
        interface == "en0" ? 0 : 1          // en0 is Wi‑Fi on iPhone and most Macs
    }
}
