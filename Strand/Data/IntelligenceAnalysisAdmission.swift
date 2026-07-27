import Foundation

/// Serial admission for the heavy `IntelligenceEngine.analyzeRecent` pipeline.
///
/// A non-forced cadence tick is disposable when another analysis already owns the pipeline. A forced request
/// represents real source change — a completed backfill, import, edit, recalibration or heal — and therefore
/// waits for the current owner, then runs with its own exact request parameters. The old Boolean re-arm lost
/// those parameters and let its caller continue before the requested analysis had actually happened.
@MainActor
final class IntelligenceAnalysisAdmission {
    private(set) var isRunning = false
    private(set) var waitingForcedCallers = 0

    /// Returns true with ownership of the pipeline. The caller must balance it with `release()` in `defer`.
    func acquire(force: Bool) async -> Bool {
        if !isRunning {
            isRunning = true
            return true
        }
        guard force else { return false }

        waitingForcedCallers += 1
        defer { waitingForcedCallers -= 1 }
        while isRunning {
            do {
                try await Task.sleep(nanoseconds: 20_000_000)
            } catch {
                return false
            }
        }
        guard !Task.isCancelled else { return false }
        isRunning = true
        return true
    }

    func release() {
        precondition(isRunning, "analysis admission released without an owner")
        isRunning = false
    }
}
