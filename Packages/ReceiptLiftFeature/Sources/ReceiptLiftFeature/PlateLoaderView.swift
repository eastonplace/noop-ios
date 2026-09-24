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
    ReceiptSheet {
      ReceiptHeader(
        title: "Plate Loader",
        subtitle: exercise.name,
        trailing: "\(LiftPlatePresentation.number(targetWeight)) LB"
      )
      ReceiptDashedRule()

      VStack(spacing: 12) {
        plateDiagram
        Text(
          "BAR \(LiftPlatePresentation.number(barWeight)) \u{00B7} EACH SIDE \(LiftPlatePresentation.number(perSideTotal))"
        )
        .font(.receipt(10, weight: .black))
        .monospacedDigit()
        .foregroundStyle(LiftTheme.ink)
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
        .fill(LiftTheme.ink)
        .frame(height: 1)

      HStack(spacing: 3) {
        if solution.perSide.isEmpty {
          Rectangle()
            .fill(LiftTheme.paper)
            .frame(width: 12, height: 72)
            .overlay {
              Rectangle().stroke(LiftTheme.ink, lineWidth: 1)
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
      .font(.receipt(8, weight: .black))
      .foregroundStyle(LiftTheme.ink)
      .rotationEffect(.degrees(-90))
      .frame(width: 20, height: 48 + (48 * ratio))
      .background(LiftTheme.paper)
      .overlay {
        Rectangle()
          .stroke(LiftTheme.ink, lineWidth: index == 0 ? 1.5 : 1)
      }
  }

  private var nearestChoices: some View {
    VStack(alignment: .leading, spacing: 8) {
      Text("NEAREST")
        .font(.receipt(9, weight: .black))
        .tracking(0.8)
        .foregroundStyle(LiftTheme.inkSecondary)

      HStack(spacing: 8) {
        if let nearestBelow = solution.nearestBelow {
          nearestButton(title: "BELOW", value: nearestBelow)
        }
        if let nearestAbove = solution.nearestAbove {
          nearestButton(title: "ABOVE", value: nearestAbove)
        }
      }
    }
    .padding(.top, 2)
  }

  private func nearestButton(title: String, value: Double) -> some View {
    Button {
      targetWeight = value
    } label: {
      VStack(spacing: 2) {
        Text(title)
          .font(.receipt(8, weight: .bold))
          .foregroundStyle(LiftTheme.inkSecondary)
        Text("\(LiftPlatePresentation.number(value)) LB")
          .font(.receipt(12, weight: .black))
          .monospacedDigit()
          .foregroundStyle(LiftTheme.ink)
      }
      .frame(maxWidth: .infinity)
      .frame(minHeight: LiftDesignMetrics.PlateLoader.minimumTargetSize)
      .overlay {
        Rectangle().stroke(LiftTheme.ink, lineWidth: 1)
      }
    }
    .buttonStyle(.plain)
    .accessibilityLabel(
      "Use \(LiftPlatePresentation.number(value)) pounds, nearest \(title.lowercased())"
    )
  }
}
