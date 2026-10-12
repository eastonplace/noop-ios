import SwiftUI

// MARK: - Correlation strength
//
// The one rule every screen that talks about a Pearson r shares: which word a value of r earns and which ink it
// is drawn in. Before this the Metric Explorer, Compare, Lab Book and Insights each carried their own copy (an
// opacity ramp on green and red in three of them, a sample of the recovery gradient in the fourth), with three
// different sets of word thresholds, so the same r read as a different strength on neighbouring screens.
//
// The type holds the thresholds and the colours. The words themselves are localised by the screen that shows
// them (the app's string catalog carries "weak", "moderate", "strong" and the rest), so this package stays free
// of any one screen's copy.

/// How strongly two series move together, from the size of their Pearson r.
public enum CorrelationStrength: Sendable, CaseIterable, Equatable {
    case negligible
    case weak
    case moderate
    case strong
    case veryStrong

    /// |r| below 0.1 is negligible, below 0.3 weak, below 0.5 moderate, below 0.7 strong, and the rest very strong.
    public init(r: Double) {
        switch abs(r) {
        case ..<0.1: self = .negligible
        case ..<0.3: self = .weak
        case ..<0.5: self = .moderate
        case ..<0.7: self = .strong
        default: self = .veryStrong
        }
    }

    /// True once a relationship is worth drawing in colour: moderate or stronger. A weak or negligible r reads
    /// in the quiet ink, so a colour always means "this one is worth a look".
    public var isNotable: Bool {
        switch self {
        case .negligible, .weak: return false
        case .moderate, .strong, .veryStrong: return true
        }
    }

    /// The pill tone for an r: green for a notable positive relationship, red for a notable negative one, the
    /// quiet neutral for anything weaker.
    public static func tone(for r: Double) -> StrandTone {
        guard CorrelationStrength(r: r).isNotable else { return .neutral }
        return r >= 0 ? .positive : .critical
    }

    /// The ink of an r value: `tone(for:)`'s colour.
    public static func color(for r: Double) -> Color { tone(for: r).color }

    /// "+0.62" or "−0.41": the sign, then |r| to two places in the person's number format. A value that rounds to
    /// zero carries no sign ("0.00"), never "−0.00".
    public static func signedText(_ r: Double) -> String {
        let magnitude = abs(r).formatted(.number.precision(.fractionLength(2)))
        let rounded = (abs(r) * 100).rounded()
        guard rounded > 0 else { return magnitude }
        return (r >= 0 ? "+" : "\u{2212}") + magnitude
    }
}
