import Foundation
import Testing
@testable import ReceiptLiftFeature

@Suite("Lift navigation shell logic")
struct LiftShellLogicTests {
  @Test func scheduledWorkoutTodayWins() throws {
    let today = Date(timeIntervalSince1970: 1_780_000_000)
    let routines = [Self.routine("First"), Self.routine("Scheduled")]
    let scheduled = ScheduledWorkout(
      id: UUID(), routineID: routines[1].id, plannedAt: today, note: "", completedSessionID: nil
    )

    let result = LiftStore.suggestedRoutine(
      routines: routines, scheduledWorkouts: [scheduled], sessions: [], on: today
    )

    #expect(result?.id == routines[1].id)
  }

  @Test func unfinishedRoutineThisWeekIsNextFallback() {
    let today = Date(timeIntervalSince1970: 1_780_000_000)
    let routines = [Self.routine("Finished"), Self.routine("Next")]
    let completed = LiftSession(
      id: UUID(), routineID: routines[0].id, title: routines[0].name,
      startedAt: today.addingTimeInterval(-86_400), endedAt: today, sets: []
    )

    let result = LiftStore.suggestedRoutine(
      routines: routines, scheduledWorkouts: [], sessions: [completed], on: today
    )

    #expect(result?.id == routines[1].id)
  }

  @Test func firstRoutineIsFinalFallback() {
    let today = Date(timeIntervalSince1970: 1_780_000_000)
    let routines = [Self.routine("First"), Self.routine("Second")]
    let sessions = routines.map {
      LiftSession(id: UUID(), routineID: $0.id, title: $0.name, startedAt: today, endedAt: today, sets: [])
    }

    #expect(
      LiftStore.suggestedRoutine(
        routines: routines, scheduledWorkouts: [], sessions: sessions, on: today
      )?.id == routines[0].id
    )
  }

  @Test func sevenDayWorkoutCountExcludesActiveAndOldSessions() {
    let today = Date(timeIntervalSince1970: 1_780_000_000)
    let sessions = [
      LiftSession(id: UUID(), routineID: nil, title: "Done", startedAt: today, endedAt: today, sets: []),
      LiftSession(id: UUID(), routineID: nil, title: "Active", startedAt: today, endedAt: nil, sets: []),
      LiftSession(id: UUID(), routineID: nil, title: "Old", startedAt: today.addingTimeInterval(-8 * 86_400), endedAt: today, sets: [])
    ]

    #expect(LiftStore.sevenDayWorkoutCount(in: sessions, asOf: today) == 1)
  }

  @Test func sevenDaySummaryUsesCompletedWindowAndWarmupSemantics() {
    let today = Date(timeIntervalSince1970: 1_780_000_000)
    let exerciseID = UUID()
    let warmup = Self.set(exerciseID: exerciseID, weight: 100, reps: 5, isWarmup: true)
    let working = Self.set(exerciseID: exerciseID, weight: 50, reps: 10, isWarmup: false)
    let sessions = [
      LiftSession(
        id: UUID(), routineID: nil, title: "Done", startedAt: today, endedAt: today,
        sets: [warmup, working]
      ),
      LiftSession(
        id: UUID(), routineID: nil, title: "Active", startedAt: today, endedAt: nil,
        sets: [working]
      ),
      LiftSession(
        id: UUID(), routineID: nil, title: "Old",
        startedAt: today.addingTimeInterval(-8 * 86_400), endedAt: today,
        sets: [working]
      ),
      LiftSession(
        id: UUID(), routineID: nil, title: "Future",
        startedAt: today.addingTimeInterval(86_400), endedAt: today.addingTimeInterval(86_500),
        sets: [working]
      )
    ]

    let summary = LiftTodayMath.sevenDaySummary(
      in: sessions,
      asOf: today,
      calendar: Calendar(identifier: .gregorian)
    )

    #expect(summary.workoutCount == 1)
    #expect(summary.workingSetCount == 1)
    #expect(summary.volume == 1_000)
  }

  @Test func recentCompletedSessionsUsesBoundedDeterministicOrdering() throws {
    let now = Date(timeIntervalSince1970: 1_780_000_000)
    let firstTieID = try #require(UUID(uuidString: "00000000-0000-4000-8000-000000000001"))
    let secondTieID = try #require(UUID(uuidString: "00000000-0000-4000-8000-000000000002"))
    let sessions = [
      LiftSession(
        id: UUID(), routineID: nil, title: "Old", startedAt: now.addingTimeInterval(-100),
        endedAt: now, sets: []
      ),
      LiftSession(
        id: secondTieID, routineID: nil, title: "Second Tie", startedAt: now,
        endedAt: now, sets: []
      ),
      LiftSession(
        id: UUID(), routineID: nil, title: "Active", startedAt: now.addingTimeInterval(1),
        endedAt: nil, sets: []
      ),
      LiftSession(
        id: firstTieID, routineID: nil, title: "First Tie", startedAt: now,
        endedAt: now, sets: []
      )
    ]

    let recent = LiftTodayMath.recentCompletedSessions(in: sessions, limit: 2)

    #expect(recent.map(\.id) == [firstTieID, secondTieID])
    #expect(LiftTodayMath.recentCompletedSessions(in: sessions, limit: 0).isEmpty)
  }

  private static func routine(_ name: String) -> LiftRoutine {
    LiftRoutine(id: UUID(), name: name, notes: "", trainingMode: .hypertrophy, exerciseIDs: [])
  }

  private static func set(
    exerciseID: UUID,
    weight: Double,
    reps: Int,
    isWarmup: Bool
  ) -> LiftSet {
    LiftSet(
      id: UUID(), exerciseID: exerciseID, setNumber: 1, weight: weight, reps: reps,
      rpe: 8, isWarmup: isWarmup, completedAt: Date(), notes: ""
    )
  }
}
