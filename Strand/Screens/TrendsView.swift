import SwiftUI
import Charts
import StrandDesign
import StrandAnalytics
import WhoopStore
import Foundation

private struct TrendsCivilContext: Equatable {
    let localDay: String
    let timeZoneIdentifier: String

    @MainActor static func current(at date: Date = Date()) -> Self {
        Self(localDay: Repository.localDayKey(date), timeZoneIdentifier: TimeZone.autoupdatingCurrent.identifier)
    }
}

struct TrendsView: View {
    @EnvironmentObject private var repo: Repository

    @State private var showingReport = false
    @State private var loadedData = TrendsLoadedData.empty
    @State private var screenSnapshot: TrendsScreenSnapshot?
    @State private var loadState = LatestWinsLoadState()
    @State private var civilContext = TrendsCivilContext.current()
    @State var selectedMetric: ProductionTrendMetric = .recovery
    @State var selectedRange: TrendRange = .month
    /// Zero is the current Monday-Sunday digest; negative values step backward.
    @State var weekOffset: Int

    init(initialWeekOffset: Int = 0) {
        _weekOffset = State(initialValue: TrendsBounds.clampWeekOffset(initialWeekOffset))
    }

    /// During the first frame, use Repository's already-published canonical projection. After the auxiliary
    /// reads finish, every Trends section consumes the same captured revision from `loadedData`.
    private var canonicalDays: [DailyMetric] {
        TrendsSnapshotHandoff.canonicalDays(
            loaded: loadedData,
            fallback: repo.canonicalDays
        )
    }

    var trendReferenceDate: Date {
        localDate(loadedData.anchorDay) ?? Calendar.current.startOfDay(for: Date())
    }

    private var screenSnapshotKey: TrendsScreenSnapshotKey {
        TrendsScreenSnapshotKey(
            revision: loadedData.revision,
            anchorDay: loadedData.anchorDay,
            timeZoneIdentifier: loadedData.timeZoneIdentifier,
            metric: selectedMetric.rawValue,
            range: selectedRange.rawValue,
            weekOffset: TrendsBounds.clampWeekOffset(weekOffset),
            completedLoadIdentity: loadedData.loadIdentity
        )
    }

    var currentScreenSnapshot: TrendsScreenSnapshot? {
        TrendsSnapshotHandoff.current(screenSnapshot, for: screenSnapshotKey)
    }

    /// Repository day keys are local civil days, not UTC instants.
    private func localDate(_ day: String, calendar: Calendar = .autoupdatingCurrent) -> Date? {
        let pieces = day.split(separator: "-").compactMap { Int($0) }
        guard pieces.count == 3 else { return nil }
        return calendar.date(from: DateComponents(year: pieces[0], month: pieces[1], day: pieces[2]))
    }

    var body: some View {
        #if os(macOS)
        NavigationStack { scaffold }
        #else
        scaffold
        #endif
    }

    private var scaffold: some View {
        ScreenScaffold(
            title: "Trends",
            subtitle: "Selected ranges and weekly reviews.",
            onRefresh: {
                _ = await repo.refresh(.currentDay)
                await loadDataForCurrentRevision()
            },
            lazy: true,
            topBackground: nil,
            trailing: {
                HStack(spacing: 12) {
                    NavigationLink {
                        TrendsExploreHubView()
                    } label: {
                        Label("Explore", systemImage: "square.grid.2x2")
                            .font(StrandFont.caption.weight(.semibold))
                            .padding(.horizontal, 10)
                            .frame(minWidth: 44, minHeight: 44)
                            .background(StrandPalette.inset, in: Capsule(style: .continuous))
                            .contentShape(Capsule(style: .continuous))
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Explore insights and metrics")
                    .accessibilityHint("Opens insights, comparisons, metrics, and experiments")
                    Button { showingReport = true } label: {
                        Image(systemName: "square.and.arrow.up")
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Share Trends")
                    .accessibilityHint("Opens a shareable Trends report")
                }
                .font(.system(size: 15, weight: .medium))
                .foregroundStyle(StrandPalette.textPrimary)
            }
        ) {
            if let message = loadState.errorMessage {
                NoopCard {
                    VStack(alignment: .leading, spacing: 10) {
                        Text("Trends could not refresh")
                            .font(StrandFont.headline)
                            .foregroundStyle(StrandPalette.textPrimary)
                        Text(message)
                            .font(StrandFont.subhead)
                            .foregroundStyle(StrandPalette.textSecondary)
                        Button {
                            Task { await loadDataForCurrentRevision() }
                        } label: {
                            Label("Try again", systemImage: "arrow.clockwise")
                        }
                        .buttonStyle(.bordered)
                    }
                }
            }
            if repo.days.isEmpty {
                ComingSoon(what: repo.loaded
                    ? "Trends need history to draw. Import your WHOOP export in Data Sources to see weeks, months and years instantly."
                    : "Loading your history…")
            } else {
                VStack(alignment: .leading, spacing: NoopMetrics.sectionSpacing) {
                    paperScoresOverTime
                    paperWeekReview
                }
            }
        }
        .sheet(isPresented: $showingReport) {
            TrendsReportSheet(days: canonicalDays)
        }
        .background {
            TimelineView(.periodic(from: .now, by: 60)) { timeline in
                Color.clear
                    .task(id: TrendsCivilContext.current(at: timeline.date)) {
                        civilContext = TrendsCivilContext.current(at: timeline.date)
                    }
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: .NSSystemTimeZoneDidChange)) { _ in
            civilContext = .current()
        }
        .onReceive(NotificationCenter.default.publisher(for: UIApplication.significantTimeChangeNotification)) { _ in
            civilContext = .current()
        }
        // A rescore can replace values without changing the number of day rows. `refreshSeq`, not count,
        // is the revision contract. `.task(id:)` cancels a superseded load; one assignment below prevents
        // Sleep, Stress, and Apple fallback data from briefly describing different revisions.
        .task(id: "\(repo.refreshSeq)-\(repo.canonicalHealth.trendsRevision)-\(civilContext.localDay)-\(civilContext.timeZoneIdentifier)-\(selectedRange.rawValue)-\(weekOffset)") {
            await loadDataForCurrentRevision()
        }
        .task(id: screenSnapshotKey) {
            await rebuildScreenSnapshot()
        }
    }

    @MainActor
    private func loadDataForCurrentRevision() async {
        let boundedRangeDays = TrendsBounds.clampRangeDays(selectedRange.days)
        let boundedOffset = TrendsBounds.clampWeekOffset(weekOffset)
        guard boundedOffset == weekOffset else {
            weekOffset = boundedOffset
            return
        }
        let requestID = loadState.begin()
        let revision = Int(truncatingIfNeeded: repo.refreshSeq
            &+ Int(repo.canonicalHealth.trendsRevision))
        let anchorDay = civilContext.localDay
        let timeZoneIdentifier = civilContext.timeZoneIdentifier
        let rangeDays = boundedRangeDays
        let offset = boundedOffset
        guard let next = await repo.loadCanonicalTrendsData(
            anchorDay: anchorDay,
            timeZoneIdentifier: timeZoneIdentifier,
            rangeDays: rangeDays,
            weekOffset: offset
        ) else {
            _ = loadState.finish(
                .failed("NOOP could not read the selected Trends range."),
                requestID: requestID)
            return
        }
        guard !Task.isCancelled else {
            _ = loadState.finish(.cancelled, requestID: requestID)
            return
        }
        guard loadState.owns(requestID),
              revision == Int(truncatingIfNeeded: repo.refreshSeq
                &+ Int(repo.canonicalHealth.trendsRevision)),
              anchorDay == civilContext.localDay,
              timeZoneIdentifier == civilContext.timeZoneIdentifier,
              rangeDays == TrendsBounds.clampRangeDays(selectedRange.days),
              offset == TrendsBounds.clampWeekOffset(weekOffset)
        else {
            _ = loadState.finish(.cancelled, requestID: requestID)
            return
        }
        let revisionAdjusted = TrendsLoadedData(
            loadIdentity: next.loadIdentity,
            revision: revision,
            anchorDay: next.anchorDay,
            timeZoneIdentifier: next.timeZoneIdentifier,
            canonicalDays: next.canonicalDays,
            sleepPerfByDay: next.sleepPerfByDay,
            stressByDay: next.stressByDay,
            appleDays: next.appleDays
        )
        if revisionAdjusted != loadedData { loadedData = revisionAdjusted }
        _ = loadState.finish(
            revisionAdjusted.canonicalDays.isEmpty ? .empty : .loaded,
            requestID: requestID)
    }

    @MainActor
    private func rebuildScreenSnapshot() async {
        let key = screenSnapshotKey
        let requestID = loadState.currentRequestID
        let data = loadedData
        guard data.revision >= 0 else { return }
        var calendar = Calendar.autoupdatingCurrent
        calendar.timeZone = TimeZone(identifier: data.timeZoneIdentifier) ?? .autoupdatingCurrent
        let referenceDate = localDate(data.anchorDay, calendar: calendar) ?? Date()
        let metric = selectedMetric
        let range = selectedRange
        let offset = TrendsBounds.clampWeekOffset(weekOffset)
        guard let identity = data.loadIdentity,
              identity.rangeDays == range.days,
              identity.weekOffset == offset,
              identity.anchorDay == civilContext.localDay,
              identity.timeZoneIdentifier == civilContext.timeZoneIdentifier else { return }
        let effortDisplayFactor = UnitPrefs.currentEffortDisplayFactor()

        let worker = Task { @concurrent in
            TrendsScreenSnapshot.build(
                key: key,
                data: data,
                metric: metric,
                range: range,
                weekOffset: offset,
                referenceDate: referenceDate,
                calendar: calendar,
                effortDisplayFactor: effortDisplayFactor
            )
        }
        let next = await withTaskCancellationHandler {
            await worker.value
        } onCancel: {
            worker.cancel()
        }
        if !Task.isCancelled,
           key == screenSnapshotKey,
           loadState.owns(requestID),
           next == nil,
           !data.canonicalDays.isEmpty {
            _ = loadState.finish(
                .failed("The selected Trends range could not be rendered."),
                requestID: requestID)
        }
        guard !Task.isCancelled, key == screenSnapshotKey, let next else { return }
        guard loadState.owns(requestID) else { return }
        screenSnapshot = next
    }
}
