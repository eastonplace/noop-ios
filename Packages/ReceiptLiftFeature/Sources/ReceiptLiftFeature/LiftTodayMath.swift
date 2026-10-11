import StrandDesign
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
    LiftScreen(
      title: "Lift",
      subtitle: LocalizedStringKey(Date().formatted(.dateTime.weekday(.wide).month(.abbreviated).day())),
      bottomPadding: 72,
      trailing: {
        NoopIconButton("gearshape", accessibilityLabel: "Settings") { showsSettings = true }
      }
    ) {
      if let session = store.activeSession {
        activeBlock(session)
      } else {
        nextWorkoutBlock
      }
      thisWeekBlock
      recentBlock
    }
    .sheet(isPresented: $showsSettings) {
      SettingsView()
        .environmentObject(store)
        .presentationDetents([.large])
    }
  }

  private var nextWorkoutBlock: some View {
    LiftSection(title: "Next workout") {
      if let routine = store.nextSuggestedRoutine {
        LiftRow(
          title: routine.name,
          detail: "~\(max(routine.exerciseIDs.count * 8, 20)) min · \(routine.exerciseIDs.count) exercises"
        )
        NoopButton("Start workout", systemImage: "play.fill", kind: .primary, fullWidth: true) {
          onStartRoutine(routine)
        }
      } else {
        LiftRow(title: "Open Lift", detail: "No routine selected")
      }
      NoopButton("Open Lift", kind: .tertiary, fullWidth: true, action: onOpenLift)
    }
  }

  private func activeBlock(_ session: LiftSession) -> some View {
    let progress = store.activeRoutineProgress()
    return LiftSection(title: "Active workout") {
      LiftRow(
        title: session.title,
        detail: "Workout in progress",
        value: progress?.setLabel ?? "0/0"
      )
      HStack {
        Text("Elapsed").strandOverline()
        Spacer()
        Text(timerInterval: session.startedAt...Date.distantFuture, countsDown: false)
          .font(StrandFont.number(15))
          .foregroundStyle(StrandPalette.textPrimary)
      }
      NoopButton("Resume", systemImage: "arrow.up.right", kind: .primary, fullWidth: true) {
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

    return LiftSection(title: "This week") {
      HStack(spacing: 12) {
        LiftMetric(title: "Workouts", value: "\(summary.workoutCount)")
        LiftMetric(title: "Sets", value: "\(summary.workingSetCount)")
        LiftMetric(title: "Volume", value: liftVolume(summary.volume))
      }
    }
  }

  private var recentBlock: some View {
    LiftSection(title: "Recent") {
      if recentSessions.isEmpty {
        LiftEmptyNote(text: "No receipts yet.")
      } else {
        ForEach(recentSessions) { session in
          NavigationLink {
            CompletedReceiptView(session: session, presentation: .settled)
          } label: {
            LiftRow(
              title: session.title,
              detail: session.startedAt.formatted(.dateTime.month(.abbreviated).day()),
              value: liftDuration((session.endedAt ?? session.startedAt).timeIntervalSince(session.startedAt)),
              showsChevron: true
            )
          }
          .buttonStyle(.plain)
        }
      }
    }
  }
}
