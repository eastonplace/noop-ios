#if os(iOS)
import Foundation
import AppIntents

/// Queue of actions requested by an App Intent while the app may be suspended. The application target
/// owns these intents and drains on an append while active, or on its next active mount/scene edge.
/// Shared defaults retain the request if no foreground consumer exists yet.
@MainActor
enum PendingIntents {
    enum Action: String, Sendable { case markMoment, buzz, syncStrap }
    static let didAppend = Notification.Name("noop.pendingIntents.didAppend")

    private static let key = "noop.pendingIntents"
    private static var defaults: UserDefaults? { UserDefaults(suiteName: WidgetSnapshot.suiteName) }

    /// Optional `at` is the invocation time, captured now and consumed on drain. Encoded into the
    /// stored string as "rawValue:epochSeconds" so the array stays a plain [String] (no schema
    /// migration; a legacy bare "markMoment" still decodes with a nil date).
    static func append(_ action: Action, at date: Date? = nil) {
        guard let d = defaults else { return }
        var list = d.stringArray(forKey: key) ?? []
        if let date { list.append("\(action.rawValue):\(date.timeIntervalSince1970)") }
        else { list.append(action.rawValue) }
        d.set(list, forKey: key)
        // App-only producers and the foreground consumer share the main actor. Persist first so a
        // synchronous drain takes this request once; a background consumer leaves it for activation.
        NotificationCenter.default.post(name: didAppend, object: nil)
    }

    static func drain() -> [(action: Action, date: Date?)] {
        guard let d = defaults else { return [] }
        let raw = d.stringArray(forKey: key) ?? []
        d.removeObject(forKey: key)
        return raw.compactMap { entry in
            // Guard `parts.first` rather than subscripting `parts[0]`: split(omittingEmptySubsequences:
            // true by default) returns an EMPTY array for an empty or ":"-leading entry, and indexing
            // [0] there is a fatal trap. This value comes from shared App Group defaults read untrusted,
            // so a corrupt/foreign entry must be skipped, not crash the app on foreground.
            let parts = entry.split(separator: ":", maxSplits: 1)
            guard let first = parts.first, let action = Action(rawValue: String(first)) else { return nil }
            let date = parts.count == 2 ? Double(parts[1]).map { Date(timeIntervalSince1970: $0) } : nil
            return (action, date)
        }
    }
}

/// Record a timestamped "moment" — the iOS analogue of the strap double-tap "mark a moment" action.
struct MarkMomentIntent: AppIntent {
    static let title: LocalizedStringResource = "Mark a Moment"
    static let description = IntentDescription("Record a timestamped moment in NOOP.")

    func perform() async throws -> some IntentResult & ProvidesDialog {
        await PendingIntents.append(.markMoment, at: Date())
        return .result(dialog: "Moment marked.")
    }
}

/// Send a confirming haptic buzz to the strap. Opens the app so the live BLE link can deliver it.
struct BuzzStrapIntent: AppIntent {
    static let title: LocalizedStringResource = "Buzz Strap"
    static let description = IntentDescription("Send a haptic buzz to your WHOOP strap.")
    static let openAppWhenRun = true

    func perform() async throws -> some IntentResult {
        await PendingIntents.append(.buzz)
        return .result()
    }
}

/// Opens NOOP and routes through its existing active-device sync coordinator.
struct SyncStrapIntent: AppIntent {
    static let title: LocalizedStringResource = "Sync Strap"
    static let description = IntentDescription("Open NOOP and sync your active strap.")
    static let openAppWhenRun = true

    func perform() async throws -> some IntentResult {
        await PendingIntents.append(.syncStrap)
        return .result()
    }
}

/// Surfaces NOOP's intents to Siri, Spotlight, and the Shortcuts gallery without any user setup.
struct NOOPShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        // Ten registrations total: the three strap actions remain. Build/review share a
        // parameterized action. Free-text questions are requested by Siri, not trigger phrases.
        AppShortcut(intent: SyncStrapIntent(),
                    phrases: ["Sync my \(.applicationName) strap"],
                    shortTitle: "Sync Strap",
                    systemImageName: "arrow.triangle.2.circlepath")
        AppShortcut(intent: MarkMomentIntent(),
                    phrases: ["Mark a moment in \(.applicationName)"],
                    shortTitle: "Mark a Moment",
                    systemImageName: "mappin.and.ellipse")
        AppShortcut(intent: BuzzStrapIntent(),
                    phrases: ["Buzz my \(.applicationName) strap"],
                    shortTitle: "Buzz Strap",
                    systemImageName: "waveform.path")
        AppShortcut(intent: AskLocalCoachIntent(),
                    phrases: ["Ask \(.applicationName) coach", "Ask my coach in \(.applicationName)"],
                    shortTitle: "Ask Coach",
                    systemImageName: "bubble.left.and.text.bubble.right")
        AppShortcut(intent: LocalCoachMorningIntent(),
                    phrases: ["My morning outlook in \(.applicationName)", "My daily outlook in \(.applicationName)"],
                    shortTitle: "Morning Outlook",
                    systemImageName: "sun.horizon")
        AppShortcut(intent: LocalCoachEveningIntent(),
                    phrases: ["Review my evening in \(.applicationName)"],
                    shortTitle: "Evening Review",
                    systemImageName: "moon.stars")
        AppShortcut(intent: LocalCoachWeeklyIntent(),
                    phrases: ["Review my week in \(.applicationName)"],
                    shortTitle: "Weekly Review",
                    systemImageName: "calendar")
        AppShortcut(intent: LocalCoachActivityIntent(),
                    phrases: ["Review my activity in \(.applicationName)"],
                    shortTitle: "Activity Review",
                    systemImageName: "figure.run")
        AppShortcut(intent: LocalCoachSleepIntent(),
                    phrases: ["Review my sleep in \(.applicationName)"],
                    shortTitle: "Sleep Review",
                    systemImageName: "bed.double")
        AppShortcut(intent: LocalCoachPlanIntent(),
                    phrases: ["\(\.$action) in \(.applicationName)", "Plan my training with \(.applicationName)"],
                    shortTitle: "Training Plan",
                    systemImageName: "list.clipboard")
    }
}
#endif
