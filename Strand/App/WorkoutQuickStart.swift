import CoreLocation
import Foundation

/// The Quick Actions "Start <last sport>" row: one tap into the countdown (or straight in) on the sport the wearer used last,
/// skipping setup. It is offered only when nothing would have to be asked on the way: a route sport whose location permission
/// is still undecided would put a system prompt in the middle of a quick start, so it is left to the setup page, which has
/// the Allow location button; and a lift in progress blocks starting at all.
enum WorkoutQuickStart {
    /// The sport the row offers, or nil for no row.
    /// - Parameters:
    ///   - recents: The persisted recent sports, most recent first.
    ///   - gps: What location allows right now.
    ///   - blockedByLift: A lift is in progress.
    static func offer(recents: [String], gps: GpsAvailability, blockedByLift: Bool) -> String? {
        guard !blockedByLift, let last = StartWorkoutChoices.recentSports(from: recents).first else { return nil }
        if last.isDistanceSport && gps == .willAsk { return nil }
        return last.name
    }

    /// What location allows now, read straight from CoreLocation (the sheet holds no recorder of its own).
    static func currentGps() -> GpsAvailability {
        GpsAvailability.of(status: CLLocationManager().authorizationStatus)
    }
}
