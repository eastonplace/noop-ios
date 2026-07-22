import AppIntents

/// Inbound iPhone automations that operate on the already-running, bonded app instance.
/// Creating a second `AppModel` from an intent would start duplicate BLE and analytics owners,
/// so intents only use the weak live instance published by the application lifecycle.
enum NOOPIntentError: Error, CustomLocalizedStringResourceConvertible {
    case notRunning
    case notConnected

    var localizedStringResource: LocalizedStringResource {
        switch self {
        case .notRunning:
            return "Open NOOP first so it can reach your strap."
        case .notConnected:
            return "Connect your WHOOP strap in NOOP, then try again."
        }
    }
}

struct BuzzStrapIntent: AppIntent {
    static var title: LocalizedStringResource = "Buzz Strap"
    static var description = IntentDescription("Vibrate your connected WHOOP strap.")
    static var openAppWhenRun = false

    @MainActor
    func perform() async throws -> some IntentResult {
        guard let model = AppModel.shared else { throw NOOPIntentError.notRunning }
        guard model.live.bonded else { throw NOOPIntentError.notConnected }
        model.buzzStrapOnce()
        return .result()
    }
}

struct MarkMomentIntent: AppIntent {
    static var title: LocalizedStringResource = "Mark a Moment"
    static var description = IntentDescription(
        "Record a timestamped moment and buzz the strap when it is connected."
    )
    static var openAppWhenRun = false

    @MainActor
    func perform() async throws -> some IntentResult {
        guard let model = AppModel.shared else { throw NOOPIntentError.notRunning }
        model.markMoment()
        return .result()
    }
}

/// Makes the two actions discoverable in Shortcuts, Spotlight, and Siri suggestions on iPhone.
struct NOOPShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(
            intent: BuzzStrapIntent(),
            phrases: [
                "Buzz my strap with \(.applicationName)",
                "Buzz \(.applicationName)",
            ],
            shortTitle: "Buzz Strap",
            systemImageName: "waveform"
        )
        AppShortcut(
            intent: MarkMomentIntent(),
            phrases: [
                "Mark a moment with \(.applicationName)",
                "Mark a moment in \(.applicationName)",
            ],
            shortTitle: "Mark a Moment",
            systemImageName: "mappin.and.ellipse"
        )
    }
}
