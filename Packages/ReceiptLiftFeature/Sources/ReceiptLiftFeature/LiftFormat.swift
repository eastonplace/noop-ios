import Foundation
import SwiftUI

/// The unit weights are shown in. Lift stores every load in pounds; the unit only changes what is drawn and what a
/// stepper moves by. The host passes the person's choice in (`ReceiptLiftView`'s `weightUnit`).
public enum LiftWeightUnit: String, CaseIterable, Sendable {
  case pounds
  case kilograms

  /// Exactly how many kilograms one pound is.
  static let kilogramsPerPound = 0.45359237

  var measurementUnit: UnitMass { self == .pounds ? .pounds : .kilograms }

  /// A short press of a weight stepper moves the load this far, in this unit.
  var step: Double { self == .pounds ? 5 : 2.5 }
  /// A long press moves it this far.
  var largeStep: Double { self == .pounds ? 25 : 10 }
  /// The empty bar the plate loader starts from, in this unit.
  var barWeight: Double { self == .pounds ? 45 : 20 }
  /// The plates the plate loader may use, heaviest first, in this unit.
  var plates: [Double] { self == .pounds ? [45, 35, 25, 10, 5, 2.5] : [25, 20, 15, 10, 5, 2.5, 1.25] }

  /// A load stored in pounds, in this unit.
  func fromPounds(_ pounds: Double) -> Double {
    self == .pounds ? pounds : pounds * Self.kilogramsPerPound
  }

  /// A load entered in this unit, in pounds.
  func toPounds(_ value: Double) -> Double {
    self == .pounds ? value : value / Self.kilogramsPerPound
  }

  /// A load stored in pounds, snapped to the nearest half unit in this unit, so 130 lb opens a kilogram stepper on
  /// 59 kg rather than 58.967 kg. Pounds already move by whole steps, so they pass through.
  func snappedDisplay(fromPounds pounds: Double) -> Double {
    let value = fromPounds(pounds)
    return self == .pounds ? value : (value * 2).rounded() / 2
  }
}

extension LiftWeightUnit {
  /// The load one press of a weight stepper away, in pounds. Pounds move by exactly the step. Kilograms first land on a
  /// multiple of the step (a 135 lb bar opens on 61 kg, and 62.5 kg is the press above it), because a converted load is
  /// never a plate-friendly figure. Never below zero.
  func stepped(pounds: Double, up: Bool, large: Bool) -> Double {
    let amount = large ? largeStep : step
    switch self {
    case .pounds:
      return max(up ? pounds + amount : pounds - amount, 0)
    case .kilograms:
      let ratio = snappedDisplay(fromPounds: pounds) / amount
      // A ratio that is a whole number already sits on a step; the 1e-9 keeps float noise from skipping one.
      let landed = up ? (ratio + 1e-9).rounded(.down) + 1 : (ratio - 1e-9).rounded(.up) - 1
      return toPounds(max(landed, 0) * amount)
    }
  }

  /// A load as the composer holds it: kilograms snap to the nearest half so the figure on screen is the figure stored.
  func canonicalPounds(_ pounds: Double) -> Double {
    self == .pounds ? pounds : toPounds(snappedDisplay(fromPounds: pounds))
  }
}

extension EnvironmentValues {
  /// The unit weights are shown in. Set once by `ReceiptLiftView`.
  @Entry var liftWeightUnit: LiftWeightUnit = .pounds
}

/// Everything Lift prints that depends on the person's unit or language: loads, volumes, durations and dates. A value
/// type built from the environment (`@Environment(\.liftFormat)`), so a view never reaches for a global and a test can
/// pass any unit and locale. Loads arrive in pounds, as Lift stores them.
struct LiftFormat: Sendable {
  var unit: LiftWeightUnit = .pounds
  var locale: Locale = .autoupdatingCurrent

  /// The text for a missing value, shared with the rest of the app.
  static let missing = "—"

  // MARK: Weights

  private var numberStyle: FloatingPointFormatStyle<Double> {
    .number.precision(.fractionLength(0...1)).locale(locale)
  }

  /// A number in the person's unit with no unit written ("102.5").
  func number(pounds: Double) -> String {
    unit.fromPounds(pounds).formatted(numberStyle)
  }

  /// A figure already in the person's unit, with no unit written.
  func number(inUnit value: Double) -> String {
    value.formatted(numberStyle)
  }

  /// "225 lb" or "102 kg" in the person's language, the unit abbreviated.
  func weight(pounds: Double) -> String {
    measurement(unit.fromPounds(pounds), width: .abbreviated)
  }

  /// The unit on its own, abbreviated in the person's language ("lb", "kg").
  var unitSymbol: String {
    let digits = 1.formatted(numberStyle)
    return measurement(1, width: .abbreviated)
      .replacingOccurrences(of: digits, with: "")
      .replacingOccurrences(of: "\u{00A0}", with: " ")
      .replacingOccurrences(of: "\u{202F}", with: " ")
      .trimmingCharacters(in: .whitespaces)
  }

  /// A weight as its figure and its unit, for a value drawn with the unit small and muted.
  func parts(pounds: Double) -> (number: String, unit: String) {
    (number(pounds: pounds), unitSymbol)
  }

  /// A figure already in the person's unit, with the unit written.
  func weight(inUnit value: Double) -> String {
    measurement(value, width: .abbreviated)
  }

  /// "225 pounds" or "102 kilograms", the unit in words, for VoiceOver.
  func spokenWeight(pounds: Double) -> String {
    measurement(unit.fromPounds(pounds), width: .wide)
  }

  func spokenWeight(inUnit value: Double) -> String {
    measurement(value, width: .wide)
  }

  /// Total volumes are tonnage: past a hundred the tenths are noise, so they read as whole numbers.
  private func volumeStyle(for value: Double) -> FloatingPointFormatStyle<Double> {
    value >= 100 ? .number.precision(.fractionLength(0)).locale(locale) : numberStyle
  }

  private func measurement(
    _ value: Double, width: Measurement<UnitMass>.FormatStyle.UnitWidth, style: FloatingPointFormatStyle<Double>? = nil
  ) -> String {
    Measurement(value: value, unit: unit.measurementUnit)
      .formatted(.measurement(width: width, usage: .asProvided, numberFormatStyle: style ?? numberStyle).locale(locale))
  }

  /// A load: bodyweight movements read "BW" at zero and "+25 lb" with added load, the rest read their weight.
  func load(pounds: Double, for exercise: LiftExercise?) -> String {
    if exercise.map(liftUsesBodyweightLoad) ?? false {
      guard pounds > 0 else { return Self.bodyweight }
      return "+" + weight(pounds: pounds)
    }
    return weight(pounds: pounds)
  }

  /// A load read aloud.
  func spokenLoad(pounds: Double, for exercise: LiftExercise?) -> String {
    if exercise.map(liftUsesBodyweightLoad) ?? false {
      guard pounds > 0 else { return String(localized: "Bodyweight") }
      return String(localized: "Bodyweight plus \(spokenWeight(pounds: pounds))")
    }
    return spokenWeight(pounds: pounds)
  }

  /// Total weight moved. Zero is a real zero, in the person's unit.
  func volume(pounds: Double) -> String {
    guard pounds > 0 else { return weight(inUnit: 0) }
    let value = unit.fromPounds(pounds)
    return measurement(value, width: .abbreviated, style: volumeStyle(for: value))
  }

  /// A total volume as its figure and its unit, whole numbers past a hundred.
  func volumeParts(pounds: Double) -> (number: String, unit: String) {
    let value = unit.fromPounds(max(pounds, 0))
    return (value.formatted(volumeStyle(for: value)), unitSymbol)
  }

  /// A weight that may be missing: no load reads as a dash, never as zero.
  func measured(pounds: Double) -> String {
    guard pounds > 0 else { return Self.missing }
    return weight(pounds: pounds)
  }

  /// "BW" in the person's language.
  static var bodyweight: String { String(localized: "BW", comment: "Bodyweight, as a load: no added weight") }

  // MARK: Durations

  /// "5:02": minutes and seconds.
  static func duration(_ interval: TimeInterval) -> String {
    let totalSeconds = max(Int(interval.rounded()), 0)
    return String(format: "%d:%02d", totalSeconds / 60, totalSeconds % 60)
  }

  /// "01:02:03": a stopwatch for the receipt's totals.
  static func clockDuration(_ interval: TimeInterval) -> String {
    let totalSeconds = max(Int(interval.rounded()), 0)
    return String(format: "%02d:%02d:%02d", totalSeconds / 3600, (totalSeconds % 3600) / 60, totalSeconds % 60)
  }

  /// "52m" or "1h 5m": a duration read at a glance in lists. Minutes round up so a lift is never "0m".
  func shortDuration(_ interval: TimeInterval) -> String {
    let minutes = max(Int((max(interval, 0) / 60).rounded()), 1)
    let style = Duration.UnitsFormatStyle(
      allowedUnits: minutes >= 60 ? [.hours, .minutes] : [.minutes], width: .narrow, maximumUnitCount: 2)
    return Duration.seconds(minutes * 60).formatted(style.locale(locale))
  }

  /// A duration in words, for VoiceOver.
  func spokenDuration(_ interval: TimeInterval) -> String {
    let seconds = max(Int(interval.rounded()), 0)
    let units: Set<Duration.UnitsFormatStyle.Unit> = seconds >= 3600 ? [.hours, .minutes] : seconds >= 60 ? [.minutes, .seconds] : [.seconds]
    return Duration.seconds(seconds).formatted(
      Duration.UnitsFormatStyle(allowedUnits: units, width: .wide, maximumUnitCount: 2).locale(locale))
  }

  /// "55 min" or "1 hr 5 min": an estimate or a length in the person's language, the unit abbreviated.
  func minutes(_ count: Int) -> String {
    let clamped = max(count, 0)
    let style = Duration.UnitsFormatStyle(
      allowedUnits: clamped >= 60 ? [.hours, .minutes] : [.minutes], width: .abbreviated, maximumUnitCount: 2)
    return Duration.seconds(clamped * 60).formatted(style.locale(locale))
  }

  /// "8 exercises", with the plural the person's language needs.
  static func exerciseCount(_ count: Int) -> String { String(localized: "\(count) exercises") }

  /// "8 reps", with the plural the person's language needs.
  static func repCount(_ count: Int) -> String { String(localized: "\(count) reps") }

  /// "3 workouts".
  static func workoutCount(_ count: Int) -> String { String(localized: "\(count) workouts") }

  /// "12 sets".
  static func setCount(_ count: Int) -> String { String(localized: "\(count) sets") }

  /// Words read aloud in a row ("Exercise 2, Pull-Up, 1 of 3 sets"), a pause between them in the person's script. They are
  /// separate facts, not the items of one list, so no language's "and" goes before the last. Empty entries are dropped.
  nonisolated static func spoken(_ parts: [String], locale: Locale = .autoupdatingCurrent) -> String {
    let separator = locale.language.languageCode == .chinese ? "，" : ", "
    return parts.filter { !$0.isEmpty }.joined(separator: separator)
  }

  /// Quiet facts about one thing, in a line ("8 exercises · 55 min"). Empty entries are dropped. When a line wraps at large
  /// text sizes the dot is tied to the fact before it and a number to its unit with no-break spaces, so the dot ends a line
  /// and never opens one, and "19 sets" is never split.
  static func facts(_ parts: [String]) -> String {
    parts.filter { !$0.isEmpty }.map(tyingNumbersToUnits).joined(separator: "\u{00A0}· ")
  }

  /// "19 sets" with a no-break space between the digit and the word after it.
  private static func tyingNumbersToUnits(_ text: String) -> String {
    var result = ""
    result.reserveCapacity(text.count)
    var previous: Character?
    var characters = text.makeIterator()
    var pending = characters.next()
    while let character = pending {
      let following = characters.next()
      if character == " ", let previous, previous.isNumber, let following, following.isLetter {
        result.append("\u{00A0}")
      } else {
        result.append(character)
      }
      previous = character
      pending = following
    }
    return result
  }

  // MARK: Dates

  /// "Oct 9" (the month and day, in the person's language).
  func day(_ date: Date) -> String {
    date.formatted(.dateTime.month(.abbreviated).day().locale(locale))
  }

  /// "Fri, Oct 9".
  func weekdayDay(_ date: Date) -> String {
    date.formatted(.dateTime.weekday(.abbreviated).month(.abbreviated).day().locale(locale))
  }

  /// "Today", "Tomorrow", else "Fri, Oct 9": how a planned day reads in a list.
  func relativeDay(_ date: Date, calendar: Calendar = .current, now: Date = Date()) -> String {
    if calendar.isDate(date, inSameDayAs: now) { return String(localized: "Today") }
    if let tomorrow = calendar.date(byAdding: .day, value: 1, to: now), calendar.isDate(date, inSameDayAs: tomorrow) {
      return String(localized: "Tomorrow")
    }
    return weekdayDay(date)
  }

  /// "Oct 9, 2026": with the year, for lists that span years.
  func dayYear(_ date: Date) -> String {
    date.formatted(.dateTime.month(.abbreviated).day().year().locale(locale))
  }

  /// The time of day on the person's clock (12 or 24 hour; the app hands its clock in through `locale`).
  func time(_ date: Date) -> String {
    date.formatted(.dateTime.hour().minute().locale(locale))
  }

  /// "Oct 9 · 5:40 PM".
  func dayTime(_ date: Date) -> String {
    String(localized: "\(dayYear(date)) · \(time(date))", comment: "A date and a time of day, joined: 'Oct 9, 2026 · 5:40 PM'")
  }

  /// "Oct 9, 2026, 5:40 PM" for the receipt's header.
  func receiptDate(_ date: Date) -> String {
    date.formatted(.dateTime.month(.abbreviated).day().year().hour().minute().locale(locale))
  }
}

extension EnvironmentValues {
  /// The formatter for this view: the person's unit, in the clock and language the app draws in.
  var liftFormat: LiftFormat { LiftFormat(unit: liftWeightUnit, locale: locale) }
}

// MARK: - Display names

extension String {
  /// The bundled exercise catalog stores lowercase names ("barbell bench press"). Chrome shows them with
  /// each lowercase word capitalised, leaving words that already carry capitals ("DB", "EZ") alone and small joining
  /// words ("or", "and", "with") lowercase after the first, so "cable fly or pec deck" reads like the routine plans do.
  var liftDisplayName: String {
    split(separator: " ", omittingEmptySubsequences: false)
      .enumerated()
      .map { index, word in
        guard let first = word.first, first.isLowercase else { return String(word) }
        if index > 0, Self.liftJoiningWords.contains(String(word)) { return String(word) }
        return first.uppercased() + word.dropFirst()
      }
      .joined(separator: " ")
  }

  private static let liftJoiningWords: Set<String> = ["or", "and", "with", "of", "to", "on", "in", "a", "the"]
}

/// Bodyweight movements read "BW" at zero load and "+25 lb" with added weight, and have no volume of their own.
func liftUsesBodyweightLoad(_ exercise: LiftExercise) -> Bool {
  let name = exercise.name.lowercased()
  let equipment = exercise.equipment.lowercased()
  return equipment.contains("bodyweight")
    || name.contains("pull-up")
    || name.contains("dead hang")
    || name.contains("plank")
    || name.contains("hanging knee raise")
    || name.contains("russian twist")
}
