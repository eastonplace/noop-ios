import Foundation
import UserNotifications
import StrandAnalytics

/// Surfaces the strap battery state as a user notification — a LOW warning when the cell falls to
/// the threshold so the user can top up before tonight's sleep, and a CHARGED note when it reaches
/// 100%. Mirrors `IllnessNotifier`: requestAuthorization() up front when the toggle is enabled,
/// status-only check at fire time, and durable per-device episode claims.
/// On-device only; gated behind the user's "Battery alerts" setting (default ON) by the caller (#368).
enum BatteryNotifier {

    /// Pure crossing-with-hysteresis policy, identical on macOS/iOS and Android (#368). The two
    /// `*Alerted` flags are PERSISTED, so they survive process death — and the 25% re-arm band means
    /// a 14↔15% jitter fires the low alert exactly once per discharge cycle (no in-memory prevPct
    /// crossing that re-fires on every bounce and resets on restart). Full re-arms only below 100.
    enum BatteryAlertPolicy {
        static let lowThreshold = 15
        static let lowRearmAbove = 25
        static let fullThreshold = 100

        /// `charging == nil` means unknown — the low alert still fires (only a confirmed `true`
        /// suppresses it). Returns the fire decisions plus the next persisted flag state.
        ///
        /// `clearFull` (#514): the strap was showing a "fully charged" notification and has now
        /// dropped below 100% — the standing note is stale, so cancel it. It's exactly the full
        /// re-arm transition (previouslyFullAlerted && pct < fullThreshold), surfaced so the
        /// notifier can pull the delivered + pending full-charge notification by its id.
        static func evaluate(pct: Int,
                             charging: Bool?,
                             lowAlerted: Bool,
                             fullAlerted: Bool)
            -> (fireLow: Bool, fireFull: Bool, clearFull: Bool, newLowAlerted: Bool, newFullAlerted: Bool) {
            var low = lowAlerted
            var full = fullAlerted
            // The stale 100%-full note must be cleared the moment we re-arm below the full line.
            let clearFull = fullAlerted && pct < fullThreshold
            // Re-arm (hysteresis) so jitter near a threshold can't re-fire. #80: re-arm ONLY on genuine
            // recovery (pct >= lowRearmAbove), NOT on charging. The strap reports its charge bit only every
            // ~8 min, so it flickers true→nil; re-arming on `true` then firing on the `nil` gap re-fired the
            // low alert repeatedly WHILE charging. `fireLow`'s `charging != true` still suppresses an explicit
            // charging reading, and a null-charging strap (generic/FTMS) still alerts.
            if pct >= lowRearmAbove { low = false }
            if pct < fullThreshold { full = false }
            // Fire at most once per genuine crossing.
            let fireLow = !low && pct <= lowThreshold && charging != true
            let fireFull = !full && pct >= fullThreshold
            if fireLow { low = true }
            if fireFull { full = true }
            return (fireLow, fireFull, clearFull, low, full)
        }
    }

    static func requestAuthorization() {
        Task { _ = try? await UNUserNotificationCenter.current().requestAuthorization(options: [.alert]) }
    }

    /// One physical-device observation feeds both low-percentage and runtime evidence.
    /// Episode identity survives a restart, but authorization failure never consumes its claim.
    @MainActor
    static func observe(deviceID: String, sourceContext: String, pct: Int, remainingHours: Double?,
                        charging: Bool?, enabled: Bool, predictiveEnabled: Bool, now: Date = Date()) async {
        guard !deviceID.isEmpty, (0...100).contains(pct),
              let store = await AppModel.shared?.repo.notificationDecisionStore() else { return }
        let runtime = remainingHours.flatMap { $0.isFinite && $0 >= 0 ? $0 : nil }
        let low = enabled && pct <= 15 && charging != true
        let shortRuntime = predictiveEnabled && runtime.map { $0 <= 24 } == true && charging != true
        // Charging=true/unknown alone never rearms. A measured recovery is necessary.
        do {
            // Track unresolved runtime evidence independently of preference changes. Missing
            // runtime cannot clear a previous low-runtime episode, while percentage-only
            // devices can still rearm from a valid 25% recovery.
            let runtimeConcern = try await store.notificationEpisode(deviceID: deviceID, family: "runtimeEvidence",
                observationIsActive: runtime.flatMap { $0 <= 24 ? true : ($0 >= 36 ? false : nil) }, now: now)
            let cleared = pct >= 25 && runtimeConcern == nil
            let chargeEpisode = try await store.notificationEpisode(deviceID: deviceID, family: "charge",
                observationIsActive: low || shortRuntime ? true : (cleared ? false : nil), now: now)
            let previousFull = try await store.notificationEpisode(deviceID: deviceID, family: "full", observationIsActive: nil, now: now)
            let fullEpisode = try await store.notificationEpisode(deviceID: deviceID, family: "full", observationIsActive: pct == 100, now: now)
            if pct < 100, let previousFull {
                await NotificationCoordinator.shared.withdraw(occurrenceID: "batteryFull:\(deviceID):\(previousFull)")
            }
            var candidates: [NotificationCandidate] = []
            func candidate(group: NotificationGroup, episode: String, title: String, body: String) -> NotificationCandidate {
                let occurrence = "\(group.rawValue):\(deviceID):\(episode)"
                return .init(ruleID: group.rawValue + ".battery", group: group, subjectID: deviceID,
                    occurrenceID: occurrence, attentionKey: "battery:\(deviceID):\(episode)",
                    evidenceRevision: "\(pct):\(runtime.map(String.init(describing:)) ?? "unknown")",
                    sourceContext: sourceContext, logicalDay: NotificationFactBuilder.dayKey(now), observedAt: now,
                    generatedAt: now, expiresAt: now.addingTimeInterval(1800), destination: .device(id: AppModel.shared?.repo.deviceId ?? deviceID),
                    genericTitle: title, genericBody: body)
            }
            if (low || shortRuntime), let chargeEpisode {
                candidates.append(candidate(group: .chargeReminder, episode: chargeEpisode,
                    title: "Charge your device", body: "Your device may need charging before your next recording."))
            }
            if enabled, pct == 100, let fullEpisode {
                candidates.append(candidate(group: .batteryFull, episode: fullEpisode,
                    title: "Device charged", body: "Your device is ready for your next recording."))
            }
            await NotificationCoordinator.shared.process(candidates: candidates)
        } catch { /* Keep episode state unconsumed; a subsequent real observation can retry. */ }
    }
}
