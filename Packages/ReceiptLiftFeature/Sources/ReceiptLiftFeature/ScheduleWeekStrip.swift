import SwiftUI

struct LiftScheduleWeekDay: Identifiable, Equatable, Sendable {
  let date: Date
  let isTrained: Bool

  var id: Date { date }
}

enum LiftScheduleWeek {
  nonisolated static func days(
    containing referenceDate: Date,
    sessions: [LiftSession],
    calendar: Calendar
  ) -> [LiftScheduleWeekDay] {
    let start = calendar.dateInterval(of: .weekOfYear, for: referenceDate)?.start
      ?? calendar.startOfDay(for: referenceDate)
    let trainedDates = sessions.lazy
      .filter { $0.endedAt != nil }
      .map(\.startedAt)

    return (0..<7).compactMap { offset in
      guard let date = calendar.date(byAdding: .day, value: offset, to: start) else {
        return nil
      }
      return LiftScheduleWeekDay(
        date: date,
        isTrained: trainedDates.contains { calendar.isDate($0, inSameDayAs: date) }
      )
    }
  }

  nonisolated static func upcoming(
    _ workouts: [ScheduledWorkout],
    on selectedDay: Date,
    calendar: Calendar
  ) -> [ScheduledWorkout] {
    workouts.filter { calendar.isDate($0.plannedAt, inSameDayAs: selectedDay) }
  }
}

struct ScheduleWeekStrip: View {
  let sessions: [LiftSession]
  @Binding private var selectedDay: Date
  private let calendar: Calendar

  @Environment(\.accessibilityReduceMotion) private var reduceMotion
  @Namespace private var selectionNamespace

  init(
    sessions: [LiftSession],
    selectedDay: Binding<Date>,
    calendar: Calendar = .current
  ) {
    self.sessions = sessions
    _selectedDay = selectedDay
    self.calendar = calendar
  }

  private var days: [LiftScheduleWeekDay] {
    LiftScheduleWeek.days(
      containing: selectedDay,
      sessions: sessions,
      calendar: calendar
    )
  }

  var body: some View {
    HStack(spacing: 4) {
      ForEach(days) { day in
        dayButton(day)
      }
    }
    .frame(maxWidth: .infinity)
    .accessibilityElement(children: .contain)
  }

  private func dayButton(_ day: LiftScheduleWeekDay) -> some View {
    let isSelected = calendar.isDate(day.date, inSameDayAs: selectedDay)
    return Button {
      withAnimation(liftAnimation(LiftMotion.compose, reduceMotion: reduceMotion)) {
        selectedDay = day.date
      }
    } label: {
      VStack(spacing: 3) {
        Text(weekdaySymbol(for: day.date))
          .font(.receipt(8, weight: .black))
          .tracking(0.3)
        Text(String(calendar.component(.day, from: day.date)))
          .font(.receipt(12, weight: .black))
          .monospacedDigit()
        Circle()
          .fill(isSelected ? LiftTheme.paper : LiftTheme.ink)
          .frame(width: 4, height: 4)
          .opacity(day.isTrained ? 1 : 0)
          .accessibilityHidden(true)
      }
      .foregroundStyle(isSelected ? LiftTheme.paper : LiftTheme.ink)
      .frame(maxWidth: .infinity)
      .frame(minHeight: LiftDesignMetrics.ScheduleWeek.minimumTargetSize)
      .background {
        if isSelected {
          RoundedRectangle(
            cornerRadius: LiftDesignMetrics.ScheduleWeek.selectionCornerRadius,
            style: .continuous
          )
          .fill(LiftTheme.ink)
          .matchedGeometryEffect(id: "schedule-week-selection", in: selectionNamespace)
        }
      }
      .contentShape(Rectangle())
    }
    .buttonStyle(.plain)
    .accessibilityLabel(accessibilityLabel(for: day))
    .accessibilityAddTraits(isSelected ? .isSelected : [])
  }

  private func weekdaySymbol(for date: Date) -> String {
    let weekday = calendar.component(.weekday, from: date)
    let symbols = calendar.veryShortWeekdaySymbols
    guard symbols.indices.contains(weekday - 1) else { return "" }
    return symbols[weekday - 1].uppercased()
  }

  private func accessibilityLabel(for day: LiftScheduleWeekDay) -> String {
    let date = day.date.formatted(.dateTime.weekday(.wide).month(.wide).day())
    return day.isTrained ? "\(date), trained" : date
  }
}
