import Foundation

enum SleepPerformanceV2Prefs {
    enum Mode: String { case off, shadow, on }
    private static let key = "sleep.performance.v2.mode"

    /// Shadow is the safe default: compute and persist V2, while legacy remains Recovery authority.
    static var mode: Mode {
        Mode(rawValue: UserDefaults.standard.string(forKey: key) ?? "") ?? .shadow
    }
}
