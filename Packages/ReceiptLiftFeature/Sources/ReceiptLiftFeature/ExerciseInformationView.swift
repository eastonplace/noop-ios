import StrandDesign
import SwiftUI

struct ExerciseInformationView: View {
  let exercise: LiftExercise

  var body: some View {
    let metadata = LiftExerciseCatalog.metadata(for: exercise)
    VStack(alignment: .leading, spacing: 16) {
      LiftExerciseThumb(exercise: exercise, size: 240)
        .frame(maxWidth: .infinity)
        .accessibilityLabel("Illustration of \(exercise.name)")
      VStack(spacing: 0) {
        infoRow("Body area", metadata?.bodyPart.capitalized ?? exercise.muscleGroup)
        infoRow("Primary muscle", metadata?.target.capitalized ?? exercise.muscleGroup)
        if let secondary = metadata?.secondaryMuscles, !secondary.isEmpty {
          infoRow("Secondary muscles", secondary.map { $0.capitalized }.joined(separator: ", "))
        }
        infoRow("Equipment", exercise.equipment.capitalized)
      }
      LiftSection(title: "How to perform") {
        if let steps = metadata?.instructionSteps?["en"], !steps.isEmpty {
          VStack(alignment: .leading, spacing: 10) {
            ForEach(Array(steps.enumerated()), id: \.offset) { index, step in
              HStack(alignment: .top, spacing: 12) {
                Text("\(index + 1).")
                  .font(StrandFont.number(15))
                  .foregroundStyle(LiftTheme.accent)
                Text(step)
                  .font(StrandFont.subhead)
                  .foregroundStyle(StrandPalette.textPrimary)
                  .fixedSize(horizontal: false, vertical: true)
              }
            }
          }
        } else {
          Text(exercise.instructions)
            .font(StrandFont.subhead)
            .foregroundStyle(StrandPalette.textPrimary)
            .fixedSize(horizontal: false, vertical: true)
        }
      }
    }
  }

  private func infoRow(_ label: String, _ value: String) -> some View {
    HStack(alignment: .firstTextBaseline, spacing: 12) {
      Text(label)
        .font(StrandFont.subhead)
        .foregroundStyle(StrandPalette.textSecondary)
      Spacer(minLength: 8)
      Text(value)
        .font(StrandFont.subhead)
        .foregroundStyle(StrandPalette.textPrimary)
        .multilineTextAlignment(.trailing)
        .fixedSize(horizontal: false, vertical: true)
    }
    .contentRowSurface(boundedPadding: NoopMetrics.space3, flatVerticalPadding: NoopMetrics.space3)
    .accessibilityElement(children: .combine)
  }
}
