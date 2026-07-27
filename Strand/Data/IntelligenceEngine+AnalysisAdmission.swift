import Foundation

/// The app owns one IntelligenceEngine, but tests/previews may create more. Keep one coordinator per engine
/// identity so unrelated instances do not serialize each other while every caller of one engine shares the
/// same admission queue. MainActor isolation makes the registry race-free.
@MainActor
private enum IntelligenceAnalysisCoordinatorRegistry {
    static var coordinators: [ObjectIdentifier: IntelligenceAnalysisCoordinator] = [:]

    static func coordinator(for engine: IntelligenceEngine) -> IntelligenceAnalysisCoordinator {
        let key = ObjectIdentifier(engine)
        if let existing = coordinators[key] { return existing }
        let created = IntelligenceAnalysisCoordinator()
        coordinators[key] = created
        return created
    }
}

extension IntelligenceEngine {
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
            // a disposable cadence request still drops.
            while self.computing {
                guard admitted.force, !Task.isCancelled else { return }
                do {
                    try await Task.sleep(nanoseconds: 20_000_000)
                } catch {
                    // Cancellation of the waiting caller does not invalidate source data that already queued,
                    // but this execute closure has not begun that work yet. A later durable-data edge or cadence
                    // pass will retry; do not steal the old lock.
                    return
                }
            }
            guard !Task.isCancelled || admitted.force else { return }

            // Preserve the exact admitted batch. A current-day request can no longer be substituted by the
            // historical chunk that happened to be active when it arrived.
            await self.analyzeRecent(
                maxDays: admitted.maxDays,
                startOffset: admitted.startOffset,
                force: admitted.force,
                refreshRepository: admitted.refreshRepository)
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
        await runAdmittedAnalysis(maxDays: 21, startOffset: 0, force: true,
                                  refreshRepository: refreshRepository)
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
