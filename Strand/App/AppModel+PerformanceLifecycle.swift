import Combine
import Foundation

/// File-scoped lifecycle state for one AppModel. Keeping this type outside the private registry avoids
/// leaking a nested private type through `entry(for:)`, which Swift rejects at compile time.
@MainActor
fileprivate final class PerformanceLifecycleEntry {
    weak var model: AppModel?
    var active = false
    var migrationTask: Task<Void, Never>?

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

    /// Owned lifecycle path for the resumable Effort migration. Backgrounding cancels the current driver,
    /// flushes workout/log durability, and leaves the committed offset intact for the next foreground.
    func setApplicationActiveOptimized(_ active: Bool) {
        let entry = PerformanceLifecycleRegistry.entry(for: self)
        entry.active = active
        guard active else {
            entry.migrationTask?.cancel()
            entry.migrationTask = nil
            flushActiveWorkoutSnapshot()
            Task { [live] in await live.flushLogPersistence() }
            return
        }

        guard entry.migrationTask == nil else { return }
        entry.migrationTask = Task { [weak self, weak entry] in
            guard let self, let entry else { return }
            defer { entry.migrationTask = nil }
            await repo.refreshLiveDayStrain(maxHR: Double(profile.hrMax))

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
