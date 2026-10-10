import Foundation
import StrandAnalytics
import StrandDesign

// The three parts of the day's score as rows for the "What set today's score" section. Pure and tested.

struct StrainScoreRow: Equatable, Identifiable {
    enum Kind: Int, CaseIterable { case cardio, steps, energy }

    let kind: Kind
    /// On the 0...21 display scale; nil when nothing feeds that part (no step count, no active energy).
    let value: Double?
    /// True only for the part that equals the day's score, and only when the parts add up to the hero.
    let setsScore: Bool

    var id: Int { kind.rawValue }
}

/// The three parts of the day's score (the score is the largest of them) as rows for the "What set today's score"
/// section.
struct StrainScoreParts: Equatable {
    /// The most the parts' own score may differ from the hero's before they are no longer the same figure.
    static let agreementTolerance = 0.05

    let rows: [StrainScoreRow]
    /// Whether the parts' score is the hero's. They differ only when the hero comes from another source or moment
    /// (the live score counts heart rate before the batch score's 20-reading gate opens).
    let agreesWithHero: Bool

    static func make(_ components: StrainScorerV2.DayStrainComponents, hero: Double?) -> StrainScoreParts? {
        guard let score = components.score else { return nil }
        let agrees = hero.map { abs(StrainScale.displayValue(fromStored: score) - $0) <= agreementTolerance } ?? false
        func row(_ kind: StrainScoreRow.Kind, _ value: Double?) -> StrainScoreRow {
            let dominant: StrainScorerV2.DayStrainComponents.Component
            switch kind {
            case .cardio: dominant = .cardio
            case .steps: dominant = .steps
            case .energy: dominant = .energy
            }
            return StrainScoreRow(kind: kind, value: value, setsScore: agrees && components.dominant == dominant)
        }
        return StrainScoreParts(
            rows: [row(.cardio, components.cardio), row(.steps, components.steps), row(.energy, components.energy)],
            agreesWithHero: agrees)
    }
}

