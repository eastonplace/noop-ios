import SwiftUI
import StrandDesign

// MARK: - Personal heart-rate zones
//
// Rest, steady and push used to split at a fixed 60 and 110 bpm for everyone. They now follow the wearer: rest below half
// of their maximum heart rate, steady up to 70%, push from there (the first, second and third-and-above zones). The
// maximum is the profile's override when set, else the age estimate. The boundaries are set once at the app's root, so
// Today's live heart-rate card, the heart-rate timeline and its time-in-range rows cannot disagree.

extension ProfileStore {
    /// The wearer's rest / steady / push boundaries for a given override and age.
    nonisolated static func hrZoneThresholds(override: Int, age: Int) -> HRZoneStyle.Thresholds {
        HRZoneStyle.Thresholds(hrMax: Double(hrMax(override: override, age: age)))
    }
}

/// Puts the profile's zones in the environment of everything below, and follows the profile when its age or maximum
/// heart rate changes.
private struct PersonalHRZones: ViewModifier {
    @ObservedObject var profile: ProfileStore

    func body(content: Content) -> some View {
        content.environment(
            \.hrZoneThresholds,
            ProfileStore.hrZoneThresholds(override: profile.hrMaxOverride, age: profile.age))
    }
}

extension View {
    func personalHRZones(_ profile: ProfileStore) -> some View {
        modifier(PersonalHRZones(profile: profile))
    }
}
