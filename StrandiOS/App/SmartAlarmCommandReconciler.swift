#if os(iOS)
import SwiftUI

/// Normalized alarm configuration retained as a small, testable contract. The production runtime uses
/// the richer `SmartAlarmRuntimeSnapshot`; this compatibility value keeps existing call-site/tests honest.
struct SmartAlarmCommandSnapshot: Equatable, Sendable {
    let enabled: Bool
    let modeRawValue: String
    let minutes: Int
    let weekdays: [Int]

    init(enabled: Bool, modeRawValue: String, minutes: Int, weekdays: Set<Int>) {
        self.enabled = enabled
        self.modeRawValue = modeRawValue
        self.minutes = ((minutes % 1_440) + 1_440) % 1_440
        self.weekdays = weekdays.filter { (1...7).contains($0) }.sorted()
    }
}

struct SmartAlarmCommandReconcileState {
    enum Decision: Equatable { case ignore, applyImmediately, debounce }
    private(set) var lastApplied: SmartAlarmCommandSnapshot?

    func decision(for snapshot: SmartAlarmCommandSnapshot) -> Decision {
        if snapshot == lastApplied { return .ignore }
        return snapshot.enabled ? .debounce : .applyImmediately
    }

    mutating func markApplied(_ snapshot: SmartAlarmCommandSnapshot) {
        lastApplied = snapshot
    }
}

/// Zero-layout app-root host. All side effects live in `SmartAlarmRuntimeController`; this view merely
/// starts the long-lived controller once the environment is installed. It intentionally does not cancel
/// on tab or scene disappearance because alarm delivery belongs to the application, not one screen.
struct SmartAlarmCommandReconciler: View {
    @EnvironmentObject private var runtime: SmartAlarmRuntimeController

    var body: some View {
        Color.clear
            .frame(width: 0, height: 0)
            .accessibilityHidden(true)
            .onAppear { runtime.start() }
    }
}
#endif
