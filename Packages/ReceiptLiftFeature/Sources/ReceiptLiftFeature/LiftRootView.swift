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

struct LiftRootView: View {
  let destination: LiftDestination
  init(destination: LiftDestination = .start) { self.destination = destination }
  @EnvironmentObject private var store: LiftStore
  @State private var showsCompletedHistory = false
  @State private var showsSettings = false
  @State private var previewRoutine: LiftRoutine?
  @State private var isWorkoutPresented = false
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
    ScrollView {
      VStack(alignment: .leading, spacing: 20) {
        HStack {
          Text("Start a lift").font(.largeTitle.bold())
          Spacer()
          Button { showsSettings = true } label: {
            Image(systemName: "gearshape").frame(width: 44, height: 44)
          }.accessibilityLabel("Lift settings")
        }
        Text("Choose a routine or build your workout as you go.")
          .font(.subheadline).foregroundStyle(.secondary)
        if store.activeSession != nil {
          Button { isWorkoutPresented = true } label: {
            Label("Resume active lift", systemImage: "play.fill")
              .frame(maxWidth: .infinity, alignment: .leading).padding(18)
          }.buttonStyle(.borderedProminent).foregroundStyle(StrandPalette.onInk)
        } else {
          Button(action: startOpenLift) {
            Label("Open workout", systemImage: "plus")
              .frame(maxWidth: .infinity, alignment: .leading).padding(18)
          }.buttonStyle(.borderedProminent).foregroundStyle(StrandPalette.onInk)
          Text("YOUR ROUTINES").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
          ForEach(store.routines) { routine in
            Button { presentPreview(routine) } label: {
              HStack(spacing: 12) {
                Image(systemName: "dumbbell").foregroundStyle(LiftTheme.accent)
                VStack(alignment: .leading, spacing: 6) {
                  Text(routine.name).font(.headline)
                  Text("\(routine.exerciseIDs.count) exercises · \(store.estimatedMinutes(for: routine)) min")
                    .font(.subheadline).foregroundStyle(.secondary)
                }
                Spacer()
                Image(systemName: "chevron.right").foregroundStyle(.secondary)
              }.padding(18).frame(maxWidth: .infinity, alignment: .leading)
                .background(StrandPalette.card, in: RoundedRectangle(cornerRadius: 16))
            }.buttonStyle(.plain)
          }
        }
      }.padding(20)
    }.background(LiftTheme.paper)
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
