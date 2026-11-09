import Foundation

/// How long each part of a read takes, and what it asks of the agent, for finding where a slow read spends its time.
/// It only watches: the read itself is the same with or without it.
public final class ReadClock {
    private let game: GameProcess
    private var started = Date()
    private var traffic: (requests: Int, bytes: Int)
    private var parts: [String] = []

    public init(_ game: GameProcess) {
        self.game = game
        traffic = game.agentTraffic
    }

    /// Ends one part and starts the next.
    public func lap(_ part: String) {
        let now = game.agentTraffic
        parts.append(ReadClock.describe(part, seconds: Date().timeIntervalSince(started), requests: now.requests - traffic.requests,
                                        bytes: now.bytes - traffic.bytes, throughAgent: !game.inside))
        started = Date()
        traffic = now
    }

    /// Every part so far, on one line.
    public var line: String { parts.joined(separator: "; ") }

    static func describe(_ part: String, seconds: Double, requests: Int, bytes: Int, throughAgent: Bool) -> String {
        let time = part + String(format: " %.2f s", seconds)
        guard throughAgent else { return time }
        return time + String(format: " (%d round trips, %.1f MiB)", requests, Double(bytes) / 1_048_576)
    }
}
