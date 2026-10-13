import Foundation

/// The one plausible heart-rate range for analytics (AN-03). The strap reports 0 bpm off-wrist and a decode
/// glitch can read far above any real maximum; neither is a heart rate. `analyzeDay` and the public
/// SleepStager entry points drop samples outside this range once, so sleep detection, resting HR, workouts,
/// calories and Effort all see the same valid stream instead of each applying its own range (or none).
public enum HRValidity {
    /// Inclusive plausible range in bpm. 30 clears deeply bradycardic athletes; 240 clears any real maximum.
    public static let bpmRange: ClosedRange<Int> = 30...240

    public static func isPlausible(_ bpm: Int) -> Bool { bpmRange.contains(bpm) }
}
