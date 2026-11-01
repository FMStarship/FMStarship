import Foundation
@preconcurrency import StarshipAnalysis
import SwiftUI

/// Cancellation that works on every thread. `Task.isCancelled` only answers on the thread running the task,
/// and the checks run on several at once.
final class CancelToken: @unchecked Sendable {
    private let lock = NSLock()
    private var cancelled = false

    var isCancelled: Bool {
        lock.lock()
        defer { lock.unlock() }
        return cancelled
    }

    func cancel() {
        lock.lock()
        cancelled = true
        lock.unlock()
    }
}

/// One long piece of work behind a screen. Starting it again abandons the run before it, so a screen only ever
/// shows the newest answer. The work runs on a dispatch queue because it blocks for seconds.
@MainActor
final class BackgroundJob<Output>: ObservableObject {
    @Published private(set) var output: Output?
    /// Goes up with every new output, which is how tables know to reload.
    @Published private(set) var version = 0
    @Published private(set) var running = false
    @Published private(set) var progress = ""

    private var token: CancelToken?

    func run(_ initial: String,
             work: @escaping @Sendable (CancelToken, @escaping @Sendable (String) -> Void) -> Output?,
             done: @escaping (Output) -> Void = { _ in }) {
        token?.cancel()
        let token = CancelToken()
        self.token = token
        running = true
        progress = initial

        let report: @Sendable (String) -> Void = { [weak self] text in
            Task { @MainActor [weak self] in
                guard let self, self.token === token else { return }
                self.progress = text
            }
        }
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let result = work(token, report)
            Task { @MainActor [weak self] in
                guard let self, self.token === token else { return }
                self.running = false
                self.progress = ""
                guard let result, !token.isCancelled else { return }
                self.output = result
                self.version += 1
                done(result)
            }
        }
    }

    func cancel() {
        token?.cancel()
        token = nil
        running = false
        progress = ""
    }
}

/// The screens that come down to one `AnalysisTable`.
typealias Report = BackgroundJob<AnalysisTable>

/// Runs blocking work off the main thread and returns the answer to the caller.
func offMain<T>(_ work: @escaping @Sendable () -> T) async -> T {
    await withCheckedContinuation { continuation in
        DispatchQueue.global(qos: .userInitiated).async { continuation.resume(returning: work()) }
    }
}

/// The visible progress and the cancel that every long job gets.
struct JobOverlay<Output>: View {
    @ObservedObject var job: BackgroundJob<Output>

    var body: some View {
        if job.running {
            ProgressCard(text: job.progress, onCancel: { job.cancel() })
        }
    }
}

/// Sits at the foot of the screen rather than over the rows it's working on.
struct ProgressCard: View {
    @Environment(\.appColors) private var colors
    let text: String
    let onCancel: (() -> Void)?

    var body: some View {
        HStack(spacing: 12) {
            ProgressView().controlSize(.small)
            Text(text.isEmpty ? "Working..." : text)
                .frame(maxWidth: 420, alignment: .leading)
            if let onCancel {
                Button("Cancel", action: onCancel)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .background(colors.ui.panel, in: RoundedRectangle(cornerRadius: Metric.radius))
        .overlay(RoundedRectangle(cornerRadius: Metric.radius).strokeBorder(colors.ui.line))
        .shadow(color: .black.opacity(0.25), radius: 10, y: 4)
        .padding(14)
    }
}
