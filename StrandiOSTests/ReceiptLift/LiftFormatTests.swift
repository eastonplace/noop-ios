import Foundation
import Testing
@testable import ReceiptLiftFeature

@Suite("Lift formatting and units")
struct LiftFormatTests {
  static let enUS = Locale(identifier: "en_US")
  static let pounds = LiftFormat(unit: .pounds, locale: enUS)
  static let kilograms = LiftFormat(unit: .kilograms, locale: enUS)

  // MARK: Stepping

  @Test("Pound steppers move by exactly the step and never go below zero")
  func poundSteps() {
    let unit = LiftWeightUnit.pounds
    #expect(unit.stepped(pounds: 135, up: true, large: false) == 140)
    #expect(unit.stepped(pounds: 135, up: false, large: false) == 130)
    #expect(unit.stepped(pounds: 135, up: true, large: true) == 160)
    #expect(unit.stepped(pounds: 3, up: false, large: false) == 0)
  }

  @Test("Kilogram steppers land on plate-friendly figures")
  func kilogramSteps() {
    let unit = LiftWeightUnit.kilograms
    // 135 lb is 61.2 kg: the first press lands on the multiple of 2.5 above or below it, not 63.7 kg.
    #expect(abs(unit.fromPounds(unit.stepped(pounds: 135, up: true, large: false)) - 62.5) < 1e-9)
    #expect(abs(unit.fromPounds(unit.stepped(pounds: 135, up: false, large: false)) - 60) < 1e-9)
    // A load already on a step moves by one step, float noise or not.
    let sixty = unit.toPounds(60)
    #expect(abs(unit.fromPounds(unit.stepped(pounds: sixty, up: true, large: false)) - 62.5) < 1e-9)
    #expect(abs(unit.fromPounds(unit.stepped(pounds: sixty, up: false, large: false)) - 57.5) < 1e-9)
    // The long press moves by ten and also lands on a multiple.
    #expect(abs(unit.fromPounds(unit.stepped(pounds: 135, up: true, large: true)) - 70) < 1e-9)
    #expect(abs(unit.fromPounds(unit.stepped(pounds: 135, up: false, large: true)) - 60) < 1e-9)
    #expect(unit.stepped(pounds: unit.toPounds(1), up: false, large: false) == 0)
  }

  @Test("Kilogram loads snap to the half so the figure on screen is the figure stored")
  func canonicalLoads() {
    #expect(LiftWeightUnit.pounds.canonicalPounds(133.3) == 133.3)
    let canonical = LiftWeightUnit.kilograms.canonicalPounds(130)
    #expect(abs(LiftWeightUnit.kilograms.fromPounds(canonical) - 59) < 1e-9)
    #expect(LiftWeightUnit.kilograms.snappedDisplay(fromPounds: 225) == 102)
  }

  // MARK: Weights

  @Test("Weights read in the person's unit with the unit abbreviated")
  func weights() {
    #expect(Self.pounds.weight(pounds: 225) == "225 lb")
    #expect(Self.kilograms.weight(pounds: 225) == "102.1 kg")
    #expect(Self.kilograms.unitSymbol == "kg")
    #expect(Self.pounds.unitSymbol == "lb")
    #expect(Self.pounds.parts(pounds: 132.5) == (number: "132.5", unit: "lb"))
  }

  @Test("Total volumes drop the tenths past a hundred; loads keep them")
  func volumeRounding() {
    #expect(Self.kilograms.volume(pounds: 1000) == "454 kg")
    #expect(Self.pounds.volume(pounds: 99.5) == "99.5 lb")
    #expect(Self.pounds.volume(pounds: 0) == "0 lb")
    #expect(Self.pounds.volumeParts(pounds: 253_646.6) == (number: "253,647", unit: "lb"))
    // A 102.5 kg bar is a load, not a volume: it keeps its half.
    let barbell = LiftExercise(id: UUID(), name: "Squat", muscleGroup: "Legs", equipment: "Barbell", instructions: "")
    #expect(Self.kilograms.load(pounds: LiftWeightUnit.kilograms.toPounds(102.5), for: barbell) == "102.5 kg")
  }

  @Test("Bodyweight movements read BW, or the load added to the body")
  func bodyweightLoads() {
    let pullUp = LiftExercise(id: UUID(), name: "Pull-Up", muscleGroup: "Back", equipment: "Bodyweight", instructions: "")
    #expect(Self.pounds.load(pounds: 0, for: pullUp) == "BW")
    #expect(Self.pounds.load(pounds: 25, for: pullUp) == "+25 lb")
    #expect(Self.pounds.measured(pounds: 0) == "—")
  }

  // MARK: Words and times

  @Test("Spoken lists drop blanks and join the way the language lists things")
  func spokenLists() {
    #expect(
      LiftFormat.spoken(["Exercise 2", "Pull-Up", "", "1 of 3 sets"], locale: Self.enUS)
        == "Exercise 2, Pull-Up, 1 of 3 sets")
    #expect(LiftFormat.spoken([], locale: Self.enUS) == "")
    #expect(LiftFormat.facts(["8 exercises", "", "55 min"]) == "8 exercises · 55 min")
  }

  @Test("Durations read as clocks, in lists and aloud")
  func durations() {
    #expect(LiftFormat.duration(90) == "1:30")
    #expect(LiftFormat.duration(-5) == "0:00")
    #expect(LiftFormat.clockDuration(3_723) == "01:02:03")
    #expect(Self.pounds.shortDuration(0) == "1m")
    #expect(Self.pounds.shortDuration(52 * 60) == "52m")
    #expect(Self.pounds.spokenDuration(90).contains("1 minute"))
    #expect(Self.pounds.minutes(55) == "55 min")
  }

  @Test("A planned day reads Today, Tomorrow, then the weekday and date")
  func relativeDays() {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = TimeZone(identifier: "UTC")!
    let noon = calendar.date(from: DateComponents(year: 2026, month: 10, day: 9, hour: 12))!
    let format = LiftFormat(unit: .pounds, locale: Self.enUS)
    #expect(format.relativeDay(noon, calendar: calendar, now: noon) == "Today")
    #expect(format.relativeDay(noon.addingTimeInterval(86_400), calendar: calendar, now: noon) == "Tomorrow")
    #expect(format.relativeDay(noon.addingTimeInterval(3 * 86_400), calendar: calendar, now: noon) == "Mon, Oct 12")
  }

  @Test("Counts take the plural their language needs")
  func counts() {
    #expect(LiftFormat.exerciseCount(1) == "1 exercise")
    #expect(LiftFormat.exerciseCount(8) == "8 exercises")
    #expect(LiftFormat.setCount(1) == "1 set")
    #expect(LiftFormat.workoutCount(13) == "13 workouts")
  }

  @Test("Exercise names from the catalog are capitalised word by word")
  func displayNames() {
    #expect("barbell bench press".liftDisplayName == "Barbell Bench Press")
    #expect("DB curl".liftDisplayName == "DB Curl")
    #expect("cable fly or pec deck".liftDisplayName == "Cable Fly or Pec Deck")
    #expect("or else".liftDisplayName == "Or Else")
  }
}

@Suite("Lift exercise search and filters")
struct LiftExerciseSearchTests {
  private static func exercise(_ name: String, _ muscle: String, _ equipment: String) -> LiftExercise {
    LiftExercise(id: UUID(), name: name, muscleGroup: muscle, equipment: equipment, instructions: "")
  }

  private let catalog = [
    exercise("Bench Press", "Chest", "Barbell"),
    exercise("Incline Dumbbell Press", "Chest", "Dumbbells"),
    exercise("Cable Fly", "Chest", "Cable"),
    exercise("Back Squat", "Legs", "Barbell"),
    exercise("Pull-Up", "Back", "Bodyweight"),
    exercise("Row", "Back", "Barbell"),
  ]

  @Test("A blank search with no filters returns the list as it came, capped at the limit")
  func blank() {
    #expect(LiftExerciseSearch.filter(exercises: catalog, query: "", limit: 60) == catalog)
    #expect(LiftExerciseSearch.filter(exercises: catalog, query: "  ", limit: 2) == Array(catalog.prefix(2)))
    #expect(LiftExerciseSearch.filter(exercises: catalog, query: "", limit: 0).isEmpty)
  }

  @Test("The query matches name, muscle or equipment, ignoring case")
  func query() {
    #expect(LiftExerciseSearch.filter(exercises: catalog, query: "press").map(\.name) == ["Bench Press", "Incline Dumbbell Press"])
    #expect(LiftExerciseSearch.filter(exercises: catalog, query: "LEGS").map(\.name) == ["Back Squat"])
    #expect(LiftExerciseSearch.filter(exercises: catalog, query: "cable").map(\.name) == ["Cable Fly"])
  }

  @Test("Muscle and equipment filters narrow the query together")
  func filters() {
    #expect(LiftExerciseSearch.filter(exercises: catalog, query: "", muscle: "chest").count == 3)
    #expect(LiftExerciseSearch.filter(exercises: catalog, query: "", equipment: "Barbell").map(\.name) == ["Bench Press", "Back Squat", "Row"])
    #expect(LiftExerciseSearch.filter(exercises: catalog, query: "", muscle: "Back", equipment: "Barbell").map(\.name) == ["Row"])
    #expect(LiftExerciseSearch.filter(exercises: catalog, query: "press", muscle: "Legs").isEmpty)
  }

  @Test("Facets list the muscles and equipment in use, most used first")
  func facets() {
    let facets = LiftExerciseSearch.facets(for: catalog + [Self.exercise("Odd", "  ", "")])
    #expect(facets.muscles == ["Chest", "Back", "Legs"])
    #expect(facets.equipment == ["Barbell", "Bodyweight", "Cable", "Dumbbells"])
  }

  @Test("A debounced search is cancelled before it runs")
  func debounceCancels() async {
    let task = Task { try await LiftExerciseSearch.debouncedFilter(exercises: catalog, query: "press") }
    task.cancel()
    do {
      _ = try await task.value
      Issue.record("A cancelled search should throw")
    } catch is CancellationError {
      // expected
    } catch {
      Issue.record("Unexpected error \(error)")
    }
  }
}

@Suite("Lift history grouping")
struct LiftReceiptMonthTests {
  private var calendar: Calendar {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = TimeZone(identifier: "UTC")!
    return calendar
  }

  private func session(_ title: String, day: Int, month: Int, finished: Bool = true) -> LiftSession {
    let start = calendar.date(from: DateComponents(year: 2026, month: month, day: day, hour: 17))!
    return LiftSession(
      id: UUID(), routineID: nil, title: title, startedAt: start,
      endedAt: finished ? start.addingTimeInterval(3_000) : nil, sets: [])
  }

  @Test("Completed lifts group by month, newest month and newest lift first, and unfinished ones stay out")
  func grouping() {
    let months = LiftReceiptMonth.group(
      [
        session("Sep 3", day: 3, month: 9), session("Oct 2", day: 2, month: 10),
        session("Oct 9", day: 9, month: 10), session("Active", day: 10, month: 10, finished: false),
        session("Sep 30", day: 30, month: 9),
      ],
      calendar: calendar, locale: Locale(identifier: "en_US"))
    #expect(months.map(\.title) == ["October 2026", "September 2026"])
    #expect(months[0].sessions.map(\.title) == ["Oct 9", "Oct 2"])
    #expect(months[1].sessions.map(\.title) == ["Sep 30", "Sep 3"])
  }

  @Test("No completed lifts means no months")
  func empty() {
    #expect(LiftReceiptMonth.group([session("Active", day: 1, month: 10, finished: false)], calendar: calendar, locale: .init(identifier: "en_US")).isEmpty)
  }
}

@Suite("Lift plate loader in either unit")
struct LiftPlateLoaderUnitTests {
  @Test("Equal plates group into one row, heaviest first")
  func grouping() {
    let groups = LiftPlatePresentation.grouped([45, 45, 25, 10, 10])
    #expect(groups.map(\.plate) == [45, 25, 10])
    #expect(groups.map(\.count) == [2, 1, 2])
    #expect(LiftPlatePresentation.grouped([]).isEmpty)
  }

  @Test("A kilogram bar loads from kilogram plates")
  func kilogramLoading() {
    let unit = LiftWeightUnit.kilograms
    let exact = LiftPlateMath.solve(target: 100, bar: unit.barWeight, plates: unit.plates)
    #expect(exact.exact)
    #expect(exact.perSide == [25, 15])
    let off = LiftPlateMath.solve(target: 102, bar: unit.barWeight, plates: unit.plates)
    #expect(!off.exact)
    #expect(off.nearestBelow == 100)
    #expect(off.nearestAbove == 102.5)
  }

  @Test("The spoken loading names every figure in the person's unit")
  func spokenLabel() {
    let format = LiftFormat(unit: .kilograms, locale: Locale(identifier: "en_US"))
    let unit = LiftWeightUnit.kilograms
    let solution = LiftPlateMath.solve(target: 100, bar: unit.barWeight, plates: unit.plates)
    let text = LiftPlatePresentation.accessibilityLabel(total: 100, solution: solution, bar: unit.barWeight, format: format)
    #expect(text.contains("100 kilograms"))
    #expect(text.contains("per side 25, 15"))
    #expect(text.contains("Bar 20 kilograms"))
  }
}

@Suite("Lift warm-up loads")
struct LiftWarmupRoundingTests {
  @Test("Warm-up loads round to 5 lb or 2.5 kg and never below one step")
  func rounding() {
    #expect(LiftStore.roundedWarmupWeight(66) == 65)
    #expect(LiftStore.roundedWarmupWeight(2) == 5)
    #expect(LiftStore.roundedWarmupWeight(0) == 0)
    let kilograms = LiftStore.roundedWarmupWeight(66, unit: .kilograms)
    #expect(abs(LiftWeightUnit.kilograms.fromPounds(kilograms) - 30) < 1e-9)
    let small = LiftStore.roundedWarmupWeight(1, unit: .kilograms)
    #expect(abs(LiftWeightUnit.kilograms.fromPounds(small) - 2.5) < 1e-9)
  }
}
