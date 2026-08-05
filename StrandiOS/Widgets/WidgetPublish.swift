#if os(iOS)
import Foundation
import NoopPhase34Core
import StrandDesign
import StrandAnalytics
import WidgetKit

enum WidgetPublicationError: Error {
    case appGroupUnavailable
    case sinkWriteFailed
}

@MainActor
private enum WidgetLivePublishGate {
    private(set) static var cachedSnapshot: WidgetSnapshot?
    private(set) static var lastPublishedAt: Date = .distantPast
    private(set) static var fullPublishGeneration: UInt64 = 0

    /// Return the last in-process snapshot, or hydrate it once from the App Group. A genuinely empty
    /// store returns nil so the first live publication is forced and creates the widget snapshot instead
    /// of repeatedly decoding a missing value on every sensor event.
    static func currentSnapshot(now: Date) -> WidgetSnapshot? {
        if let cachedSnapshot { return cachedSnapshot }
        guard let loaded = WidgetSnapshot.load() else { return nil }
        cachedSnapshot = loaded
        // A wall-clock correction can leave a persisted `updated` timestamp in the future. Do not let
        // that suppress live publication until the clock catches up.
        lastPublishedAt = loaded.updated <= now ? loaded.updated : .distantPast
        return loaded
    }

    static func shouldPublish(previous: WidgetSnapshot?, next: WidgetSnapshot, now: Date) -> Bool {
        WidgetLivePublishPolicy.shouldPublish(
            previous: previous,
            next: next,
            lastPublishedAt: lastPublishedAt,
            now: now)
    }

    static func shouldPublishFull(previous: WidgetSnapshot?, next: WidgetSnapshot, now: Date) -> Bool {
        WidgetFullPublishPolicy.shouldPublish(
            previous: previous,
            next: next,
            lastPublishedAt: lastPublishedAt,
            now: now)
    }

    static func notePublished(_ snapshot: WidgetSnapshot, at date: Date) {
        cachedSnapshot = snapshot
        lastPublishedAt = date
    }

    /// Full dashboard publications perform several async reads. A later refresh can start while an older
    /// one is suspended; generation tokens ensure that older work cannot resume and overwrite newer App
    /// Group state. The checks after each expensive await also abandon superseded work early.
    static func beginFullPublish() -> UInt64 {
        fullPublishGeneration &+= 1
        return fullPublishGeneration
    }

    static func isCurrentFullPublish(_ generation: UInt64) -> Bool {
        generation == fullPublishGeneration
    }
}

extension WidgetSnapshot {
    /// Build a glance snapshot from the live app state and publish it to the shared App Group, then
    /// ask WidgetKit to refresh. Called when the app becomes active and after a Health sync.
    ///
    /// Headline Recovery, Strain, and Sleep values come from the verified projection committed by the
    /// durable pipeline. Auxiliary sparklines remain exploratory reads and never replace those values.
    ///
    /// #911: the anchor is resolved the way Today resolves it (the current LOGICAL local day, `Date()`
    /// read here so the day rolls live as the extension republishes), NOT "the most recent day with any
    /// recovery score". The old anchor drifted around the day rollover: the new logical day exists but
    /// isn't scored yet, so `days.last(where: recovery != nil)` still pointed at yesterday's scored row
    /// and the widget showed the older day while Today had already moved on. We now anchor on today's
    /// row and, only when today isn't scored yet, carry over the last STRICTLY-PRIOR scored day for the
    /// recovery-derived fields (the same carry-over Today does), so the widget never blanks right after
    /// the rollover yet always describes today.
    @MainActor
    static func publish(from model: AppModel) async -> ExternalSinkPublicationResult {
        guard let verifiedProjection = model.repo.verifiedHealthProjection else { return .notApplicable }
        return (try? await publish(from: model, verifiedProjection: verifiedProjection)) ?? .superseded
    }

    /// Publish the exact projection generation leased by the durable external-publication worker.
    /// Auxiliary live fields may come from current app state, but headline health values remain pinned
    /// to the stored generation named by the outbox item.
    @MainActor
    static func publish(
        from model: AppModel,
        verifiedProjection: VerifiedHealthProjection,
        expectedActiveContextId: String? = nil
    ) async throws -> ExternalSinkPublicationResult {
        guard expectedActiveContextId == nil || expectedActiveContextId == verifiedProjection.contextId else {
            return .superseded
        }
        let stored = WidgetSnapshot.load()
        guard stored?.acceptsVerifiedProjection(
            contextId: verifiedProjection.contextId,
            generation: verifiedProjection.generation
        ) ?? true else { return .superseded }
        let generation = WidgetLivePublishGate.beginFullPublish()
        let days = model.repo.days
        let now = Date()
        // The recovery-derived anchor: today's row when it's scored, else the freshest STRICTLY-PRIOR
        // scored day carried over. Resolved through the SHARED `Repository.widgetAnchor`, the ONE selector
        // the watch snapshot and the iOS Live Activity now also use, so all four surfaces describe the same
        // day (the #911 fix; see `Repository.widgetAnchor` for the rollover-drift rationale, the #304
        // pre-04:00 carve-out and the #547 future-day guard it folds in). The `$0.day < carriedKey` bound
        // inside the helper (matching `TodayView.selectedDayKey`) means a stale scored row can never
        // re-surface AS today.
        let day = days.first(where: { $0.day == verifiedProjection.logicalDay.key })
            ?? Repository.widgetAnchor(days: days, now: now)
        let recovery = verifiedProjection.visibleMetric(.recovery)?.value
        let storedStrain = ExternalSurfaceProjection(verifiedProjection).effort
        let restScore = verifiedProjection.visibleMetric(.sleepScore)?.value
        guard WidgetLivePublishGate.isCurrentFullPublish(generation) else { return .superseded }
        let previousRecovery = day.flatMap { anchor in
            days.last(where: { $0.day < anchor.day && $0.recovery != nil })?.recovery
        }
        let recoveryDelta: Int? = {
            guard let current = day?.recovery, let previousRecovery else { return nil }
            return Int((current - previousRecovery).rounded())
        }()
        let hrvSeries = await model.repo.exploreSeries(key: "hrv", source: "my-whoop")
        guard WidgetLivePublishGate.isCurrentFullPublish(generation) else { return .superseded }
        let hrvSparkline = hrvSeries
            .filter { point in day.map { point.day <= $0.day } ?? true }
            .suffix(12)
            .map { Int($0.value.rounded()) }
        let stress = await dashboardStress(from: model)
        guard WidgetLivePublishGate.isCurrentFullPublish(generation) else { return .superseded }
        let sparkline = model.activeWorkout.map { Array($0.samples.suffix(48).map(\.bpm)) }
        let snap = WidgetSnapshot.publishing(
            recovery: recovery,
            storedStrain: storedStrain,
            sleepScore: restScore,
            bpm: model.bpm ?? model.live.heartRate,
            batteryPct: model.live.batteryPct,
            bonded: model.live.bonded,
            hrv: day?.avgHrv,
            restingHr: day?.restingHr,
            recoveryDelta: recoveryDelta,
            sleepMinutes: day?.totalSleepMin.map { Int($0.rounded()) },
            steps: day?.steps,
            calories: day?.activeKcalEst.map { Int($0.rounded()) },
            hourlyStress: stress.hours,
            stressSummary: stress.summary,
            hrSparkline: sparkline,
            hrvSparkline: hrvSparkline,
            verifiedContextId: verifiedProjection.contextId,
            verifiedProjectionGeneration: verifiedProjection.generation,
            updated: now
        )
        guard WidgetLivePublishGate.isCurrentFullPublish(generation) else { return .superseded }
        // A refreshSeq change unrelated to widget data must not rewrite the same App Group blob or reload
        // every timeline. Re-read the in-process latest snapshot only after all awaits; a live-lane publish
        // may have advanced it while this slower projection was suspended.
        let previous = WidgetLivePublishGate.currentSnapshot(now: now)
        guard WidgetLivePublishGate.shouldPublishFull(previous: previous, next: snap, now: now) else {
            return .alreadyCurrent
        }
        guard snap.acceptsVerifiedProjection(
            contextId: verifiedProjection.contextId,
            generation: verifiedProjection.generation
        ) else { return .superseded }
        guard let defaults = UserDefaults(suiteName: WidgetSnapshot.suiteName) else {
            throw WidgetPublicationError.appGroupUnavailable
        }
        let result = VerifiedProjectionGenerationStore.commitIfAccepted(
            contextId: verifiedProjection.contextId,
            generation: verifiedProjection.generation,
            expectedActiveContextId: expectedActiveContextId,
            defaults: defaults,
            key: "noop.widget.verified-projection-generation",
            write: { snap.save() }
        )
        switch result {
        case .published:
            WidgetLivePublishGate.notePublished(snap, at: now)
            WidgetCenter.shared.reloadAllTimelines()
            return .published
        case .alreadyCurrent:
            WidgetLivePublishGate.notePublished(snap, at: now)
            return .alreadyCurrent
        case .superseded:
            return .superseded
        case .failed:
            throw WidgetPublicationError.sinkWriteFailed
        }
    }

    /// Fast publication lane for live fields. No history query and no sleep/stress recomputation.
    ///
    /// A manual workout republishes `AppModel.activeWorkout` about once per sample. Before the gate below,
    /// every one of those ~1 Hz emissions decoded the App Group snapshot, encoded it again, and called
    /// `WidgetCenter.reloadAllTimelines()`. That made the supposedly-fast lane a synchronous disk/WidgetKit
    /// hot loop on the main actor. We now keep the last snapshot in memory, skip byte-equivalent payloads,
    /// publish connection/battery/workout-mode edges immediately, and coalesce HR, live Strain, and
    /// sparkline churn to a one-minute cadence.
    @MainActor
    static func publishLive(from model: AppModel) {
        publishLive(from: model, verifiedProjection: model.repo.verifiedHealthProjection)
    }

    /// Fast publication lane with an explicitly pinned verified projection.
    @MainActor
    static func publishLive(
        from model: AppModel,
        verifiedProjection: VerifiedHealthProjection?
    ) {
        let verified = verifiedProjection
        let recovery = verified?.visibleMetric(.recovery)?.value
        let storedStrain = verified.flatMap { ExternalSurfaceProjection($0).effort }
        let now = Date()
        let previous = WidgetLivePublishGate.currentSnapshot(now: now)
        let base = previous ?? WidgetSnapshot(
            recovery: recovery.map { Int($0.rounded()) }, bpm: nil, batteryPct: nil,
            bonded: model.live.bonded, updated: now)
        let sparkline = model.activeWorkout.map { Array($0.samples.suffix(48).map(\.bpm)) }
        var next = base.mergingLive(
            bpm: model.bpm ?? model.live.heartRate,
            batteryPct: model.live.batteryPct,
            bonded: model.live.connected,
            storedStrain: storedStrain,
            hrSparkline: sparkline,
            updated: now)
        if let verified {
            guard next.acceptsVerifiedProjection(
                contextId: verified.contextId,
                generation: verified.generation
            ) else { return }
            next.verifiedContextId = verified.contextId
            next.verifiedProjectionGeneration = verified.generation
        }
        // `mergingLive` preserves a nil optional by design, but here nil specifically means the workout
        // ended. Clear the old trace so the widget exits workout mode immediately instead of retaining the
        // last session's graph forever.
        if model.activeWorkout == nil { next.hrSparkline = nil }
        guard WidgetLivePublishGate.shouldPublish(previous: previous, next: next, now: now) else { return }
        if let verified,
           let defaults = UserDefaults(suiteName: WidgetSnapshot.suiteName) {
            let result = VerifiedProjectionGenerationStore.commitIfAccepted(
                contextId: verified.contextId,
                generation: verified.generation,
                expectedActiveContextId: verified.contextId,
                defaults: defaults,
                key: "noop.widget.verified-projection-generation",
                write: { next.save() }
            )
            guard result == .published || result == .alreadyCurrent else { return }
        } else {
            guard next.save() else { return }
        }
        WidgetLivePublishGate.notePublished(next, at: now)
        WidgetCenter.shared.reloadAllTimelines()
    }

    @MainActor
    private static func dashboardStress(from model: AppModel) async -> (hours: [Double?]?, summary: String?) {
        let now = Date()
        let start = Int(Calendar.current.startOfDay(for: now).timeIntervalSince1970)
        let end = Int(now.timeIntervalSince1970)
        let hr = await model.repo.hrSamples(from: start, to: end, limit: 200_000)
        guard hr.count >= DaytimeStress.minHourHRSamples else { return (nil, nil) }
        let rr = (try? await model.repo.storeHandle()?.rrIntervals(
            deviceId: model.repo.deviceId, from: start, to: end, limit: 200_000)) ?? []
        let tzOffset = TimeZone.current.secondsFromGMT(for: now)

        // DaytimeStress fingerprints and then buckets as many as 200k HR + 200k R-R rows. `publish` is
        // MainActor-isolated because it reads app state and writes WidgetKit, but the pure numeric scan does
        // not belong on the UI executor. Return only the tiny widget projection to the main actor.
        return await Task.detached(priority: .utility) {
            let result = DaytimeStress.analyze(hr: hr, rr: rr, tzOffsetSeconds: tzOffset)
            var hours = [Double?](repeating: nil, count: 24)
            for point in result.hours where (0..<24).contains(point.hour) {
                hours[point.hour] = point.level
            }
            let summary: String?
            if result.sustainedHigh { summary = "Sustained high" }
            else if let mean = result.dayMean {
                summary = mean >= 2 ? "High" : mean >= 1 ? "Moderate" : "Low"
            } else {
                summary = nil
            }
            return (hours, summary)
        }.value
    }

    /// #114/#169: HR is the ONE high-frequency widget-publish trigger — `model.bpm` moves every few
    /// seconds during activity, unlike battery (~8 min) or connection flips (rare). Left ungated, the
    /// `model.$bpm` hook re-ran `publish`'s `exploreSeries` read + `reloadAllTimelines()` on every tick.
    /// This caps HR-DRIVEN publishes to one per `interval`, mirroring Android's `PushGate` 60 s
    /// `HR_REFRESH_MS` cadence. Only the bpm hook consults it; the low-frequency score/battery/connection/
    /// scenePhase publish sites stay ungated, exactly as before. `@MainActor` (the hook already runs there),
    /// so the shared timestamp needs no locking.
    @MainActor
    enum HRPublishThrottle {
        static let interval: TimeInterval = 60
        private static var lastPublishedAt: Date = .distantPast
        /// True (and stamps `now`) when at least `interval` has elapsed since the last HR-driven publish;
        /// false to skip this HR change. The first call always admits (`.distantPast`).
        static func admit(now: Date = Date()) -> Bool {
            let elapsed = now.timeIntervalSince(lastPublishedAt)
            guard elapsed < 0 || elapsed >= interval else { return false }
            lastPublishedAt = now
            return true
        }
    }
}
#endif
