import SwiftUI

// MARK: - Stress load

/// The three stress band colours (calm, moderate, high). Every stress surface resolves its colour through
/// `StressHeatStyle`, which reads these, so Today, the Stress detail and the history use one ramp.
public enum StressLoadStyle {
    public static let calm = StrandPalette.accent
    public static let moderate = StrandPalette.statusPositive
    public static let high = StrandPalette.statusWarning
}
