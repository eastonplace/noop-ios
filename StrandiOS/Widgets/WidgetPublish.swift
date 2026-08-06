#if os(iOS)
import Foundation
import NoopPhase34Core
import StrandDesign
import StrandAnalytics
import WhoopStore
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
        guard let loaded = WidgetSnapshot.loadForDisplay() else { return nil }
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

/// One app-wide enrichment flight. Core publications are frequent, so the actor is shared instead of
/// constructing a new coordinator for each outbox acknowledgement. A new immutable generation cancels
/// the older flight and a repeated generation is suppressed by the actor's key/TTL gate.
@MainActor
private enum WidgetEnrichmentRuntime {
    static let coordinator = WidgetEnrichmentCoordinator()
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
        guard let verifiedProjection = model.repo.verifiedHealthProjection,
              let store = await model.repo.storeHandle(),
              let bundle = try? await store.verifiedExternalProjectionBundle(
                contextId: verifiedProjection.contextId,
                generation: verifiedProjection.generation) else { return .notApplicable }
        return (try? await publish(from: model, verifiedBundle: bundle)) ?? .superseded
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
        guard let store = await model.repo.storeHandle(),
              let bundle = try await store.verifiedExternalProjectionBundle(
                contextId: verifiedProjection.contextId,
                generation: verifiedProjection.generation) else {
            return .superseded
        }
        return try await publish(
            from: model,
            verifiedBundle: bundle,
            expectedActiveContextId: expectedActiveContextId
        )
    }

    /// Publish the exact immutable projection and Widget core captured in one durable generation.
    @MainActor
    static func publish(
        from model: AppModel,
        verifiedBundle: VerifiedExternalProjectionBundle,
        expectedActiveContextId: String? = nil
    ) async throws -> ExternalSinkPublicationResult {
        let verifiedProjection = verifiedBundle.projection
        guard expectedActiveContextId == nil || expectedActiveContextId == verifiedProjection.contextId else {
            return .superseded
        }
        guard let defaults = UserDefaults(suiteName: WidgetSnapshot.suiteName),
              let token = ActiveVerifiedSinkEpochStore.activeToken(defaults: defaults),
              token.contextId == verifiedProjection.contextId else {
            return .superseded
        }
        let now = Date()
        // This is the durable acknowledgement path. It contains only the verified core and in-memory Today
        // fields. HRV history, raw stress scans, and other enrichment run after the caller receives success.
        let snap = WidgetCorePublication.makeCoreSnapshot(
            model: model,
            bundle: verifiedBundle,
            now: now)
        let result = VerifiedWidgetEnvelopeStore.commit(
            token: token,
            generation: verifiedProjection.generation,
            snapshot: snap,
            defaults: defaults
        )
        switch result {
        case .published:
            WidgetLivePublishGate.notePublished(snap, at: now)
            WidgetCenter.shared.reloadAllTimelines()
            scheduleOptionalWidgetEnrichment(from: model, bundle: verifiedBundle, token: token)
            return .published
        case .alreadyCurrent:
            WidgetLivePublishGate.notePublished(snap, at: now)
            scheduleOptionalWidgetEnrichment(from: model, bundle: verifiedBundle, token: token)
            return .alreadyCurrent
        case .superseded:
            return .superseded
        case .failed:
            throw WidgetPublicationError.sinkWriteFailed
        }
    }

    @MainActor
    private static func scheduleOptionalWidgetEnrichment(
        from model: AppModel,
        bundle: VerifiedExternalProjectionBundle,
        token: VerifiedSinkToken
    ) {
        let key = WidgetEnrichmentKey(
            epoch: token.epoch,
            contextId: bundle.projection.contextId,
            generation: bundle.projection.generation)
        Task { @MainActor in
            await WidgetEnrichmentRuntime.coordinator.schedule(key: key, now: Date()) { _ in
                await Self.publishOptionalWidgetEnrichment(
                    from: model,
                    bundle: bundle,
                    token: token)
            }
        }
    }

    /// Optional Widget enrichment is deliberately detached from the durable outbox acknowledgement. The
    /// epoch/generation check on the second write prevents a late enrichment task from crossing a transition.
    @MainActor
    private static func publishOptionalWidgetEnrichment(
        from model: AppModel,
        bundle: VerifiedExternalProjectionBundle,
        token: VerifiedSinkToken
    ) async {
        let projection = bundle.projection
        let anchorDay = bundle.widgetCore.logicalDay.key
        let hrvSeries = await model.repo.exploreSeries(key: "hrv", source: "my-whoop", days: 30)
        let hrvSparkline = hrvSeries
            .filter { point in point.day <= anchorDay }
            .suffix(12)
            .map { Int($0.value.rounded()) }
        let stress = await dashboardStress(from: model)
        guard let defaults = UserDefaults(suiteName: WidgetSnapshot.suiteName),
              let active = ActiveVerifiedSinkEpochStore.activeToken(defaults: defaults),
              active == token,
              let base = VerifiedWidgetEnvelopeStore.loadForDisplay(defaults: defaults),
              base.verifiedContextId == projection.contextId,
              base.verifiedProjectionGeneration == projection.generation else { return }
        var enriched = base
        enriched.hrvSparkline = hrvSparkline
        enriched.hourlyStress = stress.hours
        enriched.stressSummary = stress.summary
        let result = VerifiedWidgetEnvelopeStore.commit(
            token: token,
            generation: projection.generation,
            snapshot: enriched,
            defaults: defaults
        )
        guard result == .published || result == .alreadyCurrent else { return }
        WidgetLivePublishGate.notePublished(enriched, at: Date())
        WidgetCenter.shared.reloadAllTimelines()
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
        guard let verified = verifiedProjection,
              let defaults = UserDefaults(suiteName: WidgetSnapshot.suiteName),
              let token = ActiveVerifiedSinkEpochStore.activeToken(defaults: defaults),
              token.contextId == verified.contextId,
              let base = VerifiedWidgetEnvelopeStore.loadForDisplay(defaults: defaults),
              base.verifiedContextId == verified.contextId,
              base.verifiedProjectionGeneration == verified.generation else {
            return
        }
        let now = Date()
        let previous = WidgetLivePublishGate.currentSnapshot(now: now)
        let sparkline = model.activeWorkout.map { Array($0.samples.suffix(48).map(\.bpm)) }
        var next = previous ?? base
        next.bpm = model.bpm ?? model.live.heartRate
        next.batteryPct = model.live.batteryPct.map { Int($0.rounded()) }
        next.bonded = model.live.connected
        next.updated = now
        next.hrSparkline = sparkline
        if model.activeWorkout == nil { next.hrSparkline = nil }
        let overlay = WidgetLiveOverlay(
            epoch: token.epoch,
            contextId: verified.contextId,
            generation: verified.generation,
            bpm: model.bpm ?? model.live.heartRate,
            batteryPct: model.live.batteryPct.map { Int($0.rounded()) },
            bonded: model.live.connected,
            hrSparkline: sparkline,
            updated: now)
        guard WidgetLivePublishGate.shouldPublish(previous: previous, next: next, now: now) else { return }
        guard ActiveVerifiedSinkEpochStore.commitLiveOverlayIfCurrent(
            token: token,
            generation: verified.generation,
            defaults: defaults,
            overlay: overlay) else { return }
        WidgetLivePublishGate.notePublished(next, at: now)
        WidgetCenter.shared.reloadAllTimelines()
    }

    @MainActor
    private static func dashboardStress(from model: AppModel) async -> (hours: [Double?]?, summary: String?) {
        let now = Date()
        let start = Int(Calendar.current.startOfDay(for: now).timeIntervalSince1970)
        let end = Int(now.timeIntervalSince1970)
        // Enrichment is optional. Keep this raw fallback bounded until the persisted hourly aggregate
        // exists; the coordinator's generation/TTL gate prevents this cap from becoming a hot loop.
        let hr = await model.repo.hrSamples(from: start, to: end, limit: 20_000)
        guard hr.count >= DaytimeStress.minHourHRSamples else { return (nil, nil) }
        let rr = (try? await model.repo.storeHandle()?.rrIntervals(
            deviceId: model.repo.deviceId, from: start, to: end, limit: 20_000)) ?? []
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
