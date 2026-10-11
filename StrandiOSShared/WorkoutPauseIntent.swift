#if os(iOS)
import Foundation
import AppIntents

/// Pause or resume the workout NOOP is recording, from the Live Activity's button on the Lock Screen or in the Dynamic
/// Island.
///
/// It is a `LiveActivityIntent`, so the system runs `perform()` in the app's own process (launching the app in the
/// background if it was suspended), where the recorder lives. The intent carries the state it wants, not a toggle: a
/// button pressed twice, or pressed after the in-app button already did the same thing, changes nothing the second time.
/// The widget extension links this type only to build the button; it never runs there.
public struct SetWorkoutPausedIntent: LiveActivityIntent {
    public static let title: LocalizedStringResource = "Pause or Resume Workout"
    public static let description = IntentDescription("Pauses or resumes the workout NOOP is recording.")
    public static let isDiscoverable = false

    @Parameter(title: "Paused")
    public var paused: Bool

    public init() { self.paused = true }

    public init(paused: Bool) { self.paused = paused }

    public func perform() async throws -> some IntentResult {
        await WorkoutPauseCommand.deliver(paused: paused)
        return .result()
    }
}

/// The hand-off between the intent and the recorder.
///
/// The app installs `apply` at launch, after `AppModel` has restored any workout that was in flight, so from then on a
/// request is answered at once: a workout takes it, and with none the request is dropped, not kept. Keeping it would
/// pause the next workout the person starts. A request that arrives before `apply` is installed (a process the system
/// woke for the intent) is written to the App Group and handed over by the launch drain, if it is still fresh.
public enum WorkoutPauseCommand {
    static let pendingKey = "noop.pendingWorkoutPause"
    /// A request older than this is stale: it was meant for a workout that is gone.
    public static let lifetime: TimeInterval = 30

    /// Installed by the app. Applies the request to the workout in flight and returns whether there was one to apply it
    /// to (a workout already in the requested state counts: the request is satisfied).
    @MainActor public static var apply: (@MainActor (Bool) -> Bool)?

    /// Tests point this at a throwaway suite so they never touch the App Group.
    @MainActor static var defaultsOverride: UserDefaults?

    private struct Pending: Codable {
        let paused: Bool
        let requestedAt: Date
    }

    @MainActor private static var defaults: UserDefaults? {
        defaultsOverride ?? UserDefaults(suiteName: WidgetSnapshot.suiteName)
    }

    /// The intent's entry point.
    @MainActor public static func deliver(paused: Bool, now: Date = Date()) {
        guard let apply else {
            store(Pending(paused: paused, requestedAt: now))
            return
        }
        _ = apply(paused)
    }

    /// Hand a waiting request to the recorder, once. Called at launch and when the app becomes active.
    @MainActor public static func drain(now: Date = Date()) {
        guard let pending = load() else { return }
        clear()
        guard now.timeIntervalSince(pending.requestedAt) <= lifetime, let apply else { return }
        _ = apply(pending.paused)
    }

    /// The request still waiting, if it has not expired. For tests and diagnostics.
    @MainActor public static func pendingRequest(now: Date = Date()) -> Bool? {
        guard let pending = load(), now.timeIntervalSince(pending.requestedAt) <= lifetime else { return nil }
        return pending.paused
    }

    @MainActor public static func clear() {
        defaults?.removeObject(forKey: pendingKey)
    }

    @MainActor private static func store(_ pending: Pending) {
        guard let data = try? JSONEncoder().encode(pending) else { return }
        defaults?.set(data, forKey: pendingKey)
    }

    @MainActor private static func load() -> Pending? {
        guard let data = defaults?.data(forKey: pendingKey) else { return nil }
        return try? JSONDecoder().decode(Pending.self, from: data)
    }
}
#endif
