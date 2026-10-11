import StrandDesign
import SwiftUI

enum LiftPlateLoaderEligibility {
  nonisolated static func isEligible(_ exercise: LiftExercise) -> Bool {
    exercise.equipment.localizedCaseInsensitiveContains("barbell")
      && !liftUsesBodyweightLoad(exercise)
  }
}

enum LiftPlatePresentation {
  /// The plates of one side as (plate, how many), heaviest first. `perSide` is heaviest first already.
  nonisolated static func grouped(_ perSide: [Double]) -> [(plate: Double, count: Int)] {
    var groups: [(plate: Double, count: Int)] = []
    for plate in perSide {
      if let last = groups.last, last.plate == plate {
        groups[groups.count - 1].count += 1
      } else {
        groups.append((plate, 1))
      }
    }
    return groups
  }

  /// What VoiceOver says for the whole loading. Every figure is in the person's unit.
  nonisolated static func accessibilityLabel(
    total: Double,
    solution: LiftPlateMath.PlateSolution,
    bar: Double,
    format: LiftFormat
  ) -> String {
    let totalText = format.spokenWeight(inUnit: total)
    let barText = format.spokenWeight(inUnit: bar)

    if solution.exact {
      guard !solution.perSide.isEmpty else {
        return String(localized: "\(totalText): bare bar. Bar \(barText).")
      }
      let plates = solution.perSide.map { format.number(inUnit: $0) }.joined(separator: ", ")
      return String(localized: "\(totalText): per side \(plates). Bar \(barText).")
    }

    let below = solution.nearestBelow.map { String(localized: "below \(format.spokenWeight(inUnit: $0))") }
    let above = solution.nearestAbove.map { String(localized: "above \(format.spokenWeight(inUnit: $0))") }
    let nearest = [below, above].compactMap { $0 }.joined(separator: ", ")
    return String(localized: "\(totalText): not loadable. Nearest \(nearest). Bar \(barText).")
  }
}

/// A barbell loaded to a target weight: the plates on each side, the bar, and the nearest loadable weights when the
/// target cannot be made. The target arrives in pounds (as Lift stores it) and everything on screen is in the person's
/// unit, with that unit's bar and plates.
struct PlateLoaderView: View {
  @Environment(\.dismiss) private var dismiss
  @Environment(\.liftFormat) private var format
  @Binding private var targetWeight: Double
  private let exercise: LiftExercise

  init(targetWeight: Binding<Double>, exercise: LiftExercise) {
    _targetWeight = targetWeight
    self.exercise = exercise
  }

  private var unit: LiftWeightUnit { format.unit }

  /// The target in the person's unit, kilograms snapped to the half so the figure matches what is stored.
  private var displayTarget: Double { unit.snappedDisplay(fromPounds: targetWeight) }

  private var solution: LiftPlateMath.PlateSolution {
    LiftPlateMath.solve(target: displayTarget, bar: unit.barWeight, plates: unit.plates)
  }

  private var perSideTotal: Double {
    solution.perSide.reduce(0, +)
  }

  var body: some View {
    LiftSheetPage(title: "Plate loader", onClose: { dismiss() }) {
      targetSection
      FlatSectionSeparator()
      sideSection
      if !solution.exact {
        FlatSectionSeparator()
        nearestSection
      }
    }
    .presentationDetents([.large])
    .presentationDragIndicator(.visible)
  }

  // MARK: Target

  private var targetSection: some View {
    let parts = (number: format.number(inUnit: displayTarget), unit: format.unitSymbol)
    return LiftFlatSection("Target", systemImage: "scalemass.fill") {
      HeroValue(
        value: parts.number, unit: parts.unit, caption: exercise.name.liftDisplayName, captionPlacement: .below
      )
      .accessibilityElement(children: .ignore)
      .accessibilityLabel(
        LiftPlatePresentation.accessibilityLabel(
          total: displayTarget, solution: solution, bar: unit.barWeight, format: format))
    }
  }

  // MARK: Plates

  private var sideSection: some View {
    LiftFlatSection("Each side", systemImage: "circle.grid.2x1.fill") {
      VStack(alignment: .leading, spacing: WidgetMetrics.contentSpacing) {
        plateDiagram
          .accessibilityHidden(true)
        FactStrip(facts: [
          .init("Bar", value: format.number(inUnit: unit.barWeight), unit: LocalizedStringKey(format.unitSymbol)),
          .init("Plates", value: format.number(inUnit: perSideTotal), unit: LocalizedStringKey(format.unitSymbol)),
        ])
        .accessibilityHidden(true)
        platesList
          .accessibilityHidden(true)
      }
    }
  }

  @ViewBuilder
  private var platesList: some View {
    let groups = LiftPlatePresentation.grouped(solution.perSide)
    if groups.isEmpty {
      if solution.exact { LiftNote(text: "Bare bar") }
    } else {
      LiftRowList(items: groups.map { PlateGroup(plate: $0.plate, count: $0.count) }) { group, _ in
        HStack {
          Text(verbatim: "\(group.count) ×")
            .font(StrandFont.number(15))
            .foregroundStyle(StrandPalette.textTertiary)
            .frame(minWidth: 34, alignment: .leading)
          UnitValueText(value: format.weight(inUnit: group.plate), size: 17)
          Spacer(minLength: 0)
        }
        .frame(minHeight: 44)
      }
    }
  }

  private struct PlateGroup: Identifiable {
    let plate: Double
    let count: Int
    var id: Double { plate }
  }

  private var plateDiagram: some View {
    ZStack {
      Rectangle()
        .fill(StrandPalette.textTertiary)
        .frame(height: 2)

      HStack(spacing: 3) {
        if solution.perSide.isEmpty {
          RoundedRectangle(cornerRadius: 3, style: .continuous)
            .fill(StrandPalette.surfaceInset)
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
    .frame(maxWidth: .infinity)
  }

  private func plateSlab(_ plate: Double, index: Int) -> some View {
    let heaviest = unit.plates.first ?? 45
    let ratio = CGFloat(max(min(plate / heaviest, 1), 0.22))
    return Text(format.number(inUnit: plate))
      .font(StrandFont.number(11, weight: .bold))
      .foregroundStyle(StrandPalette.appCanvas)
      .fixedSize()
      .rotationEffect(.degrees(-90))
      .frame(width: 22, height: 48 + (48 * ratio))
      .background(
        index == 0 ? DomainTint.workout.accent : DomainTint.workout.accent.opacity(0.72),
        in: RoundedRectangle(cornerRadius: 3, style: .continuous)
      )
  }

  // MARK: Nearest

  private var nearestSection: some View {
    LiftFlatSection("Nearest loadable", systemImage: "arrow.up.arrow.down") {
      VStack(alignment: .leading, spacing: NoopMetrics.space3) {
        LiftNote(text: "That weight cannot be made with these plates.")
        ChipRow {
          if let nearestBelow = solution.nearestBelow {
            nearestChip(title: String(localized: "Below"), value: nearestBelow, spoken: "below")
          }
          if let nearestAbove = solution.nearestAbove {
            nearestChip(title: String(localized: "Above"), value: nearestAbove, spoken: "above")
          }
        }
      }
    }
  }

  private func nearestChip(title: String, value: Double, spoken: String) -> some View {
    ChoiceChipButton(
      verbatimTitle: String(localized: "\(title) · \(format.weight(inUnit: value))"),
      accessibilityLabel: Text(
        spoken == "below"
          ? String(localized: "Use \(format.spokenWeight(inUnit: value)), nearest below")
          : String(localized: "Use \(format.spokenWeight(inUnit: value)), nearest above"))
    ) {
      targetWeight = unit.toPounds(value)
    }
  }
}
