import StrandDesign
import SwiftUI

/// An exercise's picture, the muscles it works and how to do it: what the exercise page opens beneath its header.
struct ExerciseInformationView: View {
  let exercise: LiftExercise

  var body: some View {
    let metadata = LiftExerciseCatalog.metadata(for: exercise)
    VStack(alignment: .leading, spacing: 0) {
      LiftExerciseThumb(exercise: exercise, size: 220)
        .frame(maxWidth: .infinity)
        .padding(.vertical, NoopMetrics.space3)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(
          LiftMedia.imageName(for: exercise) == nil
            ? Text("Illustration unavailable for \(exercise.name)")
            : Text("Illustration of \(exercise.name)")
        )
      LiftRowList(
        items: rows(metadata),
        row: { row, _ in LiftKeyValueRow(label: row.label, value: row.value) }
      )
      Text("How to perform")
        .font(StrandFont.caption.weight(.semibold))
        .foregroundStyle(StrandPalette.textTertiary)
        .padding(.top, NoopMetrics.space4)
        .padding(.bottom, NoopMetrics.space2)
        .accessibilityAddTraits(.isHeader)
      if let steps = metadata?.instructionSteps?["en"], !steps.isEmpty {
        VStack(alignment: .leading, spacing: NoopMetrics.space3) {
          ForEach(Array(steps.enumerated()), id: \.offset) { index, step in
            HStack(alignment: .firstTextBaseline, spacing: NoopMetrics.space3) {
              Text((index + 1).formatted(.number))
                .font(StrandFont.number(15))
                .foregroundStyle(DomainTint.workout.accent)
                .frame(minWidth: 20, alignment: .leading)
              Text(verbatim: step)
                .font(StrandFont.subhead)
                .foregroundStyle(StrandPalette.textPrimary)
                .fixedSize(horizontal: false, vertical: true)
            }
            .accessibilityElement(children: .combine)
          }
        }
      } else {
        Text(verbatim: exercise.instructions)
          .font(StrandFont.subhead)
          .foregroundStyle(StrandPalette.textPrimary)
          .fixedSize(horizontal: false, vertical: true)
      }
    }
  }

  private struct InfoRow: Identifiable {
    let label: LocalizedStringKey
    let value: String
    var id: String { value + "\(label)" }
  }

  private func rows(_ metadata: LiftExerciseCatalog.SourceExercise?) -> [InfoRow] {
    var rows = [
      InfoRow(label: "Body area", value: metadata?.bodyPart.capitalized ?? exercise.muscleGroup),
      InfoRow(label: "Primary muscle", value: metadata?.target.capitalized ?? exercise.muscleGroup),
    ]
    if let secondary = metadata?.secondaryMuscles, !secondary.isEmpty {
      rows.append(InfoRow(label: "Secondary muscles", value: secondary.map { $0.capitalized }.joined(separator: ", ")))
    }
    rows.append(InfoRow(label: "Equipment", value: exercise.equipment.capitalized))
    return rows
  }
}
