import SwiftUI
import StrandDesign
import StrandAnalytics
import WhoopStore

/// The Fitness Age in full: the number against the calendar age, how fast it is moving, the two inputs that drive it and
/// what each is worth in years, six months of both ages, and the context around it. Flat sections in the widget language.
/// The number and the "N years younger" sentence come from `FitnessAgeCopy`, the same words the Health Monitor says.
struct FitnessAgeDetailView: View {
    @EnvironmentObject private var repo: Repository
    @EnvironmentObject private var profile: ProfileStore

    @State private var series: [(day: String, value: Double)] = []
    @State private var vo2max: Double?
    @State private var loaded = false
    /// Open Settings from the checklist's "Fix in Settings" or the "Review profile" row.
    @State private var showProfile = false

    var body: some View {
        ScreenScaffold(
            title: "Fitness Age", lazy: true,
            headerContext: HealthFormat.headerContext(dayKey: series.last?.day)
        ) {
            if loaded {
                content
            } else {
                HealthEmptyNote(symbol: "figure.run", text: "Reading your Fitness Age…")
            }
        }
        .task(id: repo.refreshSeq) { await load() }
        #if os(iOS)
        .toolbar(.hidden, for: .navigationBar)
        #endif
        .environment(\.screenScaffoldNavigationRole, .detail)
        .navigationDestination(isPresented: $showProfile) {
            // TODO(lane-merge): openSettings(.personalProfile)
            SettingsView()
        }
    }

    @ViewBuilder private var content: some View {
        VStack(alignment: .leading, spacing: 0) {
            hero
            if let latestAge {
                DrillInSeparator()
                FitnessAgePaceRow(pace: pace)
                DrillInSeparator()
                driversSection
                if !trendPoints.isEmpty {
                    DrillInSeparator()
                    FitnessAgeTrendChart(points: trendPoints, tint: HealthTint.fitnessAge.accent)
                }
                DrillInSeparator()
                contextSection(latestAge: latestAge)
            } else {
                DrillInSeparator()
                calibrationSection
            }
        }
    }

    // MARK: Hero

    private var hero: some View {
        let calendarAge = chronologicalAge
        let delta = latestAge.map { FitnessAgeCopy.delta(fitnessAge: $0, calendarAge: calendarAge) }
        let line = delta.map(FitnessAgeCopy.deltaLine) ?? String(localized: "Calibrating from your recent nights and activity.")
        let shown = latestAge.map { "\(FitnessAgeCopy.shownAge($0))" } ?? WidgetMetrics.missingValue
        return VStack(alignment: .leading, spacing: WidgetMetrics.contentSpacing) {
            SectionEyebrow(
                "Fitness Age", systemImage: "figure.run", tint: HealthTint.fitnessAge,
                trailing: .text(String(localized: "vs age \(FitnessAgeCopy.shownCalendarAge(calendarAge))")))
            HeroValue(value: shown, unit: String(localized: "yrs"))
            Text(verbatim: line)
                .font(StrandFont.subhead)
                .foregroundStyle(delta.map(FitnessAgeCopy.deltaColor) ?? StrandPalette.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
            if let latestAge, let marks = FitnessAgeCopy.railMarks(fitnessAge: latestAge, calendarAge: calendarAge) {
                FitnessAgeRail(
                    fitnessAge: marks.fitness, chronologicalAge: marks.calendar,
                    range: FitnessAgePresentation.dynamicRailRange(fitnessAge: marks.fitness, chronologicalAge: marks.calendar),
                    reading: marks.reading)
            } else {
                FitnessAgeRail(
                    fitnessAge: nil, chronologicalAge: Double(FitnessAgeCopy.shownCalendarAge(calendarAge)),
                    range: FitnessAgePresentation.dynamicRailRange(fitnessAge: nil, chronologicalAge: calendarAge))
            }
            Text(verbatim: FitnessAgeCopy.bandCaption)
                .font(StrandFont.micro)
                .foregroundStyle(StrandPalette.textTertiary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text(verbatim: latestAge.map {
            String(localized: "Fitness Age \(FitnessAgeCopy.shownAge($0)).") + " " + line
        } ?? String(localized: "Fitness Age calibrating.")))
    }

    // MARK: Factors

    private var driversSection: some View {
        VStack(alignment: .leading, spacing: WidgetMetrics.contentSpacing) {
            SectionEyebrow("The factors", systemImage: "slider.horizontal.3", tint: HealthTint.fitnessAge,
                           trailing: .text(String(localized: "Impact in years")))
            if let inputs = weeklyInputs {
                let impacts = FitnessAgeEngine.driverImpacts(
                    age: chronologicalAge, sex: profile.sex,
                    restingHR: inputs.restingHR, paIndex: inputs.paIndex)
                FitnessAgeDriverRow(
                    title: String(localized: "Resting heart rate"),
                    value: "\(Int(inputs.restingHR.rounded())) \(String(localized: "bpm"))",
                    impactYears: impacts.restingHRYears, systemImage: "heart.fill",
                    tint: ProductionTrendMetric.restingHR.domainTint(latest: nil))
                FlatRowSeparator()
                FitnessAgeDriverRow(
                    title: String(localized: "Recent activity"),
                    value: String(localized: "PA index \(DrillInFormat.number(inputs.paIndex, fractionDigits: 1))"),
                    impactYears: impacts.activityYears, systemImage: "figure.run",
                    tint: ProductionTrendMetric.strain.domainTint(latest: nil))
                Text("These are the only variable inputs in NOOP’s Fitness Age equation. Other health metrics add context but are not assigned invented year impacts.")
                    .font(StrandFont.footnote).foregroundStyle(StrandPalette.textTertiary)
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                Text("Driver details will appear when the current seven-day input window is complete.")
                    .font(StrandFont.footnote).foregroundStyle(StrandPalette.textTertiary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    // MARK: Context

    private func contextSection(latestAge: Double) -> some View {
        VStack(alignment: .leading, spacing: WidgetMetrics.contentSpacing) {
            SectionEyebrow("Context", systemImage: "info.circle", tint: .neutral,
                           trailing: .text(String(localized: "useful, not causal")))
            if let vo2max {
                HealthValueRow(systemImage: "lungs.fill", label: String(localized: "Estimated VO₂max"),
                               value: DrillInFormat.number(vo2max), unit: String(localized: "ml/kg/min"),
                               tint: HealthTint.fitnessAge)
            }
            NavigationLink {
                if let metric = MetricCatalog.all.first(where: { $0.key == "fitness_age" }) {
                    MetricDetailView(metric: metric)
                }
            } label: {
                HealthLinkRowLabel(title: String(localized: "Open full metric history"),
                                   subtitle: String(localized: "Explore every Fitness Age reading"),
                                   symbol: "chart.xyaxis.line")
            }
            .buttonStyle(FlatRowPressStyle())
            Text("Latest weekly comparison: \(DrillInFormat.number(latestAge, fractionDigits: 1)) years. This is not a diagnosis or a biological-age measurement.")
                .font(StrandFont.footnote).foregroundStyle(StrandPalette.textTertiary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    // MARK: Still calibrating

    private var calibrationSection: some View {
        let coverage = self.coverage
        return VStack(alignment: .leading, spacing: WidgetMetrics.contentSpacing) {
            SectionEyebrow("Still calibrating", systemImage: "figure.run", tint: HealthTint.fitnessAge)
            FitnessAgeReadinessList(
                readiness: readiness, rhrDays: coverage.rhrDays, activityDays: coverage.activityDays,
                lead: nil, onFix: { showProfile = true })
            Button { showProfile = true } label: {
                HealthLinkRowLabel(title: String(localized: "Review profile"),
                                   subtitle: String(localized: "Age, sex, height, weight, and optional waist"),
                                   symbol: "person.crop.circle")
            }
            .buttonStyle(FlatRowPressStyle())
        }
    }

    // MARK: Numbers

    private var latestAge: Double? { series.last?.value }

    /// The date-of-birth calendar age, the one the Health Monitor compares against.
    private var chronologicalAge: Double { FitnessAgeCopy.calendarAge(profile) }

    private var pace: Double? {
        FitnessAgePresentation.paceOfAging(samples: datedSeries.map {
            FitnessAgeTrendSample(date: $0.date, fitnessAge: $0.value)
        })
    }

    private var datedSeries: [(date: Date, value: Double)] {
        series.compactMap { point in BodyVitalSigns.localDate(fromDayKey: point.day).map { ($0, point.value) } }
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

    private var coverage: (rhrDays: Int, activityDays: Int) {
        let days = repo.days.suffix(7)
        return (days.compactMap(\.restingHr).count, days.compactMap { repo.canonicalStrain(for: $0.day) }.count)
    }

    private var readiness: FitnessAgeReadiness {
        let coverage = self.coverage
        return FitnessAgeEngine.assessReadiness(
            hasAge: profile.age > 0, hasSex: !profile.sex.isEmpty,
            rhrDays: coverage.rhrDays,
            activityDays: coverage.activityDays,
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
