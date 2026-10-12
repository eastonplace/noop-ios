import Foundation

/// The workout preferences more than one screen reads, so they cannot drift apart.
enum WorkoutPrefs {
    /// "Keep the screen on during a workout", the `@AppStorage` key every screen shares.
    static let keepScreenOnKey = "workoutKeepScreenOn"
    /// A workout is watched in motion, with a wet thumb: the screen stays on unless the person turned that off (a stored
    /// choice, on or off, always wins over this) or Low Power Mode is on.
    static let keepScreenOnDefault = true

    /// Whether the screen is actually held awake: the preference, unless Low Power Mode is on.
    static func keepsScreenOn(preference: Bool, lowPowerMode: Bool) -> Bool {
        preference && !lowPowerMode
    }
}
