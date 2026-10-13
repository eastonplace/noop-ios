import Foundation

/// The one Steps rule. Today's Steps tile, its glance line, the dashboard card and the Home Screen widget all
/// resolve a day's count through this, so they cannot show different numbers.
///
/// A measured count wins: the day's recorded total (the strap's own counter, or a file import) first, then
/// Apple Health's count for that same day. Only when neither exists does the on-device estimate (`steps_est`,
/// what a WHOOP 4.0 wearer gets) stand in, and it is flagged as an estimate.
struct TodaySteps: Equatable, Sendable {
    /// A measured count for the day, or nil when none exists.
    let recorded: Int?
    /// The on-device estimate, shown only when `recorded` is nil.
    let estimate: Int?

    init(daily: Int?, apple: Int?, estimate: Int?) {
        self.recorded = daily ?? apple
        self.estimate = estimate
    }

    /// The figure to show, or nil when the day has no count at all.
    var value: Int? { recorded ?? estimate }

    /// True when the figure is the estimate rather than a measured count.
    var isEstimate: Bool { recorded == nil && estimate != nil }
}
