import os
import StrandDesign
import SwiftUI

private let liftWorkoutPerformanceLog = OSLog(
  subsystem: "com.eastonplace.lift",
  category: .pointsOfInterest
)

nonisolated func liftWorkoutUptime() -> TimeInterval {
  ProcessInfo.processInfo.systemUptime
}

nonisolated func liftWorkoutPerformanceEvent(
  _ name: StaticString,
  startedAt: TimeInterval
) {
  os_signpost(
    .event,
    log: liftWorkoutPerformanceLog,
    name: name,
    "duration_ms=%{public}.3f",
    max((liftWorkoutUptime() - startedAt) * 1_000, 0)
  )
}

nonisolated func liftWorkoutStampText(set: LiftSet, exercise: LiftExercise, format: LiftFormat) -> String {
  String(localized: "\(format.load(pounds: set.weight, for: exercise)) × \(set.reps) added to receipt").uppercased()
}

nonisolated func liftWorkoutStampText(
  outcome: LiftSetOutcome,
  exercise: LiftExercise,
  prDetectionEnabled: Bool,
  format: LiftFormat
) -> String {
  LiftPRPresentation.stampText(
    outcome: outcome,
    exercise: exercise,
    enabled: prDetectionEnabled,
    format: format
  )
}

nonisolated func liftWorkoutQueueAccessibilityLabel(
  row: LiftWorkoutQueueRowState,
  isPrinted: Bool,
  locale: Locale = .autoupdatingCurrent
) -> String {
  let state = isPrinted ? String(localized: "printed") : String(localized: "up next")
  return LiftFormat.spoken(
    [
      String(localized: "Exercise \(row.ordinal)"),
      row.exercise.name,
      liftWorkoutSpokenSets(row.progressLabel),
      state,
      row.supersetLabel ?? "",
    ],
    locale: locale)
}

nonisolated func liftWorkoutComposerAccessibilitySummary(
  weight: Double,
  reps: Int,
  progress: LiftSetProgress,
  exercise: LiftExercise,
  format: LiftFormat
) -> String {
  let set = progress.target.map { String(localized: "set \(progress.current) of \($0)") }
    ?? String(localized: "set \(progress.current)")
  return LiftFormat.spoken(
    [format.spokenLoad(pounds: weight, for: exercise), String(localized: "\(reps) reps"), set],
    locale: format.locale)
}

nonisolated func liftShouldOfferWarmupSuggestion(completedWorkingSets: Int) -> Bool {
  completedWorkingSets == 0
}

nonisolated func liftSupersetCandidateIDs(
  activeExerciseIDs: [UUID],
  currentExerciseID: UUID
) -> [UUID] {
  activeExerciseIDs.filter { $0 != currentExerciseID }
}

struct LiftExerciseDoneAction: Equatable {
  let title: String
  let nextValue: Bool
}

nonisolated func liftExerciseDoneAction(isDone: Bool) -> LiftExerciseDoneAction {
  LiftExerciseDoneAction(
    title: isDone ? String(localized: "Reopen") : String(localized: "Done"), nextValue: !isDone)
}

private nonisolated func liftWorkoutSpokenProgress(_ label: String) -> String {
  let parts = label.split(separator: "/", omittingEmptySubsequences: false)
  guard parts.count == 2 else { return label }
  return String(localized: "\(String(parts[0])) of \(String(parts[1]))")
}

/// A queue row's progress read aloud: "1 of 3 sets" against a target, "1 set" without one (the count takes its language's
/// plural).
nonisolated func liftWorkoutSpokenSets(_ label: String) -> String {
  if let count = Int(label) { return LiftFormat.setCount(count) }
  return String(localized: "\(liftWorkoutSpokenProgress(label)) sets")
}

struct LiftWorkoutQueueRowState: Identifiable, Equatable, Sendable {
  let id: UUID
  let ordinal: Int
  let exercise: LiftExercise
  let progressLabel: String
  let isDone: Bool
  let supersetLabel: String?
}

struct LiftWorkoutQueueRowContent: View, Equatable {
  nonisolated let row: LiftWorkoutQueueRowState
  nonisolated let isPrinted: Bool
  let continuityNamespace: Namespace.ID
  nonisolated let reduceMotion: Bool

  nonisolated static func == (lhs: Self, rhs: Self) -> Bool {
    lhs.row == rhs.row
      && lhs.isPrinted == rhs.isPrinted
      && lhs.reduceMotion == rhs.reduceMotion
  }

  @Environment(\.dynamicTypeSize) private var typeSize

  var body: some View {
    Group {
      if LiftListRow<EmptyView, EmptyView>.stacks(typeSize) {
        VStack(alignment: .leading, spacing: NoopMetrics.space2) {
          HStack(spacing: NoopMetrics.space3) {
            queueArtwork
            Spacer(minLength: 0)
            progress
          }
          texts
        }
      } else {
        HStack(alignment: .center, spacing: NoopMetrics.space3) {
          queueArtwork
          texts
            .frame(maxWidth: .infinity, alignment: .leading)
          progress
        }
      }
    }
    .padding(.vertical, NoopMetrics.space2)
    .frame(maxWidth: .infinity, minHeight: 52, alignment: .leading)
    .contentShape(Rectangle())
    .opacity(isPrinted ? 0.58 : 1)
  }

  private var texts: some View {
    VStack(alignment: .leading, spacing: 2) {
      Text(row.exercise.name.liftDisplayName)
        .font(StrandFont.body.weight(.semibold))
        .foregroundStyle(StrandPalette.textPrimary)
        .fixedSize(horizontal: false, vertical: true)
      Text(row.supersetLabel ?? (isPrinted ? String(localized: "Done") : String(localized: "Tap to log sets")))
        .font(StrandFont.footnote)
        .foregroundStyle(StrandPalette.textSecondary)
        .fixedSize(horizontal: false, vertical: true)
    }
  }

  private var progress: some View {
    Text(verbatim: row.progressLabel)
      .font(StrandFont.number(17, weight: .semibold))
      .foregroundStyle(StrandPalette.textPrimary)
      .fixedSize()
  }

  @ViewBuilder
  private var queueArtwork: some View {
    if reduceMotion {
      LiftExerciseThumb(exercise: row.exercise, size: 44)
        .transition(.opacity)
    } else {
      LiftExerciseThumb(exercise: row.exercise, size: 44)
        .matchedGeometryEffect(id: row.exercise.id, in: continuityNamespace)
    }
  }
}

private struct LiftWorkoutQueueActionRow: View {
  @Environment(\.accessibilityReduceMotion) private var reduceMotion
  let row: LiftWorkoutQueueRowState
  let isPrinted: Bool
  let continuityNamespace: Namespace.ID
  let onSelect: () -> Void
  let onSetDone: (Bool) -> Void
  @State private var revealOffset: CGFloat = 0

  private let actionWidth: CGFloat = 92

  var body: some View {
    let action = liftExerciseDoneAction(isDone: row.isDone)

    ZStack(alignment: .trailing) {
      Button {
        onSetDone(action.nextValue)
        closeAction()
      } label: {
        Label(action.title, systemImage: row.isDone ? "arrow.uturn.left" : "checkmark")
          .labelStyle(.titleAndIcon)
          .font(StrandFont.caption.weight(.semibold))
          .foregroundStyle(StrandPalette.appCanvas)
          .frame(width: actionWidth)
          .frame(maxHeight: .infinity)
          .frame(minHeight: 52)
          .background(StrandPalette.ink)
      }
      .buttonStyle(.plain)
      .accessibilityHidden(true)

      Button(action: onSelect) {
        continuityContent
      }
      .buttonStyle(.plain)
      .background(StrandPalette.appCanvas)
      .offset(x: revealOffset)
      .contentShape(Rectangle())
      .gesture(
        DragGesture(minimumDistance: 18)
          .onChanged { value in
            guard abs(value.translation.width) > abs(value.translation.height) else { return }
            if value.translation.width < 0 {
              revealOffset = max(-actionWidth, value.translation.width)
            } else if revealOffset < 0 {
              revealOffset = min(0, -actionWidth + value.translation.width)
            }
          }
          .onEnded { value in
            guard abs(value.translation.width) > abs(value.translation.height) else {
              closeAction()
              return
            }
            let shouldReveal = revealOffset < -(actionWidth / 2)
            withAnimation(reduceMotion ? LiftMotion.reducedCrossfade : LiftMotion.surface) {
              revealOffset = shouldReveal ? -actionWidth : 0
            }
          }
      )
      .contextMenu {
        Button(action.title, systemImage: row.isDone ? "arrow.uturn.left" : "checkmark") {
          onSetDone(action.nextValue)
        }
      }
      .accessibilityLabel(String(localized: "Exercise \(row.ordinal), \(row.exercise.name)"))
      .accessibilityValue(
        LiftFormat.spoken(
          [
            liftWorkoutSpokenSets(row.progressLabel),
            isPrinted ? String(localized: "printed") : String(localized: "up next"),
            row.supersetLabel ?? "",
          ])
      )
      .accessibilityHint("Shows this exercise in the set composer")
      .accessibilityAction(named: Text(action.title)) {
        onSetDone(action.nextValue)
      }
    }
    .clipped()
    .onChange(of: row.isDone) {
      revealOffset = 0
    }
  }

  @ViewBuilder
  private var continuityContent: some View {
    if reduceMotion {
      LiftWorkoutQueueRowContent(
        row: row,
        isPrinted: isPrinted,
        continuityNamespace: continuityNamespace,
        reduceMotion: true
      )
        .equatable()
        .transition(.opacity)
    } else {
      LiftWorkoutQueueRowContent(
        row: row,
        isPrinted: isPrinted,
        continuityNamespace: continuityNamespace,
        reduceMotion: false
      )
        .equatable()
    }
  }

  private func closeAction() {
    withAnimation(reduceMotion ? LiftMotion.reducedCrossfade : LiftMotion.surface) {
      revealOffset = 0
    }
  }
}

/// What the composer holds for the set about to be logged. It lives in the workout view, so the pinned "Log set" button
/// and the composer read the same figures.
struct LiveComposerDraft: Equatable {
  var weight: Double
  var reps: Int
  var rpe: Double = LiftEffortValue.defaultRPE
  /// False until the person rates the set: an untouched RPE is 8 for the engine but reads as "–" and is not "rated".
  var effortRated = false
  var isWarmup = false
}

struct LiveWorkoutView: View {
  @Environment(\.accessibilityReduceMotion) private var reduceMotion
  @Environment(\.liftFormat) private var format
  @Environment(\.dynamicTypeSize) private var typeSize
  @Environment(\.liftStrainProvider) private var strainProvider
  @EnvironmentObject private var store: LiftStore
  let onDismiss: () -> Void
  let onSessionSaved: (LiftSession) -> Void
  @State private var activeSheet: LiveWorkoutSheet?
  @State private var composerExerciseID: UUID?
  @State private var draft = LiveComposerDraft(weight: 0, reps: 8)
  @State private var confirmationStamp: WorkoutConfirmationStamp?
  @State private var stampDismissTask: Task<Void, Never>?
  @State private var confirmsDiscard = false
  @State private var isLibrarySelectionPending = false
  @State private var composerSwapStartedAt: TimeInterval?
  @State private var composerSwapTargetID: UUID?
  @State private var vitals: LiftLiveVitals?
  @Namespace private var workspaceContinuityNamespace

  init(onDismiss: @escaping () -> Void, onSessionSaved: @escaping (LiftSession) -> Void = { _ in }) {
    self.onDismiss = onDismiss
    self.onSessionSaved = onSessionSaved
  }

  var body: some View {
    let activeExercises = store.activeExercises
    let queueRows = makeQueueRows(exercises: activeExercises, session: store.activeSession)
    let composerExercise = activeExercises.first { $0.id == composerExerciseID }
    let composerOrdinal = activeExercises.firstIndex { $0.id == composerExerciseID }
    let upNextRows = queueRows.filter { $0.id != composerExerciseID && !$0.isDone }
    let printedRows = queueRows.filter { $0.id != composerExerciseID && $0.isDone }

    ScrollViewReader { scrollProxy in
      ScrollView {
        VStack(alignment: .leading, spacing: 0) {
          if store.activeSession != nil {
            LiveStatsStrip(
              vitals: vitals, workingSetsDone: store.activeSession?.workingSets.count ?? 0,
              workingSetsPlanned: plannedWorkingSets(queueRows: queueRows)
            )
            .padding(.bottom, NoopMetrics.space3)
            FlatSectionSeparator()
            if let composerExercise, let ordinal = composerOrdinal {
              VStack(spacing: 0) {
              LiveComposerSection(
                exercise: composerExercise,
                store: store,
                index: ordinal,
                draft: $draft,
                continuityNamespace: workspaceContinuityNamespace,
                reduceMotion: reduceMotion,
                onPresentSwap: presentSwapPicker,
                onPresentSuperset: presentSupersetPicker,
                onPresentHistory: presentExerciseHistory,
                onPresentWarmup: { activeSheet = .warmup(composerExercise.id) },
                onPresentPlates: { activeSheet = .plateLoader(composerExercise.id) },
                onComposed: composerDidRender,
                onLog: logCurrentSet
              )
              .id(composerExercise.id)
              }
              .id("lift.composer")
            } else {
              emptyQueue
            }
            liveCards
            queueSection(title: "Up next", symbol: "list.number", rows: upNextRows, isPrinted: false)
            queueSection(title: "Done", symbol: "checkmark.circle", rows: printedRows, isPrinted: true)
            if !activeExercises.isEmpty { addExerciseChip }
          } else {
            inactiveReceipt
          }
        }
        .padding(.horizontal, StrengthMetrics.gutter)
        .padding(.top, NoopMetrics.space3)
        .padding(.bottom, NoopMetrics.space6)
        .frame(maxWidth: LiftChromeMetrics.maxColumnWidth, alignment: .leading)
        .frame(maxWidth: .infinity)
      }
      .scrollIndicators(.hidden)
      .scrollDismissesKeyboard(.interactively)
      .liftQAScene("live-composer") { scrollProxy.scrollTo("lift.composer", anchor: .top) }
    }
    .background(StrandPalette.appCanvas.ignoresSafeArea())
    .safeAreaInset(edge: .top, spacing: 0) {
      if let session = store.activeSession {
        workspaceHeader(session)
      }
    }
    .safeAreaInset(edge: .bottom, spacing: 0) { footer }
    .overlay(alignment: .bottom) { stampOverlay }
    .task { if let strainProvider { await LiftLiveHeartRateSession.run(strainProvider) } }
    .task(id: store.activeSession?.sets.count ?? 0) { await pollVitals() }
    .disabled(store.isFinishing)
    .interactiveDismissDisabled(store.isFinishing)
    .onChange(of: activeExercises.map(\.id), initial: true) { _, exerciseIDs in
      reconcileComposer(with: exerciseIDs)
    }
    .onChange(of: composerExerciseID, initial: true) { resetDraft() }
    .liftQAScene("live-rest-options") { activeSheet = .restOptions }
    .liftQAScene("live-receipt") { activeSheet = store.activeSession.map { .receipt($0) } }
    .liftQAScene("live-library") { presentExercisePicker() }
    .liftQAScene("live-superset") { activeSheet = composerExerciseID.map { .superset($0) } }
    .liftQAScene("live-exercise") { activeSheet = composerExerciseID.map { .history($0) } }
    .liftQAScene("live-plates") {
      draft.weight = 225
      activeSheet = composerExerciseID.map { .plateLoader($0) }
    }
    .liftQAScene("live-warmup") { activeSheet = composerExerciseID.map { .warmup($0) } }
    .liftQAScene("live-pr", after: .milliseconds(1_400)) {
      draft.weight += 20
      logCurrentSet()
    }
    .onDisappear {
      stampDismissTask?.cancel()
      stampDismissTask = nil
      confirmationStamp = nil
    }
    // Discarding loses every set logged so far, so the menu entry only asks; this is where it happens.
    .confirmationDialog("Discard this workout?", isPresented: $confirmsDiscard, titleVisibility: .visible) {
      Button("Discard workout", role: .destructive) { discardWorkout() }
      Button("Cancel", role: .cancel) {}
    } message: {
      Text("The sets you’ve logged will be lost. This can’t be undone.")
    }
    .sheet(item: $activeSheet) { sheet in
      switch sheet {
      case .restOptions:
        MiniRestOptionsSheet()
          .environmentObject(store)
          .presentationDetents([.medium, .large])
          .presentationDragIndicator(.visible)
      case .receipt(let receiptSession):
        LiveReceiptView(session: receiptSession)
          .environmentObject(store)
          .presentationDetents([.large])
          .presentationDragIndicator(.visible)
      case .exercisePickerMode(let mode):
        NavigationStack {
          ExerciseLibraryView(onSelect: { exercise in
            selectExerciseFromPicker(exercise, mode: mode)
          })
            .environmentObject(store)
        }
      case .superset(let exerciseID):
        if let exercise = store.exercise(for: exerciseID) {
          SupersetPairingSheet(exercise: exercise)
            .environmentObject(store)
        }
      case .history(let exerciseID):
        if store.exercise(for: exerciseID) != nil {
          NavigationStack {
            ExerciseProgressView(exerciseID: exerciseID, showsInformation: true, closesModal: true)
            .environmentObject(store)
          }
          .presentationDetents([.large])
          .presentationDragIndicator(.visible)
        }
      case .warmup(let exerciseID):
        if let exercise = store.exercise(for: exerciseID) {
          WarmupSuggestionSheet(
            exercise: exercise,
            plan: store.warmupPlan(
              for: exercise, workingWeight: draft.weight, workingReps: draft.reps, unit: format.unit),
            draft: $draft
          )
        }
      case .plateLoader(let exerciseID):
        if let exercise = store.exercise(for: exerciseID) {
          PlateLoaderView(targetWeight: $draft.weight, exercise: exercise)
        }
      }
    }
  }

  // MARK: Header

  private func workspaceHeader(_ session: LiftSession) -> some View {
    // At the largest text sizes the title and the clock get the whole width: the chips and Finish sit on rows of their own.
    Group {
      if typeSize.isAccessibilitySize {
        VStack(alignment: .leading, spacing: NoopMetrics.space2) {
          HStack(spacing: NoopMetrics.space2) {
            headerCloseChip
            Spacer(minLength: NoopMetrics.space2)
            headerMenu(session)
          }
          LiveRecordingEyebrow(title: session.title)
          ElapsedWorkoutClock(startedAt: session.startedAt)
          finishButton
        }
      } else {
        HStack(alignment: .center, spacing: NoopMetrics.space2) {
          headerCloseChip
          VStack(alignment: .leading, spacing: 0) {
            LiveRecordingEyebrow(title: session.title)
            ElapsedWorkoutClock(startedAt: session.startedAt)
          }
          Spacer(minLength: NoopMetrics.space2)
          headerMenu(session)
          finishButton
        }
      }
    }
    .frame(minHeight: 44)
    .padding(.horizontal, StrengthMetrics.gutter)
    .padding(.top, NoopMetrics.space2)
    .padding(.bottom, NoopMetrics.space1)
    .frame(maxWidth: LiftChromeMetrics.maxColumnWidth + StrengthMetrics.gutter * 2)
    .frame(maxWidth: .infinity)
    .background(StrandPalette.appCanvas.ignoresSafeArea(edges: .top))
  }

  private var headerCloseChip: some View {
    HeaderChipButton("chevron.down", accessibilityLabel: "Close workout", action: onDismiss)
  }

  private var finishButton: some View {
    Button(action: finishWorkout) { Text("Finish") }
      .buttonStyle(NoopButtonStyle(.primary))
      .accessibilityLabel("Finish workout")
  }

  private func headerMenu(_ session: LiftSession) -> some View {
    Menu {
      Button("Add exercise", systemImage: "plus") {
        presentExercisePicker()
      }
      Button("Receipt", systemImage: "ticket") { activeSheet = .receipt(session) }
      Button("Finish workout", systemImage: "checkmark") {
        finishWorkout()
      }
      Button("Discard workout", systemImage: "trash", role: .destructive) {
        confirmsDiscard = true
      }
    } label: {
      HeaderChipGlyph(systemImage: "ellipsis")
    }
    .accessibilityLabel("Workout actions")
  }

  // MARK: Footer

  /// Only a failed save pins to the bottom; the Log set button and the rest card are part of the page.
  @ViewBuilder private var footer: some View {
    if let error = store.databaseSaveError {
      HStack(spacing: NoopMetrics.space3) {
        Text("Not saved yet: \(error)")
          .font(StrandFont.caption)
          .foregroundStyle(StrandPalette.textSecondary)
          .frame(maxWidth: .infinity, alignment: .leading)
        ChoiceChipButton(title: "Retry save") { store.flushPendingSave() }
      }
      .liftFooterBar()
    }
  }

  /// The confirmation of a logged set floats over the bottom edge for a moment, so the page never jumps to make room.
  @ViewBuilder private var stampOverlay: some View {
    if let confirmationStamp {
      WorkoutConfirmationStampView(
        setID: confirmationStamp.setID,
        text: confirmationStamp.text,
        isPersonalRecord: confirmationStamp.isPersonalRecord,
        onRendered: {
          liftWorkoutPerformanceEvent("LogToConfirmationSurface", startedAt: confirmationStamp.startedAt)
        }
      )
      .id(confirmationStamp.setID)
      .padding(.horizontal, StrengthMetrics.gutter)
      .padding(.bottom, NoopMetrics.space3)
      .frame(maxWidth: LiftChromeMetrics.maxColumnWidth + StrengthMetrics.gutter * 2)
      .transition(reduceMotion ? .opacity : .move(edge: .bottom).combined(with: .opacity))
      .allowsHitTesting(false)
    }
  }

  /// The REST card while a rest runs, then the STRAIN SO FAR card.
  @ViewBuilder private var liveCards: some View {
    let isResting = store.restTimerEndDate != nil
    if isResting || strainProvider != nil {
      VStack(spacing: NoopMetrics.space3) {
        if isResting { MiniRestBar(onPresentOptions: presentRestOptions) }
        if strainProvider != nil { LiveStrainCard(vitals: vitals) }
      }
      .padding(.bottom, NoopMetrics.space3)
    }
  }

  private func plannedWorkingSets(queueRows: [LiftWorkoutQueueRowState]) -> Int? {
    let targets = queueRows.compactMap { row -> Int? in
      let parts = row.progressLabel.split(separator: "/", omittingEmptySubsequences: false)
      guard parts.count == 2 else { return nil }
      return Int(parts[1])
    }
    guard !queueRows.isEmpty, targets.count == queueRows.count else { return nil }
    return targets.reduce(0, +)
  }

  /// Live vitals, refreshed on a log and every 15 s: heart rate now and Strain so far.
  private func pollVitals() async {
    guard let provider = strainProvider else { vitals = nil; return }
    while !Task.isCancelled {
      guard let session = store.activeSession else { return }
      let sets = LiftReceiptSetMapping.sets(for: session, exercise: { store.exercise(for: $0) })
      vitals = await provider.liveVitals(start: session.startedAt, sets: sets)
      try? await Task.sleep(for: .seconds(15))
    }
  }

  // MARK: Queue

  private func makeQueueRows(
    exercises: [LiftExercise],
    session: LiftSession?
  ) -> [LiftWorkoutQueueRowState] {
    let completedSets = (session?.sets ?? []).reduce(into: [UUID: Int]()) { counts, set in
      guard !set.isWarmup else { return }
      counts[set.exerciseID, default: 0] += 1
    }
    let plans: [LiftRoutineExercisePlan]
    if store.activeExerciseIDsOverride != nil {
      plans = Array(store.activePlanOverrides.values)
    } else if let routineID = session?.routineID,
              let routine = store.routines.first(where: { $0.id == routineID }) {
      plans = routine.exercisePlans ?? []
    } else {
      plans = []
    }
    let targets = plans.reduce(into: [UUID: Int]()) { targets, plan in
      targets[plan.exerciseID] = LiftStore.setCount(from: plan.sets)
    }

    return exercises.enumerated().map { index, exercise in
      let progress = LiftSetProgress(
        completed: completedSets[exercise.id, default: 0],
        target: targets[exercise.id]
      )
      return LiftWorkoutQueueRowState(
        id: exercise.id,
        ordinal: index + 1,
        exercise: exercise,
        progressLabel: progress.target == nil ? "\(progress.completed)" : progress.label,
        isDone: store.isExerciseDone(exercise.id) || progress.isComplete,
        supersetLabel: store.supersetLabel(for: exercise.id)
      )
    }
  }

  @ViewBuilder
  private func queueSection(
    title: LocalizedStringKey,
    symbol: String,
    rows: [LiftWorkoutQueueRowState],
    isPrinted: Bool
  ) -> some View {
    if !rows.isEmpty {
      FlatSectionSeparator()
      LiftFlatSection(title, systemImage: symbol, trailing: .text(rows.count.formatted()), contentSpacing: 0) {
        LazyVStack(alignment: .leading, spacing: 0) {
          ForEach(Array(rows.enumerated()), id: \.element.id) { index, row in
            if index > 0 { FlatRowSeparator(leadingInset: 44 + NoopMetrics.space3) }
            LiftWorkoutQueueActionRow(
              row: row,
              isPrinted: isPrinted,
              continuityNamespace: workspaceContinuityNamespace,
              onSelect: { selectComposer(row.id) },
              onSetDone: { isDone in setExerciseDone(row.id, isDone: isDone) }
            )
          }
        }
      }
    }
  }

  private var addExerciseChip: some View {
    ChipRow {
      WidgetChipButton(
        title: "Add exercise", systemImage: "plus", accessibilityLabel: "Add exercise",
        action: presentExercisePicker)
    }
    .padding(.top, NoopMetrics.space3)
  }

  private var emptyQueue: some View {
    LiftFlatSection("Current exercise") {
      VStack(alignment: .leading, spacing: WidgetMetrics.contentSpacing) {
        LiftNote(text: "No exercises in this workout yet. Add only the movements you plan to log.")
        Button(action: presentExercisePicker) { Label("Add exercise", systemImage: "plus") }
          .buttonStyle(PrimaryPillButtonStyle())
      }
    }
  }

  private var inactiveReceipt: some View {
    LiftMessage(
      title: "Workout closed",
      message: "Return to Lift to begin",
      actionTitle: "Close",
      action: onDismiss
    )
  }

  // MARK: Composer

  private func reconcileComposer(with exerciseIDs: [UUID]) {
    if let composerExerciseID, exerciseIDs.contains(composerExerciseID) {
      return
    }
    self.composerExerciseID = store.nextUnfinishedExerciseID(after: nil) ?? exerciseIDs.first
  }

  /// A fresh composer for the exercise now showing: its last working weight and reps, in the person's unit.
  private func resetDraft() {
    guard let composerExerciseID else { return }
    draft = LiveComposerDraft(
      weight: format.unit.canonicalPounds(store.suggestedWeight(for: composerExerciseID)),
      reps: store.suggestedReps(for: composerExerciseID)
    )
  }

  private func selectComposer(_ exerciseID: UUID) {
    guard exerciseID != composerExerciseID else { return }
    composerSwapStartedAt = liftWorkoutUptime()
    composerSwapTargetID = exerciseID
    withAnimation(reduceMotion ? LiftMotion.reducedCrossfade : LiftMotion.continuity) {
      composerExerciseID = exerciseID
    }
  }

  private func composerDidRender(_ exerciseID: UUID) {
    guard composerSwapTargetID == exerciseID,
          let composerSwapStartedAt
    else { return }
    liftWorkoutPerformanceEvent(
      "ComposerSwapToSurface",
      startedAt: composerSwapStartedAt
    )
    self.composerSwapStartedAt = nil
    composerSwapTargetID = nil
  }

  private func advanceComposer(after exerciseID: UUID) {
    guard let nextExerciseID = store.nextUnfinishedExerciseID(after: exerciseID) else { return }
    selectComposer(nextExerciseID)
  }

  private func setExerciseDone(_ exerciseID: UUID, isDone: Bool) {
    withAnimation(reduceMotion ? LiftMotion.reducedCrossfade : LiftMotion.compose) {
      store.setExerciseDone(exerciseID, isDone: isDone)
    }
  }

  private func presentExercisePicker() {
    isLibrarySelectionPending = false
    activeSheet = .exercisePickerMode(.add)
  }

  private func presentRestOptions() {
    guard store.restRemaining() > 0 else { return }
    activeSheet = .restOptions
  }

  private func presentSwapPicker(_ exercise: LiftExercise) {
    isLibrarySelectionPending = false
    activeSheet = .exercisePickerMode(.swap(exercise.id))
  }

  private func presentSupersetPicker(_ exercise: LiftExercise) {
    activeSheet = .superset(exercise.id)
  }

  private func presentExerciseHistory(_ exercise: LiftExercise) {
    activeSheet = .history(exercise.id)
  }

  private func selectExerciseFromPicker(
    _ exercise: LiftExercise,
    mode: ExercisePickerMode
  ) {
    guard !isLibrarySelectionPending, store.activeSession != nil else { return }
    isLibrarySelectionPending = true

    let before = store.activeExerciseIDsOverride ?? store.activeExercises.map(\.id)
    switch mode {
    case .add:
      store.addActiveExercise(exercise.id)
    case .swap(let oldExerciseID):
      store.replaceActiveExercise(oldExerciseID, with: exercise.id)
    }
    let after = store.activeExerciseIDsOverride ?? store.activeExercises.map(\.id)

    guard before != after, after.contains(exercise.id) else {
      isLibrarySelectionPending = false
      return
    }
    selectComposer(exercise.id)
    activeSheet = nil
  }

  // MARK: Logging

  private func logCurrentSet() {
    guard let exercise = store.activeExercises.first(where: { $0.id == composerExerciseID }) else { return }
    let startedAt = liftWorkoutUptime()
    let progress = store.setProgress(for: exercise.id)
    let wasIncompleteWorkingTarget = !draft.isWarmup && progress.target != nil && !progress.isComplete
    guard let outcome = store.logSet(
      exercise: exercise,
      weight: draft.weight,
      reps: draft.reps,
      rpe: draft.rpe,
      isWarmup: draft.isWarmup,
      restSeconds: store.restSecondsForNextSet(for: exercise.id),
      effortRated: draft.effortRated
    ) else { return }

    let completedTarget = wasIncompleteWorkingTarget && store.setProgress(for: exercise.id).isComplete
    draft.isWarmup = false
    draft.rpe = LiftEffortValue.defaultRPE
    draft.effortRated = false
    handleLoggedOutcome(outcome, exercise: exercise, completedTarget: completedTarget, startedAt: startedAt)
  }

  private func handleLoggedOutcome(
    _ outcome: LiftSetOutcome,
    exercise: LiftExercise,
    completedTarget: Bool,
    startedAt: TimeInterval
  ) {
    showConfirmationStamp(
      for: outcome,
      exercise: exercise,
      startedAt: startedAt
    )
    if LiftStore.prDetectionEnabled, outcome.personalRecord != nil {
      LiftHaptics.play(.personalRecord, enabled: store.settings.hapticsEnabled)
    } else if completedTarget {
      LiftHaptics.exerciseCompleted(enabled: store.settings.hapticsEnabled)
    } else {
      LiftHaptics.setLogged(enabled: store.settings.hapticsEnabled)
    }
    if completedTarget {
      advanceComposer(after: exercise.id)
    }
  }

  private func showConfirmationStamp(
    for outcome: LiftSetOutcome,
    exercise: LiftExercise,
    startedAt: TimeInterval
  ) {
    let stamp = WorkoutConfirmationStamp(
      setID: outcome.set.id,
      text: liftWorkoutStampText(
        outcome: outcome,
        exercise: exercise,
        prDetectionEnabled: LiftStore.prDetectionEnabled,
        format: format
      ),
      isPersonalRecord: LiftStore.prDetectionEnabled && outcome.personalRecord != nil,
      startedAt: startedAt
    )
    stampDismissTask?.cancel()
    withAnimation(reduceMotion ? LiftMotion.reducedCrossfade : LiftMotion.surface) {
      confirmationStamp = stamp
    }
    stampDismissTask = Task { @MainActor in
      do {
        let dwellMilliseconds = Int64(
          LiftDesignMetrics.Receipt.stampDwellSeconds * 1_000
        )
        try await Task.sleep(for: .milliseconds(dwellMilliseconds))
      } catch {
        return
      }
      guard confirmationStamp?.setID == stamp.setID else { return }
      withAnimation(reduceMotion ? LiftMotion.reducedCrossfade : LiftMotion.surface) {
        confirmationStamp = nil
      }
      stampDismissTask = nil
    }
  }

  private func finishWorkout() {
    Task { @MainActor in
      if let savedSession = await store.finishActiveSessionDurably() {
        LiftHaptics.workoutFinished(enabled: store.settings.hapticsEnabled)
        onSessionSaved(savedSession)
      }
    }
  }

  private func discardWorkout() {
    store.discardActiveSession()
    onDismiss()
  }
}

private struct WorkoutConfirmationStamp: Equatable {
  let setID: UUID
  let text: String
  let isPersonalRecord: Bool
  let startedAt: TimeInterval
}

/// The line that confirms a logged set: a check (a trophy for a personal record) and what was added to the receipt.
private struct WorkoutConfirmationStampView: View {
  let setID: UUID
  let text: String
  let isPersonalRecord: Bool
  let onRendered: () -> Void
  @State private var reportedSetID: UUID?

  var body: some View {
    HStack(spacing: NoopMetrics.space2) {
      Image(systemName: isPersonalRecord ? "trophy.fill" : "checkmark.circle.fill")
        .font(.system(size: 14, weight: .semibold))
        .foregroundStyle(DomainTint.workout.accent)
        .accessibilityHidden(true)
      Text(verbatim: text)
        .font(StrandFont.caption.weight(.semibold))
        .foregroundStyle(StrandPalette.textPrimary)
        .multilineTextAlignment(.leading)
        .lineLimit(2)
        .minimumScaleFactor(0.72)
      Spacer(minLength: 0)
    }
    .padding(.horizontal, 14)
    .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
    .background(
      DomainTint.workout.accent.opacity(isPersonalRecord ? 0.2 : 0.12),
      in: RoundedRectangle(cornerRadius: NoopMetrics.radius2, style: .continuous)
    )
    .overlay {
      RoundedRectangle(cornerRadius: NoopMetrics.radius2, style: .continuous)
        .strokeBorder(DomainTint.workout.accent.opacity(isPersonalRecord ? 0.7 : 0.35), lineWidth: 1)
    }
    .accessibilityElement(children: .ignore)
    .accessibilityLabel(text)
    .onAppear {
      guard reportedSetID != setID else { return }
      reportedSetID = setID
      onRendered()
    }
  }
}

private enum ExercisePickerMode: Equatable {
  case add
  case swap(UUID)

  var id: String {
    switch self {
    case .add: "add"
    case .swap(let exerciseID): "swap-\(exerciseID.uuidString)"
    }
  }
}

private enum LiveWorkoutSheet: Identifiable {
  case restOptions
  case receipt(LiftSession)
  case exercisePickerMode(ExercisePickerMode)
  case superset(UUID)
  case history(UUID)
  case warmup(UUID)
  case plateLoader(UUID)

  var id: String {
    switch self {
    case .restOptions: "restOptions"
    case .receipt(let session): "receipt-\(session.id.uuidString)"
    case .exercisePickerMode(let mode): "exercisePicker-\(mode.id)"
    case .superset(let exerciseID): "superset-\(exerciseID.uuidString)"
    case .history(let exerciseID): "history-\(exerciseID.uuidString)"
    case .warmup(let exerciseID): "warmup-\(exerciseID.uuidString)"
    case .plateLoader(let exerciseID): "plates-\(exerciseID.uuidString)"
    }
  }
}

/// How long the workout has run, large under the recording eyebrow: "32:14".
private struct ElapsedWorkoutClock: View {
  let startedAt: Date

  @ScaledMetric(relativeTo: .largeTitle) private var size: CGFloat = 32

  var body: some View {
    Text(timerInterval: startedAt...Date.distantFuture, countsDown: false)
      .font(StrandFont.sized(size, weight: .bold))
      .monospacedDigit()
      .foregroundStyle(StrandPalette.textPrimary)
      .lineLimit(1)
      .minimumScaleFactor(0.7)
      .accessibilityElement(children: .ignore)
      .accessibilityLabel("Elapsed")
      .accessibilityValue(Text(timerInterval: startedAt...Date.distantFuture, countsDown: false))
  }
}
