import Foundation
import Network

/// Which googlevideo nodes answer on the current network (D39). On the developer's home Wi-Fi every
/// node of the ISP's cache cluster refused connections while the URLs' alternate nodes served; on
/// cellular the same cluster worked. So dead nodes and clusters are remembered per network, and a
/// URL whose node is in a dead cluster tries its alternates first.
public actor MediaHostBook {
    public static let shared = MediaHostBook()

    public struct Candidate: Sendable, Equatable {
        public let url: URL
        /// `sn-…` node name, nil for a host that isn't a googlevideo cache node.
        public let node: String?
        /// The node has answered on this network: use the normal timeout.
        public let proven: Bool
    }

    private var network = ""
    private var dead: Set<String> = []
    private var alive: Set<String> = []

    public init() {}

    /// The URL's own host first, then its alternate nodes from `mn` (same replica prefix, then the
    /// `fvip` replica); a dead node is skipped, and a node of a dead cluster goes after the others.
    public func candidates(for url: URL, network signature: String) -> [Candidate] {
        reset(ifChangedTo: signature)
        guard let parsed = Self.parse(url) else { return [Candidate(url: url, node: nil, proven: true)] }
        var nodes = [parsed.node] + parsed.alternates.filter { $0 != parsed.node }
        nodes.removeAll { dead.contains($0) }
        let deadClusters = Set(dead.map(Self.cluster))
        let (suspect, fine) = nodes.reduce(into: ([String](), [String]())) { result, node in
            if deadClusters.contains(Self.cluster(node)) && !alive.contains(node) { result.0.append(node) } else { result.1.append(node) }
        }
        // Nodes that answered on this network go first (stable for the rest).
        let ordered = fine.filter { alive.contains($0) } + fine.filter { !alive.contains($0) } + suspect
        var result: [Candidate] = []
        for node in ordered {
            for replica in node == parsed.node ? [parsed.replica] : [parsed.replica, parsed.fallbackReplica].compactMap({ $0 }) {
                guard var parts = URLComponents(url: url, resolvingAgainstBaseURL: false) else { continue }
                parts.host = "\(replica)---\(node).googlevideo.com"
                if let candidate = parts.url, !result.contains(where: { $0.url == candidate }) {
                    result.append(Candidate(url: candidate, node: node, proven: alive.contains(node)))
                }
            }
        }
        // Everything known dead: try the URL as given rather than nothing.
        return result.isEmpty ? [Candidate(url: url, node: parsed.node, proven: false)] : result
    }

    public func markDead(_ node: String?, network signature: String) {
        reset(ifChangedTo: signature)
        guard let node, !alive.contains(node) else { return }
        dead.insert(node)
    }

    public func markAlive(_ node: String?, network signature: String) {
        reset(ifChangedTo: signature)
        guard let node else { return }
        alive.insert(node)
        dead.remove(node)
    }

    public func isDead(_ node: String) -> Bool { dead.contains(node) }

    private func reset(ifChangedTo signature: String) {
        guard signature != network else { return }
        network = signature
        dead.removeAll()
        alive.removeAll()
    }

    struct Parsed: Equatable {
        let replica: String          // rr5
        let node: String             // sn-abc1de-5hhs
        let alternates: [String]     // from mn
        let fallbackReplica: String? // r<fvip>
    }

    static func parse(_ url: URL) -> Parsed? {
        guard let host = url.host, host.hasSuffix(".googlevideo.com"), let separator = host.range(of: "---") else { return nil }
        let replica = String(host[..<separator.lowerBound])
        let node = String(host[separator.upperBound...].prefix { $0 != "." })
        guard node.hasPrefix("sn-") else { return nil }
        let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
        let alternates = (items.first { $0.name == "mn" }?.value ?? "").split(separator: ",").map(String.init)
        let fvip = items.first { $0.name == "fvip" }?.value
        return Parsed(replica: replica, node: node, alternates: alternates, fallbackReplica: fvip.map { "r\($0)" })
    }

    /// `sn-<cluster>-<node>` -> `sn-<cluster>`; a node without a second part is its own cluster.
    static func cluster(_ node: String) -> String {
        let parts = node.split(separator: "-")
        return parts.count >= 3 ? parts.prefix(2).joined(separator: "-") : node
    }
}

/// What the fetcher needs to know about the network.
public protocol NetworkWaiting: Sendable {
    /// Changes when the device moves to another network (the host book starts over).
    func signature() async -> String
    /// Returns once a path is usable (immediately when it already is).
    func waitUntilSatisfied() async
}

/// `NWPathMonitor` behind `NetworkWaiting` (PRD §4.4: resume after Wi-Fi ↔ cellular changes).
public actor NetworkWatcher: NetworkWaiting {
    public static let shared = NetworkWatcher()

    private let monitor = NWPathMonitor()
    private var satisfied = true
    private var current = "unknown"
    private var waiters: [CheckedContinuation<Void, Never>] = []
    private var firstPathWaiters: [CheckedContinuation<Void, Never>] = []
    private var received = false
    private var started = false

    public init() {}

    /// The first path arrives right after the monitor starts; answering "unknown" before it would
    /// make the host book treat that first path as a network change and forget what it learned.
    public func signature() async -> String {
        startIfNeeded()
        if !received {
            await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                firstPathWaiters.append(continuation)
                Task {
                    try? await Task.sleep(for: .milliseconds(500))
                    self.releaseFirstPathWaiters()
                }
            }
        }
        return current
    }

    private func releaseFirstPathWaiters() {
        let waiting = firstPathWaiters
        firstPathWaiters.removeAll()
        waiting.forEach { $0.resume() }
    }

    public func waitUntilSatisfied() async {
        startIfNeeded()
        if satisfied { return }
        await withCheckedContinuation { waiters.append($0) }
    }

    private func startIfNeeded() {
        guard !started else { return }
        started = true
        monitor.pathUpdateHandler = { [weak self] path in
            let usable = path.status == .satisfied
            let interfaces = path.availableInterfaces.map { "\($0.type)-\($0.name)" }.joined(separator: ",")
            Task { await self?.update(satisfied: usable, signature: interfaces) }
        }
        monitor.start(queue: DispatchQueue(label: "MediaPipeline.NetworkWatcher"))
    }

    private func update(satisfied: Bool, signature: String) {
        self.satisfied = satisfied
        current = signature
        received = true
        releaseFirstPathWaiters()
        guard satisfied else { return }
        let ready = waiters
        waiters.removeAll()
        ready.forEach { $0.resume() }
    }
}
