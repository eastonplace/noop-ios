#if os(iOS)
import SwiftUI
import StrandDesign
import StrandAnalytics

// MARK: - The figures and the page frame the live pages share
//
// Every page draws its numbers the same way: a `LiveWorkoutFigure` per metric (its colour, its unit block, whether it is
// live, quiet or frozen), laid out by a `LivePageFrame` that scales them all together so the stack fits the room the screen
// gives the page, under the notice band and clear of the dots.

/// One metric as the live pages draw it.
struct LiveWorkoutFigure: View {
    let value: LiveWorkoutGlance.Value
    var size: LiveNumeral.Size = .secondary
    var scale: CGFloat = 1
    let isPaused: Bool
    let signals: LiveWorkoutSignals.Snapshot
    /// The zone the figure's heart rate is in (heart-rate metrics only): its colour and, for the live reading, its name.
    var zone: Int?

    private var state: LiveNumeral.State { Self.state(of: value, isPaused: isPaused, signals: signals) }

    var body: some View {
        let state = state
        // A reading whose source has gone quiet keeps its last number; the zone it was in is not news either.
        let unit = state == .stale && value.metric == .heartRate ? Array(value.unit.suffix(1)) : value.unit
        LiveNumeral(value.text, unit: unit, micro: state == .stale ? String(localized: "no signal") : value.micro,
                    size: size, color: LiveWorkoutGlance.color(of: value.metric, zone: zone),
                    unitColor: LiveWorkoutGlance.unitColor(of: value.metric), state: state, scale: scale,
                    spokenLabel: value.name, spokenValue: Self.spoken(value, state: state))
    }

    /// Paused numbers are frozen; a reading whose source has gone quiet keeps its last number, stepped back. Totals and
    /// averages are never stale.
    static func state(of value: LiveWorkoutGlance.Value, isPaused: Bool, signals: LiveWorkoutSignals.Snapshot) -> LiveNumeral.State {
        if value.isMissing { return .missing }
        if isPaused { return .paused }
        switch value.metric {
        case .heartRate: return signals.heartRateIsStale ? .stale : .live
        case .pace, .speed: return signals.paceIsStale ? .stale : .live
        case .time, .distance, .strain, .calories, .averageHeartRate: return .live
        }
    }

    /// What VoiceOver reads: the zone a live heart rate is in ("149 beats per minute, Push", as the unit block draws it), a
    /// quiet source says so ("142 beats per minute, no signal", with no zone, as drawn), and a number that is not known is never
    /// a dash. Strain that is still building says when it will score.
    static func spoken(_ value: LiveWorkoutGlance.Value, state: LiveNumeral.State) -> String {
        if value.isMissing { return value.micro ?? value.spoken }
        if state == .stale { return "\(value.spoken), \(String(localized: "no signal"))" }
        return [value.spoken, value.spokenZone].compactMap { $0 }.joined(separator: ", ")
    }
}

/// What every page keeps clear: the band under the header for a notice, and a little air above the dots.
enum LivePageMetrics {
    /// The least air between the last figure and the dots (or the save preview) under the page.
    static let bottomReserve: CGFloat = 12

    /// The notice band: one pill tall, taller at the accessibility sizes where the pill wraps.
    static func band(accessibility: Bool) -> CGFloat {
        accessibility ? 76 : LiveNumeralMetrics.noticeBand
    }
}

/// A page's frame: the room the pager gives it, the notice band at its top, and the figures scaled to fit what is left (never
/// larger than designed). A page that cannot fit even at the smallest scale scrolls.
struct LivePageFrame<Content: View>: View {
    /// The figures' height at scale 1.
    let naturalHeight: CGFloat
    @ViewBuilder let content: (CGFloat) -> Content
    @Environment(\.dynamicTypeSize) private var typeSize

    var body: some View {
        GeometryReader { proxy in
            let fit = LiveNumeralMetrics.fit(natural: naturalHeight, region: max(0, proxy.size.height - LivePageMetrics.bottomReserve),
                                             band: LivePageMetrics.band(accessibility: typeSize.isAccessibilitySize))
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    Color.clear.frame(height: fit.top)
                    content(fit.scale)
                }
                .frame(maxWidth: .infinity, minHeight: proxy.size.height, alignment: .topLeading)
                .screenPadding()
            }
            .scrollBounceBehavior(.basedOnSize)
        }
    }
}
#endif
