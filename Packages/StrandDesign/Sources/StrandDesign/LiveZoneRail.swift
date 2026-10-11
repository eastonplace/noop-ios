import SwiftUI

/// The wearer's three heart-rate zones as one rail: Rest, Steady and Push, each as wide as its share of the heart-rate
/// scale, with a marker where the current reading sits and the bpm each zone starts at under it.
///
/// The words and boundaries are the ones the Today live card, the heart-rate timeline and the Strain screen use (rest
/// below half of the wearer's maximum heart rate, steady to 70%, push from there), so a workout never names a zone
/// differently from the rest of the app.
public struct LiveZoneRail: View {
    private let bpm: Int?
    private let thresholds: HRZoneStyle.Thresholds
    private let isDimmed: Bool
    private let style: Style

    /// `full` is the readout, the rail and the legend (the workout screen); `bar` is the rail and its marker alone, for a
    /// Live Activity or a widget where the reading is already drawn beside it.
    public enum Style: Sendable { case full, bar }

    @Environment(\.dynamicTypeSize) private var typeSize
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    /// - Parameters:
    ///   - bpm: The current reading, or nil while there is none (the marker is hidden and the zone reads "—").
    ///   - thresholds: The wearer's boundaries (`HRZoneStyle.Thresholds(hrMax:)`).
    ///   - isDimmed: A paused workout: the reading is a frozen one, so the rail is drawn quieter.
    public init(bpm: Int?, thresholds: HRZoneStyle.Thresholds, isDimmed: Bool = false, style: Style = .full) {
        self.bpm = bpm
        self.thresholds = thresholds
        self.isDimmed = isDimmed
        self.style = style
    }

    private static let gap: CGFloat = 3
    private static let railHeight: CGFloat = 8
    private static let markerSize: CGFloat = 16

    private var zone: Int? { bpm.map { thresholds.zone(for: Double($0)) } }

    private static func word(_ zone: Int) -> String {
        switch zone {
        case 0: String(localized: "Rest", bundle: .module)
        case 1: String(localized: "Steady", bundle: .module)
        default: String(localized: "Push", bundle: .module)
        }
    }

    private var legend: [(zone: Int, word: String, range: String)] {
        [
            (0, Self.word(0), "<\(thresholds.steadyStartBPM.formatted())"),
            (1, Self.word(1), "\(thresholds.steadyStartBPM.formatted())–\((thresholds.pushStartBPM - 1).formatted())"),
            (2, Self.word(2), "\(thresholds.pushStartBPM.formatted())+"),
        ]
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: NoopMetrics.space3) {
            if style == .full { readout }
            rail
            if style == .full { legendRow }
        }
        .opacity(isDimmed ? 0.55 : 1)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text("Heart-rate zone", bundle: .module))
        .accessibilityValue(Text(verbatim: spoken))
    }

    private var spoken: String {
        guard let bpm, let zone else { return String(localized: "No reading", bundle: .module) }
        return "\(Self.word(zone)), \(bpm) \(String(localized: "bpm", bundle: .module))"
    }

    // MARK: Readout

    private var readout: some View {
        HStack(alignment: .firstTextBaseline, spacing: NoopMetrics.space2) {
            if let zone {
                Circle().fill(HRZoneStyle.zoneColor(zone)).frame(width: 8, height: 8).accessibilityHidden(true)
                Text(verbatim: Self.word(zone)).font(StrandFont.subhead.weight(.semibold))
                    .foregroundStyle(StrandPalette.textPrimary)
            } else {
                Text(verbatim: WidgetMetrics.missingValue).font(StrandFont.subhead.weight(.semibold))
                    .foregroundStyle(StrandPalette.textTertiary)
            }
            Spacer(minLength: NoopMetrics.space2)
            if let bpm {
                Text(verbatim: "\(bpm)").font(StrandFont.bodyNumber.weight(.semibold)).monospacedDigit()
                    .foregroundStyle(StrandPalette.textPrimary)
                + Text(verbatim: " ")
                + Text("bpm", bundle: .module).font(StrandFont.micro).foregroundStyle(StrandPalette.textTertiary)
            }
        }
        .lineLimit(1)
    }

    // MARK: Rail

    /// Each zone's share of the drawn heart-rate scale.
    private var shares: [Double] {
        let rest = HRZoneStyle.unit(thresholds.rest)
        let steady = HRZoneStyle.unit(thresholds.steady)
        return [rest, steady - rest, 1 - steady]
    }

    private var rail: some View {
        ProportionalRow(weights: shares, spacing: Self.gap) {
            ForEach(0..<3, id: \.self) { index in
                Capsule(style: .continuous)
                    .fill(HRZoneStyle.zoneColor(index).opacity(zone == index ? 1 : 0.4))
                    .frame(height: Self.railHeight)
            }
        }
        .frame(height: Self.markerSize)
        .overlay(alignment: .leading) {
            GeometryReader { geometry in
                if let bpm {
                    Circle().fill(StrandPalette.textPrimary)
                        .frame(width: Self.markerSize, height: Self.markerSize)
                        .overlay(Circle().strokeBorder(StrandPalette.appCanvas.opacity(0.55), lineWidth: 2))
                        .offset(x: markerX(bpm: Double(bpm), width: geometry.size.width) - Self.markerSize / 2)
                        .frame(maxHeight: .infinity)
                        .animation(reduceMotion ? nil : .linear(duration: 0.25), value: bpm)
                }
            }
        }
        .accessibilityHidden(true)
    }

    /// Where the marker sits: inside the zone the reading is in, at the reading's place within that zone, so it never
    /// crosses a boundary the zone word has not.
    private func markerX(bpm: Double, width: CGFloat) -> CGFloat {
        let zone = thresholds.zone(for: bpm)
        let lower: Double = zone == 0 ? HRZoneStyle.floor : (zone == 1 ? thresholds.rest : thresholds.steady)
        let upper: Double = zone == 0 ? thresholds.rest : (zone == 1 ? thresholds.steady : HRZoneStyle.ceiling)
        let within = upper > lower ? min(max((bpm - lower) / (upper - lower), 0), 1) : 0
        let usable = max(0, width - Self.gap * 2)
        let widths = shares.map { CGFloat($0) * usable }
        let origin = widths.prefix(zone).reduce(0, +) + Self.gap * CGFloat(zone)
        let x = origin + widths[zone] * CGFloat(within)
        return min(max(x, Self.markerSize / 2), max(Self.markerSize / 2, width - Self.markerSize / 2))
    }

    // MARK: Legend

    @ViewBuilder private var legendRow: some View {
        if typeSize.isAccessibilitySize {
            VStack(alignment: .leading, spacing: NoopMetrics.space2) {
                ForEach(legend, id: \.zone) { entry in
                    HStack(alignment: .firstTextBaseline, spacing: NoopMetrics.space2) {
                        legendWord(entry)
                        Spacer(minLength: NoopMetrics.space2)
                        Text(verbatim: entry.range).monospacedDigit()
                            .foregroundStyle(StrandPalette.textTertiary).microLabelFit()
                    }
                }
            }
        } else {
            ProportionalRow(weights: shares, spacing: Self.gap) {
                ForEach(legend, id: \.zone) { entry in
                    VStack(alignment: .leading, spacing: 1) {
                        legendWord(entry)
                        Text(verbatim: entry.range).monospacedDigit()
                            .foregroundStyle(StrandPalette.textTertiary).microLabelFit(lines: 1)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
        }
    }

    private func legendWord(_ entry: (zone: Int, word: String, range: String)) -> some View {
        Text(verbatim: entry.word)
            .foregroundStyle(zone == entry.zone ? StrandPalette.textPrimary : StrandPalette.textSecondary)
            .fontWeight(zone == entry.zone ? .semibold : .regular)
            .microLabelFit()
    }
}


/// Lays its children side by side, each as wide as its weight's share of the row. The rail and its legend use the same
/// weights, so every word sits under the start of its own zone.
private struct ProportionalRow: Layout {
    let weights: [Double]
    let spacing: CGFloat

    private func widths(in width: CGFloat, count: Int) -> [CGFloat] {
        let usable = max(0, width - spacing * CGFloat(max(count - 1, 0)))
        let total = max(weights.prefix(count).reduce(0, +), .leastNonzeroMagnitude)
        return (0..<count).map { usable * CGFloat(weights[min($0, weights.count - 1)] / total) }
    }

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let width = proposal.width ?? 0
        let columns = widths(in: width, count: subviews.count)
        let height = zip(subviews, columns).map { $0.sizeThatFits(ProposedViewSize(width: $1, height: nil)).height }.max() ?? 0
        return CGSize(width: width, height: height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let columns = widths(in: bounds.width, count: subviews.count)
        var x = bounds.minX
        for (subview, width) in zip(subviews, columns) {
            subview.place(at: CGPoint(x: x, y: bounds.midY), anchor: .leading,
                          proposal: ProposedViewSize(width: width, height: bounds.height))
            x += width + spacing
        }
    }
}
