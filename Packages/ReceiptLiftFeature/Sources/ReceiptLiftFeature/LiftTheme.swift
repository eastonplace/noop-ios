import SwiftUI
import UIKit
import StrandDesign

enum LiftTheme {
  // Native NOOP surfaces in-app; receipt exports explicitly render in light appearance.
  static let paper = adaptive(light: .white, dark: UIColor(StrandPalette.appCanvas))
  static let ink = adaptive(light: UIColor(white: 0.067, alpha: 1), dark: .white)
  static let inkSecondary = adaptive(light: UIColor(white: 0.333, alpha: 1), dark: UIColor(StrandPalette.textSecondary))
  static let rule = adaptive(light: UIColor(white: 0.867, alpha: 1), dark: UIColor(StrandPalette.cardBorder))
  static let accent = StrandPalette.accent
  static let onAccent = StrandPalette.onInk
  static let exportCream = Color(red: 0.982, green: 0.972, blue: 0.942)
  private static func adaptive(light: UIColor, dark: UIColor) -> Color {
    Color(uiColor: UIColor { $0.userInterfaceStyle == .dark ? dark : light })
  }

}

extension Font {
  static func receipt(_ size: CGFloat, weight: Font.Weight = .regular) -> Font {
    .custom(receiptFontName(for: weight), size: size, relativeTo: receiptTextStyle(for: size))
  }

  static func receiptCondensed(_ size: CGFloat, weight: Font.Weight = .black) -> Font {
    receipt(size, weight: weight)
  }

  private static func receiptTextStyle(for size: CGFloat) -> Font.TextStyle {
    switch size {
    case 32...:
      .largeTitle
    case 26..<32:
      .title
    case 21..<26:
      .title2
    case 18..<21:
      .title3
    case 16..<18:
      .body
    case 14..<16:
      .callout
    case 12..<14:
      .footnote
    case 10..<12:
      .caption
    default:
      .caption2
    }
  }

  private static func receiptFontName(for weight: Font.Weight) -> String {
    if weight == .black || weight == .heavy { return "SFMono-Heavy" }
    if weight == .bold { return "SFMono-Bold" }
    if weight == .semibold { return "SFMono-Semibold" }
    if weight == .medium { return "SFMono-Medium" }
    if weight == .light || weight == .thin || weight == .ultraLight { return "SFMono-Light" }
    return "SFMono-Regular"
  }
}

extension View {
  func liftScreenBackground() -> some View {
    background(LiftTheme.paper.ignoresSafeArea())
  }
}

func liftWeight(_ value: Double) -> String {
  guard value > 0 else { return "BW" }
  if value.rounded() == value {
    return "\(Int(value)) lb"
  }
  return String(format: "%.1f lb", value)
}

func liftLoad(_ value: Double, for exercise: LiftExercise?) -> String {
  let usesBodyweight = exercise.map(liftUsesBodyweightLoad) ?? false
  if usesBodyweight {
    guard value > 0 else { return "BW" }
    return "+\(liftVolume(value))"
  }
  return liftVolume(value)
}

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

func liftVolume(_ value: Double) -> String {
  guard value > 0 else { return "0 lb" }
  if value.rounded() == value {
    return "\(Int(value)) lb"
  }
  return String(format: "%.1f lb", value)
}

func liftMeasuredWeight(_ value: Double) -> String {
  guard value > 0 else { return "--" }
  return liftVolume(value)
}

func liftDuration(_ interval: TimeInterval) -> String {
  let totalSeconds = max(Int(interval.rounded()), 0)
  let minutes = totalSeconds / 60
  let seconds = totalSeconds % 60
  return String(format: "%d:%02d", minutes, seconds)
}

func liftClockDuration(_ interval: TimeInterval) -> String {
  let totalSeconds = max(Int(interval.rounded()), 0)
  let hours = totalSeconds / 3600
  let minutes = (totalSeconds % 3600) / 60
  let seconds = totalSeconds % 60
  return String(format: "%02d:%02d:%02d", hours, minutes, seconds)
}

func liftDate(_ date: Date) -> String {
  date.formatted(.dateTime.month(.abbreviated).day().hour().minute())
}

func liftReceiptDate(_ date: Date) -> String {
  date.formatted(.dateTime.month(.abbreviated).day().year().hour().minute())
}
