import StrandDesign
import SwiftUI

enum LiftPlateLoaderEligibility {
  nonisolated static func isEligible(_ exercise: LiftExercise) -> Bool {
    exercise.equipment.localizedCaseInsensitiveContains("barbell")
      && !liftUsesBodyweightLoad(exercise)
  }
}

enum LiftPlatePresentation {
  nonisolated static func accessibilityLabel(
    total: Double,
    solution: LiftPlateMath.PlateSolution,
    bar: Double = LiftDesignMetrics.PlateLoader.barWeight
  ) -> String {
    let totalText = number(total)
    let barText = number(bar)

    if solution.exact {
      guard !solution.perSide.isEmpty else {
        return "\(totalText) pounds: bare bar. Bar \(barText)."
      }
      let plates = solution.perSide.map(number).joined(separator: ", ")
      return "\(totalText) pounds: per side \(plates). Bar \(barText)."
    }

    let below = solution.nearestBelow.map { "below \(number($0))" }
    let above = solution.nearestAbove.map { "above \(number($0))" }
    let nearest = [below, above].compactMap { $0 }.joined(separator: ", ")
    return "\(totalText) pounds: not loadable. Nearest \(nearest). Bar \(barText)."
  }

  nonisolated static func number(_ value: Double) -> String {
    if value.rounded() == value {
      return String(Int(value))
    }
    return String(format: "%.1f", value)
  }
}

struct PlateLoaderView: View {
  @Environment(\.dismiss) private var dismiss
  @Binding private var targetWeight: Double
  private let exercise: LiftExercise
  private let barWeight = LiftDesignMetrics.PlateLoader.barWeight

  init(targetWeight: Binding<Double>, exercise: LiftExercise) {
    _targetWeight = targetWeight
    self.exercise = exercise
  }

  private var solution: LiftPlateMath.PlateSolution {
    LiftPlateMath.solve(target: targetWeight, bar: barWeight)
  }

  private var perSideTotal: Double {
    solution.perSide.reduce(0, +)
  }

  var body: some View {
    LiftScreen(
      title: "Plate loader",
      subtitle: LocalizedStringKey("\(exercise.name.liftDisplayName) · \(LiftPlatePresentation.number(targetWeight)) lb"),
      trailing: {
        NoopIconButton("xmark", accessibilityLabel: "Close plate loader") { dismiss() }
      }
    ) {
      VStack(spacing: 12) {
        plateDiagram
        Text(
          "Bar \(LiftPlatePresentation.number(barWeight)) · Each side \(LiftPlatePresentation.number(perSideTotal))"
        )
        .font(StrandFont.number(13, weight: .medium))
        .foregroundStyle(StrandPalette.textSecondary)
      }
      .frame(maxWidth: .infinity)
      .accessibilityElement(children: .ignore)
      .accessibilityLabel(
        LiftPlatePresentation.accessibilityLabel(
          total: targetWeight,
          solution: solution,
          bar: barWeight
        )
      )

      if !solution.exact {
        nearestChoices
      }
    }
  }

  private var plateDiagram: some View {
    ZStack {
      Rectangle()
        .fill(StrandPalette.textTertiary)
        .frame(height: 2)

      HStack(spacing: 3) {
        if solution.perSide.isEmpty {
          RoundedRectangle(cornerRadius: 3, style: .continuous)
            .fill(StrandPalette.inset)
            .frame(width: 12, height: 72)
            .overlay {
              RoundedRectangle(cornerRadius: 3, style: .continuous)
                .strokeBorder(StrandPalette.textTertiary, lineWidth: 1)
            }
        } else {
          ForEach(Array(solution.perSide.enumerated()), id: \.offset) { index, plate in
            plateSlab(plate, index: index)
          }
        }
      }
    }
    .frame(height: 112)
  }

  private func plateSlab(_ plate: Double, index: Int) -> some View {
    let ratio = CGFloat(max(min(plate / 45, 1), 0.22))
    return Text(LiftPlatePresentation.number(plate))
      .font(StrandFont.number(11, weight: .bold))
      .foregroundStyle(StrandPalette.onInk)
      .fixedSize()
      .rotationEffect(.degrees(-90))
      .frame(width: 22, height: 48 + (48 * ratio))
      .background(
        index == 0 ? StrandPalette.ink : StrandPalette.accent.opacity(0.78),
        in: RoundedRectangle(cornerRadius: 3, style: .continuous)
      )
  }

  private var nearestChoices: some View {
    VStack(alignment: .leading, spacing: 8) {
      Text("Nearest loadable").strandOverline()

      HStack(spacing: 8) {
        if let nearestBelow = solution.nearestBelow {
          nearestButton(title: "Below", value: nearestBelow)
        }
        if let nearestAbove = solution.nearestAbove {
          nearestButton(title: "Above", value: nearestAbove)
        }
      }
    }
  }

  private func nearestButton(title: String, value: Double) -> some View {
    Button {
      targetWeight = value
    } label: {
      Text("\(title) · \(LiftPlatePresentation.number(value)) lb")
    }
    .buttonStyle(NoopButtonStyle(.secondary, fullWidth: true))
    .accessibilityLabel(
      "Use \(LiftPlatePresentation.number(value)) pounds, nearest \(title.lowercased())"
    )
  }
}
