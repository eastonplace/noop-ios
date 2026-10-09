import SwiftUI

// MARK: - Heart-rate zone distribution
//
// Time in each of the five heart-rate zones: one proportional bar for the shape of the effort and one row per zone
// for the numbers behind it, hardest zone first. The workout detail and the Workouts hub show the same thing the
// same way, so it lives here once. It takes plain values (names and ranges already in the person's language) and
// colours the zones from `StrandPalette.hrZones`.

public struct HRZoneDistribution: View {
    public struct Zone: Identifiable, Equatable, Sendable {
        /// 1...5.
        public let number: Int
        /// The zone's name in the person's language ("Maximum").
        public let name: String
        public let seconds: Double
        /// The zone's bpm band, already written for display ("150–168 bpm", "169+ bpm"), when it is known.
        public let range: String?

        public var id: Int { number }

        public init(number: Int, name: String, seconds: Double, range: String? = nil) {
            self.number = number
            self.name = name
            self.seconds = max(0, seconds.isFinite ? seconds : 0)
            self.range = range
        }
    }

    /// One zone's share of the total, 0...1.
    public static func fractions(_ zones: [Zone]) -> [Double] {
        let total = zones.reduce(0) { $0 + $1.seconds }
        guard total > 0 else { return zones.map { _ in 0 } }
        return zones.map { $0.seconds / total }
    }

    private let zones: [Zone]
    @Environment(\.dynamicTypeSize) private var typeSize
    @ScaledMetric(relativeTo: .body) private var barHeight: CGFloat = 12

    /// `zones` in any order; the rows read from the hardest zone down.
    public init(zones: [Zone]) {
        self.zones = zones.sorted { $0.number < $1.number }
    }

    public var body: some View {
        let total = zones.reduce(0) { $0 + $1.seconds }
        return VStack(alignment: .leading, spacing: WidgetMetrics.contentSpacing) {
            bar
            VStack(spacing: 0) {
                ForEach(Array(zones.reversed().enumerated()), id: \.element.id) { index, zone in
                    if index > 0 { rowSeparator }
                    row(zone, share: total > 0 ? zone.seconds / total : 0)
                }
            }
        }
    }

    // MARK: Bar

    private var bar: some View {
        let fractions = Self.fractions(zones)
        return GeometryReader { proxy in
            let gap: CGFloat = 2
            let shown = zones.indices.filter { fractions[$0] > 0 }
            let usable = max(0, proxy.size.width - gap * CGFloat(max(0, shown.count - 1)))
            HStack(spacing: gap) {
                ForEach(shown, id: \.self) { index in
                    Rectangle()
                        .fill(StrandPalette.hrZoneColor(zones[index].number))
                        .frame(width: max(2, usable * CGFloat(fractions[index])))
                }
            }
        }
        .frame(height: barHeight)
        .clipShape(Capsule(style: .continuous))
        .background(Capsule(style: .continuous).fill(StrandPalette.chipFill))
        .accessibilityHidden(true)
    }

    // MARK: Rows

    private var rowSeparator: some View {
        Rectangle().fill(StrandPalette.hairline).frame(height: 1).accessibilityHidden(true)
    }

    @ViewBuilder private func row(_ zone: Zone, share: Double) -> some View {
        Group {
            if typeSize.isAccessibilitySize {
                VStack(alignment: .leading, spacing: NoopMetrics.space1) {
                    HStack(spacing: NoopMetrics.space2) { swatch(zone); title(zone) }
                    if let range = zone.range { rangeText(range) }
                    HStack(spacing: NoopMetrics.space3) { duration(zone); percent(share) }
                }
            } else {
                HStack(alignment: .center, spacing: NoopMetrics.space2) {
                    swatch(zone)
                    VStack(alignment: .leading, spacing: 1) {
                        title(zone)
                        if let range = zone.range { rangeText(range) }
                    }
                    Spacer(minLength: NoopMetrics.space2)
                    duration(zone)
                    percent(share).frame(minWidth: 40, alignment: .trailing)
                }
            }
        }
        .padding(.vertical, NoopMetrics.space2)
        .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
        .accessibilityElement(children: .combine)
    }

    private func swatch(_ zone: Zone) -> some View {
        RoundedRectangle(cornerRadius: 3, style: .continuous)
            .fill(StrandPalette.hrZoneColor(zone.number))
            .frame(width: 10, height: 10)
            .opacity(zone.seconds > 0 ? 1 : 0.35)
            .accessibilityHidden(true)
    }

    private func title(_ zone: Zone) -> some View {
        HStack(spacing: NoopMetrics.space2) {
            Text(verbatim: "Z\(zone.number)")
                .font(StrandFont.subhead.weight(.semibold))
                .foregroundStyle(zone.seconds > 0 ? StrandPalette.textPrimary : StrandPalette.textTertiary)
            Text(verbatim: zone.name)
                .font(StrandFont.subhead)
                .foregroundStyle(StrandPalette.textSecondary)
                .lineLimit(1)
        }
    }

    private func rangeText(_ range: String) -> some View {
        Text(verbatim: range).font(StrandFont.micro).foregroundStyle(StrandPalette.textTertiary)
    }

    private func duration(_ zone: Zone) -> some View {
        Text(verbatim: zone.seconds >= 30 ? Self.durationText(zone.seconds) : WidgetMetrics.missingValue)
            .font(StrandFont.bodyNumber.monospacedDigit())
            .foregroundStyle(zone.seconds >= 30 ? StrandPalette.textPrimary : StrandPalette.textTertiary)
            .lineLimit(1)
    }

    private func percent(_ share: Double) -> some View {
        Text(verbatim: share > 0 ? share.formatted(.percent.precision(.fractionLength(0))) : "")
            .font(StrandFont.caption.monospacedDigit())
            .foregroundStyle(StrandPalette.textTertiary)
            .lineLimit(1)
    }

    /// "1h 05m"-style time, narrow units, never "0m" for a zone that was visited.
    static func durationText(_ seconds: Double) -> String {
        let rounded = max(60, (seconds / 60).rounded() * 60)
        return Duration.seconds(rounded).formatted(.units(allowed: [.hours, .minutes], width: .narrow))
    }
}
