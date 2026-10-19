import StrandDesign
import SwiftUI

/// The three figures of the draft set that can be edited in place.
enum LiveDraftField: Hashable { case weight, reps, rpe }

/// The set table of a live exercise (phone 3 of the approved design): SET / PREVIOUS / load / REPS / RPE / check. The
/// logged sets read as plain rows, and the draft row IS the editor: its load, reps and RPE are boxed cells. Tapping a cell
/// focuses it and opens a small tray of -/+ steps under the table; the tray is never there until a cell is tapped. At the
/// accessibility text sizes the table becomes a list of logged lines and a stack of labelled fields, so no figure is
/// squeezed into a column.
struct LiveSetTable: View {
  let exercise: LiftExercise
  let rows: [LiftSetTableRow]
  @Binding var draft: LiveComposerDraft
  @Binding var focus: LiveDraftField?
  let onLog: () -> Void

  @Environment(\.liftFormat) private var format
  @Environment(\.dynamicTypeSize) private var typeSize
  @ScaledMetric(relativeTo: .body) private var cellSize: CGFloat = 17
  @ScaledMetric(relativeTo: .caption) private var headerSize: CGFloat = 11

  private var unit: LiftWeightUnit { format.unit }

  var body: some View {
    if typeSize.isAccessibilitySize { accessibilityLayout } else { tableLayout }
  }

  // MARK: Table

  private var tableLayout: some View {
    VStack(alignment: .leading, spacing: 0) {
      Grid(alignment: .center, horizontalSpacing: 6, verticalSpacing: 0) {
        GridRow {
          header("Set").frame(width: 26, alignment: .leading)
          header("Previous").frame(width: 66, alignment: .leading)
          Text(verbatim: format.unitSymbol).headerStyle(headerSize).frame(maxWidth: .infinity)
          header("Reps").frame(maxWidth: .infinity)
          header("RPE").frame(maxWidth: .infinity)
          Color.clear.frame(width: 40, height: 1)
        }
        ForEach(rows) { row in
          GridRow {
            Text(verbatim: row.label)
              .font(StrandFont.sized(cellSize, weight: .regular))
              .foregroundStyle(row.isWarmup ? StrandPalette.textTertiary : StrandPalette.textSecondary)
              .frame(width: 26, alignment: .leading)
              .accessibilityHidden(true)
            Text(verbatim: previousText(row))
              .font(StrandFont.sized(cellSize - 2, weight: .regular))
              .foregroundStyle(StrandPalette.textTertiary)
              .lineLimit(1)
              .minimumScaleFactor(0.7)
              .frame(width: 66, alignment: .leading)
              .accessibilityHidden(true)
            valueCells(row)
            trailing(row)
          }
          .frame(minHeight: 44)
          .modifier(RowAccessibility(row: row, label: rowSpoken(row)))
        }
      }
      if let focus { tray(for: focus).padding(.top, NoopMetrics.space2) }
    }
  }

  private func header(_ title: LocalizedStringKey) -> some View {
    Text(title).headerStyle(headerSize)
  }

  @ViewBuilder private func valueCells(_ row: LiftSetTableRow) -> some View {
    switch row.kind {
    case .logged(let set):
      plain(weightText(set.weight), dim: row.isWarmup)
      plain("\(set.reps)", dim: row.isWarmup)
      plain(LiftEffortValue.text(rpe: set.rpe, rated: set.effortRated == true, locale: format.locale), dim: row.isWarmup || set.effortRated != true)
    case .draft:
      draftCell(.weight, text: weightText(draft.weight))
      draftCell(.reps, text: "\(draft.reps)")
      draftCell(.rpe, text: LiftEffortValue.text(rpe: draft.rpe, rated: draft.effortRated, locale: format.locale))
    case .planned:
      ghost(weightText(draft.weight))
      ghost("–")
      ghost("–")
    }
  }

  private func plain(_ text: String, dim: Bool) -> some View {
    Text(verbatim: text)
      .font(StrandFont.sized(cellSize, weight: .regular))
      .monospacedDigit()
      .foregroundStyle(dim ? StrandPalette.textTertiary : StrandPalette.textPrimary)
      .lineLimit(1)
      .minimumScaleFactor(0.6)
      .frame(maxWidth: .infinity)
      .accessibilityHidden(true)
  }

  private func ghost(_ text: String) -> some View {
    Text(verbatim: text)
      .font(StrandFont.sized(cellSize, weight: .regular))
      .foregroundStyle(StrandPalette.textTertiary)
      .frame(maxWidth: .infinity, minHeight: 36)
      .background(StrandPalette.surfaceInset.opacity(0.6), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
      .accessibilityHidden(true)
  }

  private func draftCell(_ field: LiveDraftField, text: String) -> some View {
    let isFocused = focus == field
    return Button { tap(field) } label: {
      Text(verbatim: text)
        .font(StrandFont.sized(cellSize, weight: .semibold))
        .monospacedDigit()
        .foregroundStyle(StrandPalette.textPrimary)
        .lineLimit(1)
        .minimumScaleFactor(0.6)
        .frame(maxWidth: .infinity, minHeight: 36)
        .background(isFocused ? StrandPalette.surfaceInset : StrandPalette.card, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay(
          RoundedRectangle(cornerRadius: 10, style: .continuous)
            .strokeBorder(isFocused ? StrandPalette.textPrimary : StrandPalette.hairlineStrong, lineWidth: isFocused ? 1.5 : 1))
        .frame(minHeight: 44)
        .contentShape(Rectangle())
    }
    .buttonStyle(.plain)
    .accessibilityLabel(fieldTitle(field))
    .accessibilityValue(Text(verbatim: spokenValue(field)))
    .accessibilityHint(field == .rpe ? Text("Tap to rate this set or clear the rating") : Text("Opens the steps for this value"))
    .accessibilityAdjustableAction { direction in
      switch direction {
      case .increment: adjust(field, up: true, large: false)
      case .decrement: adjust(field, up: false, large: false)
      @unknown default: break
      }
    }
  }

  @ViewBuilder private func trailing(_ row: LiftSetTableRow) -> some View {
    switch row.kind {
    case .logged:
      Image(systemName: "checkmark")
        .font(StrandFont.sized(13, weight: .bold))
        .foregroundStyle(row.isWarmup ? StrandPalette.textTertiary : StrandPalette.onLightFill)
        .frame(width: 28, height: 28)
        .background(row.isWarmup ? StrandPalette.tagFill : StrandPalette.solidFill, in: Circle())
        .frame(width: 40, height: 44)
        .accessibilityHidden(true)
    case .draft:
      Button(action: onLog) {
        Circle()
          .strokeBorder(StrandPalette.hairlineStrong, lineWidth: 1.5)
          .frame(width: 28, height: 28)
          .frame(width: 40, height: 44)
          .contentShape(Rectangle())
      }
      .buttonStyle(.plain)
      .accessibilityLabel("Log set")
    case .planned:
      Circle()
        .strokeBorder(StrandPalette.hairline, lineWidth: 1.5)
        .frame(width: 28, height: 28)
        .frame(width: 40, height: 44)
        .accessibilityHidden(true)
    }
  }

  // MARK: Tray

  @ViewBuilder private func tray(for field: LiveDraftField) -> some View {
    HStack(spacing: NoopMetrics.space2) {
      Text(fieldTitle(field))
        .textCase(.uppercase)
        .tracking(1.2)
        .font(StrandFont.sized(headerSize, weight: .bold))
        .foregroundStyle(StrandPalette.textTertiary)
        .lineLimit(1)
        .minimumScaleFactor(0.7)
      Spacer(minLength: NoopMetrics.space1)
      switch field {
      case .weight:
        stepChip(field, up: false, large: true)
        stepChip(field, up: false, large: false)
        stepChip(field, up: true, large: false)
        stepChip(field, up: true, large: true)
      case .reps, .rpe:
        stepChip(field, up: false, large: false)
        stepChip(field, up: true, large: false)
      }
    }
    .frame(maxWidth: .infinity, minHeight: 44)
  }

  private func stepChip(_ field: LiveDraftField, up: Bool, large: Bool) -> some View {
    let amount = stepAmount(field, large: large)
    let sign = up ? "+" : "\u{2212}"
    return ChoiceChipButton(
      verbatimTitle: sign + amount,
      accessibilityLabel: Text(stepLabel(field, up: up, amount: amount, large: large))
    ) { adjust(field, up: up, large: large) }
    .disabled(field == .rpe && !LiftEffortValue.canStep(rpe: draft.rpe, rated: draft.effortRated, up: up))
  }

  private func stepAmount(_ field: LiveDraftField, large: Bool) -> String {
    switch field {
    case .weight: return format.number(inUnit: large ? unit.largeStep : unit.step)
    case .reps: return "1"
    case .rpe: return (LiftEffortValue.step).formatted(.number.precision(.fractionLength(0...1)).locale(format.locale))
    }
  }

  private func stepLabel(_ field: LiveDraftField, up: Bool, amount: String, large: Bool) -> String {
    switch field {
    case .weight:
      let spoken = format.spokenWeight(inUnit: large ? unit.largeStep : unit.step)
      return up ? String(localized: "Increase by \(spoken)") : String(localized: "Decrease by \(spoken)")
    case .reps: return up ? String(localized: "Add a rep") : String(localized: "Remove a rep")
    case .rpe: return up ? String(localized: "Raise RPE") : String(localized: "Lower RPE")
    }
  }

  // MARK: Editing

  private func tap(_ field: LiveDraftField) {
    if field == .rpe {
      if !draft.effortRated {
        (draft.rpe, draft.effortRated) = LiftEffortValue.toggled(rpe: draft.rpe, rated: false)
        focus = .rpe
      } else if focus == .rpe {
        (draft.rpe, draft.effortRated) = LiftEffortValue.toggled(rpe: draft.rpe, rated: true)
        focus = nil
      } else {
        focus = .rpe
      }
      return
    }
    focus = focus == field ? nil : field
  }

  private func adjust(_ field: LiveDraftField, up: Bool, large: Bool) {
    switch field {
    case .weight: draft.weight = unit.stepped(pounds: draft.weight, up: up, large: large)
    case .reps: draft.reps = up ? draft.reps + 1 : max(1, draft.reps - 1)
    case .rpe: (draft.rpe, draft.effortRated) = LiftEffortValue.stepped(rpe: draft.rpe, rated: draft.effortRated, up: up)
    }
  }

  // MARK: Text

  private func fieldTitle(_ field: LiveDraftField) -> LocalizedStringKey {
    switch field {
    case .weight: "Load"
    case .reps: "Reps"
    case .rpe: "lift.composer.effort"
    }
  }

  private func weightText(_ pounds: Double) -> String {
    if liftUsesBodyweightLoad(exercise) {
      return pounds > 0 ? "+" + format.number(pounds: pounds) : LiftFormat.bodyweight
    }
    return format.number(pounds: pounds)
  }

  private func previousText(_ row: LiftSetTableRow) -> String {
    guard let previous = row.previous else { return "–" }
    return "\(weightText(previous.weight)) × \(previous.reps)"
  }

  private func spokenValue(_ field: LiveDraftField) -> String {
    switch field {
    case .weight: return format.spokenLoad(pounds: draft.weight, for: exercise)
    case .reps: return LiftFormat.repCount(draft.reps)
    case .rpe:
      return draft.effortRated
        ? LiftEffortValue.text(rpe: draft.rpe, rated: true, locale: format.locale)
        : String(localized: "Not rated")
    }
  }

  private func rowSpoken(_ row: LiftSetTableRow) -> String? {
    guard case .logged(let set) = row.kind else { return nil }
    let name = row.isWarmup ? String(localized: "Warm-up set") : String(localized: "Set \(row.label)")
    return LiftFormat.spoken([
      name, format.spokenLoad(pounds: set.weight, for: exercise), LiftFormat.repCount(set.reps),
      set.effortRated == true ? String(localized: "RPE \(LiftEffortValue.text(rpe: set.rpe, rated: true, locale: format.locale))") : "",
    ], locale: format.locale)
  }

  /// One spoken element per logged row; the draft row keeps its own controls.
  private struct RowAccessibility: ViewModifier {
    let row: LiftSetTableRow
    let label: String?

    @ViewBuilder func body(content: Content) -> some View {
      if let label {
        content.accessibilityElement(children: .ignore).accessibilityLabel(label)
      } else {
        content.accessibilityElement(children: .contain)
      }
    }
  }

  // MARK: Accessibility sizes

  private var accessibilityLayout: some View {
    VStack(alignment: .leading, spacing: NoopMetrics.space3) {
      ForEach(rows) { row in
        switch row.kind {
        case .logged(let set):
          HStack(alignment: .firstTextBaseline, spacing: NoopMetrics.space2) {
            Image(systemName: "checkmark.circle.fill").foregroundStyle(row.isWarmup ? StrandPalette.textTertiary : StrandPalette.textPrimary)
            Text(verbatim: LiftFormat.facts([
              row.isWarmup ? String(localized: "Warm-up") : String(localized: "Set \(row.label)"),
              "\(weightText(set.weight)) × \(set.reps)",
              set.effortRated == true ? String(localized: "RPE \(LiftEffortValue.text(rpe: set.rpe, rated: true, locale: format.locale))") : "",
            ]))
            .font(StrandFont.body)
            .foregroundStyle(StrandPalette.textSecondary)
            .fixedSize(horizontal: false, vertical: true)
          }
          .accessibilityElement(children: .ignore)
          .accessibilityLabel(rowSpoken(row) ?? "")
        case .draft:
          draftStack(row)
        case .planned:
          EmptyView()
        }
      }
    }
  }

  private func draftStack(_ row: LiftSetTableRow) -> some View {
    VStack(alignment: .leading, spacing: NoopMetrics.space3) {
      Text(verbatim: row.isWarmup ? String(localized: "Warm-up set") : String(localized: "Set \(row.label)"))
        .font(StrandFont.headline)
        .foregroundStyle(StrandPalette.textPrimary)
        .accessibilityAddTraits(.isHeader)
      if let previous = row.previous {
        Text("Previous \(weightText(previous.weight)) × \(previous.reps)")
          .font(StrandFont.footnote)
          .foregroundStyle(StrandPalette.textTertiary)
      }
      stackedField(.weight, value: weightText(draft.weight) + (liftUsesBodyweightLoad(exercise) ? "" : " " + format.unitSymbol))
      stackedField(.reps, value: "\(draft.reps)")
      stackedField(.rpe, value: LiftEffortValue.text(rpe: draft.rpe, rated: draft.effortRated, locale: format.locale))
    }
  }

  private func stackedField(_ field: LiveDraftField, value: String) -> some View {
    VStack(alignment: .leading, spacing: NoopMetrics.space2) {
      VStack(alignment: .leading, spacing: 2) {
        Text(fieldTitle(field)).font(StrandFont.micro).foregroundStyle(StrandPalette.textTertiary)
        Text(verbatim: value)
          .font(StrandFont.sized(cellSize * 1.4, weight: .bold))
          .monospacedDigit()
          .foregroundStyle(StrandPalette.textPrimary)
          .fixedSize(horizontal: false, vertical: true)
      }
      .accessibilityElement(children: .ignore)
      .accessibilityLabel(fieldTitle(field))
      .accessibilityValue(Text(verbatim: spokenValue(field)))
      .accessibilityAdjustableAction { direction in
        adjust(field, up: direction == .increment, large: false)
      }
      HStack(spacing: NoopMetrics.space2) {
        stepChip(field, up: false, large: false)
        stepChip(field, up: true, large: false)
        if field == .weight {
          stepChip(field, up: false, large: true)
          stepChip(field, up: true, large: true)
        }
        if field == .rpe && draft.effortRated {
          ChoiceChipButton(title: "Clear") { (draft.rpe, draft.effortRated) = (LiftEffortValue.defaultRPE, false) }
        }
      }
    }
  }
}

private extension Text {
  func headerStyle(_ size: CGFloat) -> some View {
    self
      .textCase(.uppercase)
      .tracking(1.2)
      .font(StrandFont.sized(size, weight: .bold))
      .foregroundStyle(StrandPalette.textTertiary)
      .lineLimit(1)
      .minimumScaleFactor(0.7)
  }
}
