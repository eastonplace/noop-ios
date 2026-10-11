import SwiftUI
import StrandDesign

enum LiftTab: String, CaseIterable, Identifiable {
  case today
  case history
  case progress
  case schedule

  var id: String { rawValue }

  var title: String {
    switch self {
    case .today: "Today"
    case .history: "History"
    case .progress: "Progress"
    case .schedule: "Schedule"
    }
  }

  var systemImage: String {
    switch self {
    case .today: "house.fill"
    case .history: "list.bullet.rectangle"
    case .progress: "chart.xyaxis.line"
    case .schedule: "calendar"
    }
  }
}

public enum LiftDestination: String, Identifiable {
  case start, history, progress, routines
  public var id: String { rawValue }
}

/// Whether the Lift start screen should open an active session's workout by itself. Reopening Lift after a
/// relaunch used to land on a picker whose "Resume active lift" button needed a second tap. It is one-shot per
/// presentation, so a deliberate dismissal of the workout is never undone.
enum LiftAutoResumePolicy {
  static func shouldResume(
    destination: LiftDestination,
    hasActiveSession: Bool,
    alreadyAutoResumed: Bool
  ) -> Bool {
    destination == .start && hasActiveSession && !alreadyAutoResumed
  }
}

struct LiftRootView: View {
  let destination: LiftDestination
  init(destination: LiftDestination = .start) { self.destination = destination }
  @EnvironmentObject private var store: LiftStore
  @Environment(\.liftHostChrome) private var host
  @State private var showsCompletedHistory = false
  @State private var showsSettings = false
  @State private var previewRoutine: LiftRoutine?
  @State private var isWorkoutPresented = false
  @State private var hasAutoResumed = false
  @State private var printedSession: LiftSession?
  @State private var selectedHistorySegment = LiftHistorySegment.receipts

  var body: some View {
    NavigationStack {
      Group {
        if showsCompletedHistory {
          HistoryView(selectedSegment: $selectedHistorySegment)
        } else {
          switch destination {
          case .start:
            workoutPicker
          case .history:
            HistoryView(selectedSegment: $selectedHistorySegment)
          case .progress:
            HistoryView(selectedSegment: .constant(.progress), progressOnly: true)
          case .routines:
            ScheduleView(onStartRoutine: presentPreview)
          }
        }
      }
      .navigationBarTitleDisplayMode(.inline)
      .toolbar(.hidden, for: .navigationBar)
      .liftScreenBackground()
      .navigationDestination(isPresented: previewPresentation) {
        if let routine = previewRoutine {
          RoutinePreviewView(
            routine: routine,
            onBegin: { beginPreviewedRoutine(routine) },
            onCancel: { previewRoutine = nil }
          )
          .environmentObject(store)
        }
      }
    }
    .sheet(isPresented: $showsSettings) { SettingsView().environmentObject(store) }
    .tint(LiftTheme.accent)
    .task { await autoResumeActiveSessionIfNeeded() }
    .liftQAScene("routine-preview") {
      previewRoutine = store.routines.first { $0.name == "Upper A" } ?? store.routines.first
    }
    .liftQAScene("settings") { showsSettings = true }
    .liftQAScene("receipt") {
      printedSession = store.sessions.filter { $0.endedAt != nil }.max { $0.startedAt < $1.startedAt }
    }
    .fullScreenCover(isPresented: workoutPresentation) {
      LiveWorkoutView(
        onDismiss: { isWorkoutPresented = false },
        onSessionSaved: { session in
          isWorkoutPresented = false
          showsCompletedHistory = true
          printedSession = session
        }
      )
      .environmentObject(store)
    }
    .fullScreenCover(item: $printedSession) { session in
      CompletedReceiptView(
        session: session,
        presentation: .freshlyCompleted,
        onClose: { printedSession = nil },
        onViewReceipts: {
          printedSession = nil
          showsCompletedHistory = true
        }
      )
      .environmentObject(store)
    }
  }

  private var workoutPicker: some View {
    LiftScreen(
      title: "Start a lift",
      subtitle: "Choose a routine or build your workout as you go.",
      backAction: host.onBack,
      trailing: {
        LiftHeaderTrailing {
          NoopIconButton("gearshape", accessibilityLabel: "Lift settings") { showsSettings = true }
        }
      }
    ) {
      if store.activeSession != nil {
        NoopButton("Resume active lift", systemImage: "play.fill", kind: .primary, fullWidth: true) {
          isWorkoutPresented = true
        }
      } else {
        NoopButton("Open workout", systemImage: "plus", kind: .primary, fullWidth: true, action: startOpenLift)
        LiftSection(title: "Your routines") {
          ForEach(store.routines) { routine in
            Button { presentPreview(routine) } label: {
              LiftRow(
                title: routine.name,
                detail: "\(routine.exerciseIDs.count) exercises · \(store.estimatedMinutes(for: routine)) min",
                showsChevron: true
              ) {
                Image(systemName: "dumbbell")
                  .font(.system(size: 16, weight: .semibold))
                  .foregroundStyle(LiftTheme.accent)
                  .frame(width: 28)
                  .accessibilityHidden(true)
              }
            }
            .buttonStyle(.plain)
          }
        }
      }
    }
  }

  private func autoResumeActiveSessionIfNeeded() async {
    func shouldResume() -> Bool {
      LiftAutoResumePolicy.shouldResume(
        destination: destination,
        hasActiveSession: store.activeSession != nil,
        alreadyAutoResumed: hasAutoResumed
      )
    }
    guard shouldResume() else { return }
    // This view usually appears inside a sheet that is still sliding in; a cover presented during that
    // transition can be dropped by UIKit, so let the sheet settle first.
    try? await Task.sleep(for: .milliseconds(400))
    guard !Task.isCancelled, shouldResume() else { return }
    hasAutoResumed = true
    isWorkoutPresented = true
  }

  private func presentPreview(_ routine: LiftRoutine) {
    guard store.activeSession == nil, !isWorkoutPresented else { return }
    previewRoutine = routine
  }

  private func beginPreviewedRoutine(_ routine: LiftRoutine) {
    guard previewRoutine?.id == routine.id,
          !isWorkoutPresented,
          store.activeSession == nil
    else { return }
    previewRoutine = nil
    store.startRoutine(routine)
    isWorkoutPresented = store.activeSession != nil
  }

  private func startOpenLift() {
    guard !isWorkoutPresented, store.activeSession == nil else { return }
    previewRoutine = nil
    store.startRoutine(nil)
    isWorkoutPresented = store.activeSession != nil
  }

  private var previewPresentation: Binding<Bool> {
    Binding(
      get: { previewRoutine != nil },
      set: { presented in
        if !presented {
          previewRoutine = nil
        }
      }
    )
  }

  private var workoutPresentation: Binding<Bool> {
    Binding(
      get: { isWorkoutPresented && store.activeSession != nil },
      set: { presented in
        if !presented {
          isWorkoutPresented = false
        }
      }
    )
  }
}
