import StrandDesign
import SwiftUI

struct LiftProgressionReviewSection: View {
  let review: LiftProgressionReview
  let isCurrent: Bool
  let onRefresh: () -> Void

  @Environment(\.liftFormat) private var format

  var body: some View {
    LiftFlatSection("Next-session suggestions", systemImage: "chart.line.uptrend.xyaxis") {
      VStack(alignment: .leading, spacing: NoopMetrics.space3) {
        Text("Review targets for this workout, based on your latest completed session of this routine.")
          .font(StrandFont.subhead)
          .foregroundStyle(StrandPalette.textSecondary)
          .fixedSize(horizontal: false, vertical: true)
        if !isCurrent {
          Text("These suggestions need a refresh before you apply them.")
            .font(StrandFont.subhead)
            .foregroundStyle(StrandPalette.textPrimary)
          Button(action: onRefresh) { Text("Refresh suggestions").liftPillLabel() }
            .buttonStyle(SecondaryPillButtonStyle())
            .accessibilityIdentifier("lift.progression.refresh")
        }
        ForEach(review.rows) { row in
          VStack(alignment: .leading, spacing: NoopMetrics.space1) {
            Text(row.exercise?.name.liftDisplayName ?? String(localized: "Exercise unavailable"))
              .font(StrandFont.headline)
              .foregroundStyle(StrandPalette.textPrimary)
            if let target = row.decision.target {
              Text("\(target.sets) × \(target.repsText) at \(format.load(pounds: target.weightPounds, for: row.exercise))")
                .font(StrandFont.subhead)
                .foregroundStyle(StrandPalette.accent)
            } else {
              Text("Keep the saved plan")
                .font(StrandFont.subhead)
                .foregroundStyle(StrandPalette.textPrimary)
            }
            if let evidence = row.decision.evidence, let endedAt = row.decision.sourceEndedAt {
              Text("Last session: \(endedAt.formatted(date: .abbreviated, time: .omitted)) · \(evidence.workingSets) work sets · \(repSummary(evidence)) reps · \(format.load(pounds: evidence.weightPounds, for: row.exercise))")
                .font(StrandFont.footnote)
                .foregroundStyle(StrandPalette.textSecondary)
              if let rpe = evidence.highestRPE {
                Text("Highest effort: RPE \(rpe.formatted(.number.precision(.fractionLength(0...1))))")
                  .font(StrandFont.footnote)
                  .foregroundStyle(StrandPalette.textSecondary)
              }
            }
            Text(explanation(row.decision.reason))
              .font(StrandFont.footnote)
              .foregroundStyle(StrandPalette.textSecondary)
              .fixedSize(horizontal: false, vertical: true)
            if row.decision.reason == .addWeight || row.decision.reason == .reduceWeight,
               let step = row.equipment.loadStep(in: review.unit.progressionUnit) {
              Text("Suggested equipment step: \(format.weight(pounds: review.unit.toPounds(step))). Check the available weights before lifting.")
                .font(StrandFont.footnote)
                .foregroundStyle(StrandPalette.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
            }
          }
          .frame(maxWidth: .infinity, alignment: .leading)
          .padding(.vertical, NoopMetrics.space1)
          .accessibilityElement(children: .combine)
        }
      }
    }
  }

  private func repSummary(_ evidence: LiftProgressionEvidence) -> String {
    evidence.minimumReps == evidence.maximumReps
      ? evidence.minimumReps.formatted()
      : "\(evidence.minimumReps.formatted())–\(evidence.maximumReps.formatted())"
  }

  private func explanation(_ reason: LiftProgressionDecision.Reason) -> String {
    switch reason {
    case .addReps:
      String(localized: "Every working set met the rep range at the planned effort. Try one more rep per set.")
    case .addSet:
      String(localized: "You reached the top of the rep range at RPE 7 or below. Add one set within your saved range.")
    case .addWeight:
      String(localized: "You completed the top of both ranges with effort in reserve. Add one load step and return to the lower rep target.")
    case .reduceWeight:
      String(localized: "Reps fell below the plan or effort reached RPE 9.5. Try one lighter load step.")
    case .reduceReps:
      String(localized: "Effort reached RPE 9.5. Keep the load and lower the rep target.")
    case .repeatWork:
      String(localized: "Keep the load steady while completing the prescribed reps at the intended effort.")
    case .noHistory:
      String(localized: "Complete this routine and rate your working sets to establish a baseline.")
    case .staleHistory:
      String(localized: "The latest completed session is more than six weeks old. Log a fresh baseline before progressing.")
    case .noWorkingSets:
      String(localized: "The latest session has no completed working sets for this exercise. Warm-ups do not count toward progression.")
    case .unsupportedPrescription:
      String(localized: "Automatic targets need a clear set count, rep range, and RPE or RIR target. Timed or mixed prescriptions stay as planned.")
    case .missingEffort:
      String(localized: "Rate effort on every working set to get a next-session target. An untouched RPE cell does not count as a rating.")
    case .invalidHistory:
      String(localized: "The latest session has invalid set data. Log a fresh completed session before using automatic targets.")
    case .mixedLoads:
      String(localized: "Your last working sets used different loads. Choose this workout's load manually.")
    case .incompleteSets:
      String(localized: "Fewer than the planned minimum working sets were completed. Keep the current prescription before progressing.")
    case .unknownLoadStep:
      String(localized: "Keep the last load. Confirm this equipment's next available increment before changing it.")
    case .bodyweightCeiling:
      String(localized: "Keep the recorded bodyweight or added load. Choose a harder variation or load change manually.")
    case .loadStepTooLarge:
      String(localized: "A suitable load step is unavailable or would add more than 10%. Keep the load and choose a smaller increment manually.")
    }
  }
}
