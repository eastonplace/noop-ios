import Foundation

/// What prompted a sync attempt. Mirrors WHOOP (15-min periodic floor + event-triggered "process now"
/// syncs + the strap's own prompt events + manual), adapted to iOS.
enum BackfillTrigger {
    case periodic      // the repeating timer while connected+bonded
    case connect       // a (re)connect / bond confirmation
    case foreground    // the app became active (scenePhase .active)
    case manual        // the user tapped "Sync now"
    case strap         // an incoming strap EVENT packet (WHOOP's HighFreqSyncPrompt analog)
    case autoContinue  // #364: an immediate back-to-back continuation of a deep oldest-first backlog,
                       // fired right after a 60s idle-cap exit while still connected. Like .manual it
                       // bypasses the floor — the whole point is to NOT wait the 15-min periodic floor —
                       // but BLEManager separately bounds it by pass count, radio time, durable progress,
                       // and the trim/fingerprint/frontier signature.
}

/// Pure rate-limiter for historical-offload kicks. No BLE/store deps. Floors match WHOOP
/// (observed: ~15-min periodic + expedited event syncs).
enum BackfillPolicy {
    static let periodicFloorSeconds: TimeInterval = 900   // 15 min
    static let lowPowerPeriodicFloorSeconds: TimeInterval = 2_700 // 45 min
    static let eventFloorSeconds: TimeInterval = 90       // absorbs reconnect-flaps / event bursts

    /// The timer and limiter must use the same periodic cadence. Keeping this decision here prevents a
    /// 45-minute low-power timer from repeatedly hitting an unrelated 60-minute floor and becoming an
    /// accidental 90-minute sync gap.
    static func periodicFloorSeconds(powerSaving: Bool, emptyStreak: Int = 0) -> TimeInterval {
        // Empty, replay-only, and stalled attempts add no user data but keep the radio active. Back off
        // automatic retries through 15 -> 30 -> 60 minutes. Low-power mode keeps its existing 45-minute
        // minimum, then joins the same 60-minute ceiling after two empty attempts.
        let adaptive = periodicFloorSeconds * Double(1 << min(max(0, emptyStreak), 2))
        return max(powerSaving ? lowPowerPeriodicFloorSeconds : periodicFloorSeconds, adaptive)
    }

    /// Absolute wall-clock deadline for the next periodic attempt. The deadline stays anchored to the
    /// last actual offload attempt when the power-saving floor changes. Re-arming a timer at minute 15
    /// after a 15 -> 45 minute transition therefore waits only the remaining 30 minutes, not a fresh 45.
    static func periodicDeadline(now: TimeInterval, lastBackfillAt: TimeInterval?,
                                 powerSaving: Bool, emptyStreak: Int = 0) -> TimeInterval {
        (lastBackfillAt ?? now) + periodicFloorSeconds(
            powerSaving: powerSaving,
            emptyStreak: emptyStreak
        )
    }

    /// Remaining delay for the absolute periodic deadline. A 45 -> 15 minute transition whose shorter
    /// deadline has already passed returns zero so the scheduler can attempt immediately.
    static func periodicDelaySeconds(now: TimeInterval, lastBackfillAt: TimeInterval?,
                                     powerSaving: Bool,
                                     emptyStreak: Int = 0,
                                     minimumDelaySeconds: TimeInterval = 0) -> TimeInterval {
        let remaining = periodicDeadline(now: now, lastBackfillAt: lastBackfillAt,
                                         powerSaving: powerSaving, emptyStreak: emptyStreak) - now
        return max(0, max(minimumDelaySeconds, remaining))
    }

    /// `emptyStreak` covers attempts that produced no new durable receipt work. It affects only automatic
    /// cadence; manual and bounded auto-continue admission remain separate below.
    ///
    /// `clockUntrusted` = the strap's own RTC currently reads future-dated (#928: `BackfillContinuation
    /// .isFutureDatedNewest`). Such a strap still BANKS real rows every pass, so it never trips the
    /// `emptyStreak` backoff above, yet #1012 already refuses to chase that range past one pass per
    /// connection — so the recurring AUTOMATIC triggers get near-zero value from retrying it, at a real
    /// cost: each ~60s offload holds the link and blocks the WHOOP4 realtime-HR keep-alive re-arm
    /// (BLEManager `guard !backfilling`), so live HR lapses (#160: "HR not displaying while band is
    /// active" on a strap whose logs showed exactly this future-dated clock). So `.strap`/`.periodic` are
    /// SKIPPED ENTIRELY while the clock is untrusted — the per-connection `.connect` pass still runs, so a
    /// clock that later self-corrects is picked up on the next connection (or a manual sync). As with
    /// `.connect` still gets one per-connection attempt; manual and bounded auto-continue are unaffected.
    static func shouldRun(trigger: BackfillTrigger, now: TimeInterval,
                          lastBackfillAt: TimeInterval?, emptyStreak: Int = 0,
                          clockUntrusted: Bool = false,
                          powerSaving: Bool = false) -> Bool {
        guard let last = lastBackfillAt else { return true }
        let elapsed = now - last
        switch trigger {
        // .manual (user-tapped) and .autoContinue (#364 expedited backlog drain) always run — both are
        // deliberately un-floored; .autoContinue's runaway protection lives in BLEManager.
        case .manual, .autoContinue: return true
        case .connect: return elapsed >= eventFloorSeconds
        case .foreground:
            let emptyBackoff = emptyStreak > 0
                ? periodicFloorSeconds(powerSaving: powerSaving, emptyStreak: emptyStreak)
                : eventFloorSeconds
            return elapsed >= emptyBackoff
        // #160: a future-dated-clock strap's recurring automatic offloads are near-useless (#1012 won't
        // trust the range) but each holds the link ~60s and starves the WHOOP4 realtime-HR re-arm, so skip
        // them entirely — not just stretch the floor. The .connect pass above still re-checks the clock.
        case .strap:
            let emptyBackoff = emptyStreak > 0
                ? periodicFloorSeconds(powerSaving: powerSaving, emptyStreak: emptyStreak)
                : eventFloorSeconds
            return !clockUntrusted && elapsed >= emptyBackoff
        case .periodic:              return !clockUntrusted && elapsed >= periodicFloorSeconds(
            powerSaving: powerSaving,
            emptyStreak: emptyStreak
        )
        }
    }
}
