import SwiftUI
import StrandDesign

public enum LiftDestination: String, Identifiable {
  case start, history, progress, routines
  public var id: String { rawValue }
}

/// The pages the start screen pushes: its chips lead to Lift's other pages without leaving the sheet.
enum LiftRoute: Hashable {
  case history, progress, routines, newRoutine
}

/// Which page sits at the root of Lift's stack and what is pushed over it. Showing the completed history swaps the root,
/// so whatever the start screen's chips had pushed has to go with it; otherwise "Workout history" on a receipt closes
/// onto the Schedule page that was open when the workout began.
struct LiftRootNavigation: Equatable {
  var path: [LiftRoute] = []
  var showsCompletedHistory = false

  mutating func showCompletedHistory() {
    path = []
    showsCompletedHistory = true
  }
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
    destination == .start && hasActiveSession && !alreadyAutoResumed && !suppressedByLaunchFlag
  }

  /// DEBUG `--noop-lift-no-auto-resume` keeps the home on screen with a lift in flight, so it can be captured.
  static var suppressedByLaunchFlag: Bool {
    #if DEBUG
    ProcessInfo.processInfo.arguments.contains("--noop-lift-no-auto-resume")
    #else
    false
    #endif
  }
}

struct LiftRootView: View {
  let destination: LiftDestination
  init(destination: LiftDestination = .start) { self.destination = destination }
  @EnvironmentObject private var store: LiftStore
  @State private var navigation = LiftRootNavigation()
  @State private var showsSettings = false
  @State private var previewRoutine: LiftRoutine?
  @State private var isWorkoutPresented = false
  @State private var hasAutoResumed = false
  @State private var printedSession: LiftSession?
  @State private var selectedHistorySegment = LiftHistorySegment.receipts
  #if DEBUG
  @State private var qaReceipt: LiftQAReceiptRequest?
  #endif

  var body: some View {
    NavigationStack(path: $navigation.path) {
      rootPage
        .environment(\.liftScreenRole, .root)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar(.hidden, for: .navigationBar)
        .background(StrandPalette.appCanvas.ignoresSafeArea())
        .navigationDestination(for: LiftRoute.self) { route in
          switch route {
          case .history: HistoryView(selectedSegment: $selectedHistorySegment)
          case .progress: HistoryView(selectedSegment: .constant(.progress), progressOnly: true)
          case .routines: ScheduleView(onStartRoutine: presentPreview)
          case .newRoutine: ScheduleView(onStartRoutine: presentPreview, createsRoutine: true)
          }
        }
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
    // Everything the root pushes is a pushed page; the root page opts back in above.
    .environment(\.liftScreenRole, .pushed)
    .sheet(isPresented: $showsSettings) { SettingsView().environmentObject(store) }
    .tint(StrandPalette.accent)
    .task { await autoResumeActiveSessionIfNeeded() }
    .liftQAScene("routine-preview") {
      previewRoutine = store.routines.first { $0.name == "Upper A" } ?? store.routines.first
    }
    .liftQAScene("settings") { showsSettings = true }
    #if DEBUG
    .liftQAScene("receipt", "receipt-export-white", "receipt-export-cream") {
      qaReceipt = latestCompleted.map { LiftQAReceiptRequest(session: $0, presentation: .freshlyCompleted) }
    }
    .liftQAScene("receipt-settled") {
      qaReceipt = latestCompleted.map { LiftQAReceiptRequest(session: $0, presentation: .settled) }
    }
    .liftQAScene("summary") { printedSession = latestCompleted }
    #endif
    .fullScreenCover(isPresented: workoutPresentation) {
      LiveWorkoutView(
        onDismiss: { isWorkoutPresented = false },
        onSessionSaved: { session in
          isWorkoutPresented = false
          navigation.showCompletedHistory()
          printedSession = session
        }
      )
      .environmentObject(store)
    }
    .fullScreenCover(item: $printedSession) { session in
      NavigationStack {
        LiftSessionSummaryView(
          session: session,
          context: .freshlyCompleted,
          onClose: { printedSession = nil },
          onViewReceipts: {
            printedSession = nil
            navigation.showCompletedHistory()
          }
        )
      }
      .environmentObject(store)
    }
    #if DEBUG
    .fullScreenCover(item: $qaReceipt) { request in
      CompletedReceiptView(
        session: request.session,
        presentation: request.presentation,
        onClose: { qaReceipt = nil },
        onViewReceipts: { qaReceipt = nil }
      )
      .environmentObject(store)
    }
    #endif
  }

  #if DEBUG
  private var latestCompleted: LiftSession? {
    store.sessions.filter { $0.endedAt != nil }.max { $0.startedAt < $1.startedAt }
  }
  #endif

  @ViewBuilder private var rootPage: some View {
    if navigation.showsCompletedHistory {
      HistoryView(selectedSegment: $selectedHistorySegment)
    } else {
      switch destination {
      case .start:
        LiftStartView(
          onOpenSettings: { showsSettings = true },
          onResume: { isWorkoutPresented = true },
          onStartOpen: startOpenLift,
          onStartRoutine: startRoutineNow,
          onPreview: presentPreview,
          onOpen: { navigation.path.append($0) }
        )
      case .history:
        HistoryView(selectedSegment: $selectedHistorySegment)
      case .progress:
        HistoryView(selectedSegment: .constant(.progress), progressOnly: true)
      case .routines:
        ScheduleView(onStartRoutine: presentPreview)
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

  /// "Start <routine>" on the home: the same start as the preview's Begin, without the page in between.
  private func startRoutineNow(_ routine: LiftRoutine) {
    guard !isWorkoutPresented, store.activeSession == nil else { return }
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

#if DEBUG
/// QA harness only: asks `LiftRootView` to present a receipt directly.
struct LiftQAReceiptRequest: Identifiable {
  let id = UUID()
  let session: LiftSession
  let presentation: LiftReceiptPresentation
}
#endif
