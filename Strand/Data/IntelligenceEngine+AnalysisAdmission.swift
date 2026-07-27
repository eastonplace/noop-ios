import Foundation

/// One process owns one intelligence engine. Keep admission outside the engine's stored layout so this
/// release-candidate fix can wrap every existing default-argument call without changing persistence or UI state.
@MainActor
private let sharedIntelligenceAnalysisAdmission = IntelligenceAnalysisAdmission()

extension IntelligenceEngine {
    /// The four-argument declaration in `IntelligenceEngine.swift` is the implementation entry point. Every
    /// production call that uses one or more defaults resolves to one of the overloads below and therefore
    /// passes through this admission lane. Supplying all four arguments outside this file would bypass the
    /// lane and is intentionally forbidden by the source-contract test.
    private func runAdmittedAnalysis(
        maxDays: Int,
        startOffset: Int,
        force: Bool,
        refreshRepository: Bool
    ) async {
        guard await sharedIntelligenceAnalysisAdmission.acquire(force: force) else { return }
        defer { sharedIntelligenceAnalysisAdmission.release() }

        // Belt-and-braces for an already-running legacy/full-signature caller. Forced source changes wait;
        // disposable cadence work drops. Once this branch has the shared admission, no wrapped caller can
        // enter between this check and the four-argument implementation call.
        while computing {
            guard force, !Task.isCancelled else { return }
            do {
                try await Task.sleep(nanoseconds: 20_000_000)
            } catch {
                return
            }
        }
        guard !Task.isCancelled else { return }

        // Exact request preservation is the point: a post-backfill 21-day/current-window pass cannot be
        // replaced by the 30-day historical migration chunk that happened to be active when it arrived.
        await self.analyzeRecent(
            maxDays: maxDays,
            startOffset: startOffset,
            force: force,
            refreshRepository: refreshRepository)
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
