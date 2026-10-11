import SwiftUI
import UIKit
import StrandDesign

/// Lift's colour tokens.
///
/// Chrome (screens, controls, rows) resolves straight to `StrandPalette`, the app's single fixed-dark
/// system, so Lift can never drift from the rest of NOOP. The one exception is the receipt artifact
/// (`Receipt`): the exported receipt image is rendered in an explicit light appearance, so its paper
/// and ink adapt to the colour scheme they are drawn in. In-app the scheme is always dark, which makes
/// the on-screen artifact a dark slip on the canvas.
enum LiftTheme {
  enum Receipt {
    /// White paper in the light appearance the export renders in; in the app's dark scheme the slip is a step lighter than
    /// the canvas (the card colour), so it reads as a slip lying on the page.
    static let paper = adaptive(light: .white, dark: UIColor(StrandPalette.card))
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
