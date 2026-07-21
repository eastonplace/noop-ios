import Foundation
#if os(iOS)
import BackgroundTasks
#endif

/// Best-effort iOS wake for conditional evaluation. The dependable deadline remains the firmware
/// endpoint; iOS may delay or skip this refresh, including when the user force-quits the app.
@MainActor
enum SmartAlarmScheduler {
    static let bgTaskIdentifier = "com.noopapp.noop.smartalarm"

    static func schedule(windowStart: Date) {
        #if os(iOS)
        BGTaskScheduler.shared.cancel(taskRequestWithIdentifier: bgTaskIdentifier)
        let request = BGAppRefreshTaskRequest(identifier: bgTaskIdentifier)
        request.earliestBeginDate = windowStart
        try? BGTaskScheduler.shared.submit(request)
        #endif
    }

    static func cancel() {
        #if os(iOS)
        BGTaskScheduler.shared.cancel(taskRequestWithIdentifier: bgTaskIdentifier)
        #endif
    }

    #if os(iOS)
    static func register() {
        BGTaskScheduler.shared.register(forTaskWithIdentifier: bgTaskIdentifier, using: nil) { task in
            Task { @MainActor in
                guard let model = AppModel.shared else {
                    task.setTaskCompleted(success: false)
                    return
                }
                await model.evaluateConditionalSmartAlarm(trigger: .backgroundRefresh)
                model.applySmartAlarm()
                task.setTaskCompleted(success: true)
            }
        }
    }
    #endif
}
