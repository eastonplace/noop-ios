import SwiftUI

// MARK: - Heart-rate zone distribution
//
// Time in each of the five heart-rate zones: one proportional bar for the shape of the effort and one row per zone
// for the numbers behind it, hardest zone first. The workout summary and the Workouts hub draw their zones with it,
// so they read the same way. It takes plain values (names, ranges and spoken labels already in the person's
// language) and colours the zones from `StrandPalette.hrZones`.
//
// Given a selection binding the rows become buttons: choosing a zone marks its row and dims the other zones in the
// bar, so a screen can show where that zone fell in the session. Without one the rows are plain.

public struct HRZoneDistribution: View {
    public struct Zone: Identifiable, Equatable, Sendable {
        /// 1...5.
        public let number: Int
        /// The zone's name in the person's language ("Maximum").
        public let name: String
        public let seconds: Double
        /// The zone's bpm band, already written for display ("150–168 bpm", "169+ bpm"), when it is known.
        public let range: String?
        /// What VoiceOver reads for the zone's row ("Zone 5, Maximum, 169 or more beats per minute, 4 minutes,
        /// 13 percent"). The caller writes it because a duration shown as "4m" is read as metres, and it knows the
        /// person's language. When nil the row reads its visible texts.
        public let accessibilityLabel: String?

        public var id: Int { number }

        public init(number: Int, name: String, seconds: Double, range: String? = nil, accessibilityLabel: String? = nil) {
            self.number = number
            self.name = name
            self.seconds = max(0, seconds.isFinite ? seconds : 0)
            self.range = range
            self.accessibilityLabel = accessibilityLabel
        }
    }

    /// One zone's share of the total, 0...1.
    public static func fractions(_ zones: [Zone]) -> [Double] {
        let total = zones.reduce(0) { $0 + $1.seconds }
        guard total > 0 else { return zones.map { _ in 0 } }
        return zones.map { $0.seconds / total }
    }

    private let zones: [Zone]
    private let selection: Binding<Int?>?
    private let rowHint: String?
    @Environment(\.dynamicTypeSize) private var typeSize
    @ScaledMetric(relativeTo: .body) private var barHeight: CGFloat = 12

    /// `zones` in any order; the rows read from the hardest zone down. `selection` (a zone number, or nil for none)
    /// makes the rows tappable; `rowHint` is the VoiceOver hint for a tappable row, in the person's language.
    public init(zones: [Zone], selection: Binding<Int?>? = nil, rowHint: String? = nil) {
        self.zones = zones.sorted { $0.number < $1.number }
        self.selection = selection
        self.rowHint = rowHint
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
                        .opacity(dims(zones[index].number) ? 0.3 : 1)
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

    private var selectedZone: Int? { selection?.wrappedValue }

    private func dims(_ number: Int) -> Bool {
        guard let selectedZone else { return false }
        return selectedZone != number
    }

    @ViewBuilder private func row(_ zone: Zone, share: Double) -> some View {
        if let selection {
            Button {
                selection.wrappedValue = selection.wrappedValue == zone.number ? nil : zone.number
            } label: {
                rowContent(zone, share: share)
                    .padding(.horizontal, NoopMetrics.space2)
                    .background(
                        RoundedRectangle(cornerRadius: NoopMetrics.radius1, style: .continuous)
                            .fill(selectedZone == zone.number
                                  ? StrandPalette.hrZoneColor(zone.number).opacity(0.16) : Color.clear)
                    )
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            // The row's own padding gives the text room inside the highlight; this keeps its text on the page's edge.
            .padding(.horizontal, -NoopMetrics.space2)
            .accessibilityAddTraits(selectedZone == zone.number ? .isSelected : [])
            .accessibilityHint(rowHint.map { Text(verbatim: $0) } ?? Text(verbatim: ""))
        } else {
            rowContent(zone, share: share)
        }
    }

    private func rowContent(_ zone: Zone, share: Double) -> some View {
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
        .modifier(SpokenRow(label: zone.accessibilityLabel))
    }

    /// The row as one spoken element: the caller's label when it wrote one, else the row's own texts.
    private struct SpokenRow: ViewModifier {
        let label: String?
        @ViewBuilder func body(content: Content) -> some View {
            if let label {
                content.accessibilityElement(children: .ignore).accessibilityLabel(Text(verbatim: label))
            } else {
                content.accessibilityElement(children: .combine)
            }
        }
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
