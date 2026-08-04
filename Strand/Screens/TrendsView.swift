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
    @State private var civilContext = TrendsCivilContext.current()
    @State var selectedMetric: ProductionTrendMetric = .recovery
    @State var selectedRange: TrendRange = .month
    /// Zero is the current Monday-Sunday digest; negative values step backward.
    @State var weekOffset: Int

    init(initialWeekOffset: Int = 0) {
        _weekOffset = State(initialValue: min(0, initialWeekOffset))
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
            weekOffset: weekOffset
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
            onRefresh: { _ = await repo.refresh(.currentDay) },
            lazy: true,
            topBackground: nil,
            trailing: {
                HStack(spacing: 12) {
                    Image(systemName: "calendar")
                    Button { showingReport = true } label: {
                        Image(systemName: "square.and.arrow.up")
                    }
                    .buttonStyle(.plain)
                }
                .font(.system(size: 15, weight: .medium))
                .foregroundStyle(StrandPalette.textPrimary)
            }
        ) {
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
        .task(id: "\(repo.refreshSeq)-\(repo.canonicalHealth.trendsRevision)-\(civilContext.localDay)-\(civilContext.timeZoneIdentifier)") {
            await loadDataForCurrentRevision()
        }
        .task(id: screenSnapshotKey) {
            await rebuildScreenSnapshot()
        }
    }

    @MainActor
    private func loadDataForCurrentRevision() async {
        let revision = Int(truncatingIfNeeded: repo.refreshSeq
            &+ Int(repo.canonicalHealth.trendsRevision))
        let anchorDay = Repository.localDayKey(Date())
        let timeZoneIdentifier = TimeZone.autoupdatingCurrent.identifier
        let revisionDays = repo.canonicalDays
        let canonical = repo.canonicalHealth
        let sleep = canonical.sleepSeries(from: "0000-01-01", through: "9999-12-31")
        let stress = canonical.stressSeries(from: "0000-01-01", through: "9999-12-31")
        let apple = canonical.appleDailyByDay.values.map {
            AppleDaily(
                day: $0.day, steps: $0.steps, activeKcal: $0.activeKcal,
                basalKcal: $0.basalKcal, vo2max: $0.vo2max, avgHr: $0.avgHr,
                maxHr: $0.maxHr, walkingHr: $0.walkingHr, weightKg: $0.weightKg
            )
        }.sorted { $0.day < $1.day }
        guard !Task.isCancelled,
              revision == Int(truncatingIfNeeded: repo.refreshSeq
                &+ Int(repo.canonicalHealth.trendsRevision)),
              anchorDay == Repository.localDayKey(Date()),
              timeZoneIdentifier == TimeZone.autoupdatingCurrent.identifier
        else { return }

        let next = TrendsLoadedData(
            revision: revision,
            anchorDay: anchorDay,
            timeZoneIdentifier: timeZoneIdentifier,
            canonicalDays: revisionDays,
            sleepPerfByDay: Dictionary(
                sleep.map { ($0.day, $0.value) },
                uniquingKeysWith: { _, latest in latest }
            ),
            stressByDay: Dictionary(
                stress.map { ($0.day, $0.value) },
                uniquingKeysWith: { _, latest in latest }
            ),
            appleDays: apple
        )
        if next != loadedData {
            loadedData = next
        }
    }

    @MainActor
    private func rebuildScreenSnapshot() async {
        let key = screenSnapshotKey
        let data = loadedData
        guard data.revision >= 0 else { return }
        var calendar = Calendar.autoupdatingCurrent
        calendar.timeZone = TimeZone(identifier: data.timeZoneIdentifier) ?? .autoupdatingCurrent
        let referenceDate = localDate(data.anchorDay, calendar: calendar) ?? Date()
        let metric = selectedMetric
        let range = selectedRange
        let offset = weekOffset
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
        guard !Task.isCancelled, key == screenSnapshotKey, let next else { return }
        screenSnapshot = next
    }
}
