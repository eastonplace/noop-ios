import Foundation
import Testing
@testable import ReceiptLiftFeature

@Suite("THIS WEEK summary")
struct LiftWeekSummaryTests {
  private func calendar(firstWeekday: Int) -> Calendar {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = TimeZone(identifier: "UTC")!
    calendar.firstWeekday = firstWeekday
    return calendar
  }

  /// Wednesday 2026-10-21 12:00 UTC.
  private let wednesday = Date(timeIntervalSince1970: 1_792_584_000)

  private func session(_ date: Date, sets: Int) -> LiftSession {
    let exercise = UUID()
    let logged = (1...max(sets, 1)).map {
      LiftSet(
        id: UUID(), exerciseID: exercise, setNumber: $0, weight: 100, reps: 10, rpe: 8, isWarmup: false,
        completedAt: date.addingTimeInterval(Double($0) * 120), notes: "")
    }
    return LiftSession(
      id: UUID(), routineID: nil, title: "Lift", startedAt: date, endedAt: date.addingTimeInterval(3_000),
      sets: sets == 0 ? [] : logged)
  }

  @Test func weekStartsWhereTheCalendarSays() {
    let sunday = LiftTodayMath.weekSummary(in: [], scheduled: [], asOf: wednesday, calendar: calendar(firstWeekday: 1))
    let monday = LiftTodayMath.weekSummary(in: [], scheduled: [], asOf: wednesday, calendar: calendar(firstWeekday: 2))
    let cal1 = calendar(firstWeekday: 1), cal2 = calendar(firstWeekday: 2)
    #expect(cal1.component(.weekday, from: sunday.interval.start) == 1)
    #expect(cal2.component(.weekday, from: monday.interval.start) == 2)
    #expect(sunday.interval.duration == 7 * 86_400)
  }

  @Test func countsOnlyThisWeekAndComparesWithLast() {
    let cal = calendar(firstWeekday: 2)
    let thisWeek = [
      session(wednesday.addingTimeInterval(-86_400), sets: 5),
      session(wednesday.addingTimeInterval(-2 * 86_400 + 3_600), sets: 4),
    ]
    let lastWeek = [session(wednesday.addingTimeInterval(-7 * 86_400), sets: 6)]
    let summary = LiftTodayMath.weekSummary(in: thisWeek + lastWeek, scheduled: [], asOf: wednesday, calendar: cal)
    #expect(summary.workouts == 2)
    #expect(summary.workingSets == 9)
    #expect(summary.workingSetsDeltaVsLastWeek == 3)
    #expect(summary.volume > 0)
  }

  @Test func plannedCountsScheduledWorkoutsInTheWeek() {
    let cal = calendar(firstWeekday: 2)
    let scheduled = [
      ScheduledWorkout(id: UUID(), routineID: UUID(), plannedAt: wednesday.addingTimeInterval(86_400), note: "", completedSessionID: nil),
      ScheduledWorkout(id: UUID(), routineID: UUID(), plannedAt: wednesday.addingTimeInterval(10 * 86_400), note: "", completedSessionID: nil),
    ]
    let summary = LiftTodayMath.weekSummary(in: [], scheduled: scheduled, asOf: wednesday, calendar: cal)
    #expect(summary.plannedThisWeek == 1)
  }

  @Test func nextWeekMidnightBelongsOnlyToTheNextWeek() throws {
    let cal = calendar(firstWeekday: 2)
    let interval = try #require(cal.dateInterval(of: .weekOfYear, for: wednesday))
    let boundary = interval.end
    let workout = session(boundary, sets: 4)
    let planned = ScheduledWorkout(id: UUID(), routineID: UUID(), plannedAt: boundary, note: "", completedSessionID: nil)
    let before = LiftTodayMath.weekSummary(in: [workout], scheduled: [planned], asOf: wednesday, calendar: cal)
    #expect(before.workouts == 0)
    #expect(before.workingSets == 0)
    #expect(before.plannedThisWeek == 0)
    let after = LiftTodayMath.weekSummary(in: [workout], scheduled: [planned], asOf: boundary, calendar: cal)
    #expect(after.workouts == 1)
    #expect(after.workingSetsDeltaVsLastWeek == 4)
    #expect(after.plannedThisWeek == 1)
  }

  @Test func daylightSavingWeekUsesItsCalendarEnd() throws {
    var cal = calendar(firstWeekday: 2)
    cal.timeZone = try #require(TimeZone(identifier: "America/New_York"))
    let date = try #require(cal.date(from: DateComponents(year: 2026, month: 3, day: 5, hour: 12)))
    let interval = try #require(cal.dateInterval(of: .weekOfYear, for: date))
    #expect(interval.duration == 7 * 86_400 - 3_600)
    let summary = LiftTodayMath.weekSummary(in: [session(interval.start, sets: 2), session(interval.end, sets: 7)],
        scheduled: [], asOf: date, calendar: cal)
    #expect(summary.workouts == 1)
    #expect(summary.workingSets == 2)
  }
}
