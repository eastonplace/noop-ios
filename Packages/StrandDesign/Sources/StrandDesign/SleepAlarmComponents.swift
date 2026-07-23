import SwiftUI

// MARK: - Sleep Alarm kit (promoted from the NOOP Design Lab, spec 012 T701)
//
// Ported from NOOPDesignLab/SleepAlarmComponents.swift. Visual design — spacing, type (StrandFont),
// color (StrandPalette), motion (StrandMotion) and haptics (StrandHaptic) is preserved exactly; every
// fixture value (the frozen 9:26 PM clock, the fixed 7 h 50 m need, the lab's own wake-mode list)
// becomes a real Binding / display-model input. The lab's `SleepAlarmClock` frozen constants are NOT
// promoted; its pure time-formatting helpers are, as `SleepAlarmTime` below. No component here ever
// queries storage — each receives an immutable display model plus action closures/bindings.

// MARK: - Time / need math (pure, unit-tested)

/// Pure time, duration and "asleep by" arithmetic shared by the module, the need-breakdown card, and
/// the plan timeline. Every function is a value transform — no storage, no `Date`, no fixture state —
/// so the exact math production uses is directly unit-testable.
public enum SleepAlarmTime {
    /// "6:40 AM" from a minute-of-day value. Values outside `0..<1440` (a continuous-axis minute past
    /// midnight) wrap to the correct clock time first.
    public static func clock(
        _ minutesFromMidnight: Int,
        locale: Locale = .autoupdatingCurrent,
        calendar inputCalendar: Calendar = .autoupdatingCurrent,
        timeZone: TimeZone = .autoupdatingCurrent
    ) -> String {
        let total = ((minutesFromMidnight % 1440) + 1440) % 1440
        var calendar = inputCalendar
        calendar.timeZone = timeZone
        let date = calendar.date(from: DateComponents(year: 2001, month: 1, day: 1,
                                                       hour: total / 60, minute: total % 60)) ?? Date()
        let formatter = DateFormatter()
        formatter.locale = locale
        formatter.calendar = calendar
        formatter.timeZone = timeZone
        formatter.dateStyle = .none
        formatter.timeStyle = .short
        return formatter.string(from: date).replacingOccurrences(of: "\u{202F}", with: " ")
    }

    /// Locale-aware duration phrasing for the countdown-to-bed reading. Never negative — a bedtime
    /// already in the past reads a localized zero-minute value rather than a negative countdown.
    public static func duration(
        _ minutes: Int,
        locale: Locale = .autoupdatingCurrent
    ) -> String {
        let clamped = max(0, minutes)
        let formatter = DateComponentsFormatter()
        var calendar = Calendar.autoupdatingCurrent
        calendar.locale = locale
        formatter.calendar = calendar
        formatter.allowedUnits = [.hour, .minute]
        formatter.unitsStyle = .abbreviated
        formatter.maximumUnitCount = 2
        formatter.zeroFormattingBehavior = .dropAll
        return formatter.string(from: TimeInterval(clamped * 60))
            ?? String.localizedStringWithFormat(
                String(localized: "%lld min", bundle: .module), Int64(clamped))
    }

    /// "7:30" / "+0:14" / "\u{2212}0:00" — the need-breakdown card's H:MM figure. `signed` prints an
    /// explicit +/\u{2212} (the true minus sign, matching the lab); unsigned prints the magnitude only.
    public static func hoursMinutes(_ minutes: Double, signed: Bool = false) -> String {
        let total = Int(minutes.rounded())
        let magnitude = abs(total)
        let sign = signed ? (total < 0 ? "\u{2212}" : "+") : ""
        return String(format: "%@%d:%02d", sign, magnitude / 60, magnitude % 60)
    }

    /// The next occurrence of a time-of-day (`0..<1440`) on the SAME continuous axis as `now` (also
    /// the current minute-of-day, `0..<1440`): later today if it hasn't passed yet, else `+1440` for
    /// tomorrow. Every other function in this kit takes minutes already resolved onto that shared
    /// continuous axis — this is the one seam that reconciles a real wall clock with it.
    public static func nextOccurrence(now: Int, timeOfDay: Int) -> Int {
        let day = 1440
        let wrappedNow = ((now % day) + day) % day
        let wrappedTarget = ((timeOfDay % day) + day) % day
        return wrappedTarget > wrappedNow ? wrappedTarget : wrappedTarget + day
    }

    /// Latest moment to be asleep and still bank the full need before the EARLIEST wake in the
    /// window: `wake \u{2212} window \u{2212} need`. The one formula every mode's countdown builds from —
    /// a longer canonical need pulls this earlier, a shorter one later, holding wake/window fixed.
    public static func asleepByMinutes(wakeMinutes: Int, windowMinutes: Int, needMinutes: Double) -> Int {
        wakeMinutes - windowMinutes - Int(needMinutes.rounded())
    }
}

// MARK: - Wake modes

/// One selectable wake mode with an honest availability. `.unavailable(reason:)` keeps the mode
/// visible but truthfully disabled — a smart mode with insufficient inputs explains itself rather
/// than silently vanishing.
public struct SleepAlarmWakeMode: Identifiable, Equatable, Sendable {
    public enum Availability: Equatable, Sendable {
        case available
        case unavailable(reason: String)
    }

    public let id: String
    public let title: String
    public let explanation: String
    /// Minutes the wake may pull earlier than the set time; 0 = exact, no window.
    public let windowMinutes: Int
    public let availability: Availability

    public init(id: String, title: String, explanation: String, windowMinutes: Int,
                availability: Availability = .available) {
        self.id = id
        self.title = title
        self.explanation = explanation
        self.windowMinutes = windowMinutes
        self.availability = availability
    }

    public var isAvailable: Bool { availability == .available }
}

// MARK: - SleepAlarmModuleCard

/// The alarm module: arm/disarm, pick a wake mode via inline paper chips, nudge the wake time with
/// live ±5-min steppers — and it answers "be asleep by", recomputed on every change. The host supplies
/// the real clock, the real wake modes (with truthful availability), and the real dynamic Sleep Need;
/// nothing here is fixture state.
public struct SleepAlarmModuleCard: View {
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    @Binding public var armed: Bool
    public let modes: [SleepAlarmWakeMode]
    @Binding public var selectedModeId: String
    /// Wake instant on the continuous axis described by `SleepAlarmTime.nextOccurrence` — always
    /// > `nowMinutes`.
    @Binding public var wakeMinutes: Int
    /// "Now", minutes from the same axis origin as `wakeMinutes` (i.e. today's minute-of-day).
    public let nowMinutes: Int
    /// Tonight's dynamic Sleep Need, in minutes.
    public let needMinutes: Double
    public let wakeDayLabel: String
    public let deliveryStatus: String
    public let showsBedtimePlan: Bool
    /// Optional haptics-only toggle. nil hides the row entirely — the promoted module never invents a
    /// sound-vs-haptics choice the host doesn't actually have.
    public var hapticOnly: Binding<Bool>?

    public init(
        armed: Binding<Bool>,
        modes: [SleepAlarmWakeMode],
        selectedModeId: Binding<String>,
        wakeMinutes: Binding<Int>,
        nowMinutes: Int,
        needMinutes: Double,
        wakeDayLabel: String,
        deliveryStatus: String,
        showsBedtimePlan: Bool,
        hapticOnly: Binding<Bool>? = nil
    ) {
        self._armed = armed
        self.modes = modes
        self._selectedModeId = selectedModeId
        self._wakeMinutes = wakeMinutes
        self.nowMinutes = nowMinutes
        self.needMinutes = needMinutes
        self.wakeDayLabel = wakeDayLabel
        self.deliveryStatus = deliveryStatus
        self.showsBedtimePlan = showsBedtimePlan
        self.hapticOnly = hapticOnly
    }

    private var selectedMode: SleepAlarmWakeMode? { modes.first { $0.id == selectedModeId } }
    private var windowMinutes: Int { selectedMode?.windowMinutes ?? 0 }
    private var windowStart: Int { wakeMinutes - windowMinutes }
    private var asleepBy: Int {
        SleepAlarmTime.asleepByMinutes(wakeMinutes: wakeMinutes, windowMinutes: windowMinutes,
                                       needMinutes: needMinutes)
    }
    private var minutesUntilBed: Int { asleepBy - nowMinutes }
    /// Whether `wakeMinutes` lands later today or tomorrow, by construction of the shared continuous
    /// axis (`nowMinutes` is always `0..<1440`; a same-day wake stays under 1440, a next-day wake is
    /// `timeOfDay + 1440`). A post-midnight user with a same-day wake sees "Today", never a false
    /// "Tomorrow".
    public var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            if armed {
                wakeRow
                    .padding(.horizontal, 13)
                    .padding(.top, 2)
                modeChips
                    .padding(.horizontal, 13)
                    .padding(.top, 11)
                if let selectedMode {
                    modeExplanation(selectedMode)
                        .padding(.horizontal, 13)
                        .padding(.top, 6)
                }
                if windowMinutes > 0 {
                    windowRail
                        .padding(.horizontal, 13)
                        .padding(.top, 10)
                }
                if showsBedtimePlan {
                    Divider().overlay(StrandPalette.hairline)
                        .padding(.horizontal, 13)
                        .padding(.top, 12)
                    bedtimeBlock
                        .padding(.horizontal, 13)
                        .padding(.top, 11)
                        .padding(.bottom, hapticOnly == nil ? 13 : 0)
                } else {
                    Text("Sleep Need planning appears when this alarm is for the upcoming sleep period.", bundle: .module)
                        .font(StrandFont.micro)
                        .foregroundStyle(StrandPalette.textTertiary)
                        .padding(.horizontal, 13)
                        .padding(.vertical, 11)
                }
                if let hapticOnly {
                    hapticRow(hapticOnly)
                        .padding(.horizontal, 13)
                        .padding(.top, 11)
                        .padding(.bottom, 13)
                }
            } else {
                offBlock
                    .padding(.horizontal, 13)
                    .padding(.bottom, 13)
            }
        }
        .background(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .fill(StrandPalette.surfaceRaised)
                .overlay(
                    RoundedRectangle(cornerRadius: 18, style: .continuous)
                        .strokeBorder(
                            LinearGradient(
                                colors: [Color.white.opacity(0.16), StrandPalette.hairline],
                                startPoint: .top, endPoint: .bottom
                            ),
                            lineWidth: 1
                        )
                )
        )
        .accessibilityElement(children: .contain)
    }

    private var accessibilitySummary: String {
        guard armed else {
            return String(localized: "Alarm off. No wake time set.", bundle: .module)
        }
        let modeWord = selectedMode?.title ?? ""
        let windowPart = windowMinutes > 0
            ? " " + String(localized: "Wake window from \(SleepAlarmTime.clock(windowStart)) to \(SleepAlarmTime.clock(wakeMinutes)).", bundle: .module)
            : ""
        return String(localized: "Alarm configured, \(modeWord), \(SleepAlarmTime.clock(wakeMinutes)) \(wakeDayLabel). \(deliveryStatus).", bundle: .module)
            + windowPart + " "
            + (showsBedtimePlan ? String(localized: "To meet tonight's need, be asleep by \(SleepAlarmTime.clock(asleepBy)), in \(SleepAlarmTime.duration(minutesUntilBed)).", bundle: .module) : "")
    }

    // MARK: pieces

    @ViewBuilder private var header: some View {
        if dynamicTypeSize.isAccessibilitySize {
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 8) {
                    Text("Alarm".uppercased())
                        .font(StrandFont.overline)
                        .tracking(StrandFont.overlineTracking)
                        .foregroundStyle(StrandPalette.textSecondary)
                    Spacer(minLength: 8)
                    Toggle("", isOn: $armed.animation(StrandMotion.value))
                        .labelsHidden()
                        .accessibilityLabel(Text("Alarm", bundle: .module))
                        .tint(StrandPalette.textPrimary)
                }
                Text(wakeDayLabel)
                    .font(StrandFont.micro)
                    .foregroundStyle(StrandPalette.textTertiary)
                Text(armed ? deliveryStatus : String(localized: "Off", bundle: .module))
                    .font(StrandFont.micro)
                    .foregroundStyle(armed ? StrandPalette.chargeAccent : StrandPalette.textTertiary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(.horizontal, 13)
            .padding(.top, 12)
            .padding(.bottom, 4)
        } else {
            compactHeader
        }
    }

    private var compactHeader: some View {
        HStack(spacing: 8) {
            Text("Alarm".uppercased())
                .font(StrandFont.overline)
                .tracking(StrandFont.overlineTracking)
                .foregroundStyle(StrandPalette.textSecondary)
            Text(wakeDayLabel)
                .font(StrandFont.micro)
                .foregroundStyle(StrandPalette.textTertiary)
            Spacer(minLength: 8)
            Text(armed ? deliveryStatus : String(localized: "Off", bundle: .module))
                .font(StrandFont.micro)
                .foregroundStyle(armed ? StrandPalette.chargeAccent : StrandPalette.textTertiary)
            Toggle("", isOn: $armed.animation(StrandMotion.value))
                .labelsHidden()
                .accessibilityLabel(Text("Alarm", bundle: .module))
                .tint(StrandPalette.textPrimary)
                .scaleEffect(0.82, anchor: .trailing)
        }
        .padding(.horizontal, 13)
        .padding(.top, 12)
        .padding(.bottom, 4)
    }

    @ViewBuilder private var wakeRow: some View {
        if dynamicTypeSize.isAccessibilitySize {
            VStack(alignment: .leading, spacing: 10) {
                wakeTimeLabel
                nudgeControls
            }
            .accessibilityElement(children: .contain)
            .accessibilityLabel(Text("Wake time \(SleepAlarmTime.clock(wakeMinutes)), \(wakeDayLabel)", bundle: .module))
            .accessibilityAdjustableAction { adjustWakeTime($0) }
        } else {
            HStack(alignment: .center, spacing: 10) {
                wakeTimeLabel
                Spacer(minLength: 8)
                nudgeControls
            }
            .accessibilityElement(children: .contain)
            .accessibilityLabel(Text("Wake time \(SleepAlarmTime.clock(wakeMinutes)), \(wakeDayLabel)", bundle: .module))
            .accessibilityAdjustableAction { adjustWakeTime($0) }
        }
    }

    private var wakeTimeLabel: some View {
        HStack(alignment: .firstTextBaseline, spacing: 5) {
            Text(SleepAlarmTime.clock(wakeMinutes))
                .font(StrandFont.number(34, weight: .bold))
                .monospacedDigit()
                .foregroundStyle(StrandPalette.textPrimary)
                .contentTransition(.numericText())
            Text("wake", bundle: .module)
                .font(StrandFont.micro)
                .foregroundStyle(StrandPalette.textTertiary)
        }
    }

    private var nudgeControls: some View {
        HStack(spacing: 7) {
            nudgeButton("minus", label: String(localized: "Wake 5 minutes earlier", bundle: .module), enabled: wakeMinutes - 5 > nowMinutes) { wakeMinutes -= 5 }
            Text("5 min", bundle: .module)
                .font(StrandFont.micro)
                .foregroundStyle(StrandPalette.textTertiary)
            nudgeButton("plus", label: String(localized: "Wake 5 minutes later", bundle: .module), enabled: wakeMinutes + 5 < nowMinutes + 8 * 1440) { wakeMinutes += 5 }
        }
    }

    private func adjustWakeTime(_ direction: AccessibilityAdjustmentDirection) {
        switch direction {
        case .increment where wakeMinutes + 5 < nowMinutes + 8 * 1_440: wakeMinutes += 5
        case .decrement where wakeMinutes - 5 > nowMinutes: wakeMinutes -= 5
        default: break
        }
    }

    private func nudgeButton(_ symbol: String, label: String, enabled: Bool, action: @escaping () -> Void) -> some View {
        Button {
            withAnimation(StrandMotion.interactive) { action() }
            StrandHaptic.selection.play()
        } label: {
            Image(systemName: symbol)
                .font(.system(size: 11, weight: .bold))
                .foregroundStyle(enabled ? StrandPalette.textPrimary : StrandPalette.textTertiary.opacity(0.5))
                .frame(width: 44, height: 44)
                .background(Circle().fill(StrandPalette.surfaceInset))
        }
        .buttonStyle(StressModulePressStyle())
        .disabled(!enabled)
        .accessibilityLabel(label)
    }

    @ViewBuilder private var modeChips: some View {
        if dynamicTypeSize.isAccessibilitySize {
            LazyVGrid(columns: [GridItem(.flexible())], spacing: 6) {
                ForEach(modes) { modeChip($0, fillsWidth: true) }
            }
        } else {
            HStack(spacing: 4) {
                ForEach(modes) { modeChip($0, fillsWidth: false) }
                Spacer(minLength: 0)
            }
        }
    }

    private func modeChip(_ option: SleepAlarmWakeMode, fillsWidth: Bool) -> some View {
        let selected = option.id == selectedModeId
        return Button {
            withAnimation(StrandMotion.interactive) { selectedModeId = option.id }
            StrandHaptic.selection.play()
        } label: {
            Text(option.title)
                .font(StrandFont.micro.weight(.semibold))
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
                .foregroundStyle(selected ? StrandPalette.surfaceRaised : StrandPalette.textSecondary)
                .padding(.horizontal, 9)
                .padding(.vertical, 6)
                .frame(maxWidth: fillsWidth ? .infinity : nil, minHeight: 44)
                .background(
                    Capsule(style: .continuous)
                        .fill(selected ? StrandPalette.textPrimary : StrandPalette.surfaceInset)
                )
                .opacity(option.isAvailable ? 1 : 0.45)
        }
        .buttonStyle(StressModulePressStyle())
        .disabled(!option.isAvailable)
        .accessibilityAddTraits(selected ? .isSelected : [])
        .accessibilityLabel(option.title)
        .accessibilityValue(selected ? String(localized: "Selected", bundle: .module) : String(localized: "Not selected", bundle: .module))
        .accessibilityHint(option.isAvailable ? option.explanation : unavailableReason(option))
    }

    private func unavailableReason(_ mode: SleepAlarmWakeMode) -> String {
        if case .unavailable(let reason) = mode.availability { return reason }
        return ""
    }

    /// The explanation line under the chips: the mode's normal explanation, or — when the SELECTED
    /// mode is currently unavailable — its truthful reason instead, so the disabled state never reads
    /// silently.
    private func modeExplanation(_ mode: SleepAlarmWakeMode) -> some View {
        let text: String
        switch mode.availability {
        case .available: text = mode.explanation
        case .unavailable(let reason): text = reason
        }
        return Text(text)
            .font(StrandFont.micro)
            .foregroundStyle(StrandPalette.textTertiary)
            .fixedSize(horizontal: false, vertical: true)
    }

    private var windowRail: some View {
        VStack(alignment: .leading, spacing: 4) {
            GeometryReader { proxy in
                // Rail spans one hour ending at the set time; the window fills its tail.
                let railStart = wakeMinutes - 60
                let windowFraction = min(1, max(0, CGFloat(windowMinutes) / 60))
                let startX = proxy.size.width * (1 - windowFraction)
                ZStack(alignment: .leading) {
                    Capsule(style: .continuous)
                        .fill(StrandPalette.surfaceInset)
                        .frame(height: 6)
                    Capsule(style: .continuous)
                        .fill(StrandPalette.sleepAccent.opacity(0.55))
                        .frame(width: proxy.size.width - startX, height: 6)
                        .offset(x: startX)
                    Circle()
                        .fill(StrandPalette.sleepAccent)
                        .frame(width: 10, height: 10)
                        .overlay(Circle().strokeBorder(StrandPalette.surfaceRaised, lineWidth: 1.5))
                        .offset(x: proxy.size.width - 5)
                    Text(SleepAlarmTime.clock(railStart))
                        .font(.system(size: 8.5, weight: .medium, design: .rounded))
                        .monospacedDigit()
                        .foregroundStyle(StrandPalette.textTertiary)
                        .offset(y: 12)
                }
            }
            .frame(height: 22)
            HStack {
                Spacer(minLength: 0)
                Text("earliest \(SleepAlarmTime.clock(windowStart)) · latest \(SleepAlarmTime.clock(wakeMinutes))")
                    .font(StrandFont.micro)
                    .monospacedDigit()
                    .foregroundStyle(StrandPalette.textTertiary)
            }
        }
    }

    private var bedtimeBlock: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            VStack(alignment: .leading, spacing: 2) {
                Text("To meet tonight's \(SleepAlarmTime.duration(Int(needMinutes.rounded()))) need")
                    .font(StrandFont.micro)
                    .foregroundStyle(StrandPalette.textTertiary)
                HStack(alignment: .firstTextBaseline, spacing: 5) {
                    Text("Asleep by \(SleepAlarmTime.clock(asleepBy))")
                        .font(StrandFont.caption.weight(.semibold))
                        .monospacedDigit()
                        .foregroundStyle(StrandPalette.textPrimary)
                        .contentTransition(.numericText())
                    Text("· in \(SleepAlarmTime.duration(minutesUntilBed))")
                        .font(StrandFont.micro)
                        .monospacedDigit()
                        .foregroundStyle(minutesUntilBed < 45 ? StrandPalette.stressAccent : StrandPalette.textTertiary)
                        .contentTransition(.numericText())
                }
            }
            Spacer(minLength: 8)
            Image(systemName: "moon.zzz.fill")
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(StrandPalette.sleepAccent)
        }
    }

    private func hapticRow(_ hapticOnly: Binding<Bool>) -> some View {
        HStack(spacing: 9) {
            Image(systemName: "iphone.radiowaves.left.and.right")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(StrandPalette.metricPurple)
            VStack(alignment: .leading, spacing: 0) {
                Text("Silent wrist buzz", bundle: .module)
                    .font(StrandFont.caption.weight(.medium))
                    .foregroundStyle(StrandPalette.textPrimary)
                Text(hapticOnly.wrappedValue
                     ? String(localized: "Haptics only — no sound", bundle: .module)
                     : String(localized: "Haptics + gentle sound", bundle: .module))
                    .font(StrandFont.micro)
                    .foregroundStyle(StrandPalette.textTertiary)
            }
            Spacer(minLength: 8)
            Toggle("", isOn: hapticOnly)
                .labelsHidden()
                .tint(StrandPalette.textPrimary)
                .scaleEffect(0.82, anchor: .trailing)
        }
    }

    private var offBlock: some View {
        HStack(spacing: 10) {
            Image(systemName: "alarm")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(StrandPalette.textTertiary)
                .frame(width: 30, height: 30)
                .background(
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .fill(StrandPalette.surfaceInset)
                )
            VStack(alignment: .leading, spacing: 1) {
                Text("No alarm set", bundle: .module)
                    .font(StrandFont.caption.weight(.medium))
                    .foregroundStyle(StrandPalette.textSecondary)
                Text("Sleep in — tonight's need is still \(SleepAlarmTime.duration(Int(needMinutes.rounded())))")
                    .font(StrandFont.micro)
                    .foregroundStyle(StrandPalette.textTertiary)
            }
            Spacer(minLength: 0)
        }
        .padding(.top, 4)
    }
}

// MARK: - SleepNeedBreakdownCard

/// Where tonight's need comes from. Every line signs its contribution; the total is the same number
/// the alarm module's math uses. The host builds `lines`/`totalValue` from a real store or engine —
/// this view never fabricates a component.
public struct SleepNeedBreakdownCard: View {
    public struct Line: Identifiable, Equatable, Sendable {
        public let id: String
        public let title: String
        public let value: String
        public let tone: Color

        public init(id: String, title: String, value: String, tone: Color) {
            self.id = id
            self.title = title
            self.value = value
            self.tone = tone
        }
    }

    public let lines: [Line]
    public let totalLabel: String
    public let totalValue: String
    /// Full-sentence accessibility summary. The host builds this from the same real numbers driving
    /// `lines`/`totalValue` — only it knows which lines are actually present.
    public let accessibilitySummary: String

    public init(lines: [Line], totalLabel: String, totalValue: String, accessibilitySummary: String) {
        self.lines = lines
        self.totalLabel = totalLabel
        self.totalValue = totalValue
        self.accessibilitySummary = accessibilitySummary
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 9) {
            Text("Tonight's need".uppercased())
                .font(StrandFont.overline)
                .tracking(StrandFont.overlineTracking)
                .foregroundStyle(StrandPalette.textSecondary)
            VStack(spacing: 7) {
                ForEach(lines) { line in
                    HStack(spacing: 8) {
                        Text(line.title)
                            .font(StrandFont.footnote)
                            .foregroundStyle(StrandPalette.textSecondary)
                        Spacer(minLength: 8)
                        Text(line.value)
                            .font(StrandFont.captionNumber)
                            .monospacedDigit()
                            .foregroundStyle(line.tone)
                    }
                }
            }
            Divider().overlay(StrandPalette.hairline)
            HStack(spacing: 8) {
                Text(totalLabel)
                    .font(StrandFont.caption.weight(.semibold))
                    .foregroundStyle(StrandPalette.textPrimary)
                Spacer(minLength: 8)
                Text(totalValue)
                    .font(StrandFont.captionNumber)
                    .monospacedDigit()
                    .foregroundStyle(StrandPalette.textPrimary)
            }
        }
        .padding(13)
        .background(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(StrandPalette.surfaceRaised)
                .overlay(
                    RoundedRectangle(cornerRadius: 16, style: .continuous)
                        .strokeBorder(StrandPalette.hairline, lineWidth: 1)
                )
        )
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(accessibilitySummary)
    }
}

// MARK: - SleepPlanTimeline

/// The whole night on one rail: now, the asleep-by moment, the sleep span, the wake window, and the
/// alarm — so the plan is a picture, not four numbers. The axis auto-fits the four real instants
/// (small padding either side) instead of the lab's fixed 9 PM→8 AM fixture window, so it reads
/// correctly at any real clock time.
public struct SleepPlanTimeline: View {
    public let now: Int
    public let asleepBy: Int
    public let windowStart: Int
    public let alarm: Int

    public init(now: Int, asleepBy: Int, windowStart: Int, alarm: Int) {
        self.now = now
        self.asleepBy = asleepBy
        self.windowStart = windowStart
        self.alarm = alarm
    }

    private var axisStart: Int { min(now, asleepBy) - 15 }
    private var axisEnd: Int { max(alarm, windowStart, axisStart + 1) + 15 }

    public var body: some View {
        VStack(alignment: .leading, spacing: 9) {
            Text("The plan".uppercased())
                .font(StrandFont.overline)
                .tracking(StrandFont.overlineTracking)
                .foregroundStyle(StrandPalette.textSecondary)
            GeometryReader { proxy in
                let width = proxy.size.width
                ZStack(alignment: .leading) {
                    Capsule(style: .continuous)
                        .fill(StrandPalette.surfaceInset)
                        .frame(height: 8)
                    // Sleep span: asleep-by → window start.
                    Capsule(style: .continuous)
                        .fill(StrandPalette.sleepAccent.opacity(0.45))
                        .frame(width: spanWidth(from: asleepBy, to: windowStart, in: width), height: 8)
                        .offset(x: x(asleepBy, in: width))
                    // Wake window: brighter tail.
                    Capsule(style: .continuous)
                        .fill(StrandPalette.sleepAccent)
                        .frame(width: spanWidth(from: windowStart, to: alarm, in: width), height: 8)
                        .offset(x: x(windowStart, in: width))
                    // Now tick.
                    tick(at: now, in: width, color: StrandPalette.textPrimary)
                    // Alarm bead.
                    Circle()
                        .fill(StrandPalette.sleepAccent)
                        .frame(width: 11, height: 11)
                        .overlay(Circle().strokeBorder(StrandPalette.surfaceRaised, lineWidth: 1.5))
                        .offset(x: x(alarm, in: width) - 5.5)
                }
            }
            .frame(height: 14)
            HStack(spacing: 0) {
                timelineLabel(String(localized: "now", bundle: .module), SleepAlarmTime.clock(now), at: now)
                timelineLabel(String(localized: "asleep by", bundle: .module), SleepAlarmTime.clock(asleepBy), at: asleepBy)
                timelineLabel(String(localized: "window", bundle: .module), SleepAlarmTime.clock(windowStart), at: windowStart)
                timelineLabel(String(localized: "alarm", bundle: .module), SleepAlarmTime.clock(alarm), at: alarm)
            }
            .frame(maxWidth: .infinity)
        }
        .padding(13)
        .background(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(StrandPalette.surfaceRaised)
                .overlay(
                    RoundedRectangle(cornerRadius: 16, style: .continuous)
                        .strokeBorder(StrandPalette.hairline, lineWidth: 1)
                )
        )
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(String(localized: "Night plan: now \(SleepAlarmTime.clock(now)), asleep by \(SleepAlarmTime.clock(asleepBy)), wake window opens \(SleepAlarmTime.clock(windowStart)), alarm \(SleepAlarmTime.clock(alarm))", bundle: .module))
    }

    private func fraction(_ minutes: Int) -> CGFloat {
        let span = max(1, axisEnd - axisStart)
        return CGFloat(minutes - axisStart) / CGFloat(span)
    }

    private func x(_ minutes: Int, in width: CGFloat) -> CGFloat {
        width * fraction(minutes)
    }

    private func spanWidth(from: Int, to: Int, in width: CGFloat) -> CGFloat {
        max(0, x(to, in: width) - x(from, in: width))
    }

    private func tick(at minutes: Int, in width: CGFloat, color: Color) -> some View {
        Rectangle()
            .fill(color)
            .frame(width: 1.5, height: 14)
            .offset(x: x(minutes, in: width) - 0.75)
    }

    private func timelineLabel(_ label: String, _ time: String, at minutes: Int) -> some View {
        Text("\(label)\n\(time)")
            .font(.system(size: 8.5, weight: .medium, design: .rounded))
            .monospacedDigit()
            .multilineTextAlignment(.leading)
            .foregroundStyle(StrandPalette.textTertiary)
            .fixedSize()
            .frame(maxWidth: .infinity, alignment: .leading)
    }
}
