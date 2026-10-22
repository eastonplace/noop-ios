#if os(iOS)
import SwiftUI
import StrandDesign
import MarkdownUI
import CoachPresentation

// MARK: - Coach chat building blocks
//
// The flat chat language the v2 mockups draw: plain answer text, a right-aligned bubble, hairline capsule chips,
// plain tertiary icon actions, tinted pills and one shimmering progress line. Every piece takes plain values and
// never sees the engine.

// MARK: Type

private struct CoachScaledFont: ViewModifier {
    @ScaledMetric private var size: CGFloat
    private let weight: Font.Weight
    private let digits: Bool

    init(size: CGFloat, weight: Font.Weight, relativeTo style: Font.TextStyle, digits: Bool) {
        _size = ScaledMetric(wrappedValue: size, relativeTo: style)
        self.weight = weight
        self.digits = digits
    }

    func body(content: Content) -> some View {
        content.font(digits ? Font.system(size: size, weight: weight).monospacedDigit()
                            : Font.system(size: size, weight: weight))
    }
}

extension View {
    /// A point size drawn exactly as the mockup states it, that still follows Dynamic Type from `style`.
    func coachFont(_ size: CGFloat, _ weight: Font.Weight = .regular, relativeTo style: Font.TextStyle = .body,
                   digits: Bool = false) -> some View {
        modifier(CoachScaledFont(size: size, weight: weight, relativeTo: style, digits: digits))
    }
}

// MARK: Answer text

extension Theme {
    /// The answer as plain body text: 16.5pt in the primary ink, a generous line height and no box. Bold stays white.
    @MainActor
    static func coachAnswer(size: CGFloat) -> Theme {
        Theme.strand
            .text {
                ForegroundColor(StrandPalette.textPrimary.opacity(0.92))
                FontSize(size)
            }
            .strong {
                FontWeight(.bold)
                ForegroundColor(StrandPalette.textPrimary)
            }
            .paragraph { configuration in
                configuration.label
                    .relativeLineSpacing(.em(0.3))
                    .markdownMargin(top: 0, bottom: 10)
            }
    }
}

// MARK: Chips and pills

/// The quiet capsule Coach uses for secondary controls: "3 sources", "2 more records", Workouts. A hairline outline,
/// no fill. The caller wraps it in a `Button` and adds `.coachChipHitTarget()`.
struct CoachHairlineChip: View {
    let title: Text
    var systemImage: String?
    var trailingSystemImage: String?
    @ScaledMetric(relativeTo: .caption) private var size: CGFloat = 12.5

    var body: some View {
        HStack(spacing: 6) {
            if let systemImage {
                Image(systemName: systemImage).font(.system(size: size - 0.5, weight: .semibold))
                    .accessibilityHidden(true)
            }
            title.font(.system(size: size, weight: .medium)).lineLimit(2).multilineTextAlignment(.leading)
            if let trailingSystemImage {
                Image(systemName: trailingSystemImage).font(.system(size: size - 2.5, weight: .semibold))
                    .accessibilityHidden(true)
            }
        }
        .foregroundStyle(StrandPalette.textSecondary)
        .padding(.horizontal, 11).padding(.vertical, 5)
        .frame(minHeight: 28)
        .overlay(Capsule(style: .continuous).strokeBorder(StrandPalette.hairlineStrong, lineWidth: 1))
        .contentShape(Capsule(style: .continuous))
    }
}

extension View {
    /// A 44pt tap area around a 28pt chip: the chip stays centred in it.
    func coachChipHitTarget() -> some View {
        self.frame(minHeight: 44).contentShape(Rectangle())
    }
}

/// A short status pill: neutral chrome with the tone as a leading dot (the delta to the average, a recovery band, an
/// efficiency figure).
struct CoachTintPill: View {
    let text: Text
    let tint: Color

    var body: some View {
        text.coachFont(13, .semibold, relativeTo: .footnote, digits: true)
            .foregroundStyle(StrandPalette.textPrimary)
            .lineLimit(1).minimumScaleFactor(0.8)
            .statePillChrome(tint: tint)
            .frame(minHeight: 26)
    }
}

// MARK: Follow-ups

struct CoachFollowUp: Identifiable, Equatable {
    var id: String { title }
    let title: String
    let prompt: String
}

enum CoachFollowUps {
    /// Two next questions that fit what the latest answer showed, never parsed from its prose.
    static func suggestions(for message: LocalCoachMessage) -> [CoachFollowUp] {
        let cards = message.cards ?? []
        if let journal = cards.compactMap({ card -> LocalCoachCard.JournalAssociation? in
            if case .journalAssociation(let value) = card { return value }
            return nil
        }).first {
            return [.init(title: "Explain this association", prompt: LocalCoachCardFormat.journalFollowUp(journal)),
                    .init(title: "What should I log?", prompt: "What explicit yes/no journal answers would help me compare my habits with recovery? Explain missing data without treating unlogged days as no.")]
        }
        if cards.contains(where: { $0.kind == "sleep" }) {
            return [.init(title: "Compare nights", prompt: "Compare my recorded sleep over the last seven days."),
                    .init(title: "Plan tonight", prompt: "Help me plan tonight using my recent sleep records.")]
        }
        if cards.contains(where: { $0.kind == "workouts" || $0.kind == "effort" }) {
            return [.init(title: "Review recovery", prompt: "Review my recorded recovery after recent training."),
                    .init(title: "Compare this week", prompt: "Compare my recent training with last week.")]
        }
        if !cards.isEmpty {
            return [.init(title: "Explain the change", prompt: "Explain changes in my recovery over the last seven days."),
                    .init(title: "Check my sleep", prompt: "Review my recent sleep records.")]
        }
        return []
    }
}

/// The suggested questions as one row of hairline capsules that scrolls sideways and bleeds to the screen edge, so a
/// chip that does not fit is visibly cut off. Each chip is 36pt tall inside a 44pt tap area.
struct CoachFollowUpRow: View {
    let items: [CoachFollowUp]
    let onAsk: (String) -> Void

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: NoopMetrics.space2) {
                ForEach(items) { item in
                    Button { onAsk(item.prompt) } label: {
                        Text(LocalizedStringKey(item.title))
                            .coachFont(14.5, .regular, relativeTo: .subheadline)
                            .foregroundStyle(StrandPalette.textPrimary.opacity(0.9))
                            .lineLimit(1).fixedSize(horizontal: true, vertical: false)
                            .padding(.horizontal, 14)
                            .frame(minHeight: 36)
                            .background(Capsule(style: .continuous).fill(StrandPalette.card))
                            .overlay(Capsule(style: .continuous).strokeBorder(StrandPalette.hairlineStrong, lineWidth: 1))
                            .frame(minHeight: 44)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityHint(Text("Asks Coach: \(item.prompt)"))
                }
            }
            .padding(.horizontal, NoopMetrics.space4)
        }
        .scrollBounceBehavior(.basedOnSize, axes: .horizontal)
        .accessibilityElement(children: .contain)
        .accessibilityLabel(Text("Suggested questions"))
        .accessibilityIdentifier("coach.followUps")
    }
}

// MARK: Progress line

/// One secondary line that shimmers while Coach works. Static under Reduce Motion, when the app is not active and
/// before it is on screen.
struct CoachShimmerText: View {
    let text: Text
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.scenePhase) private var scenePhase
    @State private var onScreen = false

    var body: some View {
        Group {
            if reduceMotion || scenePhase != .active || !onScreen {
                line(sweep: nil)
            } else {
                TimelineView(.animation(minimumInterval: 1.0 / 30.0)) { clock in
                    line(sweep: clock.date.timeIntervalSinceReferenceDate)
                }
            }
        }
        .onAppear { onScreen = true }
        .onDisappear { onScreen = false }
    }

    private func line(sweep time: Double?) -> some View {
        let base = StrandPalette.textTertiary
        let highlight = StrandPalette.textPrimary
        let still = LinearGradient(colors: [StrandPalette.textSecondary], startPoint: .leading, endPoint: .trailing)
        let style: LinearGradient
        if let time {
            // A soft highlight crosses the line left to right every 1.8s, resting off to either side.
            let phase = time.truncatingRemainder(dividingBy: 1.8) / 1.8
            let centre = -0.4 + phase * 1.8
            style = LinearGradient(stops: [.init(color: base, location: 0),
                                           .init(color: highlight.opacity(0.95), location: 0.5),
                                           .init(color: base, location: 1)],
                                   startPoint: UnitPoint(x: centre - 0.3, y: 0.5),
                                   endPoint: UnitPoint(x: centre + 0.3, y: 0.5))
        } else {
            style = still
        }
        return text.coachFont(16.5, .medium)
            .foregroundStyle(style)
            .fixedSize(horizontal: false, vertical: true)
    }
}
#endif
