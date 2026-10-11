#if os(iOS)
import Combine
import Foundation
import WidgetKit

/// Keeps the App Group's copy of the wearer's maximum heart rate in step with the profile: written when the app
/// launches, and again whenever the date of birth or the manual override changes, which is when the widgets must
/// redraw their zone colours.
@MainActor
enum WidgetPersonalZonesSync {
    private static var subscription: AnyCancellable?

    /// The same rule every screen applies: a positive override wins, else the Tanaka estimate from the age on `now`.
    static func hrMax(override: Int, dateOfBirth: Date, now: Date = Date()) -> Int {
        ProfileStore.hrMax(age: ProfileStore.years(from: dateOfBirth, to: now), override: override)
    }

    /// Publishes once now (the publisher replays the current values) and on every later change.
    static func start(profile: ProfileStore, defaults: UserDefaults? = nil, reloadWidgets: @escaping () -> Void = {
        WidgetCenter.shared.reloadAllTimelines()
    }) {
        subscription = Publishers.CombineLatest(profile.$hrMaxOverride, profile.$dateOfBirth)
            .map { hrMax(override: $0, dateOfBirth: $1) }
            .removeDuplicates()
            .sink { value in
                if WidgetPersonalZones.publish(hrMax: value, to: defaults) { reloadWidgets() }
            }
    }
}
#endif
