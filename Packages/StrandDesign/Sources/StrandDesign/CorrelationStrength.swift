import SwiftUI

// MARK: - Correlation strength
//
// The one rule every screen that talks about a Pearson r shares: which word a value of r earns, which ink it is drawn
// in and how it is printed. The Metric Explorer, Compare and the Lab Book's marker pages read it from here, so the same
// r reads as the same strength on all three. The Insights screens still carry their own copy of the thresholds (an
// opacity ramp on green and red with its own word cut-offs), so on those screens the same r can still read as a different
// strength until they move over; this note is updated when they do.
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

    /// |r| below 0.10 is negligible, below 0.30 weak, below 0.50 moderate, below 0.70 strong, and the rest very
    /// strong. The thresholds apply to |r| rounded to the two places the screens print, so the word always agrees
    /// with the number beside it (0.4996 prints as "+0.50" and reads "strong", not "moderate"). A value that is
    /// not a number reads as negligible.
    public init(r: Double) {
        guard r.isFinite else { self = .negligible; return }
        switch Int((abs(r) * 100).rounded()) {
        case ..<10: self = .negligible
        case ..<30: self = .weak
        case ..<50: self = .moderate
        case ..<70: self = .strong
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

    /// "+0.62" or "−0.41": the sign, then |r| to two places in `locale`'s number format (the person's own by
    /// default, so a German reader sees "+0,62"). A value that rounds to zero carries no sign ("0.00"), never
    /// "−0.00".
    public static func signedText(_ r: Double, locale: Locale = .autoupdatingCurrent) -> String {
        let magnitude = abs(r).formatted(.number.precision(.fractionLength(2)).locale(locale))
        let rounded = (abs(r) * 100).rounded()
        guard rounded > 0 else { return magnitude }
        return (r >= 0 ? "+" : "\u{2212}") + magnitude
    }
}
