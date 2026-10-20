import Foundation
import Testing
@testable import ReceiptLiftFeature

@Suite("Strength home logic")
@MainActor
struct LiftStrengthHomeLogicTests {
  private var calendar: Calendar {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = TimeZone(identifier: "UTC")!
    return calendar
  }

  private let now = Date(timeIntervalSince1970: 1_792_584_000)

  private func finished(_ routineID: UUID?, daysAgo: Int) -> LiftSession {
    let start = now.addingTimeInterval(-Double(daysAgo) * 86_400)
    return LiftSession(id: UUID(), routineID: routineID, title: "Lift", startedAt: start, endedAt: start.addingTimeInterval(3_000), sets: [])
  }

  @Test func lastDoneCountsWholeDays() {
    let routine = UUID()
    #expect(LiftHomeLogic.daysSinceLastDone(routineID: routine, in: [finished(routine, daysAgo: 6)], now: now, calendar: calendar) == 6)
    #expect(LiftHomeLogic.daysSinceLastDone(routineID: routine, in: [finished(routine, daysAgo: 0)], now: now, calendar: calendar) == 0)
  }

  @Test func lastDoneUsesTheLatestAndIgnoresOtherRoutinesAndUnfinished() {
    let routine = UUID()
    let unfinished = LiftSession(id: UUID(), routineID: routine, title: "Open", startedAt: now, endedAt: nil, sets: [])
    let sessions = [finished(routine, daysAgo: 9), finished(routine, daysAgo: 4), finished(UUID(), daysAgo: 1), unfinished]
    #expect(LiftHomeLogic.daysSinceLastDone(routineID: routine, in: sessions, now: now, calendar: calendar) == 4)
    #expect(LiftHomeLogic.daysSinceLastDone(routineID: UUID(), in: [], now: now, calendar: calendar) == nil)
  }

  @Test func startingLoggingAndFinishingNeverChangeTheRoutine() async throws {
    let exercise = LiftWorkoutLogicTests.exercise("Home Press")
    let plan = LiftWorkoutLogicTests.plan(exercise.id, sets: "3", rest: "90 s")
    let routine = LiftRoutine(
      id: UUID(), name: "Push day", notes: "keep", trainingMode: .strength, exerciseIDs: [exercise.id], exercisePlans: [plan])
    let fixture = try await LiftWorkoutLogicTests.fixture(exercises: [exercise], routines: [routine])
    defer { fixture.remove() }
    let store = fixture.store
    let before = store.routines

    store.startRoutine(routine)
    store.logSet(exercise: exercise, weight: 100, reps: 8, rpe: 8, isWarmup: false)
    _ = await store.finishActiveSessionDurably()

    #expect(store.routines == before)
  }

  @Test func loggingStoresTheRatedFlagAndDefaultsToNil() async throws {
    let exercise = LiftWorkoutLogicTests.exercise("Rated Press")
    let active = LiftSession(id: UUID(), routineID: nil, title: "Open", startedAt: Date(), endedAt: nil, sets: [])
    let fixture = try await LiftWorkoutLogicTests.fixture(exercises: [exercise], activeSession: active, activeIDs: [exercise.id])
    defer { fixture.remove() }
    let store = fixture.store

    store.logSet(exercise: exercise, weight: 100, reps: 8, rpe: 8.5, isWarmup: false, effortRated: true)
    store.logSet(exercise: exercise, weight: 100, reps: 8, rpe: 8, isWarmup: false)

    let sets = store.activeSession?.sets ?? []
    #expect(sets.count == 2)
    #expect(sets[0].effortRated == true && sets[0].rpe == 8.5)
    #expect(sets[1].effortRated == nil)
  }
}
