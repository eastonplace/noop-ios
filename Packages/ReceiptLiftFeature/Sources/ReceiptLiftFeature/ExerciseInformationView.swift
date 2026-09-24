import SwiftUI

struct ExerciseInformationView: View {
  let exercise: LiftExercise

  var body: some View {
    let metadata = LiftExerciseCatalog.metadata(for: exercise)
    VStack(alignment: .leading, spacing: 16) {
      LiftExerciseThumb(exercise: exercise, size: 240)
        .frame(maxWidth: .infinity)
        .accessibilityLabel("Illustration of \(exercise.name)")
      LabeledContent("Body area", value: metadata?.bodyPart.capitalized ?? exercise.muscleGroup)
      LabeledContent("Primary muscle", value: metadata?.target.capitalized ?? exercise.muscleGroup)
      if let secondary = metadata?.secondaryMuscles, !secondary.isEmpty {
        LabeledContent("Secondary muscles", value: secondary.map { $0.capitalized }.joined(separator: ", "))
      }
      LabeledContent("Equipment", value: exercise.equipment.capitalized)
      ReceiptSectionLabel(title: "How to perform")
      if let steps = metadata?.instructionSteps?["en"], !steps.isEmpty {
        ForEach(Array(steps.enumerated()), id: \.offset) { index, step in
          HStack(alignment: .top, spacing: 12) {
            Text("\(index + 1).")
              .foregroundStyle(LiftTheme.accent)
            Text(step).fixedSize(horizontal: false, vertical: true)
          }
        }
      } else {
        Text(exercise.instructions).fixedSize(horizontal: false, vertical: true)
      }
    }
    .font(.system(size: 15))
    .foregroundStyle(LiftTheme.ink)
  }
}
