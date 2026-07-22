import Combine
import Foundation

/// File-scoped lifecycle state for one AppModel. The task remains owned until it actually exits; cancelling
/// it never opens a window where a second migration can start against the same persisted offset.
@MainActor
fileprivate final class PerformanceLifecycleEntry {
    weak var model: AppModel?
    var active = false
    var migrationTask: Task<Void, Never>?
    var cancelRequested = false
    var restartWhenFinished = false

    init(model: AppModel) {
        self.model = model
    }
}

@MainActor
private enum PerformanceLifecycleRegistry {
    private static var entries: [ObjectIdentifier: PerformanceLifecycleEntry] = [:]

    static func entry(for model: AppModel) -> PerformanceLifecycleEntry {
        entries = entries.filter { $0.value.model != nil }
        let key = ObjectIdentifier(model)
        if let existing = entries[key] { return existing }
        let created = PerformanceLifecycleEntry(model: model)
        entries[key] = created
        return created
    }
}

extension AppModel {
    private enum PerformanceMigrationError: LocalizedError {
        case analysisBusy
        case analysisDidNotStart

        var errorDescription: String? {
            switch self {
            case .analysisBusy: return "another analysis pass is active"
            case .analysisDidNotStart: return "the analysis pass could not start"
            }
        }
    }

    private static let effortMigrationProgressKey = "intelligence.strainV2CalendarHistory.v2.progress"

    /// Owned lifecycle path for the resumable Effort migration. Backgrounding requests cancellation but keeps
    /// ownership of the old task until it exits, preventing a quick foreground transition from starting a
    /// concurrent driver at the same offset. If foreground returns while cancellation is unwinding, one restart
    /// is queued and starts only after the previous task has relinquished ownership.
    func setApplicationActiveOptimized(_ active: Bool) {
        let entry = PerformanceLifecycleRegistry.entry(for: self)
        entry.active = active
        guard active else {
            entry.cancelRequested = true
            entry.restartWhenFinished = false
            entry.migrationTask?.cancel()
            flushActiveWorkoutSnapshot()
            Task { [live] in await live.flushLogPersistence() }
            return
        }

        if entry.migrationTask != nil {
            if entry.cancelRequested { entry.restartWhenFinished = true }
            return
        }
        startPerformanceMigration(entry)
    }

    private func startPerformanceMigration(_ entry: PerformanceLifecycleEntry) {
        guard entry.active, entry.migrationTask == nil else { return }
        entry.cancelRequested = false
        entry.restartWhenFinished = false
        entry.migrationTask = Task { [weak self, weak entry] in
            guard let self, let entry else { return }
            defer {
                entry.migrationTask = nil
                entry.cancelRequested = false
                let restart = entry.active && entry.restartWhenFinished
                entry.restartWhenFinished = false
                if restart { self.startPerformanceMigration(entry) }
            }

            await repo.refreshLiveDayStrain(maxHR: Double(profile.hrMax))
            guard !Task.isCancelled else { return }

            let outcome = await HistoricalMigrationDriver.run(
                historyDays: 4_000,
                chunkDays: IntelligenceEngine.effortRescoreChunkDays,
                isCompleted: {
                    UserDefaults.standard.bool(forKey: IntelligenceEngine.effortRescoreFlagKey)
                },
                loadOffset: {
                    UserDefaults.standard.integer(forKey: IntelligenceEngine.effortRescoreOffsetKey)
                },
                saveOffset: {
                    UserDefaults.standard.set($0, forKey: IntelligenceEngine.effortRescoreOffsetKey)
                },
                markCompleted: {
                    UserDefaults.standard.set(true, forKey: IntelligenceEngine.effortRescoreFlagKey)
                },
                shouldPause: { [weak self, weak entry] in
                    guard let self, let entry else { return true }
                    return !entry.active || live.backfilling
                        || activeWorkout != nil || intelligence.computing
                },
                analyzeChunk: { [weak self] days, offset in
                    guard let self else { throw CancellationError() }
                    guard !intelligence.computing else { throw PerformanceMigrationError.analysisBusy }

                    var sawAnalysisStart = false
                    let observation = intelligence.$computing
                        .dropFirst()
                        .sink { if $0 { sawAnalysisStart = true } }
                    defer { observation.cancel() }

                    await intelligence.analyzeRecent(
                        maxDays: days,
                        startOffset: offset,
                        force: true,
                        refreshRepository: false
                    )
                    guard sawAnalysisStart, !intelligence.computing else {
                        throw PerformanceMigrationError.analysisDidNotStart
                    }
                },
                finalRefresh: { [weak self] in
                    guard let self else { return false }
                    return await repo.refresh(.fullHistoryMigration)
                },
                progress: { [weak self] completed, total in
                    UserDefaults.standard.set(completed, forKey: Self.effortMigrationProgressKey)
                    guard let self, completed == total || completed % 300 == 0 else { return }
                    live.append(log: "Effort migration progress=\(completed)/\(total)")
                }
            )

            switch outcome {
            case .chunkFailed(let offset, let message):
                live.append(log: "Effort migration paused at day offset \(offset): \(message)")
            case .finalRefreshFailed:
                live.append(log: "Effort migration data finished but final dashboard refresh failed; will retry.")
            default:
                break
            }
        }
    }
}
