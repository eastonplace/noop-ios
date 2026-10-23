import Foundation
import SwiftUI

public enum JournalTriStateSelection {
    public static func next(current: Bool?, tapped: Bool) -> Bool? {
        current == tapped ? nil : tapped
    }
}

public enum JournalStreakSummary {
    public static func currentStreak(in logged: [Bool]) -> Int {
        logged.reversed().prefix(while: { $0 }).count
    }

    /// Returns the fixed real-day window ending on `endingOn`; dates absent from
    /// persistence are represented as unlogged, never filled with fixture state.
    public static func window(loggedDays: Set<String>, endingOn: String, days: Int) -> [Bool] {
        guard days > 0, let end = parseDay(endingOn) else { return [] }
        let calendar = utcCalendar
        return (0..<days).reversed().map { offset in
            guard let day = calendar.date(byAdding: .day, value: -offset, to: end) else { return false }
            return loggedDays.contains(formatDay(day))
        }
    }

    private static var utcCalendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        return calendar
    }

    private static func parseDay(_ value: String) -> Date? {
        let parts = value.split(separator: "-").compactMap { Int($0) }
        guard parts.count == 3 else { return nil }
        return utcCalendar.date(from: DateComponents(year: parts[0], month: parts[1], day: parts[2]))
    }

    private static func formatDay(_ date: Date) -> String {
        let values = utcCalendar.dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d-%02d-%02d", values.year ?? 0, values.month ?? 0, values.day ?? 0)
    }
}

/// One yes/no habit as a flat row: the habit's symbol, its name, and a No / Yes pair of chips. Tapping a chip answers;
/// tapping the selected chip again clears the answer (`JournalTriStateSelection`). The row saves nothing itself.
public struct JournalHabitToggle: View {
    private let icon: String
    private let tint: Color
    private let question: String
    private let detail: String?
    @Binding private var answer: Bool?
    @Environment(\.dynamicTypeSize) private var typeSize

    public init(icon: String, tint: Color, question: String, detail: String? = nil,
                answer: Binding<Bool?>) {
        self.icon = icon
        self.tint = tint
        self.question = question
        self.detail = detail
        self._answer = answer
    }

    public var body: some View {
        Group {
            if typeSize.isAccessibilitySize {
                VStack(alignment: .leading, spacing: 10) {
                    label
                    chips
                }
            } else {
                HStack(spacing: 12) {
                    label
                    Spacer(minLength: 8)
                    chips
                }
            }
        }
        .padding(.vertical, 10)
        .frame(minHeight: 56)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("\(question). \(answerWord)")
    }

    private var label: some View {
        HStack(spacing: 12) {
            journalIcon(icon, tint: tint)
            VStack(alignment: .leading, spacing: 2) {
                Text(question)
                    .font(StrandFont.body)
                    .foregroundStyle(StrandPalette.textPrimary)
                    .fixedSize(horizontal: false, vertical: true)
                if let detail {
                    Text(detail).font(StrandFont.caption).foregroundStyle(StrandPalette.textTertiary)
                }
            }
        }
    }

    private var chips: some View {
        HStack(spacing: 8) {
            answerChip(value: false)
            answerChip(value: true)
        }
        .fixedSize()
    }

    private var answerWord: String {
        switch answer {
        case true?: return String(localized: "Answered yes", bundle: .module)
        case false?: return String(localized: "Answered no", bundle: .module)
        case nil: return String(localized: "Not answered yet", bundle: .module)
        }
    }

    private func answerChip(value: Bool) -> some View {
        let selected = answer == value
        let title = value ? String(localized: "Yes", bundle: .module) : String(localized: "No", bundle: .module)
        return ChoiceChipButton(verbatimTitle: title, isSelected: selected) {
            withAnimation(StrandMotion.interactive) {
                answer = JournalTriStateSelection.next(current: answer, tapped: value)
            }
            StrandHaptic.selection.play()
        }
        .opacity(answer == nil || selected ? 1 : 0.55)
    }
}

/// One counted habit as a flat row: the habit's symbol, its name over the logged amount, and a − / + stepper. Taking
/// the amount below zero clears it. The row saves nothing itself.
public struct JournalQuantityRow: View {
    private let icon: String
    private let tint: Color
    private let title: String
    private let unit: String
    private let maximum: Int
    @Binding private var value: Double?
    @Environment(\.dynamicTypeSize) private var typeSize

    public init(icon: String, tint: Color, title: String, unit: String,
                maximum: Int = 8, value: Binding<Double?>) {
        self.icon = icon
        self.tint = tint
        self.title = title
        self.unit = unit
        self.maximum = max(1, maximum)
        self._value = value
    }

    public var body: some View {
        Group {
            if typeSize.isAccessibilitySize {
                VStack(alignment: .leading, spacing: 10) {
                    label
                    stepper
                }
            } else {
                HStack(spacing: 12) {
                    label
                    Spacer(minLength: 8)
                    stepper
                }
            }
        }
        .padding(.vertical, 10)
        .frame(minHeight: 56)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(title), \(displayValue)")
        .accessibilityAdjustableAction { direction in
            switch direction {
            case .increment: increment()
            case .decrement: decrement()
            @unknown default: break
            }
        }
    }

    private var label: some View {
        HStack(spacing: 12) {
            journalIcon(icon, tint: tint)
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(StrandFont.body)
                    .foregroundStyle(StrandPalette.textPrimary)
                    .fixedSize(horizontal: false, vertical: true)
                Text(displayValue)
                    .font(StrandFont.caption)
                    .monospacedDigit()
                    .foregroundStyle(value == nil ? StrandPalette.textTertiary : tint)
                    .contentTransition(.numericText())
            }
        }
    }

    private var stepper: some View {
        HStack(spacing: 6) {
            stepButton("minus", enabled: value != nil) { decrement() }
            Text(value.map(Self.format) ?? "0")
                .font(StrandFont.bodyNumber)
                .foregroundStyle(value == nil ? StrandPalette.textTertiary : StrandPalette.textPrimary)
                .frame(minWidth: 28)
                .contentTransition(.numericText())
            stepButton("plus", enabled: true) { increment() }
        }
        .fixedSize()
    }

    private static func format(_ value: Double) -> String {
        value == value.rounded() ? String(Int(value)) : String(format: "%.1f", value)
    }

    private var displayValue: String {
        guard let value else { return String(localized: "Not logged", bundle: .module) }
        return "\(Self.format(value)) \(unit)"
    }

    private func increment() { value = min(Double(maximum) * 10, (value ?? 0) + 1) }
    private func decrement() {
        guard let value else { return }
        let next = value - 1
        self.value = next < 0 ? nil : next
    }

    private func stepButton(_ symbol: String, enabled: Bool, action: @escaping () -> Void) -> some View {
        Button {
            withAnimation(StrandMotion.interactive) { action() }
            StrandHaptic.selection.play()
        } label: {
            Image(systemName: symbol)
                .font(.system(size: 13, weight: .bold))
                .foregroundStyle(enabled ? StrandPalette.textPrimary : StrandPalette.textTertiary.opacity(0.5))
                .frame(width: 34, height: 34)
                .background(Circle().fill(StrandPalette.pillFill))
                .overlay(Circle().strokeBorder(StrandPalette.pillStroke, lineWidth: 1))
                .frame(width: 44, height: 44)
                .contentShape(Rectangle())
        }
        .buttonStyle(JournalPressStyle()).disabled(!enabled).accessibilityHidden(true)
    }
}

/// The day's mood: a question over five labelled steps, the chosen one filled. Tapping saves nothing itself.
public struct JournalMoodRow: View {
    @Binding private var mood: Int?
    private let title: String
    private let words: [String]
    @Environment(\.dynamicTypeSize) private var typeSize

    public init(mood: Binding<Int?>, title: String = "How did today feel?",
                words: [String] = ["Rough", "Low", "Okay", "Good", "Great"]) {
        self._mood = mood
        self.title = title
        self.words = words.count == 5 ? words : ["Rough", "Low", "Okay", "Good", "Great"]
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 12) {
                journalIcon("face.smiling", tint: StrandPalette.metricPurple)
                VStack(alignment: .leading, spacing: 2) {
                    Text(title).font(StrandFont.body).foregroundStyle(StrandPalette.textPrimary)
                    Text(mood.flatMap(word) ?? String(localized: "Tap a step", bundle: .module))
                        .font(StrandFont.caption)
                        .foregroundStyle(mood == nil ? StrandPalette.textTertiary : StrandPalette.metricPurple)
                }
                Spacer(minLength: 0)
            }
            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 6),
                                     count: typeSize.isAccessibilitySize ? 2 : 5),
                      spacing: 6) {
                ForEach(1...5, id: \.self) { step in moodStep(step) }
            }
        }
        .padding(.vertical, 10)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("\(title) \(mood.flatMap(word) ?? String(localized: "Not answered", bundle: .module))")
    }

    private func word(_ value: Int) -> String? { (1...5).contains(value) ? words[value - 1] : nil }

    private func moodStep(_ step: Int) -> some View {
        let selected = mood == step
        return Button {
            withAnimation(StrandMotion.interactive) { mood = step }
            StrandHaptic.selection.play()
        } label: {
            Text(word(step) ?? "")
                .font(StrandFont.caption.weight(selected ? .bold : .medium))
                .foregroundStyle(selected ? StrandPalette.onLightFill : StrandPalette.textSecondary)
                .lineLimit(1)
                .minimumScaleFactor(0.7)
                .frame(maxWidth: .infinity, minHeight: 36)
                .background(Capsule(style: .continuous).fill(selected ? StrandPalette.metricPurple : StrandPalette.pillFill))
                .overlay(Capsule(style: .continuous).strokeBorder(selected ? Color.clear : StrandPalette.pillStroke, lineWidth: 1))
                .frame(minHeight: 44)
                .contentShape(Rectangle())
        }
        .buttonStyle(JournalPressStyle())
        .accessibilityLabel(word(step) ?? "")
        .accessibilityAddTraits(selected ? .isSelected : [])
    }
}

/// How many of the day's questions are answered: the count, a thin bar and a caption. Flat, for the top of a check-in.
public struct JournalProgressHeader: View {
    private let answered: Int
    private let total: Int
    private let caption: String
    private let tint: Color
    @ScaledMetric(relativeTo: .title2) private var countSize: CGFloat = 22

    public init(answered: Int, total: Int, caption: String, tint: Color = StrandPalette.journalAccent) {
        self.answered = max(0, min(answered, total))
        self.total = max(0, total)
        self.caption = caption
        self.tint = tint
    }

    private var fraction: Double { total == 0 ? 0 : Double(answered) / Double(total) }

    public var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text(verbatim: "\(answered)")
                    .font(StrandFont.number(countSize, weight: .bold))
                    .foregroundStyle(StrandPalette.textPrimary)
                    .contentTransition(.numericText())
                Text("of \(total) answered", bundle: .module)
                    .font(StrandFont.subhead)
                    .foregroundStyle(StrandPalette.textSecondary)
                Spacer(minLength: 8)
                if total > 0, answered == total {
                    Label { Text("Done", bundle: .module) } icon: { Image(systemName: "checkmark") }
                        .font(StrandFont.caption.weight(.semibold))
                        .foregroundStyle(tint)
                }
            }
            GeometryReader { proxy in
                ZStack(alignment: .leading) {
                    Capsule(style: .continuous).fill(StrandPalette.hairline)
                    Capsule(style: .continuous).fill(tint)
                        .frame(width: proxy.size.width * fraction)
                }
            }
            .frame(height: 4)
            .animation(StrandMotion.interactive, value: answered)
            Text(caption)
                .font(StrandFont.caption)
                .foregroundStyle(StrandPalette.textTertiary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(answered) of \(total) answered. \(caption)")
    }
}

public struct JournalEntryCard<Content: View>: View {
    private let answered: Int
    private let total: Int
    private let content: Content

    public init(answered: Int, total: Int, @ViewBuilder content: () -> Content) {
        self.answered = max(0, min(answered, total))
        self.total = max(0, total)
        self.content = content()
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 8) {
                Text("Tonight’s journal", bundle: .module).textCase(.uppercase)
                    .font(StrandFont.overline).tracking(StrandFont.overlineTracking)
                    .foregroundStyle(StrandPalette.textSecondary)
                Spacer(minLength: 8)
                HStack(spacing: 3.5) {
                    ForEach(0..<total, id: \.self) { index in
                        Circle().fill(index < answered ? StrandPalette.textPrimary : StrandPalette.surfaceInset)
                            .frame(width: 5, height: 5)
                    }
                }
                Text("\(answered) of \(total)").font(StrandFont.micro).monospacedDigit()
                    .foregroundStyle(StrandPalette.textTertiary)
            }
            .padding(.horizontal, 13).padding(.top, 12).padding(.bottom, 4)
            content
        }
        .background(journalCardSurface(cornerRadius: 18))
    }
}

public struct JournalImpactValue: Equatable, Sendable {
    public let label: String
    public let magnitude: Double
    public init(label: String, magnitude: Double) {
        self.label = label
        self.magnitude = min(1, max(0, magnitude))
    }
}

public struct JournalImpactCard: View {
    private let icon: String
    private let behavior: String
    private let impact: String
    private let positive: Bool
    private let withValue: JournalImpactValue
    private let withoutValue: JournalImpactValue
    private let evidence: String

    public init(icon: String, behavior: String, impact: String, positive: Bool,
                withValue: JournalImpactValue, withoutValue: JournalImpactValue, evidence: String) {
        self.icon = icon; self.behavior = behavior; self.impact = impact; self.positive = positive
        self.withValue = withValue; self.withoutValue = withoutValue; self.evidence = evidence
    }

    private var tone: Color { positive ? StrandPalette.chargeAccent : StrandPalette.metricRose }

    public var body: some View {
        VStack(alignment: .leading, spacing: 11) {
            HStack(spacing: 10) {
                journalIcon(icon, tint: tone)
                VStack(alignment: .leading, spacing: 1) {
                    Text(behavior).font(StrandFont.caption.weight(.semibold)).foregroundStyle(StrandPalette.textPrimary)
                    Text(impact).font(StrandFont.micro).foregroundStyle(tone)
                }
                Spacer(minLength: 8)
                Image(systemName: positive ? "arrow.up.right" : "arrow.down.right")
                    .font(.system(size: 12, weight: .bold)).foregroundStyle(tone).accessibilityHidden(true)
            }
            VStack(spacing: 6) {
                impactBar(title: String(localized: "Nights with", bundle: .module), value: withValue, tinted: true)
                impactBar(title: String(localized: "Nights without", bundle: .module), value: withoutValue, tinted: false)
            }
            Text(evidence).font(StrandFont.micro).foregroundStyle(StrandPalette.textTertiary)
        }
        .padding(13).background(journalCardSurface(cornerRadius: 16))
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(behavior). \(impact). \(evidence)")
    }

    private func impactBar(title: String, value: JournalImpactValue, tinted: Bool) -> some View {
        HStack(spacing: 8) {
            Text(title).font(StrandFont.micro).foregroundStyle(StrandPalette.textTertiary)
                .frame(width: 82, alignment: .leading)
            GeometryReader { proxy in
                ZStack(alignment: .leading) {
                    Capsule(style: .continuous).fill(StrandPalette.surfaceInset)
                    Capsule(style: .continuous)
                        .fill(tinted ? tone.opacity(0.85) : StrandPalette.textTertiary.opacity(0.45))
                        .frame(width: max(8, proxy.size.width * value.magnitude))
                }
            }.frame(height: 7)
            Text(value.label).font(StrandFont.micro).monospacedDigit().foregroundStyle(StrandPalette.textSecondary)
                .frame(width: 44, alignment: .trailing)
        }
    }
}

public struct JournalStreakStrip: View {
    private let logged: [Bool]
    public init(logged: [Bool]) { self.logged = logged }

    public var body: some View {
        let streak = JournalStreakSummary.currentStreak(in: logged)
        return VStack(alignment: .leading, spacing: 9) {
            HStack {
                Text("Last 2 weeks", bundle: .module)
                    .font(StrandFont.caption)
                    .foregroundStyle(StrandPalette.textSecondary)
                Spacer(minLength: 8)
                if streak > 1 {
                    Text("\(streak)-night streak").font(StrandFont.caption.weight(.semibold)).monospacedDigit()
                        .foregroundStyle(StrandPalette.chargeAccent)
                }
            }
            HStack(spacing: 0) {
                ForEach(Array(logged.enumerated()), id: \.offset) { index, isLogged in
                    let isToday = index == logged.count - 1
                    Circle().fill(isLogged ? StrandPalette.journalAccent : StrandPalette.surfaceInset)
                        .overlay(Circle().strokeBorder(isToday ? StrandPalette.textPrimary : .clear, lineWidth: 1.5).padding(-3))
                        .frame(width: 9, height: 9).frame(maxWidth: .infinity)
                }
            }
            Text("A day counts once any answer is saved", bundle: .module)
                .font(StrandFont.micro).foregroundStyle(StrandPalette.textTertiary)
        }
        .padding(.vertical, 6)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Logging, \(streak) night streak, \(logged.filter { $0 }.count) of \(logged.count) nights logged")
    }
}

private func journalIcon(_ icon: String, tint: Color) -> some View {
    Image(systemName: icon)
        .font(.system(size: 13, weight: .semibold)).foregroundStyle(tint)
        .frame(width: 30, height: 30)
        .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(tint.opacity(0.12)))
        .accessibilityHidden(true)
}

private func journalCardSurface(cornerRadius: CGFloat) -> some View {
    RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
        .fill(StrandPalette.surfaceRaised)
        .overlay(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
            .strokeBorder(LinearGradient(colors: [Color.white.opacity(0.16), StrandPalette.hairline],
                                         startPoint: .top, endPoint: .bottom), lineWidth: 1))
}

private struct JournalPressStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.96 : 1)
            .opacity(configuration.isPressed ? 0.82 : 1)
            .animation(StrandMotion.interactive, value: configuration.isPressed)
    }
}
