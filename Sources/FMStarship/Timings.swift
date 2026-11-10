import Foundation

/// How long things took, for finding where the time goes. The app writes it to app.log, beside the plugin's log; inside
/// FM the plugin sends it to plugin.log instead.
package enum AppLog {
    package static var write: (String) -> Void = toFile

    private static let queue = DispatchQueue(label: "FMStarship.AppLog")
    private static let file: URL = {
        let folder = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Logs/FM Starship", isDirectory: true)
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        return folder.appendingPathComponent("app.log")
    }()

    private static func toFile(_ line: String) {
        let stamped = "\(Date().formatted(.iso8601)) \(line)\n"
        queue.async {
            guard let data = stamped.data(using: .utf8) else { return }
            if let handle = try? FileHandle(forWritingTo: file) {
                handle.seekToEndOfFile()
                handle.write(data)
                try? handle.close()
            } else {
                try? data.write(to: file)
            }
        }
    }
}

/// The average and worst time of something run on a timer. Inside FM those timers run on FM's main thread, so what
/// they cost, the game's frames wait for.
@MainActor
package final class TimerCost {
    private var runs = 0
    private var total = 0.0
    private var worst = 0.0

    package init() {}

    package func measure(_ body: () -> Void) {
        let started = Date()
        body()
        add(Date().timeIntervalSince(started))
    }

    func add(_ seconds: Double) {
        runs += 1
        total += seconds
        worst = max(worst, seconds)
    }

    /// What it cost since the last time this was asked, and starts again. Nil if it hasn't run since.
    package func take() -> String? {
        defer { (runs, total, worst) = (0, 0, 0) }
        guard runs > 0 else { return nil }
        return String(format: "%d runs, average %.2f ms, worst %.2f ms", runs, total / Double(runs) * 1000, worst * 1000)
    }
}
