import Foundation
import StrandAnalytics
import StrandDesign

// The three parts of the day's score as rows for the "What set today's score" section. Pure and tested.

struct StrainScoreRow: Equatable, Identifiable {
    enum Kind: Int, CaseIterable { case cardio, steps, energy, lifting }

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

    /// Cardio and steps always; active energy only when something feeds it (no source today, so no always-empty row).
    let rows: [StrainScoreRow]
    /// Whether the parts' score is the hero's. They differ only when the hero comes from another source or moment
    /// (the live score counts heart rate before the batch score's 20-reading gate opens).
    let agreesWithHero: Bool

    /// True while active energy is not one of the rows: the score is then worked out from cardio and steps alone.
    var isScoredFromCardioAndSteps: Bool { !rows.contains { $0.kind == .energy } }

    /// - Parameter liftLoad: the day's muscular load from the logged lifts (Strength Strain), 0 for none. The score is
    ///   then `max(step floor, energy floor, combine(cardio, load))` and a Lifting row shows what the sets add.
    static func make(_ components: StrainScorerV2.DayStrainComponents, hero: Double?,
                     liftLoad: Double = 0) -> StrainScoreParts? {
        guard let score = components.score else { return nil }
        let load = usable(liftLoad)
        let combinedScore = load > 0 ? (StrengthStrain.combineDay(components: components, muscularLoad: load) ?? score) : score
        let agrees = hero.map { abs(StrainScale.displayValue(fromStored: combinedScore) - $0) <= agreementTolerance } ?? false
        let dominant = Self.dominant(components, liftLoad: load)
        func row(_ kind: StrainScoreRow.Kind, _ value: Double?) -> StrainScoreRow {
            let part: StrainScorerV2.DayStrainComponents.Component
            switch kind {
            case .cardio: part = .cardio
            case .steps: part = .steps
            case .energy: part = .energy
            case .lifting: return StrainScoreRow(kind: .lifting, value: value, setsScore: false)
            }
            return StrainScoreRow(kind: kind, value: value, setsScore: agrees && dominant == part)
        }
        var rows = [row(.cardio, components.cardio), row(.steps, components.steps), row(.energy, components.energy)]
            .filter { $0.kind != .energy || $0.value != nil }
        if load > 0 {
            let add = StrainScale.displayValue(fromStored: combinedScore) - StrainScale.displayValue(fromStored: score)
            rows.append(row(.lifting, add))
        }
        return StrainScoreParts(rows: rows, agreesWithHero: agrees)
    }

    /// The part that sets the day's score. With lifts the cardio part is the one carrying them, so it is compared as
    /// `combine(cardio, load)`; without lifts it is the components' own dominant part.
    static func dominant(_ components: StrainScorerV2.DayStrainComponents,
                         liftLoad: Double) -> StrainScorerV2.DayStrainComponents.Component? {
        let load = usable(liftLoad)
        guard load > 0, let cardio = components.cardio else { return components.dominant }
        let lifted = StrengthStrain.combinedDisplay(hrDisplay: cardio, muscularLoad: load)
        let steps = components.steps ?? 0
        let energy = components.energy ?? 0
        if lifted >= steps, lifted >= energy { return .cardio }
        return steps >= energy ? .steps : .energy
    }

    private static func usable(_ load: Double) -> Double { load.isFinite && load > 0 ? load : 0 }
}
