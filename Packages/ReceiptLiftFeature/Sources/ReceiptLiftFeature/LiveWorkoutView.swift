import os
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
    HStack(alignment: .top, spacing: 9) {
      Text(String(format: "%02d", row.ordinal))
        .font(.receipt(11, weight: .bold))
        .foregroundStyle(LiftTheme.inkSecondary)
        .frame(width: 24, alignment: .leading)
      queueArtwork
      VStack(alignment: .leading, spacing: 3) {
        Text(row.exercise.name.uppercased())
          .font(.receipt(12, weight: .black))
          .foregroundStyle(LiftTheme.ink)
        Text((row.supersetLabel ?? (isPrinted ? "Printed to receipt" : "Tap to compose")).uppercased())
          .font(.receipt(9, weight: .medium))
          .foregroundStyle(LiftTheme.inkSecondary)
      }
      .frame(maxWidth: .infinity, alignment: .leading)
      Text(row.progressLabel.uppercased())
        .font(.receipt(11, weight: .black))
        .monospacedDigit()
        .foregroundStyle(LiftTheme.ink)
    }
    .frame(minHeight: 44)
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
          .font(.receipt(9, weight: .black))
          .foregroundStyle(LiftTheme.paper)
          .frame(width: actionWidth)
          .frame(maxHeight: .infinity)
          .frame(minHeight: 52)
          .background(LiftTheme.ink)
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
            ReceiptSheet {
              LazyVStack(alignment: .leading, spacing: 0, pinnedViews: [.sectionHeaders]) {
                Section {
                  VStack(alignment: .leading, spacing: 12) {
                    if let composerExercise, let ordinal = composerOrdinal {
                      ReceiptSectionLabel(title: "Current Exercise")
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
                    } else {
                      emptyQueue
                    }

                    queueSection(title: "Up Next", rows: upNextRows, isPrinted: false)
                    queueSection(title: "Printed", rows: printedRows, isPrinted: true)
                  }
                  .padding(.top, 12)
                } header: {
                  VStack(alignment: .leading, spacing: 12) {
                    workspaceHeader(session, queueRows: queueRows)
                    ReceiptDashedRule()
                  }
                  .background(LiftTheme.paper)
                  .zIndex(1)
                }
              }
            }
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
        VStack(spacing: 8) {
          Text("Not saved yet: \(error)").font(.caption)
          Button("Retry save") { store.flushPendingSave() }
        }.padding(12).frame(maxWidth: .infinity).background(LiftTheme.paper)
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
          .presentationDetents([.height(280)])
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
            .presentationDetents([.height(360), .medium])
            .presentationDragIndicator(.visible)
        }
      case .history(let exerciseID):
        if store.exercise(for: exerciseID) != nil {
          NavigationStack {
            ExerciseProgressView(exerciseID: exerciseID)
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
    VStack(alignment: .leading, spacing: 10) {
      ViewThatFits(in: .horizontal) {
        HStack(alignment: .top) {
          workspaceReceiptHeader(session, queueRows: queueRows)
            .fixedSize(horizontal: true, vertical: false)
          Spacer(minLength: 8)
          workspaceCloseButton
        }

        VStack(alignment: .leading, spacing: 8) {
          workspaceReceiptHeader(session, queueRows: queueRows)
          workspaceCloseButton
            .frame(maxWidth: .infinity, alignment: .trailing)
        }
      }

      HStack(spacing: 8) {
        ElapsedWorkoutClock(startedAt: session.startedAt)
        Spacer(minLength: 8)
        ReceiptSecondaryButton(
          title: "Receipt",
          systemImage: "ticket",
          tint: LiftTheme.ink
        ) {
          activeSheet = .receipt(session)
        }
        Menu {
          Button("Add Exercise", systemImage: "plus") {
            presentExercisePicker()
          }
          Button("Finish Workout", systemImage: "checkmark") {
            finishWorkout()
          }
          Button("Discard Workout", systemImage: "trash", role: .destructive) {
            discardWorkout()
          }
        } label: {
          Image(systemName: "ellipsis")
            .font(.receipt(16, weight: .black))
            .foregroundStyle(LiftTheme.ink)
            .frame(width: 44, height: 44)
        }
        .accessibilityLabel("Workout actions")
      }
    }
  }

  private func workspaceReceiptHeader(
    _ session: LiftSession,
    queueRows: [LiftWorkoutQueueRowState]
  ) -> some View {
    VStack(alignment: .leading, spacing: 5) {
      Text(session.title.uppercased())
        .font(.receipt(34, weight: .black))
        .foregroundStyle(LiftTheme.ink)
        .lineLimit(3)
        .minimumScaleFactor(0.52)
        .allowsTightening(true)
        .fixedSize(horizontal: false, vertical: true)

      HStack(alignment: .firstTextBaseline, spacing: 12) {
        Text("ACTIVE RECEIPT")
          .font(.receipt(10, weight: .bold))
          .tracking(0.8)
          .foregroundStyle(LiftTheme.inkSecondary)
        Spacer(minLength: 8)
        Text(sessionSetTotal(queueRows: queueRows, session: session).uppercased())
          .font(.receipt(10, weight: .bold))
          .foregroundStyle(LiftTheme.inkSecondary)
          .multilineTextAlignment(.trailing)
      }
    }
  }

  private var workspaceCloseButton: some View {
    Button(action: onDismiss) {
      Image(systemName: "chevron.down")
        .frame(width: 44, height: 44)
    }
    .buttonStyle(ReceiptIconButtonStyle())
    .accessibilityLabel("Close workout")
  }

  @ViewBuilder
  private func queueSection(
    title: String,
    rows: [LiftWorkoutQueueRowState],
    isPrinted: Bool
  ) -> some View {
    if !rows.isEmpty {
      ReceiptDashedRule()
      ReceiptSectionLabel(title: title)
      LazyVStack(alignment: .leading, spacing: 0) {
        ForEach(rows) { row in
          LiftWorkoutQueueActionRow(
            row: row,
            isPrinted: isPrinted,
            continuityNamespace: workspaceContinuityNamespace,
            onSelect: { selectComposer(row.id) },
            onSetDone: { isDone in setExerciseDone(row.id, isDone: isDone) }
          )

          if row.id != rows.last?.id {
            ReceiptDashedRule()
          }
        }
      }
    }
  }

  private var emptyQueue: some View {
    VStack(alignment: .leading, spacing: 8) {
      VStack(alignment: .leading, spacing: 8) {
        ReceiptSectionLabel(title: "Current Exercise")
        Text("NO EXERCISES ON THIS RECEIPT.")
          .font(.receipt(12, weight: .black))
          .foregroundStyle(LiftTheme.ink)
        Text("ADD ONLY THE MOVEMENTS YOU PLAN TO LOG.")
          .font(.receipt(10, weight: .bold))
          .foregroundStyle(LiftTheme.inkSecondary)
      }
      .accessibilityElement(children: .combine)

      ReceiptPrimaryButton(
        title: "Add Exercise",
        systemImage: "plus",
        tint: LiftTheme.ink,
        action: presentExercisePicker
      )
    }
  }

  private var inactiveReceipt: some View {
    ReceiptSheet {
      ReceiptHeader(title: "Workout Closed", subtitle: "Return to Today to begin")
      ReceiptDashedRule()
      ReceiptSecondaryButton(
        title: "Close",
        systemImage: "chevron.down",
        tint: LiftTheme.ink,
        fillsWidth: true,
        action: onDismiss
      )
    }
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
      .font(.receipt(11, weight: .black))
      .foregroundStyle(LiftTheme.ink)
      .multilineTextAlignment(.center)
      .lineLimit(2)
      .minimumScaleFactor(0.72)
      .padding(.horizontal, 14)
      .frame(maxWidth: .infinity, minHeight: 44)
      .background(LiftTheme.paper)
      .overlay {
        RoundedRectangle(cornerRadius: 4, style: .continuous)
          .stroke(LiftTheme.ink, lineWidth: 1.5)
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
      Text("Elapsed")
        .font(.receipt(8, weight: .bold))
        .foregroundStyle(LiftTheme.inkSecondary)
      Text(timerInterval: startedAt...Date.distantFuture, countsDown: false)
        .font(.receipt(12, weight: .black))
        .monospacedDigit()
        .foregroundStyle(LiftTheme.ink)
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
    VStack(alignment: .leading, spacing: 13) {
      composerHeader
      ReceiptDashedRule()
      lastSetsLine
      setProgressLine
      loadReadout

      if LiftPlateLoaderEligibility.isEligible(exercise) {
        Button {
          showsPlateLoader = true
        } label: {
          HStack(spacing: 8) {
            Text("PLATE LOADER")
            Spacer(minLength: 0)
            Image(systemName: "scalemass")
          }
          .font(.receipt(10, weight: .black))
          .foregroundStyle(LiftTheme.ink)
          .padding(.horizontal, LiftDesignMetrics.Composer.plateLoaderHorizontalPadding)
          .frame(maxWidth: .infinity, minHeight: 44)
          .contentShape(Rectangle())
          .overlay(Rectangle().stroke(LiftTheme.ink, lineWidth: 1))
        }
        .buttonStyle(.plain)
        .accessibilityHint("Shows plates for the current composer weight")
      }

      VStack(spacing: 10) {
        ReceiptStepper(
          title: "Weight",
          value: liftLoad(weight, for: exercise).uppercased(),
          decrement: { weight = max(0, weight - 5) },
          increment: { weight += 5 },
          decrementLarge: { weight = max(0, weight - 25) },
          incrementLarge: { weight += 25 }
        )
        ReceiptStepper(
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

      ReceiptPrimaryButton(
        title: "Log Set",
        systemImage: "plus",
        tint: LiftTheme.ink,
        action: logCurrentSet
      )
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
      .presentationDetents([.height(340)])
      .presentationDragIndicator(.visible)
    }
    .sheet(isPresented: $showsPlateLoader) {
      PlateLoaderView(targetWeight: $weight, exercise: exercise)
        .presentationDetents([.height(360)])
        .presentationDragIndicator(.visible)
    }
  }

  private var composerHeader: some View {
    ViewThatFits(in: .horizontal) {
      HStack(alignment: .top, spacing: 12) {
        VStack(alignment: .leading, spacing: LiftDesignMetrics.Composer.restInlineSpacing) {
          composerIdentityAndTools
          composerInlineRest
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        composerArtwork
      }
      VStack(alignment: .leading, spacing: 10) {
        composerIdentityAndTools
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
      composerIdentity
      Spacer(minLength: 4)
      composerToolsMenu
    }
  }

  private var composerIdentity: some View {
    VStack(alignment: .leading, spacing: 5) {
      Text(String(format: "%02d / %02d", index + 1, max(store.activeExercises.count, 1)))
        .font(.receipt(LiftDesignMetrics.Composer.ordinalFontSize, weight: .bold))
        .foregroundStyle(LiftTheme.inkSecondary)
        .monospacedDigit()
      Text(exercise.name.uppercased())
        .font(.receipt(LiftDesignMetrics.Composer.nameFontSize, weight: .black))
        .foregroundStyle(LiftTheme.ink)
        .lineLimit(3)
        .minimumScaleFactor(0.72)
    }
  }

  @ViewBuilder
  private var composerArtwork: some View {
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

  private var composerToolsMenu: some View {
    Menu {
      Button("Recent History", systemImage: "clock.arrow.circlepath") {
        onPresentHistory(exercise)
      }
      Button("Swap Exercise", systemImage: "arrow.triangle.2.circlepath") {
        onPresentSwap(exercise)
      }
      Button("Superset", systemImage: "link") {
        onPresentSuperset(exercise)
      }
    } label: {
      Image(systemName: "ellipsis")
        .font(.receipt(15, weight: .black))
        .foregroundStyle(LiftTheme.ink)
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
      Text("LAST")
        .font(.receipt(9, weight: .bold))
        .foregroundStyle(LiftTheme.inkSecondary)
      Text(lastSetsText)
        .font(.receipt(11, weight: .black))
        .foregroundStyle(savedWorkingSets.isEmpty ? LiftTheme.inkSecondary : LiftTheme.ink)
        .lineLimit(2)
        .minimumScaleFactor(0.68)
      Spacer(minLength: 0)
    }
    .accessibilityElement(children: .combine)
  }

  private var lastSetsText: String {
    guard !savedWorkingSets.isEmpty else { return "NO SAVED SETS" }
    return savedWorkingSets.map {
      "\(liftLoad($0.weight, for: exercise).uppercased()) × \($0.reps)"
    }
    .joined(separator: "   ")
  }

  private var setProgress: LiftSetProgress {
    store.setProgress(for: exercise.id)
  }

  private var setProgressLine: some View {
    Text(setProgressText)
      .font(.receipt(11, weight: .black))
      .foregroundStyle(LiftTheme.inkSecondary)
      .monospacedDigit()
  }

  private var setProgressText: String {
    guard let target = setProgress.target else {
      return "SET \(setProgress.completed + 1)"
    }
    return "SET \(min(setProgress.completed + 1, target)) OF \(target)"
  }

  private var loadReadout: some View {
    ViewThatFits(in: .horizontal) {
      loadReadoutLine(
        loadSize: LiftDesignMetrics.Composer.loadFontSize,
        multiplierSize: LiftDesignMetrics.Composer.multiplierFontSize
      )
      loadReadoutLine(loadSize: 34, multiplierSize: 26)
    }
    .foregroundStyle(LiftTheme.ink)
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
      Text(liftLoad(weight, for: exercise).uppercased())
        .font(.receipt(loadSize, weight: .black))
        .contentTransition(.numericText())
        .minimumScaleFactor(0.62)
      Text("×")
        .font(.receipt(multiplierSize, weight: .black))
        .foregroundStyle(LiftTheme.inkSecondary)
      Text("\(reps)")
        .font(.receipt(loadSize, weight: .black))
        .monospacedDigit()
        .contentTransition(.numericText())
      Spacer(minLength: 0)
    }
  }

  private var effortEditor: some View {
    VStack(spacing: 8) {
      Button {
        isEffortExpanded.toggle()
      } label: {
        HStack(spacing: 8) {
          Text("EFFORT")
          Spacer()
          Text(rpe.formatted(.number.precision(.fractionLength(0))))
            .monospacedDigit()
          Image(systemName: isEffortExpanded ? "chevron.up" : "chevron.right")
        }
        .font(.receipt(11, weight: .black))
        .foregroundStyle(LiftTheme.ink)
        .frame(minHeight: 44)
        .contentShape(Rectangle())
      }
      .buttonStyle(.plain)
      .accessibilityLabel("Effort \(Int(rpe))")
      .accessibilityHint(isEffortExpanded ? "Collapses effort choices" : "Expands effort choices")

      if isEffortExpanded {
        HStack(spacing: 6) {
          ForEach(6...10, id: \.self) { effort in
            Button {
              rpe = Double(effort)
            } label: {
              Text("\(effort)")
                .font(.receipt(11, weight: .black))
                .foregroundStyle(Int(rpe) == effort ? LiftTheme.paper : LiftTheme.ink)
                .frame(maxWidth: .infinity, minHeight: 44)
                .background(
                  Int(rpe) == effort ? LiftTheme.ink : LiftTheme.ink.opacity(0.06),
                  in: RoundedRectangle(cornerRadius: 4, style: .continuous)
                )
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Effort \(effort)")
          }
        }
      }
    }
  }

  private var warmupChip: some View {
    Button {
      isWarmup.toggle()
    } label: {
      HStack(spacing: 8) {
        Image(systemName: isWarmup ? "checkmark.square.fill" : "square")
        Text("WARM-UP")
        Spacer(minLength: 0)
      }
      .font(.receipt(11, weight: .black))
      .foregroundStyle(isWarmup ? LiftTheme.ink : LiftTheme.inkSecondary)
      .padding(.horizontal, LiftDesignMetrics.Composer.warmupChipHorizontalPadding)
      .frame(maxWidth: .infinity, minHeight: 44)
      .contentShape(Rectangle())
      .overlay(
        RoundedRectangle(cornerRadius: 4, style: .continuous)
          .stroke((isWarmup ? LiftTheme.ink : LiftTheme.inkSecondary).opacity(0.42), lineWidth: 1)
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
        Text("WARM-UP?")
        Spacer(minLength: 0)
        Image(systemName: "chevron.right")
      }
      .font(.receipt(11, weight: .black))
      .foregroundStyle(LiftTheme.ink)
      .frame(maxWidth: .infinity, minHeight: 44)
      .contentShape(Rectangle())
    }
    .buttonStyle(.plain)
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
    ScrollView {
      ReceiptSheet {
        HStack(alignment: .top, spacing: 8) {
          ReceiptHeader(title: "Warm-Up?", subtitle: exercise.name)
          Spacer(minLength: 8)
          Button { dismiss() } label: {
            Image(systemName: "xmark")
              .frame(width: 44, height: 44)
          }
          .buttonStyle(ReceiptIconButtonStyle())
          .accessibilityLabel("Close warm-up suggestion")
        }

        ReceiptDashedRule()
        Text(plan.title.uppercased())
          .font(.receipt(12, weight: .black))
          .foregroundStyle(LiftTheme.ink)
        Text(plan.reason.uppercased())
          .font(.receipt(10, weight: .bold))
          .foregroundStyle(LiftTheme.inkSecondary)
          .fixedSize(horizontal: false, vertical: true)

        if plan.hasSets {
          ReceiptDashedRule()
          ForEach(plan.sets) { set in
            WarmupSuggestionRow(set: set, exercise: exercise) {
              weight = set.weight
              reps = set.reps
              isWarmup = true
              dismiss()
            }
            if set.id != plan.sets.last?.id {
              ReceiptDashedRule()
            }
          }
        } else {
          ReceiptDashedRule()
          Text("NO LOADED RAMP NEEDED.")
            .font(.receipt(10, weight: .black))
            .foregroundStyle(LiftTheme.inkSecondary)
            .frame(minHeight: 44)
        }
      }
    }
    .scrollIndicators(.hidden)
    .liftScreenBackground()
  }
}

private struct WarmupSuggestionRow: View {
  let set: LiftWarmupSet
  let exercise: LiftExercise
  let onUse: () -> Void

  var body: some View {
    Button(action: onUse) {
      ReceiptLine(
        index: set.sequence,
        title: "\(liftLoad(set.weight, for: exercise).uppercased()) × \(set.reps)",
        detail: rowSubtitle,
        value: "Use"
      )
      .frame(minHeight: 44)
      .contentShape(Rectangle())
    }
    .buttonStyle(.plain)
    .accessibilityLabel(
      "Use warm-up set \(set.sequence), \(liftLoad(set.weight, for: exercise)), \(set.reps) reps"
    )
  }

  private var rowSubtitle: String {
    if let percent = set.percent {
      return "\(Int((percent * 100).rounded()))% / \(set.note.uppercased())"
    }
    return set.note.uppercased()
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
    ScrollView {
      ReceiptSheet {
        HStack(alignment: .top, spacing: 8) {
          ReceiptHeader(title: "Superset", subtitle: exercise.name)
          Spacer(minLength: 8)
          Button { dismiss() } label: {
            Image(systemName: "xmark")
              .frame(width: 44, height: 44)
          }
          .buttonStyle(ReceiptIconButtonStyle())
          .accessibilityLabel("Close superset pairing")
        }

        ReceiptDashedRule()
        if let label = store.supersetLabel(for: exercise.id) {
          HStack(spacing: 10) {
            Text(label.uppercased())
              .font(.receipt(9, weight: .black))
              .foregroundStyle(LiftTheme.paper)
              .padding(.horizontal, 8)
              .frame(minHeight: 30)
              .background(LiftTheme.ink, in: Capsule())
            Text(currentPartnerText.uppercased())
              .font(.receipt(10, weight: .black))
              .foregroundStyle(LiftTheme.ink)
            Spacer(minLength: 0)
          }
          ReceiptSecondaryButton(
            title: "Clear Pairing",
            systemImage: "xmark",
            tint: LiftTheme.ink,
            fillsWidth: true
          ) {
            store.clearSuperset(for: exercise.id)
            dismiss()
          }
          ReceiptDashedRule()
        }

        if candidates.isEmpty {
          Text("ADD ANOTHER ACTIVE EXERCISE TO MAKE A SUPERSET.")
            .font(.receipt(10, weight: .black))
            .foregroundStyle(LiftTheme.inkSecondary)
            .frame(minHeight: 44)
        } else {
          ForEach(candidates) { candidate in
            Button {
              store.setSuperset(exercise.id, with: candidate.id)
              dismiss()
            } label: {
              ReceiptLine(
                index: candidateOrdinal(candidate),
                title: candidate.name,
                detail: store.supersetLabel(for: candidate.id) ?? "Pair for this workout",
                value: "Pair",
                thumb: candidate
              )
              .frame(minHeight: 44)
              .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Pair \(exercise.name) with \(candidate.name)")
            if candidate.id != candidates.last?.id {
              ReceiptDashedRule()
            }
          }
        }
      }
    }
    .scrollIndicators(.hidden)
    .liftScreenBackground()
  }

  private var currentPartnerText: String {
    let names = store.supersetPartners(for: exercise.id).map(\.name)
    return names.isEmpty ? "No current partner" : "With " + names.joined(separator: " + ")
  }

  private func candidateOrdinal(_ candidate: LiftExercise) -> Int {
    (store.activeExercises.firstIndex { $0.id == candidate.id } ?? 0) + 1
  }
}
