import Foundation

/// The app owns one IntelligenceEngine, but tests/previews may create more. Keep one coordinator per live
/// engine identity so unrelated instances do not serialize each other while every caller of one engine shares
/// the same admission queue. Weak entries are pruned on access; previews/tests cannot leak coordinators for
/// engines that have already been released. MainActor isolation makes the registry race-free.
@MainActor
private enum IntelligenceAnalysisCoordinatorRegistry {
    private final class Entry {
        weak var engine: IntelligenceEngine?
        let coordinator = IntelligenceAnalysisCoordinator()

        init(engine: IntelligenceEngine) {
            self.engine = engine
        }
    }

    private static var entries: [ObjectIdentifier: Entry] = [:]

    static func coordinator(for engine: IntelligenceEngine) -> IntelligenceAnalysisCoordinator {
        entries = entries.filter { $0.value.engine != nil }
        let key = ObjectIdentifier(engine)
        if let existing = entries[key], existing.engine === engine {
            return existing.coordinator
        }
        let created = Entry(engine: engine)
        entries[key] = created
        return created.coordinator
    }
}

extension IntelligenceEngine {
    /// A queued forced request represents durable source change and must survive cancellation of the UI task
    /// that happened to request it. DispatchQueue's deadline is cancellation-insensitive, unlike Task.sleep;
    /// use it while waiting for the legacy in-engine lock or an active historical writer to clear.
    private static func waitForAnalysisPoll() async {
        await withCheckedContinuation { continuation in
            DispatchQueue.main.asyncAfter(deadline: .now() + .milliseconds(20)) {
                continuation.resume()
            }
        }
    }

    /// The four-argument declaration in `IntelligenceEngine.swift` remains the implementation entry point.
    /// Every production call using one or more defaults resolves to an exact overload below and therefore
    /// enters the completion-aware coordinator. The repository source audit forbids direct full-signature
    /// calls anywhere except this wrapper.
    private func runAdmittedAnalysis(
        maxDays: Int,
        startOffset: Int,
        force: Bool,
        refreshRepository: Bool
    ) async {
        let request = IntelligenceAnalysisRequest(
            maxDays: maxDays,
            startOffset: startOffset,
            force: force,
            refreshRepository: refreshRepository)
        let coordinator = IntelligenceAnalysisCoordinatorRegistry.coordinator(for: self)

        await coordinator.submit(request) { [weak self] admitted in
            guard let self else { return }

            // Defensive compatibility with the original implementation's internal `computing` lock. Normal
            // production calls are serialized by the coordinator, but a direct legacy/full-signature call or
            // an in-engine re-arm task may already own the old lock. Forced work waits instead of returning;
            // a disposable cadence request still drops. Once forced work is queued it ignores caller-task
            // cancellation—the durable source change still needs to be scored and published.
            while self.computing {
                guard admitted.force else { return }
                await Self.waitForAnalysisPoll()
            }
            guard admitted.force || !Task.isCancelled else { return }

            // Preserve the exact admitted batch. A current-day request can no longer be substituted by the
            // historical chunk that happened to be active when it arrived.
            await self.analyzeRecent(
                maxDays: admitted.maxDays,
                startOffset: admitted.startOffset,
                force: admitted.force,
                refreshRepository: admitted.refreshRepository)
        }
    }

    /// AppModel's post-backfill path intentionally asks analysis not to publish Repository itself; it performs
    /// one explicit cache publication immediately after this call. The old implementation could finish a pass
    /// while another offload slice had already started—or while a newer durable-data edge had arrived—and then
    /// publish a final-looking blank Recovery state from the older generation. Hold this call until one exact
    /// current-day pass begins and ends with the same quiescent generation. If data advances during analysis,
    /// rerun before returning. Forced source work deliberately survives caller cancellation.
    private func runStablePostBackfillAnalysis() async {
        guard let live = AppModel.shared?.live else {
            await runAdmittedAnalysis(
                maxDays: 21, startOffset: 0, force: true, refreshRepository: false)
            return
        }

        while true {
            let before = BackfillAnalysisSnapshot(
                dataAvailableAt: live.backfillDataAvailableAt,
                backfilling: live.backfilling)
            if before.backfilling {
                await Self.waitForAnalysisPoll()
                continue
            }

            await runAdmittedAnalysis(
                maxDays: 21, startOffset: 0, force: true, refreshRepository: false)

            let after = BackfillAnalysisSnapshot(
                dataAvailableAt: live.backfillDataAvailableAt,
                backfilling: live.backfilling)
            if after.isSettledAndUnchanged(since: before) { return }
        }
    }

    func analyzeRecent() async {
        await runAdmittedAnalysis(maxDays: 21, startOffset: 0, force: true, refreshRepository: true)
    }

    func analyzeRecent(maxDays: Int) async {
        await runAdmittedAnalysis(maxDays: maxDays, startOffset: 0, force: true, refreshRepository: true)
    }

    func analyzeRecent(startOffset: Int) async {
        await runAdmittedAnalysis(maxDays: 21, startOffset: startOffset, force: true, refreshRepository: true)
    }

    func analyzeRecent(force: Bool) async {
        await runAdmittedAnalysis(maxDays: 21, startOffset: 0, force: force, refreshRepository: true)
    }

    func analyzeRecent(refreshRepository: Bool) async {
        if refreshRepository {
            await runAdmittedAnalysis(maxDays: 21, startOffset: 0, force: true,
                                      refreshRepository: true)
        } else {
            await runStablePostBackfillAnalysis()
        }
    }

    func analyzeRecent(maxDays: Int, startOffset: Int) async {
        await runAdmittedAnalysis(maxDays: maxDays, startOffset: startOffset, force: true,
                                  refreshRepository: true)
    }

    func analyzeRecent(maxDays: Int, force: Bool) async {
        await runAdmittedAnalysis(maxDays: maxDays, startOffset: 0, force: force,
                                  refreshRepository: true)
    }

    func analyzeRecent(maxDays: Int, refreshRepository: Bool) async {
        await runAdmittedAnalysis(maxDays: maxDays, startOffset: 0, force: true,
                                  refreshRepository: refreshRepository)
    }

    func analyzeRecent(startOffset: Int, force: Bool) async {
        await runAdmittedAnalysis(maxDays: 21, startOffset: startOffset, force: force,
                                  refreshRepository: true)
    }

    func analyzeRecent(startOffset: Int, refreshRepository: Bool) async {
        await runAdmittedAnalysis(maxDays: 21, startOffset: startOffset, force: true,
                                  refreshRepository: refreshRepository)
    }

    func analyzeRecent(force: Bool, refreshRepository: Bool) async {
        await runAdmittedAnalysis(maxDays: 21, startOffset: 0, force: force,
                                  refreshRepository: refreshRepository)
    }

    func analyzeRecent(maxDays: Int, startOffset: Int, force: Bool) async {
        await runAdmittedAnalysis(maxDays: maxDays, startOffset: startOffset, force: force,
                                  refreshRepository: true)
    }

    func analyzeRecent(maxDays: Int, startOffset: Int, refreshRepository: Bool) async {
        await runAdmittedAnalysis(maxDays: maxDays, startOffset: startOffset, force: true,
                                  refreshRepository: refreshRepository)
    }

    func analyzeRecent(maxDays: Int, force: Bool, refreshRepository: Bool) async {
        await runAdmittedAnalysis(maxDays: maxDays, startOffset: 0, force: force,
                                  refreshRepository: refreshRepository)
    }

    func analyzeRecent(startOffset: Int, force: Bool, refreshRepository: Bool) async {
        await runAdmittedAnalysis(maxDays: 21, startOffset: startOffset, force: force,
                                  refreshRepository: refreshRepository)
    }
}
