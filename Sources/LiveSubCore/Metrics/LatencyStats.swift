import Foundation

/// Rolling latency percentiles per pipeline stage. Thread-safe.
public final class LatencyStats: @unchecked Sendable {
    private let lock = NSLock()
    private var samples: [String: [Double]] = [:]
    private var order: [String] = []
    private let window: Int

    public init(window: Int = 500) { self.window = window }

    public func record(_ stage: String, ms: Double) {
        lock.lock(); defer { lock.unlock() }
        if samples[stage] == nil { order.append(stage) }
        samples[stage, default: []].append(ms)
        if samples[stage]!.count > window { samples[stage]!.removeFirst(samples[stage]!.count - window) }
    }

    public struct Summary: Sendable {
        public let stage: String
        public let count: Int
        public let p50: Double
        public let p95: Double
        public let max: Double
    }

    public func summaries() -> [Summary] {
        lock.lock(); defer { lock.unlock() }
        return order.compactMap { stage in
            guard let values = samples[stage], !values.isEmpty else { return nil }
            let sorted = values.sorted()
            return Summary(stage: stage, count: sorted.count,
                           p50: Self.percentile(sorted, 0.5), p95: Self.percentile(sorted, 0.95), max: sorted.last!)
        }
    }

    public func report() -> String {
        summaries().map { s in
            String(format: "%@ p50 %.1f ms, p95 %.1f ms, max %.1f ms (n=%d)", s.stage, s.p50, s.p95, s.max, s.count)
        }.joined(separator: "\n")
    }

    /// Nearest-rank percentile on a sorted array.
    public static func percentile(_ sorted: [Double], _ p: Double) -> Double {
        guard !sorted.isEmpty else { return .nan }
        let rank = Int((p * Double(sorted.count)).rounded(.up)) - 1
        return sorted[min(max(rank, 0), sorted.count - 1)]
    }
}

public enum Log {
    nonisolated(unsafe) public static var verbose = false
    public static func info(_ s: String) { FileHandle.standardError.write(Data("[livesub] \(s)\n".utf8)) }
    public static func warn(_ s: String) { FileHandle.standardError.write(Data("[livesub] warning: \(s)\n".utf8)) }
    public static func debug(_ s: String) { if verbose { info(s) } }
}
