import StrandDesign
import SwiftUI

/// The current exercise of a live workout: who it is, what you did last time and the set about to be logged. The set's
/// figures live in `draft` (the workout view's, so the pinned "Log set" button reads them too).
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

  @Environment(\.liftFormat) private var format
  @Environment(\.dynamicTypeSize) private var typeSize
  @State private var isEffortExpanded = false

  private var unit: LiftWeightUnit { format.unit }

  var body: some View {
    LiftFlatSection(
      "Current exercise",
      trailing: .text(
        String(localized: "\((index + 1).formatted()) / \(max(store.activeExercises.count, 1).formatted())")),
      contentSpacing: NoopMetrics.space3
    ) {
      VStack(alignment: .leading, spacing: WidgetMetrics.contentSpacing) {
        identityRow
        quickActions
        lastSetsLine
        steppers
        effortEditor
        optionChips
      }
    }
    .onAppear { onComposed(exercise.id) }
  }

  // MARK: Identity

  private var identityRow: some View {
    HStack(alignment: .top, spacing: NoopMetrics.space3) {
      Button { onPresentHistory(exercise) } label: { artwork }
        .buttonStyle(.plain)
        .accessibilityLabel("View \(exercise.name) photo and muscles")
      Button { onPresentHistory(exercise) } label: {
        VStack(alignment: .leading, spacing: 4) {
          Text(exercise.name.liftDisplayName)
            .font(StrandFont.title2)
            .foregroundStyle(StrandPalette.textPrimary)
            .multilineTextAlignment(.leading)
            .lineLimit(3)
            .minimumScaleFactor(0.8)
            .fixedSize(horizontal: false, vertical: true)
          Text(verbatim: setProgressText)
            .font(StrandFont.caption.weight(.semibold))
            .foregroundStyle(DomainTint.workout.accent)
            .monospacedDigit()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentShape(Rectangle())
      }
      .buttonStyle(.plain)
      .accessibilityElement(children: .combine)
      .accessibilityHint("Opens exercise details and progress")
      toolsMenu
    }
  }

  @ViewBuilder private var artwork: some View {
    if reduceMotion {
      LiftExerciseThumb(exercise: exercise, size: LiftDesignMetrics.Composer.artworkSize)
        .transition(.opacity)
    } else {
      LiftExerciseThumb(exercise: exercise, size: LiftDesignMetrics.Composer.artworkSize)
        .matchedGeometryEffect(id: exercise.id, in: continuityNamespace)
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
    } label: {
      Image(systemName: "ellipsis")
        .font(.system(size: 16, weight: .semibold))
        .foregroundStyle(StrandPalette.textTertiary)
        .frame(width: 44, height: 44)
        .contentShape(Rectangle())
    }
    .accessibilityLabel("Exercise tools")
  }

  private var quickActions: some View {
    ChipRow {
      WidgetChipButton(
        title: "Swap", systemImage: "arrow.triangle.2.circlepath", accessibilityLabel: "Swap exercise"
      ) { onPresentSwap(exercise) }
      WidgetChipButton(title: "Superset", systemImage: "link", accessibilityLabel: "Superset") {
        onPresentSuperset(exercise)
      }
      if let label = store.supersetLabel(for: exercise.id) {
        LiftTag(text: LocalizedStringKey(label))
      }
    }
  }

  // MARK: Last sets

  private var savedWorkingSets: [LiftSet] {
    Array(
      store.sets(for: exercise.id, includeActive: false)
        .filter { !$0.isWarmup }
        .prefix(LiftDesignMetrics.Composer.lastSetLimit)
    )
  }

  private var lastSetsLine: some View {
    let sets = savedWorkingSets
    let text = sets.isEmpty
      ? String(localized: "No saved sets")
      : LiftFormat.facts(sets.map { String(localized: "\(format.load(pounds: $0.weight, for: exercise)) × \($0.reps)") })
    return VStack(alignment: .leading, spacing: 2) {
      Text("Last").font(StrandFont.micro).foregroundStyle(StrandPalette.textTertiary)
      Text(verbatim: text)
        .font(StrandFont.footnote)
        .foregroundStyle(sets.isEmpty ? StrandPalette.textTertiary : StrandPalette.textSecondary)
        .fixedSize(horizontal: false, vertical: true)
    }
    .frame(maxWidth: .infinity, alignment: .leading)
    .accessibilityElement(children: .combine)
  }

  private var setProgress: LiftSetProgress {
    store.setProgress(for: exercise.id)
  }

  private var setProgressText: String {
    guard let target = setProgress.target else {
      return String(localized: "Set \(setProgress.completed + 1)")
    }
    return String(localized: "Set \(min(setProgress.completed + 1, target)) of \(target)")
  }

  // MARK: Steppers

  private var steppers: some View {
    VStack(spacing: NoopMetrics.space3) {
      LiftBigStepper(
        title: "Load",
        value: format.load(pounds: draft.weight, for: exercise),
        spokenValue: format.spokenLoad(pounds: draft.weight, for: exercise),
        decrement: { stepWeight(up: false, large: false) },
        increment: { stepWeight(up: true, large: false) },
        decrementLarge: { stepWeight(up: false, large: true) },
        incrementLarge: { stepWeight(up: true, large: true) },
        increaseLargeLabel: String(localized: "Increase by \(format.spokenWeight(inUnit: unit.largeStep))"),
        decreaseLargeLabel: String(localized: "Decrease by \(format.spokenWeight(inUnit: unit.largeStep))")
      )
      LiftBigStepper(
        title: "Reps",
        value: draft.reps.formatted(.number.locale(format.locale)),
        spokenValue: String(localized: "\(draft.reps) reps"),
        decrement: { draft.reps = max(1, draft.reps - 1) },
        increment: { draft.reps += 1 }
      )
    }
  }

  private func stepWeight(up: Bool, large: Bool) {
    draft.weight = unit.stepped(pounds: draft.weight, up: up, large: large)
  }

  // MARK: Effort

  private var effortSelection: Binding<Int> {
    Binding(get: { Int(draft.rpe) }, set: { draft.rpe = Double($0) })
  }

  private var effortEditor: some View {
    VStack(alignment: .leading, spacing: NoopMetrics.space2) {
      Button {
        withAnimation(reduceMotion ? LiftMotion.reducedCrossfade : LiftMotion.surface) { isEffortExpanded.toggle() }
      } label: {
        HStack(spacing: NoopMetrics.space2) {
          Text("Effort")
            .font(StrandFont.subhead)
            .foregroundStyle(StrandPalette.textPrimary)
          Spacer()
          Text(draft.rpe.formatted(.number.precision(.fractionLength(0)).locale(format.locale)))
            .font(StrandFont.number(17, weight: .semibold))
            .foregroundStyle(StrandPalette.textPrimary)
          Image(systemName: "chevron.down")
            .font(.system(size: 12, weight: .semibold))
            .foregroundStyle(StrandPalette.textTertiary)
            .rotationEffect(.degrees(isEffortExpanded ? 180 : 0))
            .accessibilityHidden(true)
        }
        .frame(minHeight: 44)
        .contentShape(Rectangle())
      }
      .buttonStyle(.plain)
      .accessibilityLabel("Effort \(Int(draft.rpe))")
      .accessibilityHint(isEffortExpanded ? Text("Collapses effort choices") : Text("Expands effort choices"))

      if isEffortExpanded {
        SegmentedPillControl(Array(6...10), selection: effortSelection) { $0.formatted(.number.locale(format.locale)) }
          .frame(maxWidth: .infinity, alignment: .leading)
      }
    }
    .overlay(alignment: .top) { FlatRowSeparator() }
  }

  // MARK: Options

  private var optionChips: some View {
    ChipRow {
      if LiftPlateLoaderEligibility.isEligible(exercise) {
        WidgetChipButton(
          title: "Plate loader", systemImage: "scalemass", accessibilityLabel: "Plate loader",
          accessibilityHint: "Shows plates for the current composer weight", action: onPresentPlates)
      }
      ChoiceChipButton(
        title: "Warm-up", systemImage: draft.isWarmup ? "checkmark" : "flame", isSelected: draft.isWarmup
      ) {
        draft.isWarmup.toggle()
      }
      .accessibilityValue(draft.isWarmup ? Text("On") : Text("Off"))
      if liftShouldOfferWarmupSuggestion(completedWorkingSets: setProgress.completed) {
        WidgetChipButton(
          title: "Suggest a warm-up", systemImage: "figure.strengthtraining.traditional",
          accessibilityLabel: "Warm-up suggestion", accessibilityHint: "Shows suggested warm-up sets",
          action: onPresentWarmup)
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
          LiftRowList(items: plan.sets, separatorInset: GlyphDisc.diameter(scaled: 38) + NoopMetrics.space3) { set, _ in
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
              LiftTag(text: LocalizedStringKey(label))
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
