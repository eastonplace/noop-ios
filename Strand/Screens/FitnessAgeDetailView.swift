import SwiftUI
import StrandDesign
import StrandAnalytics
import WhoopStore

struct FitnessAgeDetailView: View {
    @EnvironmentObject private var repo: Repository
    @EnvironmentObject private var profile: ProfileStore

    @State private var series: [(day: String, value: Double)] = []
    @State private var vo2max: Double?
    @State private var loaded = false

    private static let dayFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = .current
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter
    }()

    var body: some View {
        ScreenScaffold(title: "Fitness Age", subtitle: "Your fitness compared with your calendar age", lazy: true) {
            if loaded {
                content
            } else {
                DataPendingNote(title: "Reading your Fitness Age",
                                message: "NOOP is loading your weekly history.", symbol: "figure.run")
            }
        }
        .task(id: repo.refreshSeq) { await load() }
        #if os(iOS)
        .toolbar(.hidden, for: .navigationBar)
        #endif
    }

    @ViewBuilder private var content: some View {
        FitnessAgeHero(
            fitnessAge: latestAge,
            chronologicalAge: chronologicalAge,
            railRange: FitnessAgePresentation.dynamicRailRange(
                fitnessAge: latestAge, chronologicalAge: chronologicalAge),
            uncertaintyYears: FitnessAgeEngine.displayBandYears)

        if let latestAge {
            sectionDivider
            FitnessAgePaceRow(pace: pace)
            sectionDivider
            driversSection
            if !trendPoints.isEmpty {
                sectionDivider
                FitnessAgeTrendChart(points: trendPoints)
            }
            contextSection(latestAge: latestAge)
        } else {
            calibrationSection
        }
    }

    private var driversSection: some View {
        VStack(alignment: .leading, spacing: 14) {
            componentLabel("The factors · impact said in years")
            if let inputs = weeklyInputs {
                let impacts = FitnessAgeEngine.driverImpacts(
                    age: chronologicalAge, sex: profile.sex,
                    restingHR: inputs.restingHR, paIndex: inputs.paIndex)
                FitnessAgeDriverRow(title: "Resting heart rate",
                                    value: "\(Int(inputs.restingHR.rounded())) bpm",
                                    impactYears: impacts.restingHRYears,
                                    systemImage: "heart.fill")
                Divider().overlay(StrandPalette.hairline)
                FitnessAgeDriverRow(title: "Recent activity",
                                    value: String(format: "PA index %.1f", inputs.paIndex),
                                    impactYears: impacts.activityYears,
                                    systemImage: "figure.run")
                Text("These are the only variable inputs in NOOP’s Fitness Age equation. Other health metrics add context but are not assigned invented year impacts.")
                    .font(StrandFont.footnote).foregroundStyle(StrandPalette.textTertiary)
            } else {
                Text("Driver details will appear when the current seven-day input window is complete.")
                    .font(StrandFont.footnote).foregroundStyle(StrandPalette.textTertiary)
            }
        }
    }

    private func contextSection(latestAge: Double) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            sectionDivider
            componentLabel("Context · useful, not causal")
            if let vo2max {
                HStack {
                    Text("Estimated VO₂max").font(StrandFont.subhead)
                    Spacer()
                    Text(String(format: "%.0f ml/kg/min", vo2max)).font(StrandFont.captionNumber)
                }
            }
            NavigationLink {
                if let metric = MetricCatalog.all.first(where: { $0.key == "fitness_age" }) {
                    MetricDetailView(metric: metric)
                }
            } label: {
                SettingsRow(icon: "chart.xyaxis.line", title: "Open full metric history",
                            subtitle: "Explore every Fitness Age reading")
            }
            .buttonStyle(.plain)
            Text("Latest weekly comparison: \(String(format: "%.1f", latestAge)) years. This is not a diagnosis or a biological-age measurement.")
                .font(StrandFont.footnote).foregroundStyle(StrandPalette.textTertiary)
        }
    }

    private var calibrationSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            SectionHeader("Still calibrating", overline: readiness.confidence == .notReady ? "Needs input" : "Building history")
            ForEach(readiness.items, id: \.key) { item in
                HStack(spacing: 10) {
                    Image(systemName: item.status == .satisfied ? "checkmark.circle.fill" : "circle.dashed")
                        .foregroundStyle(item.status == .satisfied ? StrandPalette.statusPositive : StrandPalette.statusWarning)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(item.label).font(StrandFont.subhead)
                        Text(item.detail).font(StrandFont.footnote).foregroundStyle(StrandPalette.textTertiary)
                    }
                    Spacer()
                }
                .accessibilityElement(children: .combine)
            }
            NavigationLink { SettingsView() } label: {
                SettingsRow(icon: "person.crop.circle", title: "Review profile",
                            subtitle: "Age, sex, height, weight, and optional waist")
            }
            .buttonStyle(.plain)
        }
    }

    private var sectionDivider: some View { Divider().overlay(StrandPalette.hairline) }
    private func componentLabel(_ title: String) -> some View {
        Text(title.uppercased())
            .font(StrandFont.overline)
            .tracking(StrandFont.overlineTracking)
            .foregroundStyle(StrandPalette.textSecondary)
    }
    private var latestAge: Double? { series.last?.value }
    private var chronologicalAge: Double {
        FitnessAgePresentation.chronologicalAge(on: Date(), dateOfBirth: profile.dateOfBirth)
    }
    private var pace: Double? {
        FitnessAgePresentation.paceOfAging(samples: datedSeries.map {
            FitnessAgeTrendSample(date: $0.date, fitnessAge: $0.value)
        })
    }
    private var datedSeries: [(date: Date, value: Double)] {
        series.compactMap { point in Self.dayFormatter.date(from: point.day).map { ($0, point.value) } }
    }
    private var trendPoints: [FitnessAgeTrendChart.Point] {
        let cutoff = Calendar.current.date(byAdding: .month, value: -6, to: Date()) ?? .distantPast
        return datedSeries.filter { $0.date >= cutoff }.map {
            FitnessAgeTrendChart.Point(
                time: $0.date.timeIntervalSince1970,
                fitnessAge: $0.value,
                chronologicalAge: FitnessAgePresentation.chronologicalAge(
                    on: $0.date, dateOfBirth: profile.dateOfBirth))
        }
    }

    private var readiness: FitnessAgeReadiness {
        let days = repo.days.suffix(7)
        return FitnessAgeEngine.assessReadiness(
            hasAge: profile.age > 0, hasSex: !profile.sex.isEmpty,
            rhrDays: days.compactMap(\.restingHr).count,
            activityDays: days.compactMap { repo.canonicalStrain(for: $0.day) }.count,
            hasHeightWeight: profile.heightCm > 0 && profile.weightKg > 0,
            hasWaist: profile.waistCm > 0)
    }

    private var weeklyInputs: (restingHR: Double, paIndex: Double)? {
        let days = Array(repo.days.suffix(7))
        let rhrs = days.compactMap(\.restingHr).map(Double.init).sorted()
        guard rhrs.count >= FitnessAgeEngine.minCoverageDays else { return nil }
        let restingHR: Double = rhrs.count.isMultiple(of: 2)
            ? (rhrs[rhrs.count / 2 - 1] + rhrs[rhrs.count / 2]) / 2 : rhrs[rhrs.count / 2]
        let strains = days.compactMap { repo.canonicalStrain(for: $0.day)?.storedValue }.filter { $0 >= 30 }
        let mean = strains.isEmpty ? 0 : strains.reduce(0, +) / Double(strains.count)
        return (restingHR, FitnessAgeEngine.physicalActivityIndexFromStrain(
            activeDaysPerWeek: strains.count, meanActiveStrain: mean))
    }

    private func load() async {
        let loadSeq = repo.refreshSeq
        async let vo2Load = repo.exploreSeries(key: "vo2max_est", source: "my-whoop")
        let fitnessAge = await repo.exploreSeries(key: "fitness_age", source: "my-whoop")
        guard !Task.isCancelled, loadSeq == repo.refreshSeq else { return }

        // Fitness Age owns the hero and trend. Publish it as soon as it is ready; VO₂max is secondary
        // context and must not hold the entire detail screen behind another history read.
        series = fitnessAge
        loaded = true

        let nextVO2 = await vo2Load.last?.value
        guard !Task.isCancelled, loadSeq == repo.refreshSeq else { return }
        vo2max = nextVO2
    }
}
