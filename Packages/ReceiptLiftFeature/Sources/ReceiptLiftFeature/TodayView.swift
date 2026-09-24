import SwiftUI

struct LiftSevenDaySummary: Equatable, Sendable {
  let workoutCount: Int
  let workingSetCount: Int
  let volume: Double

  static let zero = LiftSevenDaySummary(workoutCount: 0, workingSetCount: 0, volume: 0)
}

enum LiftTodayMath {
  nonisolated static func sevenDaySummary(
    in sessions: [LiftSession],
    asOf date: Date,
    calendar: Calendar
  ) -> LiftSevenDaySummary {
    let start = calendar.date(byAdding: .day, value: -7, to: date) ?? date
    var workoutCount = 0
    var workingSetCount = 0
    var volume = 0.0

    for session in sessions where session.endedAt != nil
      && session.startedAt >= start
      && session.startedAt <= date {
      workoutCount += 1
      for set in session.sets {
        volume += set.volume
        if !set.isWarmup {
          workingSetCount += 1
        }
      }
    }

    return LiftSevenDaySummary(
      workoutCount: workoutCount,
      workingSetCount: workingSetCount,
      volume: volume
    )
  }

  nonisolated static func recentCompletedSessions(
    in sessions: [LiftSession],
    limit: Int
  ) -> [LiftSession] {
    guard limit > 0 else { return [] }
    var recent: [LiftSession] = []
    recent.reserveCapacity(min(limit, sessions.count))

    for session in sessions where session.endedAt != nil {
      let insertionIndex = recent.firstIndex { candidate in
        isMoreRecent(session, than: candidate)
      } ?? recent.endIndex
      recent.insert(session, at: insertionIndex)
      if recent.count > limit {
        recent.removeLast()
      }
    }

    return recent
  }

  private nonisolated static func isMoreRecent(
    _ lhs: LiftSession,
    than rhs: LiftSession
  ) -> Bool {
    if lhs.startedAt != rhs.startedAt { return lhs.startedAt > rhs.startedAt }
    return lhs.id.uuidString < rhs.id.uuidString
  }
}

struct TodayView: View {
  @EnvironmentObject private var store: LiftStore
  let onStartRoutine: (LiftRoutine) -> Void
  let onOpenLift: () -> Void
  let onResumeWorkout: () -> Void
  @State private var showsSettings = false

  private var recentSessions: [LiftSession] {
    LiftTodayMath.recentCompletedSessions(in: store.sessions, limit: 3)
  }

  var body: some View {
    ScrollView {
      ReceiptSheet {
        header
        ReceiptDashedRule()
        if let session = store.activeSession {
          activeBlock(session)
        } else {
          nextWorkoutBlock
        }
        ReceiptDashedRule()
        thisWeekBlock
        ReceiptDashedRule()
        recentBlock
      }
      .padding(.bottom, 72)
    }
    .scrollIndicators(.hidden)
    .sheet(isPresented: $showsSettings) {
      SettingsView()
        .environmentObject(store)
        .presentationDetents([.large])
    }
  }

  private var header: some View {
    HStack(alignment: .top, spacing: 12) {
      ReceiptHeader(
        title: "Lift",
        subtitle: Date().formatted(.dateTime.weekday(.wide).month(.abbreviated).day()).uppercased()
      )
      Spacer(minLength: 8)
      Button { showsSettings = true } label: {
        Image(systemName: "gearshape")
          .frame(width: 44, height: 44)
      }
      .buttonStyle(ReceiptIconButtonStyle())
      .accessibilityLabel("Settings")
    }
  }

  private var nextWorkoutBlock: some View {
    VStack(alignment: .leading, spacing: 10) {
      ReceiptSectionLabel(title: "Next Workout")
      if let routine = store.nextSuggestedRoutine {
        ReceiptLine(
          index: 1,
          title: routine.name,
          detail: "~\(max(routine.exerciseIDs.count * 8, 20)) min · \(routine.exerciseIDs.count) exercises",
          value: "→"
        )
        ReceiptPrimaryButton(title: "Start Workout", systemImage: "play.fill") {
          onStartRoutine(routine)
        }
      } else {
        ReceiptLine(index: 1, title: "Open Lift", detail: "No routine selected", value: "→")
      }
      Button("OPEN LIFT", action: onOpenLift)
        .frame(minHeight: 44)
        .font(.receipt(10, weight: .bold))
        .foregroundStyle(LiftTheme.inkSecondary)
        .frame(maxWidth: .infinity)
        .buttonStyle(.plain)
    }
  }

  private func activeBlock(_ session: LiftSession) -> some View {
    let progress = store.activeRoutineProgress()
    return VStack(alignment: .leading, spacing: 10) {
      ReceiptSectionLabel(title: "Active Receipt")
      ReceiptLine(index: 1, title: session.title, detail: "Workout in progress", value: progress?.setLabel ?? "0/0")
      HStack {
        Text("ELAPSED")
          .font(.receipt(9, weight: .bold))
          .foregroundStyle(LiftTheme.inkSecondary)
        Spacer()
        Text(timerInterval: session.startedAt...Date.distantFuture, countsDown: false)
          .font(.receipt(12, weight: .black))
          .monospacedDigit()
      }
      ReceiptPrimaryButton(title: "Resume", systemImage: "arrow.up.right") {
        onResumeWorkout()
      }
    }
  }

  private var thisWeekBlock: some View {
    let summary = LiftTodayMath.sevenDaySummary(
      in: store.sessions,
      asOf: Date(),
      calendar: .current
    )

    return VStack(alignment: .leading, spacing: 10) {
      ReceiptSectionLabel(title: "This Week")
      HStack(spacing: 12) {
        ReceiptMetric(title: "Workouts", value: "\(summary.workoutCount)")
        ReceiptMetric(title: "Sets", value: "\(summary.workingSetCount)")
        ReceiptMetric(title: "Volume", value: liftVolume(summary.volume))
      }
    }
  }

  private var recentBlock: some View {
    VStack(alignment: .leading, spacing: 10) {
      ReceiptSectionLabel(title: "Recent")
      if recentSessions.isEmpty {
        Text("NO RECEIPTS YET.")
          .font(.receipt(11, weight: .bold))
          .foregroundStyle(LiftTheme.inkSecondary)
      } else {
        ForEach(Array(recentSessions.enumerated()), id: \.element.id) { index, session in
          NavigationLink {
            CompletedReceiptView(session: session, presentation: .settled)
          } label: {
            ReceiptLine(
              index: index + 1,
              title: session.title,
              detail: session.startedAt.formatted(.dateTime.month(.abbreviated).day()),
              value: "\(liftDuration((session.endedAt ?? session.startedAt).timeIntervalSince(session.startedAt))) →"
            )
          }
          .buttonStyle(.plain)
        }
      }
    }
  }
}
