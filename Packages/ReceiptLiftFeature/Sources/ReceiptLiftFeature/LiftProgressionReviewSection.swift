import StrandDesign
import SwiftUI

/// The next-session suggestions as a scannable list: each changed exercise shows its change at a glance, and the
/// exercises that stay the same fold into one quiet line.
struct LiftProgressionReviewSection: View {
  let review: LiftProgressionReview
  let isCurrent: Bool
  let onRefresh: () -> Void

  @Environment(\.liftFormat) private var environmentFormat
  @State private var showsUnchanged = false

  /// Loads read in the review's own unit, whatever the environment holds.
  private var format: LiftFormat { LiftFormat(unit: review.unit, locale: environmentFormat.locale) }

  /// One exercise, with the change it suggests (nil when the plan stays as it is).
  private struct Entry: Identifiable {
    let row: LiftProgressionReviewRow
    let change: Change?
    var id: String { row.id }
  }

  private struct Change {
    let text: String
    let spoken: String
  }

  var body: some View {
    let all = review.rows.map { Entry(row: $0, change: change(for: $0)) }
    let changed = all.filter { $0.change != nil }
    let unchanged = all.filter { $0.change == nil }
    // When nothing changes, and for one and the same reason, a list of "No change" rows is noise: say it once.
    let sameReason: Entry? = changed.isEmpty ? all.first.flatMap { first in
      all.allSatisfy { $0.row.decision.reason == first.row.decision.reason } ? first : nil
    } : nil
    LiftFlatSection("Suggested changes", systemImage: "chart.line.uptrend.xyaxis") {
      VStack(alignment: .leading, spacing: NoopMetrics.space2) {
        if !isCurrent {
          Text("These suggestions are out of date.")
            .font(StrandFont.subhead)
            .foregroundStyle(StrandPalette.textPrimary)
          Button(action: onRefresh) {
            Text("Refresh")
              .font(StrandFont.subhead.weight(.semibold))
              .foregroundStyle(StrandPalette.accent)
              .frame(minHeight: 44, alignment: .leading)
          }
          .buttonStyle(.plain)
          .accessibilityIdentifier("lift.progression.refresh")
        }
        if let sameReason {
          Text(verbatim: sameReason.row.decision.reason == .repeatWork
            ? String(localized: "No changes from your last session.") : reasonText(sameReason.row))
            .font(StrandFont.subhead)
            .foregroundStyle(StrandPalette.textSecondary)
            .fixedSize(horizontal: false, vertical: true)
            .accessibilityIdentifier("lift.progression.noChanges")
        } else {
          if isCurrent {
            Text("Based on your last session.")
              .font(StrandFont.subhead)
              .foregroundStyle(StrandPalette.textSecondary)
          }
          ForEach(Array(changed.enumerated()), id: \.element.id) { index, entry in
            if index > 0 { Divider().overlay(StrandPalette.hairline) }
            changedRow(entry)
          }
          if unchanged.count == 1, let only = unchanged.first {
            if !changed.isEmpty { Divider().overlay(StrandPalette.hairline) }
            unchangedRow(only)
          } else if unchanged.count > 1 {
            if !changed.isEmpty { Divider().overlay(StrandPalette.hairline) }
            unchangedGroup(unchanged)
          }
        }
      }
    }
  }

  // MARK: Rows

  private func name(_ row: LiftProgressionReviewRow) -> String {
    row.exercise?.name.liftDisplayName ?? String(localized: "Exercise unavailable")
  }

  private func changedRow(_ entry: Entry) -> some View {
    let title = name(entry.row)
    let reason = reasonLine(entry.row)
    let change = entry.change
    return VStack(alignment: .leading, spacing: NoopMetrics.space1) {
      headline(title) {
        Text(verbatim: change?.text ?? "")
          .font(StrandFont.bodyNumber)
          .foregroundStyle(StrandPalette.accent)
          .fixedSize(horizontal: false, vertical: true)
      }
      Text(verbatim: reason)
        .font(StrandFont.footnote)
        .foregroundStyle(StrandPalette.textTertiary)
        .fixedSize(horizontal: false, vertical: true)
    }
    .frame(maxWidth: .infinity, alignment: .leading)
    .padding(.vertical, NoopMetrics.space2)
    .accessibilityElement(children: .ignore)
    .accessibilityLabel(Text(verbatim: "\(title). \(change?.spoken ?? ""). \(reason)"))
  }

  private func unchangedRow(_ entry: Entry) -> some View {
    let title = name(entry.row)
    let reason = reasonLine(entry.row)
    return VStack(alignment: .leading, spacing: NoopMetrics.space1) {
      headline(title) {
        Text("No change")
          .font(StrandFont.subhead)
          .foregroundStyle(StrandPalette.textTertiary)
      }
      Text(verbatim: reason)
        .font(StrandFont.footnote)
        .foregroundStyle(StrandPalette.textTertiary)
        .fixedSize(horizontal: false, vertical: true)
    }
    .frame(maxWidth: .infinity, alignment: .leading)
    .padding(.vertical, NoopMetrics.space2)
    .accessibilityElement(children: .ignore)
    .accessibilityLabel(Text(verbatim: "\(title). \(String(localized: "No change")). \(reason)"))
  }

  /// "5 exercises stay the same", with the list behind a tap.
  private func unchangedGroup(_ entries: [Entry]) -> some View {
    VStack(alignment: .leading, spacing: 0) {
      Button {
        withAnimation(.easeOut(duration: 0.2)) { showsUnchanged.toggle() }
      } label: {
        HStack(spacing: NoopMetrics.space2) {
          Text("\(entries.count) exercises stay the same")
            .font(StrandFont.subhead)
            .foregroundStyle(StrandPalette.textSecondary)
            .fixedSize(horizontal: false, vertical: true)
          Spacer(minLength: NoopMetrics.space2)
          Image(systemName: showsUnchanged ? "chevron.up" : "chevron.down")
            .font(StrandFont.caption)
            .foregroundStyle(StrandPalette.textTertiary)
            .accessibilityHidden(true)
        }
        .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
        .contentShape(Rectangle())
      }
      .buttonStyle(.plain)
      .accessibilityValue(showsUnchanged ? Text("Expanded") : Text("Collapsed"))
      .accessibilityHint("Shows which exercises stay the same")
      .accessibilityIdentifier("lift.progression.unchanged")
      if showsUnchanged {
        ForEach(entries) { entry in
          Divider().overlay(StrandPalette.hairline)
          unchangedRow(entry)
        }
      }
    }
  }

  /// The exercise name with a short trailing figure: side by side, or stacked when they would not fit.
  private func headline<Trailing: View>(_ title: String, @ViewBuilder trailing: () -> Trailing) -> some View {
    let trailingView = trailing()
    return ViewThatFits(in: .horizontal) {
      HStack(alignment: .firstTextBaseline, spacing: NoopMetrics.space3) {
        Text(verbatim: title)
          .font(StrandFont.headline)
          .foregroundStyle(StrandPalette.textPrimary)
          .lineLimit(1)
        Spacer(minLength: NoopMetrics.space2)
        trailingView
      }
      VStack(alignment: .leading, spacing: 2) {
        Text(verbatim: title)
          .font(StrandFont.headline)
          .foregroundStyle(StrandPalette.textPrimary)
          .fixedSize(horizontal: false, vertical: true)
        trailingView
      }
    }
  }

  // MARK: What changes

  /// The change at a glance: a new load ("185 → 190 lb"), or new sets and reps ("3×8 → 3×9"). Loads are in the
  /// person's own unit, rounded to what can be loaded (a converted 170 lb reads 77 kg, not 77.1).
  private func change(for row: LiftProgressionReviewRow) -> Change? {
    guard let target = row.decision.target, let evidence = row.decision.evidence else { return nil }
    let from = format.unit.canonicalPounds(evidence.weightPounds)
    let to = format.unit.canonicalPounds(target.weightPounds)
    if abs(from - to) > 0.000_1 {
      let text = String(localized: "\(format.number(pounds: from)) → \(format.number(pounds: to)) \(format.unitSymbol)")
      let spoken = String(
        localized: "From \(format.spokenWeight(pounds: from)) to \(format.spokenWeight(pounds: to))")
      return Change(text: text, spoken: spoken)
    }
    let fromReps = "\(evidence.minimumReps)\(target.repSuffix)"
    guard evidence.workingSets != target.sets || fromReps != target.repsText else { return nil }
    let text = "\(evidence.workingSets)×\(fromReps) → \(target.sets)×\(target.repsText)"
    let spoken = String(
      localized: "From \(evidence.workingSets) sets of \(fromReps) to \(target.sets) sets of \(target.repsText)")
    return Change(text: text, spoken: spoken)
  }

  /// One short, plain reason. A load change also names the sets and reps to start from.
  private func reasonLine(_ row: LiftProgressionReviewRow) -> String {
    let reason = reasonText(row)
    guard row.decision.reason == .addWeight || row.decision.reason == .reduceWeight,
      let target = row.decision.target
    else { return reason }
    return "\(target.sets)×\(target.repsText) · \(reason)"
  }

  private func reasonText(_ row: LiftProgressionReviewRow) -> String {
    let decision = row.decision
    switch decision.reason {
    case .addReps, .addSet, .addWeight:
      if let rpe = decision.evidence?.highestRPE {
        return String(localized: "Hit all reps at RPE \(rpe.formatted(.number.precision(.fractionLength(0...1))))")
      }
      return String(localized: "Hit all reps last time")
    case .reduceWeight:
      let lowest = row.plan.flatMap { LiftProgressionEngine.prescribedReps($0.reps) }
      if let lowest, let reps = decision.evidence?.minimumReps, reps < lowest {
        return String(localized: "Missed reps last time")
      }
      return String(localized: "Last session felt very hard")
    case .reduceReps: return String(localized: "Last session felt very hard")
    case .repeatWork: return String(localized: "Same again to lock it in")
    case .noHistory: return String(localized: "No sessions to go on yet")
    case .staleHistory: return String(localized: "Your last session was a while ago")
    case .noWorkingSets: return String(localized: "No working sets last time")
    case .unsupportedPrescription: return String(localized: "Needs set, rep and effort goals")
    case .missingEffort: return String(localized: "Rate your effort to get a suggestion")
    case .invalidHistory: return String(localized: "Last session’s data looked off")
    case .mixedLoads: return String(localized: "Loads varied last time")
    case .incompleteSets: return String(localized: "Fewer sets than planned last time")
    case .unknownLoadStep: return String(localized: "Choose the next weight yourself")
    case .bodyweightCeiling: return String(localized: "Try a harder variation")
    case .loadStepTooLarge: return String(localized: "The next weight jump is too big")
    }
  }
}
