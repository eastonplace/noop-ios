#if os(iOS)
import Foundation
import NoopPhase34Core
import StrandDesign
import StrandAnalytics
import WhoopProtocol
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
        let olderGenerationDay = await publishedLogicalDay(
            model: model, defaults: defaults, token: token, olderThan: verifiedProjection.generation)
        let now = Date()
        let store = await model.repo.storeHandle()
        let delivery = await coreDelivery(
            repository: model.repo,
            store: store,
            bundle: verifiedBundle,
            bpm: model.bpm ?? model.live.heartRate,
            batteryPct: model.live.batteryPct,
            bonded: WidgetCorePublication.widgetBonded(model.live),
            olderGenerationDay: olderGenerationDay,
            now: now)
        // This is the durable acknowledgement path. It contains only the verified core and in-memory Today
        // fields. HRV history, raw stress scans, and other enrichment run after the caller receives success.
        // What an earlier enrichment already added is carried over, so this commit cannot take it away.
        let (snap, result) = WidgetCorePublication.commitCore(
            bundle: verifiedBundle,
            token: token,
            defaults: defaults,
            delivery: delivery,
            now: now)
        let commitKey = WidgetEnrichmentKey(
            epoch: token.epoch,
            contextId: verifiedProjection.contextId,
            generation: verifiedProjection.generation)
        switch result {
        case .published:
            WidgetLivePublishGate.notePublished(snap, at: now)
            WidgetTimelineReloads.afterVerifiedCommit(result, key: commitKey)
            scheduleOptionalWidgetEnrichment(from: model, bundle: verifiedBundle, token: token)
            return .published
        case .alreadyCurrent:
            WidgetLivePublishGate.notePublished(snap, at: now)
            // The shared snapshot can already contain this generation while WidgetKit still holds an
            // older empty timeline, so a generation this process hasn't requested yet is still read once.
            WidgetTimelineReloads.afterVerifiedCommit(result, key: commitKey)
            scheduleOptionalWidgetEnrichment(from: model, bundle: verifiedBundle, token: token)
            return .alreadyCurrent
        case .superseded:
            return .superseded
        case .failed:
            throw WidgetPublicationError.sinkWriteFailed
        }
    }

    /// Everything a core publication reads, at delivery, besides the immutable bundle: Today's Steps and Strain
    /// for the current logical day, and last night's HRV and Resting HR anchored on the day Today's row is for
    /// (`WidgetCoreDay.nightlyAnchor`). A function of its inputs and the clock, so a test drives it against an
    /// in-memory store.
    @MainActor
    static func coreDelivery(
        repository: Repository,
        store: WhoopStore?,
        bundle: VerifiedExternalProjectionBundle,
        bpm: Int?,
        batteryPct: Double?,
        bonded: Bool,
        olderGenerationDay: (generation: Int64, day: CivilDay)?,
        now: Date,
        calendar: Calendar = .current
    ) async -> WidgetCorePublication.CoreDelivery {
        let nightsFrom = WidgetCoreDay.nightlyAnchor(bundle: bundle, now: now, calendar: calendar)
        let steps = await todaySteps(repository: repository, bundle: bundle, now: now, calendar: calendar)
        let hrv = await todayHRV(store: store, bundle: bundle, anchorDay: nightsFrom)
        let restingHR = await todayRestingHR(store: store, bundle: bundle, anchorDay: nightsFrom)
        return WidgetCorePublication.CoreDelivery(
            bpm: bpm,
            batteryPct: batteryPct,
            bonded: bonded,
            steps: steps,
            currentDayStrain: todayStrain(repository: repository, now: now, calendar: calendar),
            hrv: hrv,
            restingHR: restingHR,
            olderGenerationDay: olderGenerationDay)
    }

    /// The Steps figure Today shows right now. The core carries only the strap's count, and a HealthKit step sync
    /// never mints a generation, so Today's other two sources are read here, at delivery, through the same
    /// Repository reads Today loads them with and resolved by the same rule (`TodaySteps`): the strap's count,
    /// else Apple Health's count for the day, else the `steps_est` estimate.
    ///
    /// The day is the current logical day, which is the one Today shows. The strap's count is used only when the
    /// core is that day's (`WidgetCoreDay`); a core from an earlier day has yesterday's count, and Apple Health's
    /// count for yesterday is no better, so neither is read for any day but today's. The reads cover the last few
    /// days only; a failed read leaves nothing to show, never a number from another day.
    @MainActor
    static func todaySteps(
        repository: Repository,
        bundle: VerifiedExternalProjectionBundle,
        now: Date = Date(),
        calendar: Calendar = .current
    ) async -> Int? {
        let day = WidgetCoreDay.currentKey(now: now, calendar: calendar)
        let strap = WidgetCoreDay.isCurrent(bundle.widgetCore.logicalDay, now: now, calendar: calendar)
            ? bundle.widgetCore.steps : nil
        let phone = await repository.appleDailyRows(days: 3, now: now).last(where: { $0.day == day })?.steps
        let estimate = await repository.exploreSeries(key: "steps_est", source: "my-whoop", days: 3, now: now)
            .last(where: { $0.day == day }).map { Int($0.value.rounded()) }
        return TodaySteps(daily: strap, apple: phone, estimate: estimate).value
    }

    /// The stored-scale Strain Today shows for the current logical day, or nil when there is none.
    @MainActor
    static func todayStrain(repository: Repository, now: Date, calendar: Calendar = .current) -> Double? {
        let key = WidgetCoreDay.currentKey(now: now, calendar: calendar)
        guard let day = try? CivilDay(key: key) else { return nil }
        return liveStoredStrain(repository.canonicalStrain(for: key), day: day)
    }

    /// The HRV scalar for `anchorDay` (`WidgetCoreDay.nightlyAnchor`), computed in the core path so every core
    /// carries it: that night's own RMSSD, else the freshest earlier night inside the window Today carries one
    /// for (`CarriedVitalWindow`), read from the bundle's sources by the rule the enrichment uses. A failed read
    /// leaves nil.
    static func todayHRV(
        store: WhoopStore?,
        bundle: VerifiedExternalProjectionBundle,
        anchorDay: CivilDay
    ) async -> Int? {
        guard let store else { return nil }
        let series = (try? await verifiedHRVSeries(
            store: store,
            sourceIds: bundle.verifiedEnrichmentSourceIds,
            anchorDay: anchorDay,
            dayCount: CarriedVitalWindow.maximumAgeDays + 1)) ?? []
        return widgetHRVProjection(from: series, anchorDay: anchorDay).current
    }

    /// The Resting HR Today shows for `anchorDay` (`WidgetCoreDay.nightlyAnchor`), with Apple Health in it. The exact read behind the core
    /// is the strap's only, but Today's row takes Apple's Resting HR wherever the strap has none, and a HealthKit
    /// sync never mints a generation, so Apple's nights are read here, at delivery, like Steps. The strap's
    /// nights come from the bundle's own sources in their precedence order, Apple's from its own source; the
    /// rule is `resolvedRestingHR`. nil when the read fails, and then the core's own value stands.
    static func todayRestingHR(
        store: WhoopStore?,
        bundle: VerifiedExternalProjectionBundle,
        anchorDay: CivilDay
    ) async -> Int? {
        guard let store, let first = try? CarriedVitalWindow.earliestDay(anchorDay: anchorDay) else { return nil }
        var strap: [String: Int] = [:]
        var apple: [String: Int] = [:]
        do {
            for sourceId in bundle.verifiedEnrichmentSourceIds where !nonStrapSourceIds.contains(sourceId) {
                for row in try await store.dailyMetrics(deviceId: sourceId, from: first.key, to: anchorDay.key)
                where strap[row.day] == nil {
                    if let rhr = row.restingHr { strap[row.day] = rhr }
                }
            }
            for row in try await store.dailyMetrics(
                deviceId: Repository.appleHealthSource, from: first.key, to: anchorDay.key) {
                if let rhr = row.restingHr { apple[row.day] = rhr }
            }
        } catch {
            return nil
        }
        return resolvedRestingHR(strap: strap, apple: apple, anchorDay: anchorDay)
    }

    /// Today's Resting HR for `anchorDay`, by night: the strap's value, else Apple Health's, as the day's merged
    /// row takes them; for the anchor day itself, else the freshest earlier night that has one inside
    /// `CarriedVitalWindow`. A night whose winning value is implausible is skipped, never replaced by the other
    /// source's, exactly as the exact read does.
    static func resolvedRestingHR(strap: [String: Int], apple: [String: Int], anchorDay: CivilDay) -> Int? {
        for day in Set(strap.keys).union(apple.keys).filter({ $0 <= anchorDay.key }).sorted(by: >) {
            guard CarriedVitalWindow.permits(day: day, anchorDay: anchorDay.key) else { break }
            if let rhr = strap[day] ?? apple[day], (20...300).contains(rhr) { return rhr }
        }
        return nil
    }

    /// The logical day of the generation the App Group envelope currently holds, when that generation is older
    /// than `generation` and belongs to the same epoch and context. Read from its immutable bundle, because the
    /// envelope itself does not record a day. nil when there is no such envelope or the bundle is gone, and then
    /// no enrichment is carried across generations.
    @MainActor
    private static func publishedLogicalDay(
        model: AppModel,
        defaults: UserDefaults,
        token: VerifiedSinkToken,
        olderThan generation: Int64
    ) async -> (generation: Int64, day: CivilDay)? {
        guard let existing = VerifiedWidgetEnvelopeStore.rawActiveEnvelope(defaults: defaults),
              existing.epoch == token.epoch,
              existing.contextId == token.contextId,
              existing.generation < generation,
              let store = await model.repo.storeHandle(),
              let bundle = try? await store.verifiedExternalProjectionBundle(
                contextId: existing.contextId,
                generation: existing.generation) else { return nil }
        return (existing.generation, bundle.widgetCore.logicalDay)
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

    /// Convert verified HRV history into the scalar and sparkline that the widget renders. Invalid values
    /// are omitted without touching Recovery or Strain.
    ///
    /// With an `anchorDay` the scalar is the anchor day's own night, or else the freshest earlier night inside
    /// the window Today carries one for (`CarriedVitalWindow`). Without it the scalar is the newest point.
    static func widgetHRVProjection(
        from series: [(day: String, value: Double)],
        anchorDay: CivilDay? = nil
    ) -> (current: Int?, sparkline: [Int]) {
        let points = series.compactMap { point -> (day: String, value: Int)? in
            guard point.value.isFinite else { return nil }
            let rounded = Int(point.value.rounded())
            return (5...300).contains(rounded) ? (point.day, rounded) : nil
        }
        let sparkline = Array(points.map(\.value).suffix(12))
        guard let anchorDay else { return (points.last?.value, sparkline) }
        let current = points.last { CarriedVitalWindow.permits(day: $0.day, anchorDay: anchorDay.key) }?.value
        return (current, sparkline)
    }

    /// Regression seam for optional enrichment. The returned base is always the immutable verified envelope;
    /// `loadForDisplay` is intentionally excluded because it may contain a transient live overlay.
    static func verifiedEnrichmentBase(
        defaults: UserDefaults,
        token: VerifiedSinkToken,
        contextId: String,
        generation: Int64
    ) -> WidgetSnapshot? {
        guard let active = ActiveVerifiedSinkEpochStore.activeToken(defaults: defaults),
              active == token,
              let envelope = VerifiedWidgetEnvelopeStore.rawActiveEnvelope(defaults: defaults),
              envelope.epoch == token.epoch,
              envelope.contextId == contextId,
              envelope.generation == generation else { return nil }
        return envelope.snapshot
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
        let anchorDay = WidgetCoreDay.nightlyAnchor(bundle: bundle, now: Date())
        let hrvSeries: [(day: String, value: Double)]?
        if let store = await model.repo.storeHandle() {
            hrvSeries = try? await verifiedHRVSeries(
                store: store,
                sourceIds: bundle.verifiedEnrichmentSourceIds,
                anchorDay: anchorDay
            )
        } else {
            hrvSeries = nil
        }
        let hrvSparkline = widgetHRVProjection(from: hrvSeries ?? []).sparkline
        let stress = await enrichmentStress(
            store: await model.repo.storeHandle(), bundle: bundle, now: Date())
        guard let defaults = UserDefaults(suiteName: WidgetSnapshot.suiteName),
              let committed = commitEnrichment(
                defaults: defaults,
                token: token,
                bundle: bundle,
                hrvSparkline: hrvSparkline,
                stress: stress,
                now: Date()),
              committed.result == .published || committed.result == .alreadyCurrent else { return }
        WidgetLivePublishGate.notePublished(committed.snapshot, at: Date())
        WidgetTimelineReloads.afterVerifiedCommit(committed.result, key: WidgetEnrichmentKey(
            epoch: token.epoch, contextId: projection.contextId, generation: projection.generation))
    }

    /// Write the enrichment onto the committed core of its generation. Start from the immutable verified payload,
    /// never the display view. The display view may contain a transient live overlay; baking it back into the
    /// envelope would turn non-durable HR/battery fields into verified state and could resurrect them after a
    /// transition or relaunch. The HRV scalar is not written here: the core's delivery owns it
    /// (`CoreDelivery.hrv`), read for the night Today's row is for (`WidgetCoreDay.nightlyAnchor`), and this
    /// enrichment, anchored on the logical day, used to overwrite it with another night's value. Only the history
    /// strip is written, read up to that same anchor. nil when the envelope is no longer this generation's.
    ///
    /// The strip was computed for a day that was current when the enrichment started, but the scan can straddle
    /// 04:00, and a re-commit of the same generation then restamps the core after the rollover. The day is
    /// checked again here, so a strip is only ever written into a core of its own logical day.
    @MainActor
    static func commitEnrichment(
        defaults: UserDefaults,
        token: VerifiedSinkToken,
        bundle: VerifiedExternalProjectionBundle,
        hrvSparkline: [Int],
        stress: (hours: [Double?]?, summary: String?),
        now: Date,
        calendar: Calendar = .current
    ) -> (snapshot: WidgetSnapshot, result: VerifiedProjectionGenerationWriteResult)? {
        let projection = bundle.projection
        guard var enriched = verifiedEnrichmentBase(
            defaults: defaults,
            token: token,
            contextId: projection.contextId,
            generation: projection.generation) else { return nil }
        enriched.hrvSparkline = hrvSparkline
        enriched.hourlyStress = stress.hours
        enriched.stressSummary = stress.summary
        if !WidgetCoreDay.isCurrent(bundle.widgetCore.logicalDay, now: now, calendar: calendar)
            || !WidgetStressFreshness.isCurrent(updated: enriched.updated, now: now, calendar: calendar) {
            enriched.hourlyStress = nil
            enriched.stressSummary = nil
        }
        let result = VerifiedWidgetEnvelopeStore.commit(
            token: token,
            generation: projection.generation,
            snapshot: enriched,
            defaults: defaults
        )
        return (enriched, result)
    }

    /// Sources whose daily rows are not the strap's: Apple Health (HRV there is SDNN), Health Connect and the
    /// activity-file importer. A test pins these to `Repository`'s constants.
    static let nonStrapSourceIds: Set<String> = [Repository.appleHealthSource, "health-connect", "activity-file"]

    /// The stress strip and summary the enrichment writes for the bundle's day. A day that is behind the current
    /// logical day gets none: its strip is yesterday's, and computing it again would only restamp it as today's.
    /// Legacy core rows did not persist the day-defining time zone either; optional stress is then omitted
    /// instead of mixing their verified headline with a wall-clock day or mutable active-source union.
    @MainActor
    static func enrichmentStress(
        store: WhoopStore?,
        bundle: VerifiedExternalProjectionBundle,
        now: Date,
        calendar: Calendar = .current
    ) async -> (hours: [Double?]?, summary: String?) {
        guard WidgetCoreDay.isCurrent(bundle.widgetCore.logicalDay, now: now, calendar: calendar),
              let store,
              let recordedTimeZoneIdentifier = bundle.widgetCore.recordedTimeZoneIdentifier else { return (nil, nil) }
        return (try? await verifiedDashboardStress(
            store: store,
            sourceIds: bundle.verifiedEnrichmentSourceIds,
            anchorDay: bundle.widgetCore.logicalDay,
            timeZoneIdentifier: recordedTimeZoneIdentifier
        )) ?? (nil, nil)
    }

    /// Read exact immutable namespaces. Repository's canonical `my-whoop`
    /// alias intentionally unions the current active source, which is unsafe for
    /// a delayed verified generation. The source order captured by the bundle is
    /// the precedence order; the first value for a day wins.
    ///
    /// The value is `daily_metrics.avgHrv`, the nightly RMSSD Today shows. The strap pipeline writes it there
    /// and never to the `hrv` metric series, which only file importers fill. Apple Health's `avgHrv` is SDNN, a
    /// different quantity, and DL-11 keeps it from filling or outranking RMSSD. A namespace never lists it, but a
    /// repaired legacy core lists whichever source its projection metrics came from, so it is excluded here,
    /// with the other sources that are not the strap's (`nonStrapSourceIds`), however `sourceIds` is built.
    static func verifiedHRVSeries(
        store: WhoopStore,
        sourceIds: [String],
        anchorDay: CivilDay,
        dayCount: Int = 30
    ) async throws -> [(day: String, value: Double)] {
        var calendar = Calendar(identifier: .gregorian)
        calendar.locale = Locale(identifier: "en_US_POSIX")
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        let anchorDate = try anchorDay.date(in: calendar)
        guard let firstDate = calendar.date(
            byAdding: .day,
            value: -(max(1, dayCount) - 1),
            to: anchorDate
        ) else { throw CivilDayError.unrepresentableDate }
        let firstComponents = calendar.dateComponents([.year, .month, .day], from: firstDate)
        guard let year = firstComponents.year,
              let month = firstComponents.month,
              let day = firstComponents.day else {
            throw CivilDayError.unrepresentableDate
        }
        let firstDay = try CivilDay(year: year, month: month, day: day)

        var byDay: [String: Double] = [:]
        for sourceId in sourceIds where !nonStrapSourceIds.contains(sourceId) {
            try Task.checkCancellation()
            let rows = try await store.dailyMetrics(
                deviceId: sourceId,
                from: firstDay.key,
                to: anchorDay.key
            )
            try Task.checkCancellation()
            for row in rows where byDay[row.day] == nil {
                if let hrv = row.avgHrv { byDay[row.day] = hrv }
            }
        }
        return byDay.keys.sorted().compactMap { day in
            byDay[day].map { (day: day, value: $0) }
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
        let (next, overlay) = WidgetCorePublication.assembleLive(
            previous: previous,
            base: base,
            coreStrain: VerifiedWidgetEnvelopeStore.rawActiveEnvelope(defaults: defaults)?.snapshot.strain,
            token: token,
            verified: verified,
            bpm: model.bpm ?? model.live.heartRate,
            batteryPct: model.live.batteryPct,
            bonded: WidgetCorePublication.widgetBonded(model.live),
            workoutSparkline: model.activeWorkout.map { Array($0.samples.suffix(48).map(\.bpm)) },
            // The Strain Today shows for the current logical day. With none, the core's own Strain stands only
            // while the core is that day's.
            todayStrain: { model.repo.canonicalStrain(for: $0) },
            now: now)
        guard WidgetLivePublishGate.shouldPublish(previous: previous, next: next, now: now) else { return }
        guard ActiveVerifiedSinkEpochStore.commitLiveOverlayIfCurrent(
            token: token,
            generation: verified.generation,
            defaults: defaults,
            overlay: overlay) else { return }
        WidgetLivePublishGate.notePublished(next, at: now)
        WidgetTimelineReloads.afterLivePublish(previous: previous, next: next)
    }

    /// The live Strain to lay over the core: the one Today resolves for the generation's own day, in the stored
    /// scale, or nil when there is none for that day.
    static func liveStoredStrain(_ resolved: ResolvedStrain?, day: CivilDay) -> Double? {
        guard let resolved, resolved.day == day.key, resolved.storedValue.isFinite else { return nil }
        return resolved.storedValue
    }

    /// Measured HR and its PPG fallback share one timestamp per source, so the number of seconds
    /// in this civil day is a complete HR row bound, including a daylight-saving repeat hour.
    static func stressInputBounds(
        start: TimeInterval,
        endExclusive: TimeInterval
    ) throws -> (from: Int, to: Int, hrLimit: Int) {
        guard let from = Int(exactly: start), let end = Int(exactly: endExclusive) else {
            throw CivilDayError.unrepresentableDate
        }
        let (seconds, overflow) = end.subtractingReportingOverflow(from)
        guard !overflow, seconds > 0 else { throw CivilDayError.unrepresentableDate }
        return (from, end - 1, seconds)
    }

    static func verifiedStressInput(
        store: WhoopStore,
        sourceIds: [String],
        anchorDay: CivilDay,
        timeZoneIdentifier: String
    ) async throws -> (hr: [HRSample], rr: [RRInterval], timeZoneOffsetSeconds: Int) {
        guard let zone = TimeZone(identifier: timeZoneIdentifier) else {
            throw CivilDayError.unrepresentableDate
        }
        var calendar = Calendar(identifier: .gregorian)
        calendar.locale = Locale(identifier: "en_US_POSIX")
        calendar.timeZone = zone
        let startDate = try anchorDay.date(in: calendar)
        guard let endDate = calendar.date(byAdding: .day, value: 1, to: startDate) else {
            throw CivilDayError.unrepresentableDate
        }
        let bounds = try stressInputBounds(
            start: startDate.timeIntervalSince1970,
            endExclusive: endDate.timeIntervalSince1970)

        var hrByTimestamp: [Int: HRSample] = [:]
        var rrByTimestamp: [Int: [RRInterval]] = [:]
        var seenSourceIds = Set<String>()
        for sourceId in sourceIds
            .map({ $0.trimmingCharacters(in: .whitespacesAndNewlines) })
            .filter({ !$0.isEmpty && seenSourceIds.insert($0).inserted }) {
            try Task.checkCancellation()
            for sample in try await store.hrSamples(
                deviceId: sourceId,
                from: bounds.from,
                to: bounds.to,
                limit: bounds.hrLimit
            ) where hrByTimestamp[sample.ts] == nil {
                hrByTimestamp[sample.ts] = sample
            }
            // RR can contain several distinct or equal beats in one second, so no one-row-per-second
            // cap is valid. Keep the complete civil-day window and its existing transport selection:
            // narrowing it into pages would change WHOOP 5's whole-window source choice.
            let sourceRR = try await store.rrIntervals(
                deviceId: sourceId,
                from: bounds.from,
                to: bounds.to,
                limit: Int.max
            )
            for group in Dictionary(grouping: sourceRR, by: \.ts)
                where rrByTimestamp[group.key] == nil {
                rrByTimestamp[group.key] = group.value
            }
        }
        let hr = hrByTimestamp.values.sorted { $0.ts < $1.ts }
        let rr = rrByTimestamp.keys.sorted().flatMap { rrByTimestamp[$0] ?? [] }
        return (hr, rr, zone.secondsFromGMT(for: startDate))
    }

    static func verifiedDashboardStress(
        store: WhoopStore,
        sourceIds: [String],
        anchorDay: CivilDay,
        timeZoneIdentifier: String
    ) async throws -> (hours: [Double?]?, summary: String?) {
        let input = try await verifiedStressInput(
            store: store,
            sourceIds: sourceIds,
            anchorDay: anchorDay,
            timeZoneIdentifier: timeZoneIdentifier
        )
        let hr = input.hr
        guard hr.count >= DaytimeStress.minHourHRSamples else { return (nil, nil) }

        // DaytimeStress fingerprints and then buckets dense full-day HR and R-R rows. `publish` is
        // MainActor-isolated because it reads app state and writes WidgetKit, but the pure numeric scan does
        // not belong on the UI executor. Return only the tiny widget projection to the main actor.
        return await Task.detached(priority: .utility) {
            let result = DaytimeStress.analyze(
                hr: hr,
                rr: input.rr,
                tzOffsetSeconds: input.timeZoneOffsetSeconds
            )
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
