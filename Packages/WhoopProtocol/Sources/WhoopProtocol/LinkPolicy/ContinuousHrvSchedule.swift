import Foundation

/// #927: the "overnight only" schedule for Continuous HRV capture. When the user opts in, the dense
/// R10/R11 + TOGGLE realtime R-R stream that continuous capture holds armed 24/7 is armed only inside a
/// nightly window, roughly halving the battery cost (overnight is where the HRV/recovery/sleep value is;
/// daytime Stress just gets sparser readings, since Stress reads this realtime R-R stream).
///
/// The window reuses the app's quiet-hours convention byte-for-byte (the NotificationSettingsStore keys,
/// the same defaults, and the same wrap-aware membership as SedentaryDetector.windowContains and the
/// Android NotifPrefs.inQuietHours): minutes since LOCAL midnight, inclusive start, exclusive end, and
/// the window may cross midnight (22:00 → 07:00 by default). Local wall time keeps it DST-agnostic the
/// same way quiet hours are: a DST jump moves the wall clock, the window definition never changes.
///
/// The MODE is composed from the two persisted booleans so existing users need no migration:
///   continuous OFF                → stream never held open (unchanged)
///   continuous ON, overnight OFF  → ALWAYS: armed 24/7 (the pre-#927 behaviour; overnight defaults off)
///   continuous ON, overnight ON   → OVERNIGHT: armed only inside the window
///
/// Pure + value-typed so the predicate is unit-testable (ContinuousHrvScheduleTests). BLEManager
/// RE-DERIVES it at every arm site (reconcile / keep-alive tick / post-bond arm) instead of caching it,
/// so a reconnect outside the window can never re-arm the flood from a stale precomputed want.
public struct ContinuousHrvSchedule: Sendable {
    /// The reused quiet-hours window keys (written by NotificationSettingsStore; the same reuse idiom as
    /// InactivityPrefs.NotifK) and their defaults (22:00 / 07:00).
    public static let quietStartKey = "notif.quietStartMinutes"
    public static let quietEndKey = "notif.quietEndMinutes"
    public static let defaultStartMinutes = 22 * 60
    public static let defaultEndMinutes = 7 * 60

    /// Wrap-aware membership: is `minuteOfDay` inside `[startMin, endMin)`, where the window may cross
    /// midnight? Byte-for-byte the quiet-hours semantics (SedentaryDetector.windowContains / the Android
    /// NotifPrefs.inQuietHours): start <= end is the plain daytime interval; start > end wraps midnight.
    public static func windowContains(_ minuteOfDay: Int, startMin: Int, endMin: Int) -> Bool {
        if startMin <= endMin { return minuteOfDay >= startMin && minuteOfDay < endMin }
        return minuteOfDay >= startMin || minuteOfDay < endMin
    }

    /// The composed want: should the continuous-capture stream be held open at local wall-clock minute
    /// `minuteOfDay`? False when the feature is off; true 24/7 in ALWAYS mode (overnightOnly false, the
    /// pre-#927 behaviour every existing user reads with no migration); window-gated in OVERNIGHT mode.
    public static func streamWanted(continuousHrv: Bool, overnightOnly: Bool,
                             minuteOfDay: Int, startMin: Int, endMin: Int) -> Bool {
        guard continuousHrv else { return false }
        guard overnightOnly else { return true }
        return windowContains(minuteOfDay, startMin: startMin, endMin: endMin)
    }
}
