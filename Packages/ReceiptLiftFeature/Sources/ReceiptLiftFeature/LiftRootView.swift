import SwiftUI

enum LiftTab: String, CaseIterable, Identifiable {
  case today
  case history
  case schedule

  var id: String { rawValue }

  var title: String {
    switch self {
    case .today: "Today"
    case .history: "History"
    case .schedule: "Schedule"
    }
  }

  var systemImage: String {
    switch self {
    case .today: "house.fill"
    case .history: "list.bullet.rectangle"
    case .schedule: "calendar"
    }
  }
}

struct LiftRootView: View {
  @EnvironmentObject private var store: LiftStore
  @State private var selectedTab: LiftTab = .today
  @State private var previewRoutine: LiftRoutine?
  @State private var isWorkoutPresented = false
  @State private var printedSession: LiftSession?
  @State private var selectedHistorySegment = LiftHistorySegment.receipts

  var body: some View {
    NavigationStack {
      ZStack(alignment: .bottom) {
        Group {
          switch selectedTab {
          case .today:
            TodayView(
              onStartRoutine: presentPreview,
              onOpenLift: startOpenLift,
              onResumeWorkout: { isWorkoutPresented = true }
            )
          case .history:
            HistoryView(selectedSegment: $selectedHistorySegment)
          case .schedule:
            ScheduleView(onStartRoutine: presentPreview)
          }
        }
        .safeAreaPadding(.top, 8)
        .id(selectedTab)
        .transition(.asymmetric(
          insertion: .move(edge: .trailing).combined(with: .opacity),
          removal: .move(edge: .leading).combined(with: .opacity)
        ))

        TopSafeAreaScrim()
        ReceiptTabBar(selectedTab: $selectedTab)
          .ignoresSafeArea(.container, edges: .bottom)
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
    .tint(LiftTheme.accent)
    .fullScreenCover(isPresented: workoutPresentation) {
      LiveWorkoutView(
        onDismiss: { isWorkoutPresented = false },
        onSessionSaved: { session in
          isWorkoutPresented = false
          selectedTab = .history
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
          selectedTab = .history
        }
      )
      .environmentObject(store)
    }
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

private struct TopSafeAreaScrim: View {
  var body: some View {
    GeometryReader { proxy in
      VStack(spacing: 0) {
        LiftTheme.paper
          .frame(height: proxy.safeAreaInsets.top + 10)
          .overlay(alignment: .bottom) {
            LinearGradient(
              colors: [LiftTheme.paper.opacity(0), LiftTheme.paper],
              startPoint: .bottom,
              endPoint: .top
            )
            .frame(height: 16)
          }
          .ignoresSafeArea(edges: .top)
        Spacer()
      }
      .allowsHitTesting(false)
    }
  }
}
