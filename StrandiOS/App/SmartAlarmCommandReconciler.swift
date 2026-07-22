#if os(iOS)
import SwiftUI

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

/// Owns one latest-wins lane for persisted alarm edits. Disabling is urgent and
/// applies immediately; enabled edits are briefly coalesced so changing mode,
/// time, and weekdays in one interaction cannot produce a BLE command burst.
@MainActor
final class SmartAlarmCommandReconcileCoordinator: ObservableObject {
    private let debounceNanoseconds: UInt64
    private var pendingTask: Task<Void, Never>?
    private var lastApplied: SmartAlarmCommandSnapshot?

    init(debounceNanoseconds: UInt64 = 150_000_000) {
        self.debounceNanoseconds = debounceNanoseconds
    }

    deinit {
        pendingTask?.cancel()
    }

    func schedule(
        _ snapshot: SmartAlarmCommandSnapshot,
        apply: @escaping @MainActor () -> Void
    ) {
        pendingTask?.cancel()
        pendingTask = nil

        guard snapshot != lastApplied else { return }

        if !snapshot.enabled {
            applyNow(snapshot, apply: apply)
            return
        }

        pendingTask = Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                try await Task.sleep(nanoseconds: debounceNanoseconds)
            } catch {
                return
            }
            guard !Task.isCancelled else { return }
            applyNow(snapshot, apply: apply)
        }
    }

    func cancelPending() {
        pendingTask?.cancel()
        pendingTask = nil
    }

    private func applyNow(
        _ snapshot: SmartAlarmCommandSnapshot,
        apply: @MainActor () -> Void
    ) {
        lastApplied = snapshot
        pendingTask = nil
        apply()
    }
}

/// Both Sleep and Alarms edit the same `BehaviorStore`. This root-mounted leaf
/// observes one normalized snapshot and is the only UI edit path that triggers
/// BLE and notification reconciliation.
struct SmartAlarmCommandReconciler: View {
    @EnvironmentObject private var model: AppModel
    @EnvironmentObject private var behavior: BehaviorStore
    @StateObject private var coordinator = SmartAlarmCommandReconcileCoordinator()

    private var snapshot: SmartAlarmCommandSnapshot {
        SmartAlarmCommandSnapshot(
            enabled: behavior.smartAlarmEnabled,
            modeRawValue: behavior.smartAlarmMode.rawValue,
            minutes: behavior.smartAlarmMinutes,
            weekdays: behavior.smartAlarmWeekdays
        )
    }

    var body: some View {
        Color.clear
            .frame(width: 0, height: 0)
            .onChangeCompat(of: snapshot) { next in
                coordinator.schedule(next) {
                    model.applySmartAlarm()
                }
            }
            .onDisappear {
                coordinator.cancelPending()
            }
    }
}
#endif
