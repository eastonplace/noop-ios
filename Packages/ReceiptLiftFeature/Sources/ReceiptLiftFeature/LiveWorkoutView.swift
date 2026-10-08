import os
import StrandDesign
import SwiftUI

private let liftWorkoutPerformanceLog = OSLog(
  subsystem: "com.eastonplace.lift",
  category: .pointsOfInterest
)

private nonisolated func liftWorkoutUptime() -> TimeInterval {
  ProcessInfo.processInfo.systemUptime
}

private nonisolated func liftWorkoutPerformanceEvent(
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

nonisolated func liftWorkoutStampText(set: LiftSet, exercise: LiftExercise) -> String {
  "\(liftLoad(set.weight, for: exercise).uppercased()) × \(set.reps) ADDED TO RECEIPT"
}

nonisolated func liftWorkoutStampText(
  outcome: LiftSetOutcome,
  exercise: LiftExercise,
  prDetectionEnabled: Bool
) -> String {
  LiftPRPresentation.stampText(
    outcome: outcome,
    exercise: exercise,
    enabled: prDetectionEnabled
  )
}

nonisolated func liftWorkoutQueueAccessibilityLabel(
  row: LiftWorkoutQueueRowState,
  isPrinted: Bool
) -> String {
  let state = isPrinted ? "printed" : "up next"
  let superset = row.supersetLabel.map { ", \($0)" } ?? ""
  return "Exercise \(row.ordinal), \(row.exercise.name), \(liftWorkoutSpokenProgress(row.progressLabel)) sets, \(state)\(superset)"
}

nonisolated func liftWorkoutComposerAccessibilitySummary(
  weight: Double,
  reps: Int,
  progress: LiftSetProgress,
  exercise: LiftExercise
) -> String {
  let load: String
  if liftUsesBodyweightLoad(exercise) {
    load = weight > 0 ? "Bodyweight plus \(liftWorkoutSpokenPounds(weight))" : "Bodyweight"
  } else {
    load = liftWorkoutSpokenPounds(weight)
  }

  let set = progress.target.map { "set \(progress.current) of \($0)" } ?? "set \(progress.current)"
  return "\(load), \(reps) reps, \(set)"
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
  LiftExerciseDoneAction(title: isDone ? "Reopen" : "Done", nextValue: !isDone)
}

private nonisolated func liftWorkoutSpokenProgress(_ label: String) -> String {
  let parts = label.split(separator: "/", omittingEmptySubsequences: false)
  guard parts.count == 2 else { return label }
  return "\(parts[0]) of \(parts[1])"
}

private nonisolated func liftWorkoutSpokenPounds(_ weight: Double) -> String {
  let value = weight.rounded() == weight
    ? String(Int(weight))
    : String(format: "%.1f", weight)
  return "\(value) \(weight == 1 ? "pound" : "pounds")"
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

  var body: some View {
    HStack(alignment: .center, spacing: 12) {
      Text(String(format: "%02d", row.ordinal))
        .font(StrandFont.number(12, weight: .medium))
        .foregroundStyle(StrandPalette.textTertiary)
        .frame(width: 24, alignment: .leading)
      queueArtwork
      VStack(alignment: .leading, spacing: 2) {
        Text(row.exercise.name.liftDisplayName)
          .font(StrandFont.body)
          .foregroundStyle(StrandPalette.textPrimary)
        Text(row.supersetLabel ?? (isPrinted ? "Done" : "Tap to log sets"))
          .font(StrandFont.caption)
          .foregroundStyle(StrandPalette.textSecondary)
      }
      .frame(maxWidth: .infinity, alignment: .leading)
      Text(row.progressLabel)
        .font(StrandFont.number(14))
        .foregroundStyle(StrandPalette.textPrimary)
    }
    .padding(.vertical, 4)
    .frame(minHeight: 52)
    .contentShape(Rectangle())
    .opacity(isPrinted ? 0.58 : 1)
  }

  @ViewBuilder
  private var queueArtwork: some View {
    if reduceMotion {
      LiftExerciseThumb(exercise: row.exercise, size: 40, showsBorder: false)
        .transition(.opacity)
    } else {
      LiftExerciseThumb(exercise: row.exercise, size: 40, showsBorder: false)
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
          .foregroundStyle(StrandPalette.onInk)
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
      .background(LiftTheme.paper)
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
      .accessibilityLabel("Exercise \(row.ordinal), \(row.exercise.name)")
      .accessibilityValue(
        liftWorkoutQueueAccessibilityLabel(row: row, isPrinted: isPrinted)
          .replacingOccurrences(of: "Exercise \(row.ordinal), \(row.exercise.name), ", with: "")
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
        .matchedGeometryEffect(id: row.id, in: continuityNamespace)
    }
  }

  private func closeAction() {
    withAnimation(reduceMotion ? LiftMotion.reducedCrossfade : LiftMotion.surface) {
      revealOffset = 0
    }
  }
}

struct LiveWorkoutView: View {
  @Environment(\.accessibilityReduceMotion) private var reduceMotion
  @EnvironmentObject private var store: LiftStore
  let onDismiss: () -> Void
  let onSessionSaved: (LiftSession) -> Void
  @State private var activeSheet: LiveWorkoutSheet?
  @State private var composerExerciseID: UUID?
  @State private var confirmationStamp: WorkoutConfirmationStamp?
  @State private var stampDismissTask: Task<Void, Never>?
  @State private var isLibrarySelectionPending = false
  @State private var composerSwapStartedAt: TimeInterval?
  @State private var composerSwapTargetID: UUID?
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

    ZStack(alignment: .top) {
      ScrollView {
        LazyVStack(alignment: .leading, spacing: 0) {
          if let session = store.activeSession {
            LazyVStack(alignment: .leading, spacing: 0, pinnedViews: [.sectionHeaders]) {
              Section {
                VStack(alignment: .leading, spacing: LiftChromeMetrics.blockSpacing) {
                  if let composerExercise, let ordinal = composerOrdinal {
                    LiftSection(title: "Current exercise") {
                      ExerciseLogRow(
                        exercise: composerExercise,
                        store: store,
                        index: ordinal,
                        continuityNamespace: workspaceContinuityNamespace,
                        reduceMotion: reduceMotion,
                        onLogged: handleLoggedOutcome,
                        onPresentSwap: presentSwapPicker,
                        onPresentSuperset: presentSupersetPicker,
                        onPresentHistory: presentExerciseHistory,
                        onPresentRestOptions: presentRestOptions,
                        onComposed: composerDidRender
                      )
                      .id(composerExercise.id)
                    }
                  } else {
                    emptyQueue
                  }

                  queueSection(title: "Up next", rows: upNextRows, isPrinted: false)
                  queueSection(title: "Done", rows: printedRows, isPrinted: true)
                }
                .padding(.top, 12)
              } header: {
                workspaceHeader(session, queueRows: queueRows)
                  .background(LiftTheme.paper)
                  .zIndex(1)
              }
            }
            .padding(.horizontal, LiftChromeMetrics.gutter)
          } else {
            inactiveReceipt
          }
        }
        .padding(.bottom, 32)
      }
      .scrollIndicators(.hidden)

      WorkoutTopSafeAreaScrim()
    }
    .disabled(store.isFinishing)
    .interactiveDismissDisabled(store.isFinishing)
    .liftScreenBackground()
    .safeAreaInset(edge: .bottom) {
      if let error = store.databaseSaveError {
        HStack(spacing: 12) {
          Text("Not saved yet: \(error)")
            .font(StrandFont.caption)
            .foregroundStyle(StrandPalette.textSecondary)
            .frame(maxWidth: .infinity, alignment: .leading)
          ChipButton("Retry save") { store.flushPendingSave() }
        }
        .liftFooterBar()
      }
    }
    .overlay(alignment: .top) {
      if let confirmationStamp {
        WorkoutConfirmationStampView(
          setID: confirmationStamp.setID,
          text: confirmationStamp.text,
          onRendered: {
            liftWorkoutPerformanceEvent(
              "LogToConfirmationSurface",
              startedAt: confirmationStamp.startedAt
            )
          }
        )
          .id(confirmationStamp.setID)
          .padding(.horizontal, 16)
          .padding(.top, 8)
          .transition(
            reduceMotion
              ? .opacity
              : .move(edge: .top).combined(with: .opacity)
          )
          .allowsHitTesting(false)
      }
    }
    .onChange(of: activeExercises.map(\.id), initial: true) { _, exerciseIDs in
      reconcileComposer(with: exerciseIDs)
    }
    .onDisappear {
      stampDismissTask?.cancel()
      stampDismissTask = nil
      confirmationStamp = nil
    }
    .sheet(item: $activeSheet) { sheet in
      switch sheet {
      case .restOptions:
        MiniRestOptionsSheet()
          .environmentObject(store)
          .presentationDetents([.height(400)])
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
            .presentationDetents([.medium, .large])
            .presentationDragIndicator(.visible)
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
      }
    }
  }

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

  private func workspaceHeader(
    _ session: LiftSession,
    queueRows: [LiftWorkoutQueueRowState]
  ) -> some View {
    VStack(alignment: .leading, spacing: 8) {
      NoopScreenHeader(
        title: LocalizedStringKey(session.title),
        subtitle: LocalizedStringKey(sessionSetTotal(queueRows: queueRows, session: session)),
        style: .compact
      ) {
        NoopIconButton("chevron.down", accessibilityLabel: "Close workout", action: onDismiss)
      }

      HStack(spacing: 8) {
        ElapsedWorkoutClock(startedAt: session.startedAt)
        Spacer(minLength: 8)
        ChipButton("Receipt", systemImage: "ticket") {
          activeSheet = .receipt(session)
        }
        Menu {
          Button("Add exercise", systemImage: "plus") {
            presentExercisePicker()
          }
          Button("Finish workout", systemImage: "checkmark") {
            finishWorkout()
          }
          Button("Discard workout", systemImage: "trash", role: .destructive) {
            discardWorkout()
          }
        } label: {
          Image(systemName: "ellipsis")
            .font(.system(size: 16, weight: .semibold))
            .foregroundStyle(StrandPalette.textPrimary)
            .frame(width: 44, height: 44)
            .contentShape(Rectangle())
        }
        .accessibilityLabel("Workout actions")
      }

      LiftDivider()
    }
  }

  @ViewBuilder
  private func queueSection(
    title: String,
    rows: [LiftWorkoutQueueRowState],
    isPrinted: Bool
  ) -> some View {
    if !rows.isEmpty {
      LiftSection(title: LocalizedStringKey(title)) {
        LazyVStack(alignment: .leading, spacing: 0) {
          ForEach(rows) { row in
            LiftWorkoutQueueActionRow(
              row: row,
              isPrinted: isPrinted,
              continuityNamespace: workspaceContinuityNamespace,
              onSelect: { selectComposer(row.id) },
              onSetDone: { isDone in setExerciseDone(row.id, isDone: isDone) }
            )

            LiftDivider()
          }
        }
      }
    }
  }

  private var emptyQueue: some View {
    LiftSection(title: "Current exercise") {
      LiftEmptyNote(text: "No exercises in this workout yet. Add only the movements you plan to log.")
      NoopButton("Add exercise", systemImage: "plus", kind: .primary, fullWidth: true, action: presentExercisePicker)
    }
  }

  private var inactiveReceipt: some View {
    VStack(alignment: .leading, spacing: LiftChromeMetrics.blockSpacing) {
      NoopScreenHeader(title: "Workout closed", subtitle: "Return to Lift to begin")
      NoopButton("Close", systemImage: "chevron.down", kind: .secondary, fullWidth: true, action: onDismiss)
    }
    .padding(.horizontal, LiftChromeMetrics.gutter)
  }

  private func sessionSetTotal(
    queueRows: [LiftWorkoutQueueRowState],
    session: LiftSession
  ) -> String {
    let completed = session.workingSets.count
    let targets = queueRows.compactMap { row -> Int? in
      let parts = row.progressLabel.split(separator: "/", omittingEmptySubsequences: false)
      guard parts.count == 2 else { return nil }
      return Int(parts[1])
    }
    guard !queueRows.isEmpty, targets.count == queueRows.count else {
      return "\(completed) sets"
    }
    let target = targets.reduce(0, +)
    return "\(min(completed, target))/\(target) sets"
  }

  private func reconcileComposer(with exerciseIDs: [UUID]) {
    if let composerExerciseID, exerciseIDs.contains(composerExerciseID) {
      return
    }
    self.composerExerciseID = store.nextUnfinishedExerciseID(after: nil) ?? exerciseIDs.first
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
        prDetectionEnabled: LiftStore.prDetectionEnabled
      ),
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

private struct WorkoutTopSafeAreaScrim: View {
  var body: some View {
    GeometryReader { proxy in
      VStack(spacing: 0) {
        LiftTheme.paper
          .frame(height: proxy.safeAreaInsets.top)
          .ignoresSafeArea(edges: .top)
        Spacer(minLength: 0)
      }
      .allowsHitTesting(false)
    }
  }
}

private struct WorkoutConfirmationStamp: Equatable {
  let setID: UUID
  let text: String
  let startedAt: TimeInterval
}

private struct WorkoutConfirmationStampView: View {
  let setID: UUID
  let text: String
  let onRendered: () -> Void
  @State private var reportedSetID: UUID?

  var body: some View {
    Text(text)
      .font(StrandFont.caption.weight(.semibold))
      .foregroundStyle(StrandPalette.textPrimary)
      .multilineTextAlignment(.center)
      .lineLimit(2)
      .minimumScaleFactor(0.72)
      .padding(.horizontal, 14)
      .frame(maxWidth: .infinity, minHeight: 44)
      .background(
        StrandPalette.card,
        in: RoundedRectangle(cornerRadius: NoopMetrics.radius2, style: .continuous)
      )
      .overlay {
        RoundedRectangle(cornerRadius: NoopMetrics.radius2, style: .continuous)
          .strokeBorder(StrandPalette.cardBorder, lineWidth: 1)
      }
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

  var id: String {
    switch self {
    case .restOptions: "restOptions"
    case .receipt(let session): "receipt-\(session.id.uuidString)"
    case .exercisePickerMode(let mode): "exercisePicker-\(mode.id)"
    case .superset(let exerciseID): "superset-\(exerciseID.uuidString)"
    case .history(let exerciseID): "history-\(exerciseID.uuidString)"
    }
  }
}

private struct ElapsedWorkoutClock: View {
  let startedAt: Date

  var body: some View {
    VStack(alignment: .leading, spacing: 2) {
      Text("Elapsed").strandOverline()
      Text(timerInterval: startedAt...Date.distantFuture, countsDown: false)
        .font(StrandFont.number(18, weight: .bold))
        .foregroundStyle(StrandPalette.textPrimary)
    }
    .accessibilityElement(children: .combine)
  }
}

private struct ExerciseLogRow: View {
  let exercise: LiftExercise
  let store: LiftStore
  let index: Int
  let onLogged: (LiftSetOutcome, LiftExercise, Bool, TimeInterval) -> Void
  let onPresentSwap: (LiftExercise) -> Void
  let onPresentSuperset: (LiftExercise) -> Void
  let onPresentHistory: (LiftExercise) -> Void
  let onPresentRestOptions: () -> Void
  let onComposed: (UUID) -> Void
  let continuityNamespace: Namespace.ID
  let reduceMotion: Bool

  @State private var weight: Double
  @State private var reps: Int
  @State private var rpe: Double = 8
  @State private var isWarmup = false
  @State private var isEffortExpanded = false
  @State private var isWarmupSuggestionPresented = false
  @State private var showsPlateLoader = false

  init(
    exercise: LiftExercise,
    store: LiftStore,
    index: Int,
    continuityNamespace: Namespace.ID,
    reduceMotion: Bool,
    onLogged: @escaping (LiftSetOutcome, LiftExercise, Bool, TimeInterval) -> Void,
    onPresentSwap: @escaping (LiftExercise) -> Void,
    onPresentSuperset: @escaping (LiftExercise) -> Void,
    onPresentHistory: @escaping (LiftExercise) -> Void,
    onPresentRestOptions: @escaping () -> Void,
    onComposed: @escaping (UUID) -> Void
  ) {
    self.exercise = exercise
    self.store = store
    self.index = index
    self.continuityNamespace = continuityNamespace
    self.reduceMotion = reduceMotion
    self.onLogged = onLogged
    self.onPresentSwap = onPresentSwap
    self.onPresentSuperset = onPresentSuperset
    self.onPresentHistory = onPresentHistory
    self.onPresentRestOptions = onPresentRestOptions
    self.onComposed = onComposed
    _weight = State(initialValue: store.suggestedWeight(for: exercise.id))
    _reps = State(initialValue: store.suggestedReps(for: exercise.id))
  }

  var body: some View {
    VStack(alignment: .leading, spacing: 16) {
      composerHeader
      lastSetsLine
      setProgressLine
      loadReadout

      if LiftPlateLoaderEligibility.isEligible(exercise) {
        NoopButton("Plate loader", systemImage: "scalemass", kind: .secondary, fullWidth: true) {
          showsPlateLoader = true
        }
        .accessibilityHint("Shows plates for the current composer weight")
      }

      VStack(spacing: 10) {
        LiftStepper(
          title: "Weight",
          value: liftLoad(weight, for: exercise),
          decrement: { weight = max(0, weight - 5) },
          increment: { weight += 5 },
          decrementLarge: { weight = max(0, weight - 25) },
          incrementLarge: { weight += 25 }
        )
        LiftStepper(
          title: "Reps",
          value: "\(reps)",
          decrement: { reps = max(1, reps - 1) },
          increment: { reps += 1 }
        )
      }

      effortEditor
      if liftShouldOfferWarmupSuggestion(completedWorkingSets: setProgress.completed) {
        warmupSuggestionChip
      }
      warmupChip

      NoopButton("Log set", systemImage: "plus", kind: .primary, fullWidth: true, action: logCurrentSet)
    }
    .onAppear {
      onComposed(exercise.id)
    }
    .sheet(isPresented: $isWarmupSuggestionPresented) {
      WarmupSuggestionSheet(
        exercise: exercise,
        plan: store.warmupPlan(for: exercise, workingWeight: weight, workingReps: reps),
        weight: $weight,
        reps: $reps,
        isWarmup: $isWarmup
      )
      .presentationDetents([.medium, .large])
      .presentationDragIndicator(.visible)
    }
    .sheet(isPresented: $showsPlateLoader) {
      PlateLoaderView(targetWeight: $weight, exercise: exercise)
        .presentationDetents([.medium, .large])
        .presentationDragIndicator(.visible)
    }
  }

  private var composerHeader: some View {
    ViewThatFits(in: .horizontal) {
      HStack(alignment: .top, spacing: 12) {
        VStack(alignment: .leading, spacing: LiftDesignMetrics.Composer.restInlineSpacing) {
          composerIdentityAndTools
          composerQuickActions
          composerInlineRest
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        composerArtwork
      }
      VStack(alignment: .leading, spacing: 10) {
        composerIdentityAndTools
        composerQuickActions
        HStack(alignment: .top, spacing: 8) {
          composerInlineRest
          Spacer(minLength: 8)
          composerArtwork
        }
      }
    }
  }

  @ViewBuilder
  private var composerInlineRest: some View {
    if store.restTimerEndDate != nil {
      MiniRestBar(compact: true, onPresentOptions: onPresentRestOptions)
        .environmentObject(store)
    }
  }

  private var composerIdentityAndTools: some View {
    HStack(alignment: .top, spacing: 8) {
      Button { onPresentHistory(exercise) } label: { composerIdentity }
        .buttonStyle(.plain)
        .accessibilityHint("Opens exercise details and progress")
      Spacer(minLength: 4)
      composerToolsMenu
    }
  }

  private var composerIdentity: some View {
    VStack(alignment: .leading, spacing: 4) {
      Text(String(format: "%02d / %02d", index + 1, max(store.activeExercises.count, 1)))
        .font(StrandFont.number(12, weight: .medium))
        .foregroundStyle(StrandPalette.textTertiary)
      Text(exercise.name.liftDisplayName)
        .font(StrandFont.title2)
        .foregroundStyle(StrandPalette.textPrimary)
        .multilineTextAlignment(.leading)
        .lineLimit(3)
        .minimumScaleFactor(0.8)
    }
  }

  @ViewBuilder
  private var composerArtwork: some View {
    Button { onPresentHistory(exercise) } label: { composerArtworkImage }
      .buttonStyle(.plain)
      .accessibilityLabel("View \(exercise.name) photo and muscles")
  }

  @ViewBuilder
  private var composerArtworkImage: some View {
    if reduceMotion {
      LiftExerciseThumb(
        exercise: exercise,
        size: LiftDesignMetrics.Composer.artworkSize
      )
      .transition(.opacity)
      .accessibilityHidden(true)
    } else {
      LiftExerciseThumb(
        exercise: exercise,
        size: LiftDesignMetrics.Composer.artworkSize
      )
      .matchedGeometryEffect(id: exercise.id, in: continuityNamespace)
      .accessibilityHidden(true)
    }
  }

  private var composerQuickActions: some View {
    HStack(spacing: 8) {
      ChipButton("Swap", systemImage: "arrow.triangle.2.circlepath") { onPresentSwap(exercise) }
      ChipButton("Superset", systemImage: "link") { onPresentSuperset(exercise) }
    }
    .padding(.vertical, 6)
  }

  private var composerToolsMenu: some View {
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
        .foregroundStyle(StrandPalette.textPrimary)
        .frame(width: 44, height: 44)
        .contentShape(Rectangle())
    }
    .accessibilityLabel("Exercise tools")
  }

  private var savedWorkingSets: [LiftSet] {
    Array(
      store.sets(for: exercise.id, includeActive: false)
        .filter { !$0.isWarmup }
        .prefix(LiftDesignMetrics.Composer.lastSetLimit)
    )
  }

  private var lastSetsLine: some View {
    HStack(alignment: .firstTextBaseline, spacing: 10) {
      Text("Last").strandOverline()
      Text(lastSetsText)
        .font(StrandFont.number(13, weight: .medium))
        .foregroundStyle(savedWorkingSets.isEmpty ? StrandPalette.textTertiary : StrandPalette.textPrimary)
        .lineLimit(2)
        .minimumScaleFactor(0.68)
      Spacer(minLength: 0)
    }
    .accessibilityElement(children: .combine)
  }

  private var lastSetsText: String {
    guard !savedWorkingSets.isEmpty else { return "No saved sets" }
    return savedWorkingSets.map {
      "\(liftLoad($0.weight, for: exercise)) × \($0.reps)"
    }
    .joined(separator: "   ")
  }

  private var setProgress: LiftSetProgress {
    store.setProgress(for: exercise.id)
  }

  private var setProgressLine: some View {
    Text(setProgressText)
      .font(StrandFont.caption.weight(.semibold))
      .foregroundStyle(StrandPalette.textSecondary)
      .monospacedDigit()
  }

  private var setProgressText: String {
    guard let target = setProgress.target else {
      return "Set \(setProgress.completed + 1)"
    }
    return "Set \(min(setProgress.completed + 1, target)) of \(target)"
  }

  private var loadReadout: some View {
    ViewThatFits(in: .horizontal) {
      loadReadoutLine(
        loadSize: LiftDesignMetrics.Composer.loadFontSize,
        multiplierSize: LiftDesignMetrics.Composer.multiplierFontSize
      )
      loadReadoutLine(loadSize: 34, multiplierSize: 26)
    }
    .foregroundStyle(StrandPalette.textPrimary)
    .lineLimit(1)
    .accessibilityElement(children: .ignore)
    .accessibilityLabel(
      liftWorkoutComposerAccessibilitySummary(
        weight: weight,
        reps: reps,
        progress: setProgress,
        exercise: exercise
      )
    )
    .accessibilityHint("Swipe up or down to adjust weight. Use the reps controls to adjust reps.")
    .accessibilityAdjustableAction { direction in
      switch direction {
      case .increment:
        weight += 5
      case .decrement:
        weight = max(0, weight - 5)
      @unknown default:
        break
      }
    }
  }

  private func loadReadoutLine(loadSize: CGFloat, multiplierSize: CGFloat) -> some View {
    HStack(alignment: .firstTextBaseline, spacing: 8) {
      Text(liftLoad(weight, for: exercise))
        .font(StrandFont.number(loadSize, weight: .bold))
        .contentTransition(.numericText())
        .minimumScaleFactor(0.62)
      Text("×")
        .font(StrandFont.number(multiplierSize, weight: .medium))
        .foregroundStyle(StrandPalette.textSecondary)
      Text("\(reps)")
        .font(StrandFont.number(loadSize, weight: .bold))
        .contentTransition(.numericText())
      Spacer(minLength: 0)
    }
  }

  private var effortSelection: Binding<Int> {
    Binding(get: { Int(rpe) }, set: { rpe = Double($0) })
  }

  private var effortEditor: some View {
    VStack(alignment: .leading, spacing: 8) {
      Button {
        isEffortExpanded.toggle()
      } label: {
        HStack(spacing: 8) {
          Text("Effort")
            .font(StrandFont.subhead)
            .foregroundStyle(StrandPalette.textPrimary)
          Spacer()
          Text(rpe.formatted(.number.precision(.fractionLength(0))))
            .font(StrandFont.number(15))
            .foregroundStyle(StrandPalette.textPrimary)
          Image(systemName: isEffortExpanded ? "chevron.up" : "chevron.right")
            .font(.system(size: 13, weight: .semibold))
            .foregroundStyle(StrandPalette.textTertiary)
        }
        .frame(minHeight: 44)
        .contentShape(Rectangle())
      }
      .buttonStyle(.plain)
      .accessibilityLabel("Effort \(Int(rpe))")
      .accessibilityHint(isEffortExpanded ? "Collapses effort choices" : "Expands effort choices")

      if isEffortExpanded {
        SegmentedPillControl(Array(6...10), selection: effortSelection) { "\($0)" }
          .frame(maxWidth: .infinity, alignment: .leading)
      }
    }
  }

  private var warmupChip: some View {
    Button {
      isWarmup.toggle()
    } label: {
      HStack(spacing: 8) {
        Image(systemName: isWarmup ? "checkmark.square.fill" : "square")
          .foregroundStyle(isWarmup ? StrandPalette.accent : StrandPalette.textSecondary)
        Text("Warm-up")
          .font(StrandFont.subhead)
          .foregroundStyle(StrandPalette.textPrimary)
        Spacer(minLength: 0)
      }
      .padding(.horizontal, LiftDesignMetrics.Composer.warmupChipHorizontalPadding)
      .frame(maxWidth: .infinity, minHeight: 44)
      .contentShape(Rectangle())
      .overlay(
        RoundedRectangle(cornerRadius: NoopMetrics.radius2, style: .continuous)
          .strokeBorder(isWarmup ? StrandPalette.accent : StrandPalette.cardBorder, lineWidth: 1)
      )
    }
    .buttonStyle(.plain)
    .accessibilityLabel("Warm-up")
    .accessibilityValue(isWarmup ? "On" : "Off")
  }

  private var warmupSuggestionChip: some View {
    Button {
      isWarmupSuggestionPresented = true
    } label: {
      HStack(spacing: 8) {
        Image(systemName: "figure.strengthtraining.traditional")
          .foregroundStyle(StrandPalette.accent)
        Text("Suggest a warm-up")
          .font(StrandFont.subhead)
          .foregroundStyle(StrandPalette.textPrimary)
        Spacer(minLength: 0)
        Image(systemName: "chevron.right")
          .font(.system(size: 13, weight: .semibold))
          .foregroundStyle(StrandPalette.textTertiary)
      }
      .frame(maxWidth: .infinity, minHeight: 44)
      .contentShape(Rectangle())
    }
    .buttonStyle(.plain)
    .accessibilityLabel("Warm-up suggestion")
    .accessibilityHint("Shows suggested warm-up sets")
  }

  private func logCurrentSet() {
    let startedAt = liftWorkoutUptime()
    let wasIncompleteWorkingTarget = !isWarmup && setProgress.target != nil && !setProgress.isComplete
    guard let outcome = store.logSet(
      exercise: exercise,
      weight: weight,
      reps: reps,
      rpe: rpe,
      isWarmup: isWarmup,
      restSeconds: store.restSecondsForNextSet(for: exercise.id)
    ) else { return }

    let completedTarget = wasIncompleteWorkingTarget && store.setProgress(for: exercise.id).isComplete
    isWarmup = false
    onLogged(outcome, exercise, completedTarget, startedAt)
  }
}

private struct WarmupSuggestionSheet: View {
  @Environment(\.dismiss) private var dismiss
  let exercise: LiftExercise
  let plan: LiftWarmupPlan
  @Binding var weight: Double
  @Binding var reps: Int
  @Binding var isWarmup: Bool

  var body: some View {
    LiftScreen(
      title: "Warm-up?",
      subtitle: LocalizedStringKey(exercise.name.liftDisplayName),
      trailing: {
        NoopIconButton("xmark", accessibilityLabel: "Close warm-up suggestion") { dismiss() }
      }
    ) {
      VStack(alignment: .leading, spacing: 4) {
        Text(plan.title)
          .font(StrandFont.headline)
          .foregroundStyle(StrandPalette.textPrimary)
        Text(plan.reason)
          .font(StrandFont.subhead)
          .foregroundStyle(StrandPalette.textSecondary)
          .fixedSize(horizontal: false, vertical: true)
      }

      if plan.hasSets {
        VStack(spacing: 0) {
          ForEach(plan.sets) { set in
            WarmupSuggestionRow(set: set, exercise: exercise) {
              weight = set.weight
              reps = set.reps
              isWarmup = true
              dismiss()
            }
          }
        }
      } else {
        LiftEmptyNote(text: "No loaded ramp needed.")
      }
    }
  }
}

private struct WarmupSuggestionRow: View {
  let set: LiftWarmupSet
  let exercise: LiftExercise
  let onUse: () -> Void

  var body: some View {
    Button(action: onUse) {
      LiftRow(
        title: "\(liftLoad(set.weight, for: exercise)) × \(set.reps)",
        detail: rowSubtitle,
        value: "Use"
      ) {
        LiftRowIndex(index: set.sequence)
      }
    }
    .buttonStyle(.plain)
    .accessibilityLabel(
      "Use warm-up set \(set.sequence), \(liftLoad(set.weight, for: exercise)), \(set.reps) reps"
    )
  }

  private var rowSubtitle: String {
    if let percent = set.percent {
      return "\(Int((percent * 100).rounded()))% · \(set.note)"
    }
    return set.note
  }
}

private struct SupersetPairingSheet: View {
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
    LiftScreen(
      title: "Superset",
      subtitle: LocalizedStringKey(exercise.name.liftDisplayName),
      trailing: {
        NoopIconButton("xmark", accessibilityLabel: "Close superset pairing") { dismiss() }
      }
    ) {
      if let label = store.supersetLabel(for: exercise.id) {
        HStack(spacing: 10) {
          LiftBadge(text: label)
          Text(currentPartnerText)
            .font(StrandFont.subhead)
            .foregroundStyle(StrandPalette.textPrimary)
          Spacer(minLength: 0)
        }
        NoopButton("Clear pairing", systemImage: "xmark", kind: .secondary, fullWidth: true) {
          store.clearSuperset(for: exercise.id)
          dismiss()
        }
      }

      if candidates.isEmpty {
        LiftEmptyNote(text: "Add another active exercise to make a superset.")
      } else {
        VStack(spacing: 0) {
          ForEach(candidates) { candidate in
            Button {
              store.setSuperset(exercise.id, with: candidate.id)
              dismiss()
            } label: {
              LiftRow(
                title: candidate.name.liftDisplayName,
                detail: store.supersetLabel(for: candidate.id) ?? "Pair for this workout",
                value: "Pair"
              ) {
                LiftRowIndex(index: candidateOrdinal(candidate))
                LiftExerciseThumb(exercise: candidate, size: 40, showsBorder: false)
              }
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Pair \(exercise.name) with \(candidate.name)")
          }
        }
      }
    }
  }

  private var currentPartnerText: String {
    let names = store.supersetPartners(for: exercise.id).map(\.name)
    return names.isEmpty ? "No current partner" : "With " + names.joined(separator: " + ")
  }

  private func candidateOrdinal(_ candidate: LiftExercise) -> Int {
    (store.activeExercises.firstIndex { $0.id == candidate.id } ?? 0) + 1
  }
}
