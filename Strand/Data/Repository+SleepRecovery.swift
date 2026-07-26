import Foundation
import StrandAnalytics
import WhoopStore

enum MissedSleepRecoveryStatus: Equatable {
    case complete
    case partial
    case invalidWindow
    case insufficientData
    case noSleepEvidence
    case overlapConflict
    case storeUnavailable
    case failed
}

struct MissedSleepRecoverySaveResult: Equatable {
    let status: MissedSleepRecoveryStatus
    let title: String
    let message: String
    let confidence: Double?
    let sessionStart: Int?
    let sessionEnd: Int?

    var savedSession: Bool {
        status == .complete || status == .partial
    }
}

extension Repository {
    /// Recover a detector-missed night from a user-supplied search interval. The user
    /// supplies boundaries only; staging, RHR and HRV are re-derived from raw local data.
    func recoverMissedSleep(startTs: Int, endTs: Int) async -> MissedSleepRecoverySaveResult {
        guard let safeWindow = SleepEditGuard.clampedEditWindow(
            start: startTs,
            end: endTs,
            now: Int(Date().timeIntervalSince1970)
        ) else {
            return MissedSleepRecoverySaveResult(
                status: .invalidWindow,
                title: "Check the sleep window",
                message: "Wake time must be after bedtime, the window must be at least 30 minutes, and it cannot end in the future.",
                confidence: nil,
                sessionStart: nil,
                sessionEnd: nil)
        }

        let (safeStart, safeEnd) = safeWindow
        guard safeEnd - safeStart >= SleepWindowRecovery.minWindowSeconds,
              safeEnd - safeStart <= SleepWindowRecovery.maxWindowSeconds else {
            return MissedSleepRecoverySaveResult(
                status: .invalidWindow,
                title: "Check the sleep window",
                message: "Choose a window between 30 minutes and 16 hours.",
                confidence: nil,
                sessionStart: nil,
                sessionEnd: nil)
        }

        guard let store = await storeHandle() else {
            return MissedSleepRecoverySaveResult(
                status: .storeUnavailable,
                title: "Local data is unavailable",
                message: "NOOP could not open the local store. Your selected times were not saved.",
                confidence: nil,
                sessionStart: nil,
                sessionEnd: nil)
        }
        // IntelligenceEngine intentionally writes all canonical on-device calculations to
        // `my-whoop-noop`, regardless of which physical strap is active. Use the same stable
        // namespace so the normal merge, export and projection paths see this correction.
        let computedId = Repository.whoopSource + "-noop"

        let lo = safeStart - 3_600
        let hi = safeEnd + 3_600
        async let gravityRead = store.gravitySamples(
            deviceId: deviceId, from: lo, to: hi, limit: 200_000)
        async let hrRead = store.hrSamples(
            deviceId: deviceId, from: lo, to: hi, limit: 200_000)
        async let rrRead = store.rrIntervals(
            deviceId: deviceId, from: lo, to: hi, limit: 200_000)
        async let respRead = store.respSamples(
            deviceId: deviceId, from: lo, to: hi, limit: 200_000)

        let gravity = (try? await gravityRead) ?? []
        let hr = (try? await hrRead) ?? []
        let rr = (try? await rrRead) ?? []
        let resp = (try? await respRead) ?? []
        let useV2 = PuffinExperiment.experimentalSleepV2Enabled

        let analysis = await Task.detached(priority: .utility) {
            SleepWindowRecovery.analyze(
                start: safeStart,
                end: safeEnd,
                source: .manualWindow,
                hr: hr,
                rr: rr,
                resp: resp,
                gravity: gravity,
                useSleepStagerV2: useV2)
        }.value

        let now = Int(Date().timeIntervalSince1970)
        let audit = SleepRecoveryAuditRecord(
            id: "manual-window:\(computedId):\(safeStart):\(safeEnd)",
            source: analysis.source.rawValue,
            requestedStartTs: safeStart,
            requestedEndTs: safeEnd,
            outcome: analysis.outcome.rawValue,
            confidence: analysis.confidence,
            reason: analysis.reason.rawValue,
            resultStartTs: analysis.canPersistSession ? safeStart : nil,
            resultEndTs: analysis.canPersistSession ? safeEnd : nil,
            stagesAvailable: analysis.hasDefensibleStages,
            restingHr: analysis.restingHR,
            avgHrv: analysis.avgHRV,
            algorithmVersion: analysis.algorithmVersion,
            createdAt: now,
            updatedAt: now)

        guard analysis.canPersistSession else {
            _ = try? await store.recordSleepRecoveryAttempt(audit, deviceId: computedId)
            switch analysis.outcome {
            case .invalidWindow:
                return MissedSleepRecoverySaveResult(
                    status: .invalidWindow,
                    title: "Check the sleep window",
                    message: "Choose a valid sleep window between 30 minutes and 16 hours.",
                    confidence: analysis.confidence,
                    sessionStart: nil,
                    sessionEnd: nil)
            case .noSleepEvidence:
                return MissedSleepRecoverySaveResult(
                    status: .noSleepEvidence,
                    title: "No sleep evidence found",
                    message: "NOOP found data in that window, but not enough sleep-like physiology to create a session. Try tightening the times around when you were actually asleep.",
                    confidence: analysis.confidence,
                    sessionStart: nil,
                    sessionEnd: nil)
            default:
                return MissedSleepRecoverySaveResult(
                    status: .insufficientData,
                    title: "Not enough recorded data",
                    message: "The strap did not record enough usable physiology in that window. Nothing was invented or saved.",
                    confidence: analysis.confidence,
                    sessionStart: nil,
                    sessionEnd: nil)
            }
        }

        let stagesJSON = analysis.stages.isEmpty
            ? nil
            : AnalyticsEngine.encodeStages(analysis.stages)
        let session = CachedSleepSession(
            startTs: safeStart,
            endTs: safeEnd,
            efficiency: analysis.efficiency,
            restingHr: analysis.restingHR,
            avgHrv: analysis.avgHRV,
            stagesJSON: stagesJSON,
            userEdited: true,
            startTsAdjusted: nil)

        // Score the corrected wake day from the same personal baseline chain as the
        // regular engine. Imported history wins on a same-day tie, matching Repository's
        // normal source resolver; the corrected row itself remains canonical computed data.
        let wakeDate = Date(timeIntervalSince1970: TimeInterval(safeEnd))
        let offset = TimeZone.current.secondsFromGMT(for: wakeDate)
        let day = AnalyticsEngine.dayString(safeEnd, offsetSec: offset)
        let fromDay = AnalyticsEngine.dayString(safeEnd - 180 * 86_400, offsetSec: offset)
        async let computedHistoryRead = store.dailyMetrics(
            deviceId: computedId, from: fromDay, to: day)
        async let importedHistoryRead = store.dailyMetrics(
            deviceId: Repository.whoopSource, from: fromDay, to: day)
        let computedHistory = (try? await computedHistoryRead) ?? []
        let importedHistory = (try? await importedHistoryRead) ?? []
        let existing = computedHistory.first { $0.day == day }
        var mergedByDay = Dictionary(
            computedHistory.map { ($0.day, $0) },
            uniquingKeysWith: { _, newest in newest })
        for row in importedHistory { mergedByDay[row.day] = row }
        let priorHistory = mergedByDay.values.sorted { $0.day < $1.day }

        let scored = ManualSleepDailyScorer.score(
            day: day,
            analysis: analysis,
            existing: existing,
            priorHistory: priorHistory)
        let dailyOverride = SleepRecoveryDailyOverride(
            day: day,
            sessionStartTs: safeStart,
            totalSleepMin: scored.daily.totalSleepMin,
            efficiency: scored.daily.efficiency,
            deepMin: scored.daily.deepMin,
            remMin: scored.daily.remMin,
            lightMin: scored.daily.lightMin,
            disturbances: scored.daily.disturbances,
            restingHr: scored.daily.restingHr,
            avgHrv: scored.daily.avgHrv,
            recovery: scored.daily.recovery,
            restScore: scored.restScore,
            updatedAt: now)

        do {
            let write = try await store.replaceWithManualSleepRecovery(
                session,
                deviceId: computedId,
                audit: audit,
                dailyOverride: dailyOverride,
                daily: scored.daily)
            switch write {
            case .conflict:
                return MissedSleepRecoverySaveResult(
                    status: .overlapConflict,
                    title: "A corrected sleep already exists",
                    message: "This window overlaps another sleep you edited. Open that sleep and adjust its times instead so NOOP never double-counts the night.",
                    confidence: analysis.confidence,
                    sessionStart: nil,
                    sessionEnd: nil)
            case .inserted, .updated:
                _ = await refresh(.recentDashboard(days: 120))
                if analysis.outcome == .partial {
                    let charge = scored.daily.recovery == nil
                        ? " Charge will remain in calibration until its personal HRV baseline is usable."
                        : " Charge was regenerated from those real vitals."
                    return MissedSleepRecoverySaveResult(
                        status: .partial,
                        title: "Sleep window recovered",
                        message: "NOOP saved the overnight vitals it could defend. Sleep stages and Rest remain unavailable because motion coverage was incomplete." + charge,
                        confidence: analysis.confidence,
                        sessionStart: safeStart,
                        sessionEnd: safeEnd)
                }
                let charge = scored.daily.recovery == nil
                    ? " Rest is available; Charge will appear once the personal baseline finishes calibrating."
                    : " Rest and Charge were regenerated from the corrected night."
                return MissedSleepRecoverySaveResult(
                    status: .complete,
                    title: "Sleep recovered",
                    message: "NOOP reprocessed the selected window from your recorded data." + charge,
                    confidence: analysis.confidence,
                    sessionStart: safeStart,
                    sessionEnd: safeEnd)
            }
        } catch {
            return MissedSleepRecoverySaveResult(
                status: .failed,
                title: "Could not save the sleep",
                message: "The local write failed, so no partial correction was left behind.",
                confidence: analysis.confidence,
                sessionStart: nil,
                sessionEnd: nil)
        }
    }

    /// Persist the outcome of the user explicitly asking the automatic detector to retry.
    /// This does not alter the session; `IntelligenceEngine.analyzeRecent` remains the one
    /// automatic detection path.
    func recordSleepDetectionRetry(
        requestedStartTs: Int,
        requestedEndTs: Int,
        recoveredSession: CachedSleepSession?
    ) async {
        guard let store = await storeHandle() else { return }
        let computedId = Repository.whoopSource + "-noop"
        let now = Int(Date().timeIntervalSince1970)
        let audit = SleepRecoveryAuditRecord(
            id: "retry:\(computedId):\(requestedStartTs):\(requestedEndTs)",
            source: SleepWindowRecoverySource.retry.rawValue,
            requestedStartTs: requestedStartTs,
            requestedEndTs: requestedEndTs,
            outcome: recoveredSession == nil
                ? SleepWindowRecoveryOutcome.noSleepEvidence.rawValue
                : SleepWindowRecoveryOutcome.complete.rawValue,
            confidence: recoveredSession?.efficiency ?? 0,
            reason: recoveredSession == nil
                ? SleepWindowRecoveryReason.noAsleepEpochs.rawValue
                : "automatic_redetection",
            resultStartTs: recoveredSession?.effectiveStartTs,
            resultEndTs: recoveredSession?.endTs,
            stagesAvailable: recoveredSession?.stagesJSON != nil,
            restingHr: recoveredSession?.restingHr,
            avgHrv: recoveredSession?.avgHrv,
            algorithmVersion: "sleep-detector-retry-v1",
            createdAt: now,
            updatedAt: now)
        _ = try? await store.recordSleepRecoveryAttempt(audit, deviceId: computedId)
    }
}
