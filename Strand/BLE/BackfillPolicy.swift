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
                       // but it's separately bounded by BLEManager's consecutive-cap + trim spin-detector,
                       // so it can't loop forever the way an un-floored periodic could.
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
    static func periodicFloorSeconds(powerSaving: Bool) -> TimeInterval {
        powerSaving ? lowPowerPeriodicFloorSeconds : periodicFloorSeconds
    }

    /// Absolute wall-clock deadline for the next periodic attempt. The deadline stays anchored to the
    /// last actual offload attempt when the power-saving floor changes. Re-arming a timer at minute 15
    /// after a 15 -> 45 minute transition therefore waits only the remaining 30 minutes, not a fresh 45.
    static func periodicDeadline(now: TimeInterval, lastBackfillAt: TimeInterval?,
                                 powerSaving: Bool) -> TimeInterval {
        (lastBackfillAt ?? now) + periodicFloorSeconds(powerSaving: powerSaving)
    }

    /// Remaining delay for the absolute periodic deadline. A 45 -> 15 minute transition whose shorter
    /// deadline has already passed returns zero so the scheduler can attempt immediately.
    static func periodicDelaySeconds(now: TimeInterval, lastBackfillAt: TimeInterval?,
                                     powerSaving: Bool,
                                     minimumDelaySeconds: TimeInterval = 0) -> TimeInterval {
        let remaining = periodicDeadline(now: now, lastBackfillAt: lastBackfillAt,
                                         powerSaving: powerSaving) - now
        return max(0, max(minimumDelaySeconds, remaining))
    }

    /// `emptyStreak` is intentionally retained in this API for call-site compatibility and the existing
    /// user-facing three-empty warning, but it no longer changes automatic cadence. The old multiplier
    /// made normal mode slower after harmless empty completions and could compound a 45-minute low-power
    /// one-shot timer into a 90-minute effective interval.
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
    /// `emptyStreak`, `.connect`/`.foreground`/`.manual`/`.autoContinue` are never affected.
    static func shouldRun(trigger: BackfillTrigger, now: TimeInterval,
                          lastBackfillAt: TimeInterval?, emptyStreak: Int = 0,
                          clockUntrusted: Bool = false,
                          powerSaving: Bool = false) -> Bool {
        guard let last = lastBackfillAt else { return true }
        let elapsed = now - last
        _ = emptyStreak
        switch trigger {
        // .manual (user-tapped) and .autoContinue (#364 expedited backlog drain) always run — both are
        // deliberately un-floored; .autoContinue's runaway protection lives in BLEManager's cap, not here.
        case .manual, .autoContinue: return true
        case .connect, .foreground:  return elapsed >= eventFloorSeconds
        // #160: a future-dated-clock strap's recurring automatic offloads are near-useless (#1012 won't
        // trust the range) but each holds the link ~60s and starves the WHOOP4 realtime-HR re-arm, so skip
        // them entirely — not just stretch the floor. The .connect pass above still re-checks the clock.
        case .strap:                 return !clockUntrusted && elapsed >= eventFloorSeconds
        case .periodic:              return !clockUntrusted && elapsed >= periodicFloorSeconds(powerSaving: powerSaving)
        }
    }
}
