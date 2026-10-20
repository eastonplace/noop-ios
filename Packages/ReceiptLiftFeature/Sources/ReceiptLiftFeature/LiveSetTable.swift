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
  @ScaledMetric(relativeTo: .body) private var columnScale: CGFloat = 1

  private var unit: LiftWeightUnit { format.unit }

  var body: some View {
    if typeSize.isAccessibilitySize { accessibilityLayout } else { tableLayout }
  }

  // MARK: Table

  /// The design's columns: SET | PREVIOUS (whatever is left) | load | REPS | RPE | check, 8pt apart. The fixed ones grow a
  /// little with the text size (never past 1.2x) so a figure keeps its room.
  private enum Column {
    static let set: CGFloat = 30
    static let load: CGFloat = 66
    static let reps: CGFloat = 52
    static let rpe: CGFloat = 48
    static let check: CGFloat = 34
    static let gap: CGFloat = 8
    /// A figure box is 34pt tall and 9pt round; the row around it keeps the 44pt tap height.
    static let box: CGFloat = 34
    static let boxRadius: CGFloat = 9
    /// The current row's wash reaches this far past the table on each side.
    static let currentBleed: CGFloat = 8
  }

  private var columnFactor: CGFloat { min(columnScale, 1.2) }
  private var setWidth: CGFloat { Column.set * columnFactor }
  private var loadWidth: CGFloat { Column.load * columnFactor }
  private var repsWidth: CGFloat { Column.reps * columnFactor }
  private var rpeWidth: CGFloat { Column.rpe * columnFactor }
  private var checkWidth: CGFloat { Column.check * columnFactor }

  private var tableLayout: some View {
    VStack(alignment: .leading, spacing: 0) {
      HStack(spacing: Column.gap) {
        header("Set").frame(width: setWidth, alignment: .leading)
        header("Previous").frame(maxWidth: .infinity, alignment: .leading)
        Text(verbatim: format.unitSymbol).headerStyle(headerSize).frame(width: loadWidth)
        header("Reps").frame(width: repsWidth)
        header("RPE").frame(width: rpeWidth)
        Color.clear.frame(width: checkWidth, height: 1)
      }
      .frame(minHeight: 24)
      ForEach(rows) { row in
        let isCurrent = row.kind == .draft
        HStack(spacing: Column.gap) {
          Text(verbatim: row.label)
            .font(StrandFont.sized(cellSize, weight: .regular))
            .foregroundStyle(row.isWarmup ? StrandPalette.textTertiary : StrandPalette.textSecondary)
            .frame(width: setWidth, alignment: .leading)
            .accessibilityHidden(true)
          Text(verbatim: previousText(row))
            .font(StrandFont.sized(cellSize - 2, weight: .regular))
            .foregroundStyle(StrandPalette.textTertiary)
            .lineLimit(1)
            .minimumScaleFactor(0.7)
            .frame(maxWidth: .infinity, alignment: .leading)
            .accessibilityHidden(true)
          valueCells(row)
          trailing(row).frame(width: checkWidth)
        }
        .frame(minHeight: 44)
        // The current row sits on a quiet wash that reaches 8pt past the table on each side: the inset pads it in, the
        // negative pad puts the columns back where every other row has them.
        .padding(.horizontal, isCurrent ? Column.currentBleed : 0)
        .background {
          if isCurrent {
            RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Color.white.opacity(0.04))
          }
        }
        .padding(.horizontal, isCurrent ? -Column.currentBleed : 0)
        .modifier(RowAccessibility(row: row, label: rowSpoken(row)))
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
      plain(weightText(set.weight), dim: row.isWarmup).frame(width: loadWidth)
      plain("\(set.reps)", dim: row.isWarmup).frame(width: repsWidth)
      plain(LiftEffortValue.text(rpe: set.rpe, rated: set.effortRated == true, locale: format.locale), dim: row.isWarmup || set.effortRated != true)
        .frame(width: rpeWidth)
    case .draft:
      draftCell(.weight, text: weightText(draft.weight)).frame(width: loadWidth)
      draftCell(.reps, text: "\(draft.reps)").frame(width: repsWidth)
      draftCell(.rpe, text: LiftEffortValue.text(rpe: draft.rpe, rated: draft.effortRated, locale: format.locale)).frame(width: rpeWidth)
    case .planned:
      ghost(weightText(draft.weight)).frame(width: loadWidth)
      ghost("–").frame(width: repsWidth)
      ghost("–").frame(width: rpeWidth)
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

  /// A figure box: 34pt tall, 9pt round, the card fill and a 12% white edge. The field being edited draws its edge in the
  /// light ink instead (1pt, #F2F4F5).
  private func figureBox(_ text: String, ink: Color, active: Bool) -> some View {
    Text(verbatim: text)
      .font(StrandFont.sized(cellSize, weight: .semibold))
      .monospacedDigit()
      .foregroundStyle(ink)
      .lineLimit(1)
      .minimumScaleFactor(0.6)
      .frame(maxWidth: .infinity, minHeight: Column.box)
      .background(StrandPalette.card, in: RoundedRectangle(cornerRadius: Column.boxRadius, style: .continuous))
      .overlay(
        RoundedRectangle(cornerRadius: Column.boxRadius, style: .continuous)
          .strokeBorder(active ? StrandPalette.solidFill : StrandPalette.pillStroke, lineWidth: 1))
  }

  /// A set still to come: the same box, with its figures in the quiet ink.
  private func ghost(_ text: String) -> some View {
    figureBox(text, ink: StrandPalette.textTertiary, active: false)
      .accessibilityHidden(true)
  }

  /// The load is the field the steps start from, so it reads as the active one until another field is chosen.
  private func isActive(_ field: LiveDraftField) -> Bool { (focus ?? .weight) == field }

  private func draftCell(_ field: LiveDraftField, text: String) -> some View {
    Button { tap(field) } label: {
      figureBox(text, ink: StrandPalette.textPrimary, active: isActive(field))
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
        .frame(maxWidth: .infinity, minHeight: 44)
        .accessibilityHidden(true)
    case .draft:
      Button(action: onLog) {
        Circle()
          .strokeBorder(StrandPalette.hairlineStrong, lineWidth: 1.5)
          .frame(width: 28, height: 28)
          .frame(maxWidth: .infinity, minHeight: 44)
          .contentShape(Rectangle().inset(by: -5))
      }
      .buttonStyle(.plain)
      .accessibilityLabel("Log set")
    case .planned:
      Circle()
        .strokeBorder(StrandPalette.hairlineStrong, lineWidth: 1.5)
        .frame(width: 28, height: 28)
        .frame(maxWidth: .infinity, minHeight: 44)
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
      Button(action: onLog) {
        Text("Log set")
          .frame(maxWidth: .infinity, minHeight: 44)
      }
      .buttonStyle(PrimaryPillButtonStyle())
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
