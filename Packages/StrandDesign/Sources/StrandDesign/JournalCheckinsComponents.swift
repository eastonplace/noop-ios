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

public struct JournalHabitToggle: View {
    private let icon: String
    private let tint: Color
    private let question: String
    private let detail: String?
    @Binding private var answer: Bool?

    public init(icon: String, tint: Color, question: String, detail: String? = nil,
                answer: Binding<Bool?>) {
        self.icon = icon
        self.tint = tint
        self.question = question
        self.detail = detail
        self._answer = answer
    }

    public var body: some View {
        HStack(spacing: 11) {
            journalIcon(icon, tint: tint)
            VStack(alignment: .leading, spacing: 1) {
                Text(question)
                    .font(StrandFont.caption.weight(.medium))
                    .foregroundStyle(StrandPalette.textPrimary)
                    .fixedSize(horizontal: false, vertical: true)
                if let detail {
                    Text(detail).font(StrandFont.micro).foregroundStyle(StrandPalette.textTertiary)
                }
            }
            Spacer(minLength: 8)
            HStack(spacing: 6) {
                answerCircle(symbol: "xmark", value: false)
                answerCircle(symbol: "checkmark", value: true)
            }
        }
        .padding(.horizontal, 13)
        .padding(.vertical, 10)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("\(question). \(answerWord)")
    }

    private var answerWord: String {
        switch answer {
        case true?: return String(localized: "Answered yes", bundle: .module)
        case false?: return String(localized: "Answered no", bundle: .module)
        case nil: return String(localized: "Not answered yet", bundle: .module)
        }
    }

    private func answerCircle(symbol: String, value: Bool) -> some View {
        let selected = answer == value
        return Button {
            withAnimation(StrandMotion.interactive) {
                answer = JournalTriStateSelection.next(current: answer, tapped: value)
            }
            StrandHaptic.selection.play()
        } label: {
            Image(systemName: symbol)
                .font(.system(size: 12, weight: .bold))
                .foregroundStyle(selected ? StrandPalette.surfaceRaised : StrandPalette.textTertiary)
                .frame(width: 34, height: 34)
                .background(Circle().fill(selected ? StrandPalette.textPrimary : StrandPalette.surfaceInset))
                .overlay(Circle().strokeBorder(selected ? .clear : StrandPalette.hairlineStrong, lineWidth: 1))
                .opacity(answer == nil || selected ? 1 : 0.45)
        }
        .buttonStyle(JournalPressStyle())
        .accessibilityLabel(value ? String(localized: "Yes", bundle: .module)
                                  : String(localized: "No", bundle: .module))
        .accessibilityAddTraits(selected ? .isSelected : [])
    }
}

public struct JournalQuantityRow: View {
    private let icon: String
    private let tint: Color
    private let title: String
    private let unit: String
    private let maximum: Int
    @Binding private var value: Double?

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
        HStack(spacing: 11) {
            journalIcon(icon, tint: tint)
            VStack(alignment: .leading, spacing: 5) {
                HStack(alignment: .firstTextBaseline, spacing: 4) {
                    Text(title).font(StrandFont.caption.weight(.medium)).foregroundStyle(StrandPalette.textPrimary)
                    Text(displayValue)
                        .font(StrandFont.micro).monospacedDigit().foregroundStyle(StrandPalette.textTertiary)
                        .contentTransition(.numericText())
                }
                HStack(spacing: 3.5) {
                    ForEach(0..<maximum, id: \.self) { index in
                        Capsule(style: .continuous)
                            .fill(index < pipCount ? tint : StrandPalette.surfaceInset)
                            .frame(width: 11, height: 5)
                    }
                }
            }
            Spacer(minLength: 8)
            HStack(spacing: 7) {
                quantityButton("minus", enabled: value != nil) { decrement() }
                quantityButton("plus", enabled: true) { increment() }
            }
        }
        .padding(.horizontal, 13)
        .padding(.vertical, 10)
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

    private var pipCount: Int { min(maximum, max(0, Int((value ?? 0).rounded()))) }
    private var displayValue: String {
        guard let value else { return String(localized: "Not logged", bundle: .module) }
        let number = value == value.rounded() ? String(Int(value)) : String(format: "%.1f", value)
        return "\(number) \(unit)"
    }
    private func increment() { value = (value ?? 0) + 1 }
    private func decrement() {
        guard let value else { return }
        let next = value - 1
        self.value = next < 0 ? nil : next
    }
    private func quantityButton(_ symbol: String, enabled: Bool, action: @escaping () -> Void) -> some View {
        Button {
            withAnimation(StrandMotion.interactive) { action() }
            StrandHaptic.selection.play()
        } label: {
            Image(systemName: symbol)
                .font(.system(size: 11, weight: .bold))
                .foregroundStyle(enabled ? StrandPalette.textPrimary : StrandPalette.textTertiary.opacity(0.5))
                .frame(width: 26, height: 26)
                .background(Circle().fill(StrandPalette.surfaceInset))
        }
        .buttonStyle(JournalPressStyle()).disabled(!enabled).accessibilityHidden(true)
    }
}

public struct JournalMoodRow: View {
    @Binding private var mood: Int?
    private let title: String
    private let words: [String]

    public init(mood: Binding<Int?>, title: String = "How did today feel?",
                words: [String] = ["Rough", "Low", "Okay", "Good", "Great"]) {
        self._mood = mood
        self.title = title
        self.words = words.count == 5 ? words : ["Rough", "Low", "Okay", "Good", "Great"]
    }

    public var body: some View {
        HStack(spacing: 11) {
            journalIcon("face.smiling", tint: StrandPalette.metricPurple)
            VStack(alignment: .leading, spacing: 1) {
                Text(title).font(StrandFont.caption.weight(.medium)).foregroundStyle(StrandPalette.textPrimary)
                Text(mood.flatMap(word) ?? String(localized: "Tap a step", bundle: .module))
                    .font(StrandFont.micro)
                    .foregroundStyle(mood == nil ? StrandPalette.textTertiary : StrandPalette.metricPurple)
            }
            Spacer(minLength: 8)
            HStack(spacing: 5) {
                ForEach(1...5, id: \.self) { step in moodDot(step) }
            }
        }
        .padding(.horizontal, 13).padding(.vertical, 10)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("\(title) \(mood.flatMap(word) ?? String(localized: "Not answered", bundle: .module))")
    }

    private func word(_ value: Int) -> String? { (1...5).contains(value) ? words[value - 1] : nil }
    private func moodDot(_ step: Int) -> some View {
        let selected = mood == step
        return Button {
            withAnimation(StrandMotion.interactive) { mood = step }
            StrandHaptic.selection.play()
        } label: {
            Circle()
                .fill(selected ? StrandPalette.metricPurple : StrandPalette.surfaceInset)
                .overlay(Circle().strokeBorder(selected ? .clear : StrandPalette.hairlineStrong, lineWidth: 1))
                .frame(width: selected ? 24 : 13, height: selected ? 24 : 13)
                .frame(width: 24, height: 28).contentShape(Rectangle())
        }
        .buttonStyle(JournalPressStyle())
        .accessibilityLabel(word(step) ?? "")
        .accessibilityAddTraits(selected ? .isSelected : [])
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
                Text("Logging", bundle: .module).textCase(.uppercase)
                    .font(StrandFont.overline).tracking(StrandFont.overlineTracking)
                    .foregroundStyle(StrandPalette.textSecondary)
                Spacer(minLength: 8)
                if streak > 1 {
                    Text("\(streak)-night streak").font(StrandFont.micro).monospacedDigit()
                        .foregroundStyle(StrandPalette.chargeAccent)
                }
            }
            HStack(spacing: 0) {
                ForEach(Array(logged.enumerated()), id: \.offset) { index, isLogged in
                    let isToday = index == logged.count - 1
                    Circle().fill(isLogged ? StrandPalette.textPrimary : StrandPalette.surfaceInset)
                        .overlay(Circle().strokeBorder(isToday ? StrandPalette.textPrimary : .clear, lineWidth: 1.5).padding(-3))
                        .frame(width: 8, height: 8).frame(maxWidth: .infinity)
                }
            }
            Text("2 weeks · a night counts once any answer is saved", bundle: .module)
                .font(StrandFont.micro).foregroundStyle(StrandPalette.textTertiary)
        }
        .padding(13).background(journalCardSurface(cornerRadius: 16))
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
