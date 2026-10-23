import Foundation
#if os(iOS)
import BackgroundTasks
#endif

/// The DAILY scheduled debug auto-export (#510 — maddognik) for Apple, in PARITY with Android's
/// `DebugExportScheduler`.
///
/// At the user's chosen time-of-day this writes the durable strap-log tail ([LiveState.scheduledExportText])
/// — and, when a raw 5/MG capture exists, copies that alongside — to the app's Documents directory under a
/// `yyMMdd-HHmm` timestamped filename, once per day, with no UI. It exists so a reporter chasing an
/// intermittent overnight fault gets a dated log waiting each morning instead of having to remember to hit
/// "Save strap log" at the right moment.
///
/// HONEST about platform limits (the whole point of doing this carefully on Apple):
/// - **macOS** — the app is usually running, so a foreground `DispatchSourceTimer` fires reliably at the
///   chosen minute, and `catchUpIfDue()` covers the case where the time passed while the app wasn't open.
///   This path is dependable.
/// - **iOS** — a sideloaded, backgrounded app can't guarantee a drop to the exact minute. We submit a
///   `BGAppRefreshTaskRequest` for *no earlier than* the chosen time and write when iOS next wakes us near
///   it. The Settings copy says exactly that — we never promise an exact background drop. (The app entry
///   point registers the handler id below via `register(perform:)`; if it isn't registered/permitted yet,
///   `submit` fails gracefully and the in-app "Run now" + the macOS path still work.)
///
/// Opt-in, default OFF — like every NOOP automation. Everything is on-device; nothing is sent anywhere.
@MainActor
enum ScheduledDebugExport {

    // MARK: - Persisted settings (own keys; mirror Android `DebugExportSettings` + the WindDownNudge shape)

    private enum K {
        static let enabled = "debugExport.enabled"          // master enable; default OFF
        static let time = "debugExport.timeMinutes"         // minutes since local midnight; default 07:00
        static let lastRun = "debugExport.lastRunDayKey"    // yyyy-MM-dd of the last completed drop (catch-up dedup)
    }

    /// 07:00 — a log waiting when you wake (matches Android's `DEFAULT_TIME`).
    static let defaultTimeMinutes = 7 * 60
    private static let minutesPerDay = 24 * 60

    /// iOS BGTask identifier. Must also appear in the iOS target's `BGTaskSchedulerPermittedIdentifiers`
    /// (Info.plist) and be registered at launch for `submit` to succeed — wired in the app entry point.
    static let bgTaskIdentifier = "com.noopapp.noop.debugexport"

    static var isEnabled: Bool { UserDefaults.standard.bool(forKey: K.enabled) }

    /// Time-of-day to export, minutes since local midnight. Clamped to a valid minute. Default 07:00.
    static var timeMinutes: Int {
        let v = UserDefaults.standard.object(forKey: K.time) as? Int ?? defaultTimeMinutes
        return min(max(v, 0), minutesPerDay - 1)
    }

    // MARK: - Public API (Settings calls these)

    /// Enable/disable and (re)schedule. Disabling cancels the schedule and stops the drops.
    static func setEnabled(_ on: Bool) {
        UserDefaults.standard.set(on, forKey: K.enabled)
        if on {
            scheduleNext()
            catchUpIfDue()
        } else {
            cancel()
        }
    }

    /// Update the time-of-day and reschedule so the new time takes effect immediately (the Android
    /// `applyTimeChange` analogue).
    static func setTimeMinutes(_ minutes: Int) {
        UserDefaults.standard.set(min(max(minutes, 0), minutesPerDay - 1), forKey: K.time)
        if isEnabled { scheduleNext() }
    }

    /// Call on app start AND when the Settings screen appears so the schedule self-heals (re-arms the
    /// macOS timer after a relaunch, re-submits the iOS request) and a drop missed while the app wasn't
    /// running is written once. No-op when the feature is off.
    static func activateIfEnabled() {
        guard isEnabled else { return }
        scheduleNext()
        catchUpIfDue()
    }

    /// User-initiated immediate export (the "Run now" button). Always writes, ignoring the daily dedup,
    /// so a tap produces a file there and then. The caller may pass the current raw 5/MG capture URL (from
    /// `live.puffinCaptureURL`) so a scheduled drop carries the same matched pair the one-tap "Export raw +
    /// log" does. Returns the written log file URL or nil if the body couldn't be written.
    @discardableResult
    static func runNow(captureURL: URL? = nil) async -> URL? {
        await performExport(captureURL: captureURL)
    }

    // MARK: - Scheduling

    private static var macTimer: DispatchSourceTimer?
    private static var dailyExport: Task<URL?, Never>?
    private static var dailyExportID: UUID?

    /// (Re)arm the next occurrence. macOS uses a foreground `DispatchSourceTimer`; iOS submits a
    /// background-refresh request. Both target the next wall-clock occurrence of `timeMinutes`.
    private static func scheduleNext() {
        #if os(macOS)
        macTimer?.cancel()
        let timer = DispatchSource.makeTimerSource(queue: .main)
        let delay = secondsToNextOccurrence(timeMinutes)
        timer.schedule(deadline: .now() + delay)
        timer.setEventHandler {
            guard isEnabled else { return }
            catchUpIfDue()
            // Re-arm for the following day (the timer is one-shot so a clock change can't drift it).
            scheduleNext()
        }
        timer.resume()
        macTimer = timer
        #elseif os(iOS)
        submitBackgroundRequest()
        #endif
    }

    /// Cancel any armed schedule.
    private static func cancel() {
        dailyExport?.cancel()
        dailyExport = nil
        dailyExportID = nil
        #if os(macOS)
        macTimer?.cancel()
        macTimer = nil
        #elseif os(iOS)
        BGTaskScheduler.shared.cancel(taskRequestWithIdentifier: bgTaskIdentifier)
        #endif
    }

    /// If today's drop is due (we're at/after the chosen time and haven't written today), write it once.
    /// Covers macOS launches where the time passed while the app wasn't open, and the iOS foreground path.
    private static func catchUpIfDue() {
        _ = startDueExport()
    }

    /// Repeated activation and a concurrent BG wake share one owned daily job. The reservation is
    /// synchronous; the completed-day marker follows successful IO rather than scheduling the work.
    private static func startDueExport() -> Task<URL?, Never>? {
        guard isEnabled else { return nil }
        if let dailyExport { return dailyExport }
        let now = Date()
        let cal = Calendar.current
        let comps = cal.dateComponents([.hour, .minute], from: now)
        let nowMinutes = (comps.hour ?? 0) * 60 + (comps.minute ?? 0)
        guard nowMinutes >= timeMinutes else { return nil }      // not yet time today
        let day = dayKey(now)
        guard UserDefaults.standard.string(forKey: K.lastRun) != day else { return nil }
        let id = UUID()
        let operation = Task { @MainActor in
            let result = await performExport()
            if result != nil, !Task.isCancelled { UserDefaults.standard.set(day, forKey: K.lastRun) }
            // A disabled/re-enabled schedule may already own a newer job. Its reservation survives
            // this cancelled job's delayed completion.
            if dailyExportID == id { dailyExport = nil; dailyExportID = nil }
            return result
        }
        dailyExport = operation
        dailyExportID = id
        return operation
    }

    /// Seconds from now until the next wall-clock occurrence of `minuteOfDay` (today if still ahead, else
    /// tomorrow). Mirrors Android's `delayToNextOccurrenceMs`.
    private static func secondsToNextOccurrence(_ minuteOfDay: Int, now: Date = Date()) -> TimeInterval {
        let cal = Calendar.current
        var comps = cal.dateComponents([.year, .month, .day], from: now)
        comps.hour = minuteOfDay / 60
        comps.minute = minuteOfDay % 60
        comps.second = 0
        var target = cal.date(from: comps) ?? now
        if target <= now { target = cal.date(byAdding: .day, value: 1, to: target) ?? target }
        return max(1, target.timeIntervalSince(now))
    }

    // MARK: - The export itself

    /// Write the durable strap-log tail to `Documents/noop-strap-log-<yyMMdd-HHmm>.txt`, and (when the
    /// caller supplies one) copy the raw 5/MG capture beside it. Reuses the already-shipped writers (the
    /// durable tail from `LiveState`, the timestamped naming from `FileExport`) so a scheduled drop reads
    /// the same as a manual share. Only the daily job marks its completed day; manual taps always write.
    @discardableResult
    private static func performExport(captureURL: URL? = nil) async -> URL? {
        guard let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first else {
            return nil
        }
        let stamp = FileExport.timestamp()
        let header = DebugDataDiagnostics.strapStateLines()
        do {
            return try await FileExport.saveScheduledExport(to: docs, stamp: stamp, extraHeaderLines: header, captureURL: captureURL)
        } catch {
            return nil
        }
    }

    /// yyyy-MM-dd local-day key for the once-per-day dedup. POSIX locale so the key is stable everywhere.
    private static func dayKey(_ date: Date) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd"
        return f.string(from: date)
    }

    // MARK: - iOS background task plumbing

    #if os(iOS)
    /// Register the BGTask handler. MUST be called from the app's launch (before launch finishes) AND the
    /// identifier MUST be listed in `BGTaskSchedulerPermittedIdentifiers` (Info.plist) for iOS to deliver
    /// the task. Both live in the iOS app target — call this from `StrandiOSApp.init()`. Safe to leave
    /// uncalled: `submitBackgroundRequest()` fails gracefully and the macOS path + "Run now" still work.
    static func register() {
        // `.main`, not nil: this enum is @MainActor, so the closure traps if iOS invokes it on a worker queue.
        BGTaskScheduler.shared.register(forTaskWithIdentifier: bgTaskIdentifier, using: .main) { task in
            let operation = Task { @MainActor in
                var success = true
                if let export = startDueExport() {
                    let result = await withTaskCancellationHandler {
                        await export.value
                    } onCancel: { export.cancel() }
                    success = result != nil
                }
                if isEnabled { submitBackgroundRequest() }
                task.setTaskCompleted(success: success && !Task.isCancelled)
            }
            // Expiration cancels the owned export; streaming checks between bounded reads. Completion
            // follows the IO barrier, and a cancelled job cannot acknowledge the completed day.
            task.expirationHandler = { operation.cancel() }
        }
    }

    /// Submit a background-refresh request for *no earlier than* the next chosen time. Honest: iOS decides
    /// when (and whether) to actually run it, so this is best-effort. `try?` swallows the
    /// "identifier not permitted/registered" error so a build that hasn't wired Info.plist still behaves.
    private static func submitBackgroundRequest() {
        let request = BGAppRefreshTaskRequest(identifier: bgTaskIdentifier)
        request.earliestBeginDate = Date(timeIntervalSinceNow: secondsToNextOccurrence(timeMinutes))
        try? BGTaskScheduler.shared.submit(request)
    }
    #endif
}
