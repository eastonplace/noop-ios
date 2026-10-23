import SwiftUI
import StrandDesign
import StrandAnalytics
import WhoopStore

// MARK: - Heads-Up wording
//
// The Heads-Up surfaces' words and colours, from a `HeadsUpSnapshot`. Pure, so every state is testable without a
// view. Copy rules (from IllnessSignalEngine): never name a condition; say what was ruled out, not only what fired;
// missing signals are skipped, never guessed; the detail page always ends with the not-a-diagnosis line.

enum HeadsUpPresentation {
    // MARK: Colour

    static func tone(_ phase: HeadsUpSnapshot.Phase) -> Color {
        switch phase {
        case .off: return StrandPalette.textTertiary
        case .learning: return StrandPalette.accent
        case .scored(let level): return tone(level)
        }
    }

    static func tone(_ level: IllnessSignalEngine.Level) -> Color {
        switch level {
        case .quiet: return StrandPalette.statusPositive
        case .mild: return StrandPalette.restColor
        case .raised: return StrandPalette.statusWarning
        case .suppressed: return StrandPalette.textTertiary
        case .alreadyUnwell: return StrandPalette.journalAccent
        }
    }

    /// The ink a counting signal's change takes. An explained or all-clear read keeps it white: the signal is real,
    /// but painting it the read's colour would make a move look explained away, or good news.
    static func emphasis(_ level: IllnessSignalEngine.Level) -> Color {
        level == .suppressed || level == .quiet ? StrandPalette.textPrimary : tone(level)
    }

    // MARK: Signals

    static func name(_ kind: HeadsUpSnapshot.SignalKind) -> String {
        switch kind {
        case .restingHR: return String(localized: "Resting heart rate")
        case .hrv: return String(localized: "Heart rate variability")
        case .skinTemp: return String(localized: "Skin temperature")
        case .respiration: return String(localized: "Respiratory rate")
        }
    }

    static func shortName(_ kind: HeadsUpSnapshot.SignalKind) -> String {
        switch kind {
        case .restingHR: return String(localized: "Resting HR")
        case .hrv: return String(localized: "HRV")
        case .skinTemp: return String(localized: "Skin temp")
        case .respiration: return String(localized: "Resp. rate")
        }
    }

    /// The symbols and colours Health Monitor gives the same four vitals.
    static func icon(_ kind: HeadsUpSnapshot.SignalKind) -> String {
        switch kind {
        case .restingHR: return "heart.fill"
        case .hrv: return "waveform.path.ecg"
        case .skinTemp: return "thermometer.medium"
        case .respiration: return "lungs.fill"
        }
    }

    static func tint(_ kind: HeadsUpSnapshot.SignalKind) -> Color {
        switch kind {
        case .restingHR: return DomainTint.heart.accent
        case .hrv: return DomainTint.hrv.accent
        case .skinTemp: return StrandPalette.metricAmber
        case .respiration: return StrandPalette.accent
        }
    }

    static func about(_ kind: HeadsUpSnapshot.SignalKind) -> String {
        switch kind {
        case .restingHR: return String(localized: "Your lowest steady heart rate overnight")
        case .hrv: return String(localized: "Beat-to-beat variation while you sleep")
        case .skinTemp: return String(localized: "Wrist temperature compared with your usual")
        case .respiration: return String(localized: "Breaths per minute while you sleep")
        }
    }

    /// A signed number with a real minus sign: "+6", "−22", "0".
    static func signed(_ value: Double, fractionDigits: Int) -> String {
        let scale = fractionDigits == 0 ? 1.0 : 10.0
        let rounded = (value * scale).rounded() / scale
        let magnitude = fractionDigits == 0 ? String(Int(abs(rounded))) : String(format: "%.1f", abs(rounded))
        if rounded > 0 { return "+" + magnitude }
        if rounded < 0 { return "\u{2212}" + magnitude }
        return magnitude
    }

    /// The change against the person's usual and its unit: "+6" bpm, "−22%", "+0.7°", "+0.5" rpm.
    static func delta(_ signal: HeadsUpSnapshot.Signal) -> (text: String, unit: String?) {
        guard signal.z != nil, let latest = signal.latest, let usual = signal.usual else {
            return (WidgetMetrics.missingValue, nil)
        }
        switch signal.kind {
        case .restingHR:
            return (signed(latest - usual, fractionDigits: 0), String(localized: "bpm"))
        case .hrv:
            guard usual > 0 else { return (WidgetMetrics.missingValue, nil) }
            return (signed((latest / usual - 1) * 100, fractionDigits: 0) + "%", nil)
        case .skinTemp:
            return (signed(latest, fractionDigits: 1) + "°", nil)
        case .respiration:
            return (signed(latest - usual, fractionDigits: 1), String(localized: "rpm"))
        }
    }

    /// A value in its units: "58 bpm", "48 ms", "+0.7 °C", "15.6 rpm".
    static func value(_ kind: HeadsUpSnapshot.SignalKind, _ value: Double) -> String {
        switch kind {
        case .restingHR: return String(localized: "\(Int(value.rounded())) bpm")
        case .hrv: return String(localized: "\(Int(value.rounded())) ms")
        case .skinTemp: return signed(value, fractionDigits: 1) + " °C"
        case .respiration: return String(localized: "\(String(format: "%.1f", value)) rpm")
        }
    }

    static func stateWord(_ signal: HeadsUpSnapshot.Signal) -> String {
        guard let z = signal.z else {
            return signal.latest == nil ? String(localized: "No data") : String(localized: "Building")
        }
        if signal.fired { return z > 0 ? String(localized: "Up") : String(localized: "Down") }
        // Outside the normal range the way a rough patch does not move it (a higher HRV, a cooler night).
        if abs(z) > IllnessSignalEngine.signalZThreshold {
            return z > 0 ? String(localized: "Higher") : String(localized: "Lower")
        }
        return String(localized: "Normal")
    }

    /// Every recorded signal sits inside its normal range, in either direction.
    static func allInRange(_ snapshot: HeadsUpSnapshot) -> Bool {
        snapshot.signals.allSatisfy { signal in
            signal.z.map { abs($0) <= IllnessSignalEngine.signalZThreshold } ?? true
        }
    }

    /// Where the last 2 nights sit on a rail whose middle 40% is the normal range (±2 SD).
    static func railPosition(_ signal: HeadsUpSnapshot.Signal) -> Double? {
        signal.z.map { min(0.95, max(0.05, 0.5 + $0 * 0.1)) }
    }

    /// The detail row's second line: the value against the usual, or why there is none.
    static func detailLine(_ signal: HeadsUpSnapshot.Signal, phase: HeadsUpSnapshot.Phase) -> String {
        if case .off = phase { return about(signal.kind) }
        guard let latest = signal.latest else { return String(localized: "No reading in the last 2 nights") }
        let now = value(signal.kind, latest)
        if case .learning = phase { return String(localized: "\(now) lately") }
        switch signal.kind {
        case .skinTemp:
            guard let band = signal.normalBand else { return now }
            return String(localized: "\(now) · usual within ±\(String(format: "%.1f", band.upperBound)) °C")
        default:
            guard let usual = signal.usual else { return now }
            return String(localized: "\(now) · usual \(value(signal.kind, usual))")
        }
    }

    static func cell(_ signal: HeadsUpSnapshot.Signal, level: IllnessSignalEngine.Level) -> HeadsUpSignalCell {
        let change = delta(signal)
        return HeadsUpSignalCell(id: signal.kind.rawValue, icon: icon(signal.kind), tint: tint(signal.kind),
                                 label: shortName(signal.kind), delta: change.text, unit: change.unit,
                                 state: stateWord(signal), emphasis: signal.fired ? emphasis(level) : nil,
                                 position: railPosition(signal))
    }

    // MARK: Causes

    static func causeName(_ cause: HeadsUpSnapshot.Cause) -> String {
        switch cause {
        case .alcohol: return String(localized: "Alcohol")
        case .hardWorkout: return String(localized: "Hard or late workout")
        case .sauna: return String(localized: "Sauna")
        case .stress: return String(localized: "High stress")
        }
    }

    /// The cause inside a sentence: "you logged alcohol", "you logged a hard workout".
    static func causePhrase(_ cause: HeadsUpSnapshot.Cause) -> String {
        switch cause {
        case .alcohol: return String(localized: "alcohol")
        case .hardWorkout: return String(localized: "a hard workout")
        case .sauna: return String(localized: "a sauna")
        case .stress: return String(localized: "stress")
        }
    }

    static func causeIcon(_ cause: HeadsUpSnapshot.Cause) -> String {
        switch cause {
        case .alcohol: return "wineglass"
        case .hardWorkout: return "figure.run"
        case .sauna: return "thermometer.sun"
        case .stress: return "bolt.heart"
        }
    }

    /// Logged causes in a fixed order, so the words never shuffle between renders.
    static func orderedCauses(_ causes: Set<HeadsUpSnapshot.Cause>) -> [HeadsUpSnapshot.Cause] {
        HeadsUpSnapshot.Cause.allCases.filter { causes.contains($0) }
    }

    static func joined(_ words: [String]) -> String {
        ListFormatter.localizedString(byJoining: words)
    }

    // MARK: Dates

    static func date(_ key: String?) -> Date? {
        guard let key else { return nil }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.timeZone = .current
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter.date(from: key)
    }

    static func weekday(_ key: String?) -> String? {
        date(key).map { $0.formatted(.dateTime.weekday(.abbreviated)) }
    }

    static func shortDate(_ key: String?) -> String? {
        date(key).map { $0.formatted(.dateTime.day().month(.abbreviated)) }
    }

    /// The newest day is today's (either the calendar day or the 04:00 logical day, which differ after midnight).
    static func isToday(_ key: String?, now: Date = Date()) -> Bool {
        guard let key else { return false }
        return key == Repository.localDayKey(now) || key == Repository.logicalDayKey(now)
    }

    /// "Today" for today's row, else its short date: a history that ends on an older night says so.
    static func dayLabel(_ key: String?, now: Date = Date()) -> String {
        isToday(key, now: now) ? String(localized: "Today") : (shortDate(key) ?? "")
    }

    // MARK: Today card

    static func card(_ snapshot: HeadsUpSnapshot) -> HeadsUpCardModel {
        let color = Self.tone(snapshot.phase)
    // MARK: Elsewhere today

    static func contextRecovery(_ recovery: Double?) -> String {
        recovery.map { "\(Int($0.rounded()))%" } ?? WidgetMetrics.missingValue
    }

    /// Today's own Sleep duration text, so "Elsewhere today" can never round differently from the tile.
    static func contextSleep(_ minutes: Double?) -> String {
        minutes.map { TodayView.sleepDurationText(minutes: $0) } ?? WidgetMetrics.missingValue
    }

    /// Strain on the display scale, one decimal, like the Strain ring.
    static func contextStrain(_ stored: Double?) -> String {
        stored.map { String(format: "%.1f", StrainScale.displayValue(fromStored: $0)) } ?? WidgetMetrics.missingValue
    }

        switch snapshot.phase {
        case .off:
            return HeadsUpCardModel(
                pill: String(localized: "Off"), tone: color,
                line: String(localized: "Get a nudge when your body looks run down, sometimes before you feel it."),
                lineIsPrimary: false, content: .turnOn)
        case .learning(let nights):
            let needed = HeadsUpSnapshot.nightsNeeded
            let left = max(1, needed - nights)
            return HeadsUpCardModel(
                pill: String(localized: "Learning"), tone: color,
                line: String(localized: "Learning your normal. Ready after \(needed) baseline nights."),
                lineIsPrimary: false,
                content: .progress(fraction: Double(nights) / Double(needed),
                                   leading: String(localized: "\(nights) of \(needed) nights"),
                                   trailing: left == 1 ? String(localized: "Ready tomorrow")
                                                       : String(localized: "Ready in about \(left) days")))
        case .scored(let level):
            return HeadsUpCardModel(
                pill: pill(level, snapshot), tone: color, line: line(level, snapshot),
                lineIsPrimary: level != .quiet,
                content: .signals(snapshot.signals.map { cell($0, level: level) }),
                chip: chip(level, snapshot))
        }
    }

    static func pill(_ level: IllnessSignalEngine.Level, _ snapshot: HeadsUpSnapshot) -> String {
        switch level {
        case .quiet: return String(localized: "All clear")
        case .mild: return String(localized: "\(snapshot.firedCount) slightly up")
        case .raised: return String(localized: "\(snapshot.firedCount) of \(snapshot.presentCount) up")
        case .suppressed: return String(localized: "Explained")
        case .alreadyUnwell: return String(localized: "Rest up")
        }
    }

    static func line(_ level: IllnessSignalEngine.Level, _ snapshot: HeadsUpSnapshot) -> String {
        switch level {
        case .quiet:
            let fired = snapshot.signals.filter(\.fired)
            if fired.count == 1, let one = fired.first {
                let name = shortName(one.kind)
                return (one.z ?? 0) > 0
                    ? String(localized: "\(name) is up on its own. One signal alone isn’t a pattern.")
                    : String(localized: "\(name) is down on its own. One signal alone isn’t a pattern.")
            }
            if fired.count > 1 {
                return String(localized: "\(firedNames(snapshot)) moved off your normal. Not enough to flag.")
            }
            if snapshot.presentCount == 0 { return String(localized: "No overnight signals in the last 2 nights.") }
            if !allInRange(snapshot) { return String(localized: "Nothing points to being run down.") }
            if snapshot.presentCount == HeadsUpSnapshot.SignalKind.allCases.count {
                return String(localized: "All 4 signals are in your normal range.")
            }
            return String(localized: "Your recorded signals are in your normal range.")
        case .mild:
            return String(localized: "\(snapshot.firedCount) signals are slightly off. A calmer day helps.")
        case .raised:
            return String(localized: "Your body looks run down. Take it easy today.")
        case .suppressed:
            let causes = joined(orderedCauses(snapshot.causes).map(causePhrase))
            return String(localized: "Signals are up, but you logged \(causes). Likely that.")
        case .alreadyUnwell:
            return agrees(snapshot)
                ? String(localized: "You logged feeling sick. Your numbers agree.")
                : String(localized: "You logged feeling sick. Take it easy today.")
        }
    }

    /// The person's own "feeling sick" log is backed by the signals.
    static func agrees(_ snapshot: HeadsUpSnapshot) -> Bool {
        snapshot.score >= IllnessSignalEngine.mildThreshold && snapshot.firedCount >= 1
    }

    static func chip(_ level: IllnessSignalEngine.Level, _ snapshot: HeadsUpSnapshot) -> HeadsUpCardModel.Chip? {
        switch level {
        case .suppressed:
            guard let cause = orderedCauses(snapshot.causes).first else { return nil }
            return HeadsUpCardModel.Chip(icon: causeIcon(cause), tint: StrandPalette.textSecondary,
                                         text: String(localized: "\(causeName(cause)) logged · likely the cause"))
        case .alreadyUnwell:
            let text = weekday(snapshot.unwellDay).map { String(localized: "Logged: feeling sick · \($0)") }
                ?? String(localized: "Logged: feeling sick")
            return HeadsUpCardModel.Chip(icon: "square.and.pencil", tint: StrandPalette.journalAccent, text: text)
        case .quiet, .mild, .raised:
            return nil
        }
    }

    /// The one-line banner at the top of Today: only the reads that ask for something.
    static func bannerLine(_ snapshot: HeadsUpSnapshot?) -> String? {
        switch snapshot?.level {
        case .raised?: return String(localized: "Heads-up: your body looks run down")
        case .alreadyUnwell?: return String(localized: "Rest up: you logged feeling sick")
        default: return nil
        }
    }

    // MARK: Detail page

    static func overline(_ snapshot: HeadsUpSnapshot) -> String {
        switch snapshot.phase {
        case .off: return String(localized: "Heads-Up · Off")
        case .learning: return String(localized: "Heads-Up · Learning")
        case .scored(let level):
            let day = date(snapshot.day).map { $0.formatted(.dateTime.weekday(.abbreviated).day().month(.abbreviated)) }
            let window = level == .alreadyUnwell ? String(localized: "rest mode") : String(localized: "last 2 nights")
            return day.map { "\($0) · \(window)" } ?? window
        }
    }

    static func icon(_ phase: HeadsUpSnapshot.Phase) -> String {
        switch phase {
        case .off: return "bell"
        case .learning: return "hourglass"
        case .scored(let level):
            switch level {
            case .quiet: return "checkmark"
            case .mild: return "waveform.path"
            case .raised: return "exclamationmark.triangle.fill"
            case .suppressed: return "info.circle"
            case .alreadyUnwell: return "bed.double.fill"
            }
        }
    }

    static func headline(_ snapshot: HeadsUpSnapshot) -> String {
        switch snapshot.phase {
        case .off: return String(localized: "Spot a rough patch early")
        case .learning: return String(localized: "Learning your normal")
        case .scored(let level):
            switch level {
            case .quiet: return String(localized: "All clear")
            case .mild: return String(localized: "A few signals are up")
            case .raised: return String(localized: "Your body looks run down")
            case .suppressed:
                guard let cause = orderedCauses(snapshot.causes).first else {
                    return String(localized: "Probably not your body")
                }
                return String(localized: "Probably \(causePhrase(cause))")
            case .alreadyUnwell: return String(localized: "Rest up")
            }
        }
    }

    private static func firedNames(_ snapshot: HeadsUpSnapshot) -> String {
        joined(snapshot.signals.filter(\.fired).map { shortName($0.kind) })
    }

    static func body(_ snapshot: HeadsUpSnapshot) -> String {
        switch snapshot.phase {
        case .off:
            return String(localized: "Heads-Up reads four overnight signals together and tells you when they drift from your normal at the same time, sometimes a day or two before you feel it.")
        case .learning:
            return String(localized: "Heads-Up compares each night with your own baseline, so it needs \(HeadsUpSnapshot.nightsNeeded) baseline nights first. Your newest 3 nights stay out of the baseline, so a rough patch can’t blend into it. Keep wearing your strap to bed.")
        case .scored(let level):
            switch level {
            case .quiet:
                let fired = snapshot.signals.filter(\.fired)
                if fired.count == 1 {
                    return String(localized: "\(firedNames(snapshot)) moved off your normal on its own. Heads-Up speaks up when several signals move together.")
                }
                if fired.count > 1 {
                    return String(localized: "\(firedNames(snapshot)) moved off your normal, but not enough to flag. Heads-Up keeps watching and speaks up if the move grows.")
                }
                if !allInRange(snapshot) {
                    return String(localized: "Nothing is moving the way it does when you’re run down. A shift the other way, like a higher HRV, isn’t a warning sign.")
                }
                return String(localized: "Resting HR, HRV, skin temperature and breathing rate are inside your normal range, or not recorded.")
            case .mild:
                return String(localized: "\(firedNames(snapshot)) moved slightly off your normal. Nothing alarming, but a calmer day won’t hurt.")
            case .raised:
                return String(localized: "\(firedNames(snapshot)) moved away from your normal over the last 2 nights, and nothing you logged explains it.")
            case .suppressed:
                let causes = joined(orderedCauses(snapshot.causes).map(causePhrase))
                return String(localized: "\(firedNames(snapshot)) moved off your normal, but you logged \(causes). That moves the same signals, so Heads-Up is standing down.")
            case .alreadyUnwell:
                return agrees(snapshot)
                    ? String(localized: "You logged feeling sick, and \(snapshot.firedCount) of \(snapshot.presentCount) signals agree. Take it easy. Heads-Up keeps watching until they settle.")
                    : String(localized: "You logged feeling sick. Take it easy today. Heads-Up keeps watching your signals.")
            }
        }
    }

    static func meterNote(_ snapshot: HeadsUpSnapshot) -> String? {
        guard let raw = snapshot.rawScore else { return nil }
        let causes = joined(orderedCauses(snapshot.causes).map(causePhrase))
        return String(localized: "Raw reading was \(Int(raw.rounded())). Softened to \(Int(snapshot.score.rounded())) because you logged \(causes).")
    }

    static func historyBars(_ snapshot: HeadsUpSnapshot) -> [HeadsUpHistoryBar] {
        snapshot.history.enumerated().map { index, day in
            let isLast = index == snapshot.history.count - 1
            let color: Color
            if isLast, snapshot.level == .suppressed {
                color = StrandPalette.textSecondary
            } else if day.score >= IllnessSignalEngine.raiseThreshold {
                color = StrandPalette.statusWarning
            } else if day.score >= IllnessSignalEngine.mildThreshold {
                color = StrandPalette.restColor
            } else {
                color = day.score > 0 ? StrandPalette.hairlineStrong : StrandPalette.hairline
            }
            return HeadsUpHistoryBar(id: day.day, score: day.score, color: color,
                                     outline: isLast ? snapshot.rawScore : nil)
        }
    }

    struct Advice: Identifiable, Equatable {
        var id: String { title }
        let icon: String
        let tint: Color
        let title: String
        let detail: String
    }

    static func advice(_ snapshot: HeadsUpSnapshot) -> [Advice] {
        guard let level = snapshot.level else { return [] }
        switch level {
        case .quiet:
            return [Advice(icon: "checkmark", tint: StrandPalette.statusPositive,
                           title: String(localized: "Train as planned"),
                           detail: String(localized: "Nothing in your signals says to hold back today."))]
        case .mild:
            return [
                Advice(icon: "flame.fill", tint: StrandPalette.strainAccent, title: String(localized: "Go a little easier"),
                       detail: String(localized: "A moderate day is fine. Hold off on max efforts.")),
                Advice(icon: "moon.stars.fill", tint: StrandPalette.sleepAccent, title: String(localized: "Get an early night"),
                       detail: String(localized: "Sleep is the quickest way back to your normal.")),
            ]
        case .raised:
            return [
                Advice(icon: "flame.fill", tint: StrandPalette.strainAccent, title: String(localized: "Keep it light"),
                       detail: String(localized: "Skip hard intervals and max efforts today.")),
                Advice(icon: "moon.stars.fill", tint: StrandPalette.sleepAccent, title: String(localized: "Bank extra sleep"),
                       detail: String(localized: "Go to bed earlier tonight and give yourself a slow morning.")),
                Advice(icon: "drop.fill", tint: StrandPalette.accent, title: String(localized: "Hydrate and check in"),
                       detail: String(localized: "Log how you feel tonight so tomorrow’s read is sharper.")),
            ]
        case .suppressed:
            return [
                Advice(icon: "drop.fill", tint: StrandPalette.accent, title: String(localized: "Hydrate and sleep it off"),
                       detail: String(localized: "Your logged cause can lift resting HR and skin temperature for a night or two.")),
                Advice(icon: "chart.line.uptrend.xyaxis", tint: StrandPalette.textSecondary,
                       title: String(localized: "We’ll check again tomorrow"),
                       detail: String(localized: "If signals stay up with nothing logged, Heads-Up will say so.")),
            ]
        case .alreadyUnwell:
            return [
                Advice(icon: "bed.double.fill", tint: StrandPalette.journalAccent, title: String(localized: "Rest is the workout today"),
                       detail: String(localized: "Skip training. Easy walks only if you feel up to it.")),
                Advice(icon: "moon.stars.fill", tint: StrandPalette.sleepAccent, title: String(localized: "Sleep as much as you can"),
                       detail: String(localized: "Naps count. Your body is doing the work.")),
            ]
        }
    }
}

// MARK: - Today

/// The Heads-Up card under Health Monitor, with the hairline above it. Observes AppModel in isolation, like
/// `HealthAlertBanner`, so the 1 Hz HR stream re-renders only this leaf; the card itself redraws only when the
/// snapshot changes.
struct TodayHeadsUpSection: View {
    @EnvironmentObject private var model: AppModel
    let onOpen: () -> Void

    var body: some View {
        if let snapshot = model.headsUp {
            TodayHeadsUpCardLeaf(snapshot: snapshot, onOpen: onOpen,
                                 onTurnOn: { model.setHeadsUpEnabled(true) })
                .equatable()
        }
    }
}

private struct TodayHeadsUpCardLeaf: View, @preconcurrency Equatable {
    let snapshot: HeadsUpSnapshot
    let onOpen: () -> Void
    let onTurnOn: () -> Void

    static func == (lhs: Self, rhs: Self) -> Bool { lhs.snapshot == rhs.snapshot }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            TodaySectionSeparator(above: 0, below: 13.3)
            HeadsUpTodayCard(model: HeadsUpPresentation.card(snapshot), onOpen: onOpen, onTurnOn: onTurnOn)
        }
    }
}

// MARK: - Detail page

/// The facts the detail page shows for context ("Elsewhere today"). They are not part of the Heads-Up math.
///
/// They are resolved exactly as Today resolves its rings and its Sleep tile: the same display day (the saved
/// first-paint snapshot when Today would use it, else the logical-day row), the same first-paint Recovery and
/// Strain values with the same fallbacks, Strain through the canonical resolver, and Sleep through Today's own
/// duration formatter. Reading `repo.days.last` and the row's raw `strain` instead put this page on a different
/// row, a different Strain source and a different rounding from the rings it sits behind.
struct HeadsUpDayContext: Equatable {
    let day: String?
    /// Strain on the stored 0–100 axis; `HeadsUpPresentation.contextStrain` draws it on the display scale.
    let recovery: Double?
    let sleepMinutes: Double?
    let strain: Double?

    nonisolated static func resolve(days: [DailyMetric], snapshot: TodayHealthSnapshot?,
                                    canonicalStrain: (String) -> Double?,
                                    logicalKey: String, localKey: String) -> HeadsUpDayContext {
        let firstPaint = snapshot.flatMap {
            TodayView.acceptsFirstPaintSnapshot(displayDay: $0.displayDay, selectedDayOffset: 0,
                                                logicalKey: logicalKey, localKey: localKey) ? $0 : nil
        }
        let row = firstPaint?.dailyMetric
            ?? TodayView.resolveDisplayDay(days: days, selectedDayOffset: 0, logicalKey: logicalKey,
                                           localKey: localKey, selectedDayKey: localKey)
        func metric(_ kind: TodayHealthSnapshot.Metric) -> TodayHealthMetricValue? {
            TodayView.firstPaintMetric(kind, snapshot: firstPaint, selectedDayOffset: 0,
                                       currentLogicalDay: logicalKey, currentLocalDay: localKey)
        }
        return HeadsUpDayContext(
            day: row?.day,
            recovery: metric(.recovery)?.value ?? (firstPaint == nil ? row?.recovery : nil),
            sleepMinutes: row?.totalSleepMin,
            strain: TodayView.renderedStrainValue(
                firstPaint: firstPaint, strainMetric: metric(.strain),
                fallback: firstPaint == nil ? row.flatMap { canonicalStrain($0.day) } : nil))
    }

    @MainActor
    static func current(_ repo: Repository, now: Date = Date()) -> HeadsUpDayContext {
        resolve(days: repo.days, snapshot: repo.todayHealthSnapshot,
                canonicalStrain: { repo.canonicalStrain(for: $0)?.storedValue },
                logicalKey: Repository.logicalDayKey(now), localKey: Repository.localDayKey(now))
    }
}

struct HeadsUpDetailView: View {
    @EnvironmentObject private var model: AppModel
    @EnvironmentObject private var repo: Repository

    var body: some View {
        HeadsUpDetailContent(snapshot: model.headsUp ?? HeadsUpSnapshot.off,
                             context: HeadsUpDayContext.current(repo),
                             setEnabled: { model.setHeadsUpEnabled($0) })
            .equatable()
    }
}

private struct HeadsUpDetailContent: View, @preconcurrency Equatable {
    let snapshot: HeadsUpSnapshot
    let context: HeadsUpDayContext
    let setEnabled: (Bool) -> Void
    @State private var showingJournal = false

    static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.snapshot == rhs.snapshot && lhs.context == rhs.context
    /// The width reserved for a bare row symbol, so the text beside it lines up row to row.
    private static let iconColumn: CGFloat = 24

    }

    private var tone: Color { HeadsUpPresentation.tone(snapshot.phase) }
    private var level: IllnessSignalEngine.Level? { snapshot.level }

    var body: some View {
        ScreenScaffold(title: "Heads-Up", lazy: true) {
            VStack(alignment: .leading, spacing: 0) {
                hero
                DrillInSeparator()
                signalsSection
                if level != nil, !snapshot.history.isEmpty {
                    DrillInSeparator()
                    historySection
                }
                if level == .mild || level == .raised || level == .suppressed {
                    DrillInSeparator()
                    checksSection
                }
                if level == .alreadyUnwell {
                    DrillInSeparator()
                    loggedSection
                }
                if level != nil {
                    DrillInSeparator()
                    contextSection
                }
                Group {
                    let advice = HeadsUpPresentation.advice(snapshot)
                    if !advice.isEmpty {
                        DrillInSeparator()
                        adviceSection(advice)
                    }
                    DrillInSeparator()
                    howSection
                    DrillInSeparator()
                    footer
                }
            }
            .accessibilityElement(children: .contain)
            .accessibilityIdentifier("headsUp.detail")
        }
        .sheet(isPresented: $showingJournal) {
            CoachingRootView()
                .sheetScreenScaffoldEnvironment(onClose: { showingJournal = false })
        }
    }

    // MARK: Hero

    private var hero: some View {
        VStack(alignment: .leading, spacing: NoopMetrics.space3) {
            HStack(spacing: 10) {
                Image(systemName: HeadsUpPresentation.icon(snapshot.phase))
                    .font(StrandFont.body.weight(.semibold))
                    .foregroundStyle(tone)
                    .frame(width: 40, height: 40)
                    .background(tone.opacity(0.16), in: Circle())
                    .accessibilityHidden(true)
                Text(verbatim: HeadsUpPresentation.overline(snapshot))
                    .strandOverline()
            }
            Text(verbatim: HeadsUpPresentation.headline(snapshot))
                .font(StrandFont.title1)
                .foregroundStyle(StrandPalette.textPrimary)
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityAddTraits(.isHeader)
            Text(verbatim: HeadsUpPresentation.body(snapshot))
                .font(StrandFont.subhead)
                .foregroundStyle(StrandPalette.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
            switch snapshot.phase {
            case .off:
                VStack(alignment: .leading, spacing: NoopMetrics.space2) {
                    Button { setEnabled(true) } label: { Text("Turn on Heads-Up") }
                        .buttonStyle(PrimaryPillButtonStyle())
                        .accessibilityIdentifier("headsUp.turnOn")
                    Text("Needs 14 nights of wear before the first read. Turn it off any time.")
                        .font(StrandFont.caption)
                        .foregroundStyle(StrandPalette.textTertiary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            case .learning(let nights):
                learningProgress(nights)
            case .scored:
                HeadsUpStrengthMeter(score: snapshot.score, rawScore: snapshot.rawScore, tone: tone,
                                     note: HeadsUpPresentation.meterNote(snapshot))
                HStack(spacing: NoopMetrics.space2) {
                    if let confidence = snapshot.confidence {
                        ValuePill(String(localized: "Confidence: \(confidence)"), tint: tone)
                    }
                    ValuePill(String(localized: "vs your 28-night baseline"), tint: StrandPalette.textSecondary)
                }
            }
        }
        .padding(.top, NoopMetrics.space2)
    }

    private func learningProgress(_ nights: Int) -> some View {
        let needed = HeadsUpSnapshot.nightsNeeded
        return VStack(alignment: .leading, spacing: NoopMetrics.space2) {
            HStack(alignment: .firstTextBaseline) {
                Text("Baseline").strandOverline()
                Spacer(minLength: NoopMetrics.space2)
                Text(verbatim: String(localized: "\(nights) of \(needed) nights"))
                    .font(StrandFont.bodyNumber)
                    .foregroundStyle(StrandPalette.textPrimary)
            }
            ProgressView(value: Double(nights), total: Double(needed))
                .tint(tone)
            Text("Missed nights just push it back. Nothing is judged until then.")
                .font(StrandFont.caption)
                .foregroundStyle(StrandPalette.textTertiary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(14)
        .background(StrandPalette.chipFill, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(StrandPalette.hairline, lineWidth: 1))
    }

    // MARK: Signals

    private var signalsTitle: LocalizedStringKey {
        switch snapshot.phase {
        case .off: return "What it reads"
        case .learning: return "Your signals so far"
        case .scored: return "Your signals"
        }
    }

    private var signalsFoot: LocalizedStringKey {
        switch snapshot.phase {
        case .off: return "Uses whatever your wearable records overnight. Missing signals are skipped, never guessed."
        case .learning: return "Lines fill in as nights are recorded. The normal band appears once your baseline is ready."
        case .scored: return "Last 14 nights. The shaded band is your normal range; the bright end is the last 2 nights."
        }
    }

    private var signalsSection: some View {
        FlatSection(signalsTitle, systemImage: "waveform.path.ecg", tint: .custom(tone), contentSpacing: 4) {
            VStack(alignment: .leading, spacing: 0) {
                ForEach(Array(snapshot.signals.enumerated()), id: \.element.id) { index, signal in
                    if index > 0 { FlatRowSeparator() }
                    signalRow(signal)
                }
                Text(signalsFoot)
                    .font(StrandFont.caption)
                    .foregroundStyle(StrandPalette.textTertiary)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.top, NoopMetrics.space2)
            }
        }
    }

    private func signalRow(_ signal: HeadsUpSnapshot.Signal) -> some View {
        let kind = signal.kind
        let change = HeadsUpPresentation.delta(signal)
        let ink: Color? = signal.fired ? level.map(HeadsUpPresentation.emphasis) : nil
        let showsReading: Bool = {
            if case .off = snapshot.phase { return false }
            return true
        }()
        return VStack(alignment: .leading, spacing: NoopMetrics.space2) {
            HStack(alignment: .top, spacing: NoopMetrics.space3) {
                Image(systemName: HeadsUpPresentation.icon(kind))
                    .font(StrandFont.subhead.weight(.semibold))
                    .foregroundStyle(HeadsUpPresentation.tint(kind))
                    .frame(width: 32, height: 32)
                    .background(HeadsUpPresentation.tint(kind).opacity(0.14), in: Circle())
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 2) {
                    Text(verbatim: HeadsUpPresentation.name(kind))
                        .font(StrandFont.body.weight(.semibold))
                        .foregroundStyle(StrandPalette.textPrimary)
                        .fixedSize(horizontal: false, vertical: true)
                    Text(verbatim: HeadsUpPresentation.detailLine(signal, phase: snapshot.phase))
                        .font(StrandFont.footnote)
                        .monospacedDigit()
                        .foregroundStyle(StrandPalette.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: NoopMetrics.space2)
                if showsReading {
                    VStack(alignment: .trailing, spacing: 2) {
                        HStack(alignment: .firstTextBaseline, spacing: 2) {
                            Text(verbatim: change.text)
                                .font(StrandFont.bodyNumber)
                                .foregroundStyle(ink ?? StrandPalette.textPrimary)
                            if let unit = change.unit {
                                Text(verbatim: unit)
                                    .font(StrandFont.caption)
                                    .foregroundStyle(StrandPalette.textTertiary)
                            }
                        }
                        Text(verbatim: HeadsUpPresentation.stateWord(signal))
                            .font(StrandFont.caption)
                            .foregroundStyle(ink ?? StrandPalette.textTertiary)
                    }
                }
            }
            if showsReading, signal.history.contains(where: { $0 != nil }) {
                HeadsUpSparkline(values: signal.history, band: signal.normalBand,
                                 highlight: ink ?? StrandPalette.textPrimary)
                    .padding(.leading, 44)
            }
        }
        .padding(.vertical, NoopMetrics.space3)
        .accessibilityElement(children: .combine)
    }

    // MARK: History

    private var historySection: some View {
        let bars = HeadsUpPresentation.historyBars(snapshot)
        let middle = bars.count > 7 ? HeadsUpPresentation.shortDate(snapshot.history[bars.count - 7].day) : nil
        return FlatSection("Last 14 days", systemImage: "chart.bar.fill", tint: .custom(tone)) {
            HeadsUpHistoryChart(bars: bars,
                                leadingLabel: HeadsUpPresentation.shortDate(snapshot.history.first?.day) ?? "",
                                middleLabel: middle ?? "",
                                trailingLabel: HeadsUpPresentation.dayLabel(snapshot.history.last?.day))
        }
    }

    // MARK: Causes

    private var checksSection: some View {
        FlatSection("Checked before warning you", systemImage: "checklist", tint: .neutral, contentSpacing: 4) {
            VStack(alignment: .leading, spacing: 0) {
                ForEach(Array(HeadsUpSnapshot.Cause.allCases.enumerated()), id: \.element) { index, cause in
                    if index > 0 { FlatRowSeparator() }
                    checkRow(cause)
                }
                Text("Logging these helps Heads-Up tell a big night from getting sick.")
                    .font(StrandFont.caption)
                    .foregroundStyle(StrandPalette.textTertiary)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.top, NoopMetrics.space2)
            }
        }
    }

    /// One thing the Journal can explain a move with: logged yes ("Logged"), answered no ("No"), or never asked
    /// ("Not logged", no tick: a tick beside it would read as if it had been logged).
    private func checkRow(_ cause: HeadsUpSnapshot.Cause) -> some View {
        let logged = snapshot.causes.contains(cause)
        let ruledOut = !logged && snapshot.answeredNo.contains(cause)
        return HStack(spacing: NoopMetrics.space3) {
            Image(systemName: HeadsUpPresentation.causeIcon(cause))
                .font(StrandFont.footnote.weight(.semibold))
                .foregroundStyle(logged ? StrandPalette.textPrimary : StrandPalette.textTertiary)
                .frame(width: Self.iconColumn, alignment: .leading)
                .accessibilityHidden(true)
            Text(verbatim: HeadsUpPresentation.causeName(cause))
                .font(StrandFont.body)
                .foregroundStyle(StrandPalette.textPrimary)
            Spacer(minLength: NoopMetrics.space2)
            if logged {
                Text("Logged")
                    .font(StrandFont.footnote.weight(.semibold))
                    .foregroundStyle(StrandPalette.textPrimary)
            } else if ruledOut {
                Text("No")
                    .font(StrandFont.footnote)
                    .foregroundStyle(StrandPalette.textSecondary)
            } else {
                Text("Not logged")
                    .font(StrandFont.footnote)
                    .foregroundStyle(StrandPalette.textTertiary)
            }
        }
        .frame(minHeight: 52)
        .accessibilityElement(children: .combine)
    }

    private var loggedSection: some View {
        FlatSection("You logged", systemImage: "square.and.pencil", tint: .journal) {
            HStack(spacing: NoopMetrics.space3) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Feeling sick")
                        .font(StrandFont.body.weight(.semibold))
                        .foregroundStyle(StrandPalette.textPrimary)
                    Text(verbatim: HeadsUpPresentation.weekday(snapshot.unwellDay).map { String(localized: "Journal · \($0)") }
                         ?? String(localized: "Journal"))
                        .font(StrandFont.footnote)
                        .foregroundStyle(StrandPalette.textSecondary)
                }
                Spacer(minLength: NoopMetrics.space2)
                if HeadsUpPresentation.agrees(snapshot) {
                    ValuePill(String(localized: "\(snapshot.firedCount) of \(snapshot.presentCount) agree"),
                              tint: StrandPalette.journalAccent)
                }
            }
            .accessibilityElement(children: .combine)
        }
    }

    // MARK: Context

    private var contextSection: some View {
        let today = HeadsUpPresentation.isToday(context.day)
        return FlatSection(today ? LocalizedStringKey("Elsewhere today") : LocalizedStringKey("Elsewhere"),
                           systemImage: "square.grid.2x2", tint: .neutral,
                           trailing: today ? .none : .text(HeadsUpPresentation.shortDate(context.day) ?? "")) {
            VStack(alignment: .leading, spacing: NoopMetrics.space2) {
                FactStrip(facts: [
                    FactStrip.Fact("Recovery", value: HeadsUpPresentation.contextRecovery(context.recovery)),
                    FactStrip.Fact("Sleep", value: HeadsUpPresentation.contextSleep(context.sleepMinutes)),
                    FactStrip.Fact("Strain", value: HeadsUpPresentation.contextStrain(context.strain)),
                ])
                Text("For context. These are not part of the Heads-Up math.")
                    .font(StrandFont.caption)
                    .foregroundStyle(StrandPalette.textTertiary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    // MARK: Advice

    private func adviceSection(_ advice: [HeadsUpPresentation.Advice]) -> some View {
        FlatSection("What helps today", systemImage: "sparkles", tint: .custom(tone), contentSpacing: 4) {
            VStack(alignment: .leading, spacing: 0) {
                ForEach(advice) { item in
                    HStack(alignment: .top, spacing: NoopMetrics.space3) {
                        Image(systemName: item.icon)
                            .font(StrandFont.subhead.weight(.semibold))
                            .foregroundStyle(item.tint)
                            .frame(width: 32, height: 32)
                            .background(item.tint.opacity(0.14), in: Circle())
                            .accessibilityHidden(true)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(verbatim: item.title)
                                .font(StrandFont.body.weight(.semibold))
                                .foregroundStyle(StrandPalette.textPrimary)
                            Text(verbatim: item.detail)
                                .font(StrandFont.footnote)
                                .foregroundStyle(StrandPalette.textSecondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        Spacer(minLength: 0)
                    }
                    .padding(.vertical, NoopMetrics.space2)
                    .accessibilityElement(children: .combine)
                }
                if level != .quiet {
                    Button { showingJournal = true } label: { Text("Log how you feel") }
                        .buttonStyle(PrimaryPillButtonStyle())
                        .padding(.top, NoopMetrics.space2)
                        .accessibilityIdentifier("headsUp.logFeeling")
                }
            }
        }
    }

    // MARK: How it works

    private var howSection: some View {
        FlatSection("How Heads-Up works", systemImage: "questionmark.circle", tint: .neutral) {
            VStack(alignment: .leading, spacing: NoopMetrics.space3) {
                howStep(1, title: "Compares you with you",
                        detail: "Your last 2 nights against your own 28-night baseline, one signal at a time.")
                howStep(2, title: "Needs signals to agree",
                        detail: "At least 2 have to move the wrong way together. One noisy night never counts.")
                howStep(3, title: "Checks your Journal first",
                        detail: "Alcohol, a hard workout, a sauna or stress soften the read instead of raising an alarm.")
            }
        }
    }

    private func howStep(_ number: Int, title: LocalizedStringKey, detail: LocalizedStringKey) -> some View {
        HStack(alignment: .top, spacing: NoopMetrics.space3) {
            Text(verbatim: "\(number)")
                .font(StrandFont.captionNumber)
                .foregroundStyle(StrandPalette.textSecondary)
                .frame(width: 24, height: 24)
                .background(StrandPalette.chipFill, in: Circle())
                .overlay(Circle().strokeBorder(StrandPalette.pillStroke, lineWidth: 1))
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(StrandFont.body.weight(.semibold))
                    .foregroundStyle(StrandPalette.textPrimary)
                Text(detail)
                    .font(StrandFont.footnote)
                    .foregroundStyle(StrandPalette.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .accessibilityElement(children: .combine)
    }

    // MARK: Footer

    private var footer: some View {
        VStack(alignment: .leading, spacing: NoopMetrics.space3) {
            Toggle(isOn: Binding(get: { snapshot.phase != .off }, set: { setEnabled($0) })) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Heads-Up")
                        .font(StrandFont.body)
                        .foregroundStyle(StrandPalette.textPrimary)
                    Text("Same as Health-pattern alerts in Notifications.")
                        .font(StrandFont.caption)
                        .foregroundStyle(StrandPalette.textTertiary)
                }
            }
            .noopToggle()
            .accessibilityIdentifier("headsUp.enabled")
            Label {
                Text("Worked out on your phone. Never uploaded, never synced.")
            } icon: {
                Image(systemName: "lock.fill")
            }
            .font(StrandFont.caption)
            .foregroundStyle(StrandPalette.textTertiary)
            Text("An on-device estimate, not a diagnosis. If you feel unwell, talk to a doctor.")
                .font(StrandFont.caption)
                .foregroundStyle(StrandPalette.textTertiary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.bottom, NoopMetrics.space6)
    }
}
