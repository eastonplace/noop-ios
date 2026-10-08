import SwiftUI
import UIKit
import StrandDesign

/// Lift's colour tokens.
///
/// Chrome (screens, controls, rows) resolves straight to `StrandPalette`, the app's single fixed-dark
/// system, so Lift can never drift from the rest of NOOP. The one exception is the receipt artifact
/// (`Receipt`): the exported receipt image is rendered in an explicit light appearance, so its paper
/// and ink adapt to the colour scheme they are drawn in. In-app the scheme is always dark, which makes
/// the on-screen artifact sit on the canvas.
enum LiftTheme {
  static let paper = StrandPalette.appCanvas
  static let ink = StrandPalette.textPrimary
  static let inkSecondary = StrandPalette.textSecondary
  static let rule = StrandPalette.hairline
  static let accent = StrandPalette.accent
  static let onAccent = StrandPalette.onInk
  /// Transitional alias: the receipt artifact moves onto `Receipt` in a follow-up commit.
  static let exportCream = Receipt.cream

  enum Receipt {
    static let paper = adaptive(light: .white, dark: UIColor(StrandPalette.appCanvas))
    static let ink = adaptive(light: UIColor(white: 0.067, alpha: 1), dark: UIColor(StrandPalette.textPrimary))
    static let inkSecondary = adaptive(light: UIColor(white: 0.333, alpha: 1), dark: UIColor(StrandPalette.textSecondary))
    static let rule = adaptive(light: UIColor(white: 0.867, alpha: 1), dark: UIColor(StrandPalette.cardBorder))
    /// Optional warm paper stock for exported receipts. It is an artifact colour, not a UI token.
    static let cream = Color(uiColor: UIColor(red: 0.982, green: 0.972, blue: 0.942, alpha: 1))

    private static func adaptive(light: UIColor, dark: UIColor) -> Color {
      Color(uiColor: UIColor { $0.userInterfaceStyle == .dark ? dark : light })
    }
  }
}

extension Font {
  /// Lift chrome text. The legacy `(size, weight)` call shape is kept so every call site inherits the
  /// app's type system: sizes snap to the nearest `StrandFont` role and emphasis maps to the role's
  /// bold step, so Lift text uses the same proportional face, Dynamic Type scaling, and weights as the
  /// rest of NOOP. Numerals pair this with `.monospacedDigit()` at the call site. Very large sizes are
  /// display numerals and use the shared fixed numeric role.
  static func receipt(_ size: CGFloat, weight: Font.Weight = .regular) -> Font {
    let strong = weight == .bold || weight == .heavy || weight == .black
    let role: Font
    switch size {
    case ..<9.5: role = StrandFont.micro
    case ..<12: role = StrandFont.caption
    case ..<14: role = StrandFont.footnote
    case ..<17: role = StrandFont.subhead
    case ..<22: role = StrandFont.headline
    case ..<28: role = StrandFont.title2
    default: return StrandFont.number(size, weight: .bold)
    }
    return strong ? role.weight(size >= 14 ? .bold : .semibold) : role
  }

  /// Large display text and numerals that previously used the condensed receipt face.
  static func receiptCondensed(_ size: CGFloat, weight: Font.Weight = .black) -> Font {
    StrandFont.number(size, weight: .bold)
  }

  /// Monospaced type for the receipt artifact only (the printed receipt, its totals, and the exported
  /// image). Chrome never uses this; it exists so a printed receipt reads like a till slip.
  static func receiptArtifact(_ size: CGFloat, weight: Font.Weight = .regular) -> Font {
    StrandFont.mono(size, weight: weight)
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
