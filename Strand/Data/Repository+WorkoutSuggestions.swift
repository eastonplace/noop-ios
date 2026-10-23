import Foundation
import StrandAnalytics
import WhoopStore

@MainActor
extension Repository {
    /// Includes source lineage/cursor epoch even before the first dashboard snapshot has hydrated.
    /// Ordinary metric refreshes do not invalidate a user-reviewed suggestion; source replacement does.
    var workoutSuggestionContext: WorkoutSuggestionContext {
        WorkoutSuggestionContext(sourceContext: notificationSourceContext,
                                 sourceLineage: liveSourceState.lineageComponent,
                                 invalidationEpoch: externalSurfaceInvalidationEpoch)
    }

    /// The unchanged detector runs independently for each admitted raw namespace. Classification,
    /// counter movement, prior confirmed labels, and the eventual manual row keep that same owner.
    func autoDetectedWorkoutSuggestion(daysBack: Int = 2, now: Date = Date()) async -> AutoWorkoutSuggestion? {
        guard PuffinExperiment.autoDetectWorkoutsEnabled, !verifiedExternalSurfaceFenced,
              (1...7).contains(daysBack), !Task.isCancelled else { return nil }
        let lineage = liveSourceState
        let epoch = externalSurfaceInvalidationEpoch
        guard let store = await storeHandle(), !verifiedExternalSurfaceFenced, liveSourceState == lineage,
              externalSurfaceInvalidationEpoch == epoch, !Task.isCancelled else { return nil }
        let context = workoutSuggestionContext
        let nowSec = Int(now.timeIntervalSince1970)
        let from = max(0, nowSec - daysBack * 86_400)
        let sourceIds = importedReadIds

        do {
            let databaseId = try await store.databaseInstanceId()
            let storedSpans = try await store.workoutSuggestionSpans(
                deviceIds: workoutSuggestionSuppressionSources, from: from, to: nowSec)
            let dismissedDetected = workoutSuggestionDismissedDetectedSpans
            let savedSpans = storedSpans.filter { !$0.isDismissed(by: dismissedDetected) }.map {
                SavedWorkoutSpan(startSec: $0.startSec, endSec: $0.endSec)
            }
            let dismissed = workoutSuggestionDismissedTokens
            let restingBpm = days.last(where: { $0.restingHr != nil })?.restingHr
            var newest: (window: DetectedWorkout, source: String, owner: HistoricalCursorScope)?
            for source in sourceIds {
                try Task.checkCancellation()
                guard !verifiedExternalSurfaceFenced, context == workoutSuggestionContext else { return nil }
                let owner: HistoricalCursorScope
                do {
                    owner = try await store.workoutSuggestionSourceOwner(deviceId: source)
                } catch is LiftReceiptStateError {
                    // An unavailable canonical/history source cannot hide a valid active-source candidate.
                    continue
                }
                guard !verifiedExternalSurfaceFenced, context == workoutSuggestionContext, !Task.isCancelled else { return nil }
                let samples = try await store.hrSamples(deviceId: source, from: from, to: nowSec, limit: 200_000)
                let hr = samples.map { (ts: $0.ts, bpm: $0.bpm) }
                let candidates: [DetectedWorkout]
                if TestCentre.active(.workouts), let logger = workoutsLog {
                    let traced = AutoWorkoutDetector.detectTrace(
                        hr: hr, restingBpm: restingBpm, motion: nil, savedSpans: savedSpans, path: "autoDetect")
                    traced.trace.forEach(logger)
                    candidates = traced.results
                } else {
                    candidates = AutoWorkoutDetector.detect(hr: hr, restingBpm: restingBpm,
                                                            motion: nil, savedSpans: savedSpans)
                }
                for window in candidates where !dismissed.contains(Self.workoutSuggestionToken(window)) {
                    // Active source is first and wins an exact timestamp tie, without interleaving sensors.
                    if window.startSec > (newest?.window.startSec ?? .min) { newest = (window, source, owner) }
                }
            }
            guard let newest, !verifiedExternalSurfaceFenced, context == workoutSuggestionContext,
                  PuffinExperiment.autoDetectWorkoutsEnabled, !Task.isCancelled else { return nil }
            let window = newest.window
            async let steps = store.stepSamples(deviceId: newest.source, from: window.startSec,
                                                 to: window.endSec, limit: 200_000)
            async let history = store.workouts(
                deviceId: newest.source,
                from: max(0, window.startSec - WorkoutTypeSuggestion.historyLookbackSeconds),
                to: window.startSec - 1, limit: 2_000)
            let (movement, priorRows) = try await (steps, history)
            let confirmed = priorRows.filter { $0.source == "manual" }.map {
                WorkoutTypeSuggestion.ConfirmedWorkout(startSec: $0.startTs, endSec: $0.endTs, sport: $0.sport)
            }
            let prediction = WorkoutTypeSuggestion.classify(workout: window, steps: movement,
                                                             confirmedHistory: confirmed)
            guard try await store.workoutSuggestionSourceOwner(deviceId: newest.source) == newest.owner else { return nil }
            guard !verifiedExternalSurfaceFenced, context == workoutSuggestionContext, importedReadIds.contains(newest.source),
                  PuffinExperiment.autoDetectWorkoutsEnabled, !Task.isCancelled,
                  !workoutSuggestionDismissedTokens.contains(Self.workoutSuggestionToken(window)) else { return nil }
            return AutoWorkoutSuggestion(window: window, prediction: prediction, sourceId: newest.source,
                                         context: context, databaseInstanceId: databaseId, sourceOwner: newest.owner)
        } catch {
            // Incomplete sensor/overlap reads cannot safely produce a suggestion. Nothing is persisted.
            return nil
        }
    }

    /// Save only after the user confirms the type. A true interval-overlap check and insertion share
    /// one transaction; changing the type or tapping another card cannot create a duplicate window.
    /// Database identity and source lineage/cursor/lifecycle are checked in that transaction before writing.
    func saveWorkoutSuggestion(_ suggestion: AutoWorkoutSuggestion, type: String,
                               now: Date = Date()) async -> WorkoutSuggestionSaveResult {
        guard isCurrentWorkoutSuggestion(suggestion), !Task.isCancelled else { return .stale }
        let window = suggestion.window
        let (duration, overflow) = window.endSec.subtractingReportingOverflow(window.startSec)
        let sport = type.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !overflow, window.startSec > 0, duration > 0, duration <= 2 * 86_400,
              window.endSec <= Int(now.timeIntervalSince1970), !sport.isEmpty, sport.count <= 80,
              !sport.contains("\0") else { return .failed }
        guard let store = await storeHandle() else { return .failed }
        guard isCurrentWorkoutSuggestion(suggestion), !Task.isCancelled else { return .stale }
        let row = WorkoutRow(startTs: window.startSec, endTs: window.endSec, sport: sport, source: "manual",
                             durationS: Double(duration), energyKcal: nil, avgHr: window.avgBpm,
                             maxHr: nil, strain: nil, distanceM: nil, zonesJSON: nil, notes: nil)
        do {
            let result = try await store.insertWorkoutSuggestion(
                row, deviceId: suggestion.sourceId, overlapDeviceIds: workoutSuggestionSuppressionSources,
                dismissedDetectedSpans: workoutSuggestionDismissedDetectedSpans,
                expectedDatabaseInstanceId: suggestion.databaseInstanceId, sourceOwner: suggestion.sourceOwner)
            switch result {
            case .inserted:
                editedDayRescoreQueue.enqueue([window.endSec]) { [weak self] days in
                    _ = await self?.refresh(.recentDashboard(days: days))
                }
                return .saved
            case .overlapsExisting: return .alreadySaved
            case .staleDatabase, .staleSource: return .stale
            }
        } catch is CancellationError {
            return .stale
        } catch {
            return .failed
        }
    }

    @discardableResult
    func dismissWorkoutSuggestion(_ suggestion: AutoWorkoutSuggestion) -> Bool {
        guard isCurrentWorkoutSuggestion(suggestion) else { return false }
        // Retain the existing bounded, durable suppression policy and its legacy stored tokens.
        dismissDetectedSuggestion(suggestion.window)
        return true
    }

    func isCurrentWorkoutSuggestion(_ suggestion: AutoWorkoutSuggestion) -> Bool {
        PuffinExperiment.autoDetectWorkoutsEnabled && !verifiedExternalSurfaceFenced
            && suggestion.context == workoutSuggestionContext
            && suggestion.sourceOwner.deviceId == suggestion.sourceId
            && importedReadIds.contains(suggestion.sourceId)
            && !workoutSuggestionDismissedTokens.contains(Self.workoutSuggestionToken(suggestion.window))
    }

    private var workoutSuggestionSuppressionSources: [String] {
        Array(Set(importedReadIds + computedReadIds + [Self.appleHealthSource, "lifting", Self.activityFileSource])).sorted()
    }

    private var workoutSuggestionDismissedDetectedSpans: [WorkoutSuggestionSpan] {
        WorkoutSource.parseDismissedSpans(
            UserDefaults.standard.stringArray(forKey: WorkoutSource.dismissedDefaultsKey) ?? []
        ).map { WorkoutSuggestionSpan(startSec: $0.start, endSec: $0.end) }
    }

    private var workoutSuggestionDismissedTokens: Set<String> {
        Set(UserDefaults.standard.stringArray(forKey: "workouts.autoDetectDismissed") ?? [])
    }

    private static func workoutSuggestionToken(_ window: DetectedWorkout) -> String {
        "\(window.startSec):\(window.endSec)"
    }
}
