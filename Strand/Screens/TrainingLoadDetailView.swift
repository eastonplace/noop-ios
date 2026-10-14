import SwiftUI
import Charts
import StrandDesign
import StrandAnalytics
import WhoopStore

struct TrainingLoadDetailRequest {
    let key: TrendsScreenSnapshotKey
    let sourceID: String
    let rangeDays: Int
}

/// Capture source ownership at the link, rather than after a destination's asynchronous read starts.
struct TrainingLoadDetailLink<Label: View>: View {
    let key: TrendsScreenSnapshotKey
    let rangeDays: Int
    let label: () -> Label
    @EnvironmentObject private var repo: Repository

    init(key: TrendsScreenSnapshotKey, rangeDays: Int, @ViewBuilder label: @escaping () -> Label) {
        self.key = key; self.rangeDays = rangeDays; self.label = label
    }

    var body: some View {
        let request = TrainingLoadDetailRequest(key: key, sourceID: TrainingLoadDetailView.sourceID(repo), rangeDays: rangeDays)
        NavigationLink {
            TrainingLoadDetailView(request: request)
                .environment(\.screenScaffoldNavigationRole, .detail)
        } label: { label().contentShape(Rectangle()) }
        .buttonStyle(PaperPressStyle())
        .accessibilityHint("Opens dated training load, coverage and calculation details")
        .accessibilityIdentifier("trends.trainingLoad.open")
    }
}

/// A bounded read of the same canonical Trends projection. TrainingLoadEngine remains the only calculator.
struct TrainingLoadDetailView: View {
    let request: TrainingLoadDetailRequest
    @EnvironmentObject private var repo: Repository
    @Environment(\.dismiss) private var dismiss
    @AppStorage(UnitPrefs.effortScaleKey) private var effortScaleRaw = EffortScale.whoop.rawValue
    @State private var result: TrainingLoadEngine.Result?
    @State private var failure: String?
    @State private var loading = true
    @State private var period = 42
    @State private var selection: Date?
    @State private var showMethod = false
    @State private var showRows = false
    @State private var readID = UUID()

    @MainActor static func sourceID(_ repo: Repository) -> String {
        repo.todayHealthSnapshotScopeId + "|" + repo.liveSourceState.lineageComponent
            + "|" + String(repo.externalSurfaceInvalidationEpoch)
    }

    private var contextIsCurrent: Bool {
        request.sourceID == Self.sourceID(repo)
            && request.key.revision == Int(truncatingIfNeeded: repo.refreshSeq &+ Int(repo.canonicalHealth.trendsRevision))
            && !repo.verifiedExternalSurfaceFenced
    }
    private var calendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: request.key.timeZoneIdentifier) ?? .autoupdatingCurrent
        return calendar
    }
    private var dayFormat: Date.FormatStyle {
        .init(date: .abbreviated, time: .omitted, locale: .autoupdatingCurrent,
              calendar: calendar, timeZone: calendar.timeZone)
    }
    private var anchor: Date { date(request.key.anchorDay) ?? Date() }
    private var rangeStart: Date { calendar.date(byAdding: .day, value: 1 - period, to: anchor) ?? anchor }
    private var displayed: [LoadDay] {
        let raw = result?.points.compactMap { point -> LoadDay? in
            guard let day = date(point.day), day >= rangeStart else { return nil }
            return LoadDay(point: point, date: day, run: 0)
        } ?? []
        var run = 0
        var previous: Date?
        return raw.map { point in
            if let previous, (calendar.dateComponents([.day], from: previous, to: point.date).day ?? 0) > 1 { run += 1 }
            previous = point.date
            return LoadDay(point: point.point, date: point.date, run: run)
        }
    }
    private var selected: LoadDay? {
        guard let selection else { return displayed.last }
        return displayed.first { calendar.isDate($0.date, inSameDayAs: selection) }
    }

    var body: some View {
        ScreenScaffold(title: "Training load", lazy: true, headerContext: request.key.anchorDay) {
            if !contextIsCurrent {
                state(title: "The source records changed", detail: "Return to Trends and open Training load again to use the current records.")
                Button("Back to Trends") { dismiss() }.buttonStyle(SecondaryPillButtonStyle())
            } else if loading {
                VStack(alignment: .leading, spacing: 14) {
                    HStack { ProgressView(); Text("Reading dated load history").font(StrandFont.subhead) }
                    Text("Using the same source and date as Trends.").font(StrandFont.footnote)
                        .foregroundStyle(StrandPalette.textTertiary)
                    RoundedRectangle(cornerRadius: 8).fill(StrandPalette.inset).frame(height: 180)
                        .accessibilityHidden(true)
                }
            } else if let failure {
                state(title: "Could not read this history", detail: failure)
                Button("Try again") { readID = UUID() }.buttonStyle(SecondaryPillButtonStyle())
            } else if let result {
                if result.isAvailable { loadContent(result) }
                else { state(title: "Building your load history", detail: unavailable(result)) }
                coverage(result)
                method
                NavigationLink { WorkoutsView() } label: {
                    HStack {
                        Label("View workout history", systemImage: "figure.run")
                        Spacer()
                        Image(systemName: "arrow.up.right")
                    }
                    .font(StrandFont.subhead).frame(minHeight: 52).contentShape(Rectangle())
                }.buttonStyle(PaperPressStyle())
                Text("These values describe recorded daily Effort. They do not change Readiness or provide medical clearance.")
                    .font(StrandFont.footnote).foregroundStyle(StrandPalette.textTertiary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .segmentedPillSelectionStyle(.quiet)
        .task(id: readID) { await load() }
        .onChange(of: period) { _, _ in selection = nil }
        .onChange(of: effortScaleRaw) { _, _ in selection = nil }
        .accessibilityIdentifier("trends.trainingLoad.detail")
    }

    @ViewBuilder private func loadContent(_ result: TrainingLoadEngine.Result) -> some View {
        let points = displayed
        VStack(alignment: .leading, spacing: NoopMetrics.space4) {
            SectionEyebrow("Load over time", systemImage: "flame", tint: .strain,
                           trailing: .text(result.state == .established ? "Established" : "Building"))
            Text("See how recent effort compares with your longer baseline.")
                .font(StrandFont.title2).fixedSize(horizontal: false, vertical: true)
            SegmentedPillControl([28, 42, 90, 180], selection: $period) { "\($0)D" }
                .accessibilityLabel("Displayed history")
                .accessibilityValue("\(period) calendar days")
            Chart {
                ForEach(points) { day in
                    LineMark(x: .value("Day", day.date), y: .value("Acute", day.acute),
                             series: .value("Series", "acute-\(day.run)"))
                        .foregroundStyle(StrandPalette.strainAccent)
                        .lineStyle(StrokeStyle(lineWidth: 2.5)).interpolationMethod(.linear)
                    LineMark(x: .value("Day", day.date), y: .value("Chronic", day.chronic),
                             series: .value("Series", "chronic-\(day.run)"))
                        .foregroundStyle(StrandPalette.textSecondary)
                        .lineStyle(StrokeStyle(lineWidth: 1.75, dash: [5, 3])).interpolationMethod(.linear)
                }
                if let selection {
                    RuleMark(x: .value("Selected day", calendar.startOfDay(for: selection)))
                        .foregroundStyle(StrandPalette.textTertiary.opacity(0.5))
                }
            }
            .chartXScale(domain: rangeStart...anchor)
            .environment(\.calendar, calendar)
            .environment(\.timeZone, calendar.timeZone)
            .chartLegend(.hidden)
            .chartXSelection(value: $selection)
            .chartYAxis { AxisMarks(position: .leading, values: .automatic(desiredCount: 4)) }
            .frame(height: 200)
            .accessibilityLabel("Acute and chronic load from observed daily Effort")
            .accessibilityIdentifier("trends.trainingLoad.chart")
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 18) { legend }
                VStack(alignment: .leading, spacing: 8) { legend }
            }
            inspector
            DisclosureGroup("Dated values", isExpanded: $showRows) {
                VStack(spacing: 0) {
                    ForEach(points.reversed()) { day in
                        VStack(alignment: .leading, spacing: 5) {
                            Text(day.date.formatted(dayFormat)).font(StrandFont.footnote.weight(.semibold))
                            Text("Acute \(number(day.acute)) · Chronic \(number(day.chronic)) · Balance \(signed(day.balance))")
                                .font(StrandFont.footnote).foregroundStyle(StrandPalette.textSecondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        .frame(maxWidth: .infinity, alignment: .leading).padding(.vertical, 10)
                        .overlay(alignment: .bottom) { Rectangle().fill(StrandPalette.hairline).frame(height: 1) }
                        .accessibilityElement(children: .combine)
                    }
                }
            }.font(StrandFont.footnote)
        }
    }

    @ViewBuilder private var legend: some View {
        Label { Text("Acute · 7-day response") } icon: {
            Rectangle().fill(StrandPalette.strainAccent).frame(width: 18, height: 2)
        }
        .font(StrandFont.micro).foregroundStyle(StrandPalette.textSecondary)
        Label { Text("Chronic · 42-day baseline") } icon: {
            HStack(spacing: 2) { Rectangle().frame(width: 7, height: 2); Rectangle().frame(width: 7, height: 2) }
        }
        .font(StrandFont.micro).foregroundStyle(StrandPalette.textSecondary)
    }

    private var inspector: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text((selection ?? displayed.last?.date ?? anchor).formatted(dayFormat))
                .font(StrandFont.footnote.weight(.semibold))
            if let day = selected {
                StatFooter(items: [("Acute", number(day.acute)), ("Chronic", number(day.chronic)),
                                   ("Balance", signed(day.balance))], style: .prominent)
                Text("Recorded Effort: \(number(StrainScale.displayValue(fromStored: day.point.load)))")
                    .font(StrandFont.footnote).foregroundStyle(StrandPalette.textSecondary)
            } else {
                Text("No modeled observation for this day. Missing values stay separate from recorded zero Effort.")
                    .font(StrandFont.footnote).foregroundStyle(StrandPalette.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading).padding(14)
        .background(StrandPalette.card, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .accessibilityIdentifier("trends.trainingLoad.inspector")
    }

    private func coverage(_ result: TrainingLoadEngine.Result) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            TodaySectionSeparator(above: 12, below: 12)
            SectionEyebrow("History coverage", systemImage: "calendar", tint: .neutral)
            Text("\(result.contiguousDays) observed days across \(result.spanDays) calendar days")
                .font(StrandFont.subhead).fixedSize(horizontal: false, vertical: true)
            if let coverage = result.coverage {
                ProgressView(value: min(1, max(0, coverage))).tint(StrandPalette.strainAccent)
                    .accessibilityLabel("Observed-day coverage")
                    .accessibilityValue(coverage.formatted(.percent.precision(.fractionLength(0))))
            }
            Text("The model needs 14 observed days to begin and 42 to reach its established state. Gaps of up to two days can remain in the modeled span.")
                .font(StrandFont.footnote).foregroundStyle(StrandPalette.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var method: some View {
        DisclosureGroup("How this is calculated", isExpanded: $showMethod) {
            VStack(alignment: .leading, spacing: 12) {
                Text("Both lines use exponentially weighted daily Effort. Recent values carry more weight. Seven and 42 days are model time constants; the chart range does not change them.")
                Text("Balance is chronic load minus acute load. The first seven observed days seed both lines.")
                Text("For gaps up to two days, the existing model decays its state with zero load internally. Those gap days are not measurements and have no observed chart point. A longer gap starts a new run.")
                Text("Dates use the Trends source time zone: " + request.key.timeZoneIdentifier)
            }
            .font(StrandFont.footnote).foregroundStyle(StrandPalette.textSecondary)
            .fixedSize(horizontal: false, vertical: true).padding(.top, 8)
        }.font(StrandFont.subhead).padding(.vertical, 14)
    }

    private func state(title: String, detail: String) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(LocalizedStringKey(title)).font(StrandFont.title2)
            Text(LocalizedStringKey(detail)).font(StrandFont.subhead)
                .foregroundStyle(StrandPalette.textSecondary).fixedSize(horizontal: false, vertical: true)
        }.padding(.vertical, 18)
    }
    private func unavailable(_ result: TrainingLoadEngine.Result) -> String {
        switch result.unavailableReason {
        case .missingTargetDay: "There is no usable Effort value for the selected end date."
        case .notEnoughContiguousDays: "This history has \(result.contiguousDays) observed days. The model needs 14 before it can show a load estimate."
        case .noData: "No daily Effort history is available for this source."
        default: "The source history cannot produce a valid load estimate. Check the records in Trends."
        }
    }
    private func date(_ key: String) -> Date? {
        let values = key.split(separator: "-").compactMap { Int($0) }
        guard values.count == 3 else { return nil }
        return calendar.date(from: DateComponents(year: values[0], month: values[1], day: values[2]))
    }
    private func number(_ value: Double) -> String { value.formatted(.number.precision(.fractionLength(1))) }
    private func signed(_ value: Double) -> String { (value > 0 ? "+" : "") + number(value) }

    @MainActor private func load() async {
        loading = true; failure = nil
        let token = readID
        guard contextIsCurrent else { loading = false; return }
        guard let data = await repo.loadCanonicalTrendsData(anchorDay: request.key.anchorDay,
            timeZoneIdentifier: request.key.timeZoneIdentifier, rangeDays: request.rangeDays,
            weekOffset: request.key.weekOffset) else {
            guard token == readID, !Task.isCancelled else { return }
            failure = "Try reading the selected source again."; loading = false; return
        }
        guard !Task.isCancelled, token == readID, contextIsCurrent else { return }
        guard data.anchorDay == request.key.anchorDay,
              data.timeZoneIdentifier == request.key.timeZoneIdentifier,
              let identity = data.loadIdentity,
              identity.anchorDay == request.key.anchorDay,
              identity.timeZoneIdentifier == request.key.timeZoneIdentifier,
              identity.rangeDays == request.rangeDays,
              identity.weekOffset == request.key.weekOffset else {
            failure = "The returned history belongs to another range. Return to Trends and try again."
            loading = false
            return
        }
        let history = Array(data.canonicalDays.filter { $0.day <= request.key.anchorDay }.suffix(TrainingLoadTrendsWindow.days))
        result = TrainingLoadEngine.evaluate(days: history.map { .init(day: $0.day, load: $0.strain) },
                                             through: request.key.anchorDay)
        loading = false
    }

    private struct LoadDay: Identifiable {
        let point: TrainingLoadEngine.Point
        let date: Date
        let run: Int
        var id: String { point.day }
        var acute: Double { StrainScale.displayValue(fromStored: point.acuteLoad) }
        var chronic: Double { StrainScale.displayValue(fromStored: point.chronicLoad) }
        var balance: Double { StrainScale.displayDelta(fromStored: point.balance) }
    }
}
