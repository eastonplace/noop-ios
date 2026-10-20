import StrandDesign
import SwiftUI


/// The current exercise of a live workout (the exercise card of the approved design): who it is, the set table whose
/// draft row is the editor, and the best estimate so far today. Every tool that belongs to the set (warm-up, warm-up
/// suggestion, plate loader, swap, superset) is in the "..." menu, so the REST and STRAIN cards sit right under the
/// table. A set is logged on its row's check circle. The set's figures live in `draft` (the workout view's).
struct LiveComposerSection: View {
  let exercise: LiftExercise
  let store: LiftStore
  let index: Int
  @Binding var draft: LiveComposerDraft
  let continuityNamespace: Namespace.ID
  let reduceMotion: Bool
  let onPresentSwap: (LiftExercise) -> Void
  let onPresentSuperset: (LiftExercise) -> Void
  let onPresentHistory: (LiftExercise) -> Void
  let onPresentWarmup: () -> Void
  let onPresentPlates: () -> Void
  let onComposed: (UUID) -> Void
  let onLog: () -> Void

  @Environment(\.liftFormat) private var format
  @Environment(\.dynamicTypeSize) private var typeSize
  @State private var focus: LiveDraftField?
  @State private var previousSets: [LiftSet] = []
  @ScaledMetric(relativeTo: .footnote) private var estimateSize: CGFloat = 12.5

  var body: some View {
    VStack(alignment: .leading, spacing: NoopMetrics.space3) {
      identityRow
      LiveSetTable(exercise: exercise, rows: tableRows, draft: $draft, focus: $focus, onLog: logSet)
      bestEstimateLine
    }
    .padding(.vertical, NoopMetrics.space3)
    .onAppear { onComposed(exercise.id) }
    .task(id: exercise.id) { previousSets = LiftPreviousSets.lastSession(for: exercise.id, in: store.sessions) }
  }

  private func logSet() {
    focus = nil
    onLog()
  }

  // MARK: Identity

  private var identityRow: some View {
    HStack(alignment: .center, spacing: NoopMetrics.space3) {
      Button { onPresentHistory(exercise) } label: {
        HStack(alignment: .center, spacing: NoopMetrics.space3) {
          artwork
          VStack(alignment: .leading, spacing: 2) {
            Text(exercise.name.liftDisplayName)
              .font(StrandFont.headline)
              .foregroundStyle(StrandPalette.textPrimary)
              .multilineTextAlignment(.leading)
              .lineLimit(3)
              .minimumScaleFactor(0.8)
              .fixedSize(horizontal: false, vertical: true)
            let subtitle = LiftExerciseSubtitle.make(exercise)
            if !subtitle.isEmpty {
              Text(verbatim: subtitle)
                .font(StrandFont.footnote)
                .foregroundStyle(StrandPalette.textSecondary)
                .multilineTextAlignment(.leading)
                .lineLimit(typeSize.isAccessibilitySize ? 4 : 2)
                .fixedSize(horizontal: false, vertical: true)
            }
            if let label = store.supersetLabel(for: exercise.id) {
              LiftTag(text: LocalizedStringKey(label), systemImage: "link")
                .padding(.top, 2)
            }
          }
          .frame(maxWidth: .infinity, alignment: .leading)
        }
        .contentShape(Rectangle())
      }
      .buttonStyle(.plain)
      .accessibilityElement(children: .combine)
      .accessibilityHint("Opens exercise details and progress")
      toolsMenu
    }
  }

  @ViewBuilder private var artwork: some View {
    let tile = StrengthExerciseTile(exercise: exercise, size: typeSize.isAccessibilitySize ? 48 : 60)
    if reduceMotion {
      tile.transition(.opacity)
    } else {
      tile.matchedGeometryEffect(id: exercise.id, in: continuityNamespace)
    }
  }

  private var toolsMenu: some View {
    Menu {
      Button("Details & progress", systemImage: "clock.arrow.circlepath") {
        onPresentHistory(exercise)
      }
      Button("Swap exercise", systemImage: "arrow.triangle.2.circlepath") {
        onPresentSwap(exercise)
      }
      Button("Superset", systemImage: "link") {
        onPresentSuperset(exercise)
      }
      Divider()
      Toggle(isOn: $draft.isWarmup) {
        Label("Warm-up", systemImage: "flame")
      }
      if liftShouldOfferWarmupSuggestion(completedWorkingSets: setProgress.completed) {
        Button("Suggest a warm-up", systemImage: "figure.strengthtraining.traditional") {
          onPresentWarmup()
        }
      }
      if LiftPlateLoaderEligibility.isEligible(exercise) {
        Button("Plate loader", systemImage: "scalemass") {
          onPresentPlates()
        }
      }
    } label: {
      StrengthIconGlyph(systemImage: "ellipsis")
    }
    .accessibilityLabel("Exercise tools")
  }

  // MARK: Table

  private var loggedToday: [LiftSet] {
    (store.activeSession?.sets ?? [])
      .filter { $0.exerciseID == exercise.id }
      .sorted { $0.completedAt < $1.completedAt }
  }

  private var setProgress: LiftSetProgress { store.setProgress(for: exercise.id) }

  private var tableRows: [LiftSetTableRow] {
    LiftSetTable.rows(
      logged: loggedToday, previousSession: previousSets, target: setProgress.target, draftIsWarmup: draft.isWarmup)
  }

  /// "Best estimate today: 234 lb one-rep max" with a NEW BEST tag on the right when it beats everything before today. It
  /// shows once a working set is logged on this exercise.
  @ViewBuilder private var bestEstimateLine: some View {
    if let best = LiftSetTable.bestEstimate(
      logged: loggedToday, previousBest: store.previousBestEstimatedOneRepMax(for: exercise.id))
    {
      let value = format.weight(pounds: best.value)
      let text = Text(markdown: String(localized: "Best estimate today: **\(value)** one-rep max"), emphasis: StrandPalette.textPrimary)
        .font(StrandFont.sized(estimateSize, weight: .regular))
        .foregroundStyle(StrandPalette.textSecondary)
      let tag = best.isNewBest && LiftStore.prDetectionEnabled
      // One line beside the tag at the regular text sizes (it shrinks a little before it would wrap, so "one-rep max"
      // never splits); the accessibility sizes stack the text over the tag and let it wrap.
      if typeSize.isAccessibilitySize {
        VStack(alignment: .leading, spacing: NoopMetrics.space2) {
          text.fixedSize(horizontal: false, vertical: true)
          if tag { LiftTag(text: "NEW BEST", systemImage: "star.fill", tint: StrandPalette.signalYellow) }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .combine)
      } else {
        HStack(alignment: .center, spacing: NoopMetrics.space2) {
          text.lineLimit(1).minimumScaleFactor(0.75)
          Spacer(minLength: 0)
          if tag { LiftTag(text: "NEW BEST", systemImage: "star.fill", tint: StrandPalette.signalYellow) }
        }
        .accessibilityElement(children: .combine)
      }
    }
  }
}

// MARK: - Warm-up sheet

struct WarmupSuggestionSheet: View {
  @Environment(\.dismiss) private var dismiss
  @Environment(\.liftFormat) private var format
  let exercise: LiftExercise
  let plan: LiftWarmupPlan
  @Binding var draft: LiveComposerDraft

  var body: some View {
    LiftSheetPage(title: "Warm-up?", onClose: { dismiss() }) {
      LiftFlatSection("Ramp", systemImage: "flame", contentSpacing: NoopMetrics.space3) {
        VStack(alignment: .leading, spacing: NoopMetrics.space2) {
          Text(verbatim: exercise.name.liftDisplayName)
            .font(StrandFont.caption)
            .foregroundStyle(StrandPalette.textTertiary)
          Text(verbatim: plan.title)
            .font(StrandFont.headline)
            .foregroundStyle(StrandPalette.textPrimary)
            .fixedSize(horizontal: false, vertical: true)
          Text(verbatim: plan.reason)
            .font(StrandFont.subhead)
            .foregroundStyle(StrandPalette.textSecondary)
            .fixedSize(horizontal: false, vertical: true)
        }
      }
      FlatSectionSeparator()
      LiftFlatSection("Warm-up sets", systemImage: "list.number", contentSpacing: 0) {
        if plan.hasSets {
          // The warm-up number circle is a fixed 38pt, not a scaling GlyphDisc, so its inset is fixed too.
          LiftRowList(items: plan.sets, separatorInset: 38 + NoopMetrics.space3) { set, _ in
            WarmupSuggestionRow(set: set, exercise: exercise) {
              draft.weight = unit(set.weight)
              draft.reps = set.reps
              draft.isWarmup = true
              dismiss()
            }
          }
        } else {
          LiftNote(text: "No loaded ramp needed.").padding(.vertical, NoopMetrics.space2)
        }
      }
    }
    .presentationDetents([.medium, .large])
    .presentationDragIndicator(.visible)
  }

  private func unit(_ pounds: Double) -> Double { format.unit.canonicalPounds(pounds) }
}

private struct WarmupSuggestionRow: View {
  @Environment(\.liftFormat) private var format
  let set: LiftWarmupSet
  let exercise: LiftExercise
  let onUse: () -> Void

  var body: some View {
    Button(action: onUse) {
      LiftListRow(
        title: String(localized: "\(format.load(pounds: set.weight, for: exercise)) × \(set.reps)"),
        details: [rowSubtitle],
        leading: {
          Text(set.sequence.formatted(.number.locale(format.locale)))
            .font(StrandFont.number(17, weight: .semibold))
            .foregroundStyle(DomainTint.workout.accent)
            .frame(width: 38, height: 38)
            .background(Circle().fill(DomainTint.workout.accent.opacity(0.14)))
            .accessibilityHidden(true)
        },
        accessory: {
          Text("Use")
            .font(StrandFont.subhead.weight(.semibold))
            .foregroundStyle(StrandPalette.accent)
        }
      )
    }
    .buttonStyle(FlatRowPressStyle())
    .accessibilityElement(children: .ignore)
    .accessibilityLabel(
      "Use warm-up set \(set.sequence), \(format.spokenLoad(pounds: set.weight, for: exercise)), \(LiftFormat.repCount(set.reps))")
  }

  private var rowSubtitle: String {
    if let percent = set.percent {
      return LiftFormat.facts([percent.formatted(.percent.precision(.fractionLength(0)).locale(format.locale)), set.note])
    }
    return set.note
  }
}

// MARK: - Superset sheet

struct SupersetPairingSheet: View {
  @Environment(\.dismiss) private var dismiss
  @EnvironmentObject private var store: LiftStore
  let exercise: LiftExercise

  private var candidates: [LiftExercise] {
    let ids = liftSupersetCandidateIDs(
      activeExerciseIDs: store.activeExercises.map(\.id),
      currentExerciseID: exercise.id
    )
    return ids.compactMap(store.exercise(for:))
  }

  var body: some View {
    LiftSheetPage(title: "Superset", onClose: { dismiss() }) {
      if let label = store.supersetLabel(for: exercise.id) {
        LiftFlatSection("Paired", systemImage: "link") {
          VStack(alignment: .leading, spacing: NoopMetrics.space3) {
            HStack(spacing: NoopMetrics.space3) {
              LiftTag(text: LocalizedStringKey(label), systemImage: "link")
              Text(verbatim: currentPartnerText)
                .font(StrandFont.subhead)
                .foregroundStyle(StrandPalette.textPrimary)
                .fixedSize(horizontal: false, vertical: true)
              Spacer(minLength: 0)
            }
            Button {
              store.clearSuperset(for: exercise.id)
              dismiss()
            } label: {
              Label("Clear pairing", systemImage: "xmark")
            }
            .buttonStyle(SecondaryPillButtonStyle())
          }
        }
        FlatSectionSeparator()
      }
      LiftFlatSection("Pair with", systemImage: "plus.circle", contentSpacing: 0) {
        if candidates.isEmpty {
          LiftNote(text: "Add another active exercise to make a superset.").padding(.vertical, NoopMetrics.space2)
        } else {
          LiftRowList(items: candidates, separatorInset: 44 + NoopMetrics.space3) { candidate, _ in
            Button {
              store.setSuperset(exercise.id, with: candidate.id)
              dismiss()
            } label: {
              LiftListRow(
                title: candidate.name.liftDisplayName,
                details: [store.supersetLabel(for: candidate.id) ?? String(localized: "Pair for this workout")],
                leading: { LiftExerciseThumb(exercise: candidate, size: 44) },
                accessory: {
                  Text("Pair")
                    .font(StrandFont.subhead.weight(.semibold))
                    .foregroundStyle(StrandPalette.accent)
                }
              )
            }
            .buttonStyle(FlatRowPressStyle())
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("Pair \(exercise.name) with \(candidate.name)")
          }
        }
      }
    }
    .presentationDetents([.medium, .large])
    .presentationDragIndicator(.visible)
  }

  private var currentPartnerText: String {
    let names = store.supersetPartners(for: exercise.id).map(\.name)
    guard !names.isEmpty else { return String(localized: "No current partner") }
    let joined = names.formatted(.list(type: .and, width: .narrow))
    return String(localized: "With \(joined)")
  }
}
