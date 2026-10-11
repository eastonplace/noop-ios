import SwiftUI

// The strength-training Live Activity in the same widget language as the cardio one: black card, a pulsing eyebrow,
// the clock as the hero, then a strip of facts. The shapes take plain values so the widget extension (which cannot see
// `ReceiptLiftActivity`'s types here) and the simulator QA gallery render the very same views.

/// The clock: the rest countdown while resting, otherwise the time since the lift began.
public struct NOOPLiftClockText: View {
    public let startedAt: Date
    /// Non-nil while a rest timer is running; the clock then counts down to it.
    public let restEndsAt: Date?
    public let size: CGFloat
    public let isDimmed: Bool

    public init(startedAt: Date, restEndsAt: Date? = nil, size: CGFloat, isDimmed: Bool = false) {
        self.startedAt = startedAt
        self.restEndsAt = restEndsAt
        self.size = size
        self.isDimmed = isDimmed
    }

    public var body: some View {
        Group {
            if let restEndsAt {
                Text(restEndsAt, style: .timer).foregroundStyle(StrandPalette.statusWarning)
            } else {
                Text(startedAt, style: .timer).foregroundStyle(StrandPalette.textPrimary)
            }
        }
        .font(StrandFont.number(size, weight: .bold))
        .monospacedDigit()
        .lineLimit(1)
        .minimumScaleFactor(0.6)
        // `.timer` text claims the whole row; the caller's frame decides where it sits.
        .multilineTextAlignment(.leading)
        .opacity(isDimmed ? 0.45 : 1)
    }
}

/// Moves, sets and volume as a strip of small facts.
public struct NOOPLiftFacts: View {
    public let move: String?
    public let setProgress: String
    public let volume: Double

    public init(move: String?, setProgress: String, volume: Double) {
        self.move = move
        self.setProgress = setProgress
        self.volume = volume
    }

    /// 842 stays "842"; 12 450 reads "12.5k".
    public static func volumeText(_ volume: Double) -> String {
        let value = max(volume, 0)
        if value >= 1_000 { return String(format: "%.1fk", value / 1_000) }
        return "\(Int(value.rounded()))"
    }

    public var body: some View {
        HStack(alignment: .top, spacing: 14) {
            if let move {
                fact(Text("Move", bundle: .module), value: move.isEmpty ? WidgetMetrics.missingValue : move, tint: StrandPalette.textPrimary)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            fact(Text("Sets", bundle: .module), value: setProgress, tint: StrandPalette.strainAccent)
            fact(Text("Volume", bundle: .module), value: Self.volumeText(volume), tint: StrandPalette.textPrimary)
            if move == nil { Spacer(minLength: 0) }
        }
    }

    private func fact(_ label: Text, value: String, tint: Color) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            label.textCase(.uppercase).font(.system(size: 9, weight: .bold)).tracking(0.8)
                .foregroundStyle(StrandPalette.textTertiary).lineLimit(1)
            Text(verbatim: value).font(StrandFont.number(16, weight: .semibold)).monospacedDigit()
                .foregroundStyle(value == WidgetMetrics.missingValue ? StrandPalette.textTertiary : tint)
                .lineLimit(1).minimumScaleFactor(0.62)
        }
    }
}

/// Lock Screen and banner card.
public struct NOOPLiftLiveActivityView: View {
    public let workoutName: String
    public let startedAt: Date
    public let move: String
    public let setProgress: String
    public let volume: Double
    /// Set while resting between sets.
    public let restEndsAt: Date?
    /// ActivityKit's own staleness: the app has not updated this activity for a while.
    public let isStale: Bool

    public init(workoutName: String, startedAt: Date, move: String, setProgress: String, volume: Double,
                restEndsAt: Date?, isStale: Bool = false) {
        self.workoutName = workoutName
        self.startedAt = startedAt
        self.move = move
        self.setProgress = setProgress
        self.volume = volume
        self.restEndsAt = restEndsAt
        self.isStale = isStale
    }

    private var isResting: Bool { restEndsAt != nil }

    public var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                EyebrowPulseIcon(systemName: isResting ? "timer" : "figure.strengthtraining.traditional",
                                 color: isResting ? StrandPalette.statusWarning : StrandPalette.strainAccent,
                                 pulses: !isStale)
                Text("Active lift", bundle: .module).textCase(.uppercase)
                    .font(StrandFont.overline).tracking(1.2)
                    .foregroundStyle(StrandPalette.textSecondary).lineLimit(1)
                Spacer(minLength: 8)
                if isStale {
                    LivePill(title: "Not updating", tint: StrandPalette.textSecondary)
                } else if isResting {
                    LivePill(title: "Resting", tint: StrandPalette.statusWarning)
                }
            }
            HStack(alignment: .lastTextBaseline, spacing: 12) {
                NOOPLiftClockText(startedAt: startedAt, restEndsAt: restEndsAt, size: 38, isDimmed: isStale)
                    .frame(maxWidth: 150, alignment: .leading)
                Text(verbatim: workoutName)
                    .font(StrandFont.headline).foregroundStyle(StrandPalette.textPrimary)
                    .lineLimit(1).minimumScaleFactor(0.7)
                    .frame(maxWidth: .infinity, alignment: .trailing)
            }
            NOOPLiftFacts(move: move, setProgress: setProgress, volume: volume)
                .opacity(isStale ? 0.6 : 1)
        }
        .padding(14)
        .background(Color.black)
        .accessibilityElement(children: .contain)
        .accessibilityLabel(Text(verbatim: "\(workoutName), \(move), \(setProgress)"))
    }
}

/// Compact leading and minimal: one glyph, the rest timer's while resting.
public struct NOOPLiftIslandGlyph: View {
    public let isResting: Bool
    public init(isResting: Bool) { self.isResting = isResting }
    public var body: some View {
        Image(systemName: isResting ? "timer" : "figure.strengthtraining.traditional")
            .font(.system(size: 12, weight: .bold))
            .foregroundStyle(isResting ? StrandPalette.statusWarning : StrandPalette.strainAccent)
    }
}

/// Compact trailing and expanded trailing: the clock at the caller's size.
public struct NOOPLiftIslandClock: View {
    public let startedAt: Date
    public let restEndsAt: Date?
    public let size: CGFloat
    public init(startedAt: Date, restEndsAt: Date?, size: CGFloat = 13) {
        self.startedAt = startedAt
        self.restEndsAt = restEndsAt
        self.size = size
    }
    public var body: some View {
        NOOPLiftClockText(startedAt: startedAt, restEndsAt: restEndsAt, size: size)
            .frame(maxWidth: size > 14 ? 90 : 56, alignment: .trailing)
    }
}

/// Expanded centre: the lift's name over the move in hand.
public struct NOOPLiftIslandTitle: View {
    public let workoutName: String
    public let move: String
    public init(workoutName: String, move: String) {
        self.workoutName = workoutName
        self.move = move
    }
    public var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(verbatim: workoutName).textCase(.uppercase)
                .font(StrandFont.overline).tracking(1.0)
                .foregroundStyle(StrandPalette.textSecondary).lineLimit(1)
            Text(verbatim: move.isEmpty ? WidgetMetrics.missingValue : move)
                .font(StrandFont.headline).foregroundStyle(StrandPalette.textPrimary)
                .lineLimit(1).minimumScaleFactor(0.7)
        }
    }
}
