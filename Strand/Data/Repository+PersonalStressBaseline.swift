import Foundation
import StrandAnalytics
import WhoopProtocol
import WhoopStore

enum PersonalStressBaselinePreference {
    /// A display preference only. Background publishers do not read it or load trailing raw history.
    static let enabledKey = "noop.stress.personalBaseline.enabled"
}

/// Value ownership for an asynchronous foreground read. A source switch, database replacement,
/// import/backfill publication, or explicit data invalidation cannot publish an older source's lens.
struct StressReadScope: Equatable, Sendable {
    let sourceIDs: [String]
    let sourceContext: String
    let sourceLineage: String
    let repositoryRevision: Int
    let dataVersion: Int
    let invalidationEpoch: UInt64
    let isFenced: Bool
}

struct ForegroundStressTaskKey: Equatable, Sendable {
    let scope: StressReadScope
    let personalBaseline: Bool
    let dayStart: Int
    let timeZoneIdentifier: String
    let calendarRevision: Int

    init(scope: StressReadScope, personalBaseline: Bool, calendarRevision: Int = 0,
         now: Date = Date(), calendar: Calendar = .current) {
        self.scope = scope
        self.personalBaseline = personalBaseline
        self.dayStart = Int(calendar.startOfDay(for: now).timeIntervalSince1970)
        self.timeZoneIdentifier = calendar.timeZone.identifier
        self.calendarRevision = calendarRevision
    }
}

struct ForegroundStressRead: Sendable {
    let scope: StressReadScope
    let daytime: DaytimeStress.Result
    let baseline: PersonalStressBaseline.Resolution
    let stressIndex: StressIndex.Components?
    let frequencyDomain: HRVFreqDomain.Bands?
}

enum ForegroundStressReadError: Error {
    case storeUnavailable
}

@MainActor
extension Repository {
    var stressReadScope: StressReadScope {
        StressReadScope(sourceIDs: importedReadIds, sourceContext: notificationSourceContext,
                        sourceLineage: liveSourceState.lineageComponent,
                        repositoryRevision: refreshSeq, dataVersion: dataVersion,
                        invalidationEpoch: externalSurfaceInvalidationEpoch,
                        isFenced: verifiedExternalSurfaceFenced)
    }

    /// One foreground funnel for Stress detail and Today's hourly ribbon. Store reads and array work
    /// run off the main actor. No results are persisted and no background surface calls this method.
    func foregroundStressRead(
        now: Date = Date(), calendar: Calendar = .current,
        personalBaseline: Bool, includeAdvancedReadouts: Bool = false
    ) async throws -> ForegroundStressRead {
        try await readForegroundStress(now: now, calendar: calendar, personalBaseline: personalBaseline,
                                       includeAdvancedReadouts: includeAdvancedReadouts, afterRead: nil)
    }

    #if DEBUG
    func foregroundStressReadForTesting(
        now: Date, calendar: Calendar, personalBaseline: Bool,
        afterRead: @escaping @MainActor () async -> Void
    ) async throws -> ForegroundStressRead {
        try await readForegroundStress(now: now, calendar: calendar, personalBaseline: personalBaseline,
                                       includeAdvancedReadouts: false, afterRead: afterRead)
    }
    #endif

    private func readForegroundStress(
        now: Date, calendar: Calendar, personalBaseline: Bool, includeAdvancedReadouts: Bool,
        afterRead: (@MainActor () async -> Void)?
    ) async throws -> ForegroundStressRead {
        try Task.checkCancellation()
        guard !verifiedExternalSurfaceFenced else { throw CancellationError() }
        guard let store = await storeHandle() else { throw ForegroundStressReadError.storeUnavailable }
        try Task.checkCancellation()
        let scope = stressReadScope
        guard !scope.isFenced else { throw CancellationError() }
        let start = Int(calendar.startOfDay(for: now).timeIntervalSince1970)
        let end = Int(now.timeIntervalSince1970)
        let offset = calendar.timeZone.secondsFromGMT(for: now)
        let windows = personalBaseline ? PersonalStressBaseline.windows(before: now, calendar: calendar) : []

        let worker = Task.detached(priority: .utility) {
            async let baselineLoad = Self.readPersonalStressBaseline(
                store: store, ids: scope.sourceIDs, windows: windows, enabled: personalBaseline)
            let signals = try await Self.readStressSignals(
                store: store, ids: scope.sourceIDs, from: start, to: end)
            let baseline = try await baselineLoad
            try Task.checkCancellation()
            let result = ForegroundStressRead(
                scope: scope,
                daytime: DaytimeStress.analyze(
                    hr: signals.hr, rr: signals.rr, tzOffsetSeconds: offset, mode: baseline.mode),
                baseline: baseline,
                stressIndex: includeAdvancedReadouts ? StressIndex.components(rr: signals.rr) : nil,
                frequencyDomain: includeAdvancedReadouts ? HRVFreqDomain.freqDomain(rr: signals.rr) : nil)
            try Task.checkCancellation()
            return result
        }
        let result = try await withTaskCancellationHandler {
            try await worker.value
        } onCancel: {
            worker.cancel()
        }
        await afterRead?()
        try Task.checkCancellation()
        let currentStore = await storeHandle()
        try Task.checkCancellation()
        guard currentStore === store, result.scope == stressReadScope else { throw CancellationError() }
        return result
    }

    nonisolated private static func readPersonalStressBaseline(
        store: WhoopStore, ids: [String], windows: [PersonalStressBaseline.DayWindow], enabled: Bool
    ) async throws -> PersonalStressBaseline.Resolution {
        guard enabled else { return .disabled }
        do {
            var dailyHR: [Double?] = []
            dailyHR.reserveCapacity(PersonalStressBaseline.historyDays)
            for window in windows {
                try Task.checkCancellation()
                let hours = try await store.stressBaselineHourSummaries(
                    deviceIds: ids, windows: window.hours, plausibleBPM: HRValidity.bpmRange)
                try Task.checkCancellation()
                // Include missing days. A long gap must age the baseline instead of looking fresh.
                dailyHR.append(PersonalStressBaseline.aggregate(hours))
            }
            return PersonalStressBaseline.resolve(dailyHR: dailyHR)
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            // Reading failure is explicit in the section; a healthy same-day curve can still be shown.
            return .unavailable
        }
    }

    nonisolated private static func readStressSignals(
        store: WhoopStore, ids: [String], from: Int, to: Int
    ) async throws -> (hr: [HRSample], rr: [RRInterval]) {
        var hrBySecond: [Int: HRSample] = [:]
        var rr: [RRInterval] = []
        var occupiedRRSeconds = Set<Int>()
        for id in ids {
            try Task.checkCancellation()
            let sourceHR = try await store.hrSamples(deviceId: id, from: from, to: to, limit: 200_000)
            try Task.checkCancellation()
            for sample in sourceHR where hrBySecond[sample.ts] == nil { hrBySecond[sample.ts] = sample }
            let sourceRR = try await store.rrIntervals(deviceId: id, from: from, to: to, limit: 200_000)
            try Task.checkCancellation()
            // Preserve multiple beats in one second; only suppress a LOWER-PRIORITY source's second.
            rr.append(contentsOf: sourceRR.filter { !occupiedRRSeconds.contains($0.ts) })
            occupiedRRSeconds.formUnion(sourceRR.map(\.ts))
        }
        return (hrBySecond.values.sorted { $0.ts < $1.ts }, rr.sorted { $0.ts < $1.ts })
    }
}
