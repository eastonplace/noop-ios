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

  private func measurement(_ value: Double, width: Measurement<UnitMass>.FormatStyle.UnitWidth) -> String {
    Measurement(value: value, unit: unit.measurementUnit)
      .formatted(.measurement(width: width, usage: .asProvided, numberFormatStyle: numberStyle).locale(locale))
  }

  /// A load: bodyweight movements read "BW" at zero and "+25 lb" with added load, the rest read their weight.
  func load(pounds: Double, for exercise: LiftExercise?) -> String {
    if exercise.map(liftUsesBodyweightLoad) ?? false {
      guard pounds > 0 else { return Self.bodyweight }
      return "+" + volume(pounds: pounds)
    }
    return volume(pounds: pounds)
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
    return weight(pounds: pounds)
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

  // MARK: Dates

  /// "Oct 9" (the month and day, in the person's language).
  func day(_ date: Date) -> String {
    date.formatted(.dateTime.month(.abbreviated).day().locale(locale))
  }

  /// "Fri, Oct 9".
  func weekdayDay(_ date: Date) -> String {
    date.formatted(.dateTime.weekday(.abbreviated).month(.abbreviated).day().locale(locale))
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
