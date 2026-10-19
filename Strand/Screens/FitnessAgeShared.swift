import SwiftUI
import StrandDesign
import StrandAnalytics

// MARK: - What the Health Monitor and the Fitness Age detail both say
//
// The Health Monitor's Fitness Age section and the Fitness Age detail show the same number and the same sentence
// about it ("4 years younger than your age"). They share the calculation (the whole-number gap between the shown Fitness Age
// and the shown date-of-birth calendar age) and the words, so the two screens cannot disagree.

enum FitnessAgeCopy {
    /// The Fitness Age as the whole number both screens show.
    static func shownAge(_ fitnessAge: Double) -> Int { Int(fitnessAge.rounded()) }

    /// The fractional, date-of-birth based calendar age, held inside the whole year the profile reports.
    ///
    /// The fraction divides days by 365.2425, which is off from calendar years by up to a day around a birthday
    /// (a date of birth exactly 30 calendar years back reads 29.9998). Left alone, "vs age 29" would sit beside a
    /// profile, heart-rate zones and Max HR that all say 30, so the fraction is clamped to `profile.age`'s year.
    @MainActor static func calendarAge(_ profile: ProfileStore, on date: Date = Date()) -> Double {
        withinWholeYear(
            FitnessAgePresentation.chronologicalAge(on: date, dateOfBirth: profile.dateOfBirth),
            wholeYears: ProfileStore.years(from: profile.dateOfBirth, to: date))
    }

    /// `age` limited to `[wholeYears, wholeYears + 1)`. Non-finite input is returned unchanged.
    nonisolated static func withinWholeYear(_ age: Double, wholeYears: Int) -> Double {
        guard age.isFinite else { return age }
        return min(max(age, Double(wholeYears)), Double(wholeYears + 1).nextDown)
    }

    /// The calendar age as the whole number the screens say ("vs age 42"): a birthday not yet reached is not counted.
    static func shownCalendarAge(_ calendarAge: Double) -> Int { Int(calendarAge.rounded(.down)) }

    /// How many years younger or older the screen says. It is the difference of the two whole numbers the screens
    /// print ("34 yrs" against "vs age 29"), so the sentence can never disagree with the numbers beside it; 0 reads
    /// "about the same as your age". Non-finite input is `.same`.
    static func delta(fitnessAge: Double, calendarAge: Double) -> FitnessAgeDelta {
        guard fitnessAge.isFinite, calendarAge.isFinite else { return FitnessAgeDelta(years: 0, direction: .same) }
        let gap = shownCalendarAge(calendarAge) - shownAge(fitnessAge)
        guard gap != 0 else { return FitnessAgeDelta(years: 0, direction: .same) }
        return FitnessAgeDelta(years: abs(gap), direction: gap > 0 ? .younger : .older)
    }

    /// The two marks the detail's rail draws and how it reads them: the whole numbers the screen prints and the
    /// direction the sentence uses (`delta`), so the dot is on the side the sentence names and the rail's colour is
    /// the sentence's. Drawn on the raw fractions, a Fitness Age of 29.6 against a calendar age of 29.7 put the dot
    /// left of the tick, in green, over "1 year older". Nil for a non-finite age.
    static func railMarks(
        fitnessAge: Double, calendarAge: Double
    ) -> (fitness: Double, calendar: Double, reading: FitnessAgeRail.Reading)? {
        guard fitnessAge.isFinite, calendarAge.isFinite else { return nil }
        let reading: FitnessAgeRail.Reading
        switch delta(fitnessAge: fitnessAge, calendarAge: calendarAge).direction {
        case .younger: reading = .younger
        case .older: reading = .older
        case .same: reading = .same
        }
        return (Double(shownAge(fitnessAge)), Double(shownCalendarAge(calendarAge)), reading)
    }

    /// The younger/older-than-your-age sentence as whole-phrase variants per count and direction, so translators see
    /// complete sentences (never a stitched plural or direction fragment).
    static func deltaLine(_ delta: FitnessAgeDelta) -> String {
        switch (delta.direction, delta.years == 1) {
        case (.same, _):      return String(localized: "About the same as your age")
        case (.younger, true):  return String(localized: "1 year younger than your age")
        case (.younger, false): return String(localized: "\(delta.years) years younger than your age")
        case (.older, true):    return String(localized: "1 year older than your age")
        case (.older, false):   return String(localized: "\(delta.years) years older than your age")
        }
    }

    /// Younger reads as good news, older as a heads-up, the same as a calendar age.
    static func deltaColor(_ delta: FitnessAgeDelta) -> Color {
        switch delta.direction {
        case .younger: StrandPalette.statusPositive
        case .older: StrandPalette.statusWarning
        case .same: StrandPalette.textSecondary
        }
    }

    /// The band under the number, the honest-precision contract of docs/FITNESS_AGE.md.
    static var bandCaption: String {
        String(localized: "± \(Int(FitnessAgeEngine.displayBandYears)) yr · a fitness comparison, not a biological age")
    }

    // MARK: Readiness words

    /// The engine's readiness rows carry English text; the screens say them in the person's language, from the same
    /// inputs the engine was given.
    static func readinessLabel(_ item: FitnessReadinessItem) -> String {
        switch item.key {
        case "age": String(localized: "Your age")
        case "sex": String(localized: "Biological sex")
        case "rhr": String(localized: "Resting heart rate")
        case "activity": String(localized: "Recent activity")
        case "bodyMetrics": String(localized: "Height & weight")
        case "waist": String(localized: "Waist (optional)")
        default: item.label
        }
    }

    static func readinessDetail(_ item: FitnessReadinessItem, rhrDays: Int, activityDays: Int) -> String {
        switch item.key {
        case "age", "sex":
            return item.status == .satisfied ? String(localized: "Set") : String(localized: "Add it in Settings")
        case "rhr": return String(localized: "\(rhrDays) of last 7 nights")
        case "activity": return String(localized: "\(activityDays) of last 7 days")
        case "bodyMetrics":
            return item.status == .satisfied ? String(localized: "Unlocks your VO₂max")
                                             : String(localized: "Add to also see VO₂max")
        case "waist":
            return item.status == .satisfied ? String(localized: "Sharpens VO₂max")
                                             : String(localized: "Optional - sharpens VO₂max")
        default: return item.detail
        }
    }

    /// Whether a row can be fixed from Settings: age, sex, body measurements and waist. Resting heart rate and activity
    /// coverage come from wearing the strap, so they get no fix button.
    static func isFixableInSettings(_ item: FitnessReadinessItem) -> Bool {
        item.status != .satisfied
            && (item.key == "age" || item.key == "sex" || item.key == "bodyMetrics" || item.key == "waist")
    }
}

// MARK: - Readiness checklist

/// What the Fitness Age has and still needs, grouped by what each input does: "Drives your Fitness Age" (age, sex,
/// resting heart rate, activity) against "Unlocks your VO₂max" (height and weight, waist), never implying the body
/// measurements sharpen the age (the body term cancels in the model). One flat block for the Health Monitor and the
/// detail alike. A required-but-missing input offers "Fix in Settings".
struct FitnessAgeReadinessList: View {
    let readiness: FitnessAgeReadiness
    let rhrDays: Int
    let activityDays: Int
    /// An intro line above the groups (the "a few more days" message while there is no value yet).
    let lead: LocalizedStringKey?
    /// Called when a missing row's "Fix in Settings" is tapped.
    let onFix: () -> Void

    @Environment(\.dynamicTypeSize) private var typeSize

    private var drivesAge: [FitnessReadinessItem] { readiness.items.filter { $0.role == .drivesAge } }
    private var unlocksVO2: [FitnessReadinessItem] { readiness.items.filter { $0.role == .unlocksVO2max } }

    var body: some View {
        VStack(alignment: .leading, spacing: WidgetMetrics.contentSpacing) {
            confidence
            if let lead {
                Text(lead)
                    .font(StrandFont.subhead)
                    .foregroundStyle(StrandPalette.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            group(title: "Drives your Fitness Age", items: drivesAge)
            group(title: "Unlocks your VO₂max", items: unlocksVO2)
            Text("Built from published methods (Nes/HUNT) on \(Platform.deviceNounPhrase). It's a fitness comparison against an average peer your age, not a biological or medical age.")
                .font(StrandFont.footnote)
                .foregroundStyle(StrandPalette.textTertiary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    /// The overall confidence, on the shared state pill.
    @ViewBuilder private var confidence: some View {
        switch readiness.confidence {
        case .ready: StatePill("Ready", tone: .positive, showsDot: false)
        case .estimate: StatePill("Estimate (partial data)", tone: .neutral, showsDot: false)
        case .notReady: StatePill("Not enough data yet", tone: .warning, showsDot: false)
        }
    }

    @ViewBuilder
    private func group(title: LocalizedStringKey, items: [FitnessReadinessItem]) -> some View {
        if !items.isEmpty {
            VStack(alignment: .leading, spacing: NoopMetrics.space2) {
                Text(title).foregroundStyle(StrandPalette.textTertiary).microLabelFit(lines: 2, weight: .semibold)
                ForEach(items, id: \.key) { item in
                    row(item)
                }
            }
        }
    }

    private func row(_ item: FitnessReadinessItem) -> some View {
        let fixable = FitnessAgeCopy.isFixableInSettings(item)
        let label = FitnessAgeCopy.readinessLabel(item)
        let detail = FitnessAgeCopy.readinessDetail(item, rhrDays: rhrDays, activityDays: activityDays)
        let text = HStack(alignment: .firstTextBaseline, spacing: NoopMetrics.space3) {
            HealthGlyph(systemImage: statusIcon(item.status), color: statusColor(item.status))
            VStack(alignment: .leading, spacing: 1) {
                Text(verbatim: label).font(StrandFont.subhead).foregroundStyle(StrandPalette.textPrimary)
                Text(verbatim: detail).font(StrandFont.footnote).foregroundStyle(StrandPalette.textTertiary)
            }
            .fixedSize(horizontal: false, vertical: true)
        }
        return Group {
            if fixable {
                // Stacked at the accessibility sizes, so the action never squeezes the words.
                let fix = Button(action: onFix) {
                    WidgetChip(appTitle: "Fix in Settings", showsChevron: false, overhangs: false).chipHitTarget()
                }
                .buttonStyle(.plain)
                .accessibilityLabel(Text(verbatim: "\(label): \(detail). " + String(localized: "Fix in Settings")))
                if typeSize.isAccessibilitySize {
                    VStack(alignment: .leading, spacing: NoopMetrics.space1) {
                        text
                        fix.healthIconIndent(gap: NoopMetrics.space3)
                    }
                } else {
                    HStack(alignment: .firstTextBaseline, spacing: NoopMetrics.space2) {
                        text
                        Spacer(minLength: NoopMetrics.space2)
                        fix
                    }
                }
            } else {
                text
                    .accessibilityElement(children: .ignore)
                    .accessibilityLabel(Text(verbatim: "\(label), \(statusWord(item.status)). \(detail)"))
            }
        }
    }

    private func statusIcon(_ status: FitnessReadinessStatus) -> String {
        switch status {
        case .satisfied: "checkmark.circle.fill"
        case .partial: "exclamationmark.triangle.fill"
        case .missing: "circle"
        }
    }

    private func statusColor(_ status: FitnessReadinessStatus) -> Color {
        switch status {
        case .satisfied: StrandPalette.statusPositive
        case .partial: StrandPalette.statusWarning
        case .missing: StrandPalette.textTertiary
        }
    }

    private func statusWord(_ status: FitnessReadinessStatus) -> String {
        switch status {
        case .satisfied: String(localized: "ready")
        case .partial: String(localized: "partial")
        case .missing: String(localized: "missing")
        }
    }
}
