import Foundation
import WhoopProtocol

/// Overlap-aware de-duplication of banked sleep sessions (#899).
///
/// An unstable strap clock can re-bank the SAME night's raw data under a shifted timebase across
/// syncs, so successive analyze passes detect the night at shifted bounds and the sleepSession
/// table accumulates two (or more) OVERLAPPING copies of one night under different `startTs` keys.
/// The exact (deviceId, startTs) primary-key upsert cannot collapse them (the keys differ), day
/// assignment then keys the stale copy to the wrong wake day, and Charge/Rest pin to the old night.
///
/// This is the shared collapse rule, applied wherever banked sessions are assembled before day
/// assignment / scoring (habitual-midsleep learning, band sleep-state consumption, and the
/// post-upsert store heal in IntelligenceEngine). Pure + deterministic so it is unit-tested
/// directly and the Kotlin twin (`com.noop.analytics.SleepSessionDedup`) mirrors it byte-for-byte.
public enum SleepSessionDedup {

    /// Cached sessions eventually feed Double/JSON-based analytics. Keep malformed wall clocks out
    /// of the shared dedupe boundary before they can be ranked or forwarded downstream.
    private static let exactDoubleUnixTimestampLimit = 9_007_199_254_740_991

    /// Absolute overlap (seconds) at or above which two sessions are copies of the same night.
    /// On one honest timeline two REAL sleeps can never overlap at all; material overlap only
    /// arises from re-detected bound drift or a timebase-shifted re-bank. 30 min keeps the rule
    /// conservative at the seams: sub-30-min grazes from boundary jitter are never collapsed.
    public static let minOverlapSeconds = 30 * 60

    /// Fractional overlap of the SHORTER session at or above which two sessions are duplicates.
    /// Catches a short duplicate fragment swallowed by a longer copy of the same night even when
    /// the absolute overlap is under the 30 min bar (e.g. a 40 min fragment 60% inside the night).
    public static let minOverlapFractionOfShorter = 0.5

    /// The duration of a valid effective session span. Store rows are persisted data, not trusted
    /// arithmetic inputs: `end > start` still permits an overflowing `end - start` for Int.min/max.
    /// The shared 30-minute to 16-hour policy is part of this trust boundary. A legacy row outside
    /// that policy is quarantined: it is not scored or ranked, and crucially it is not returned as
    /// a duplicate for the analytics heal to delete.
    private static func duration(of session: CachedSleepSession) -> Int? {
        guard SleepSessionWindow.isValid(start: session.effectiveStartTs, end: session.endTs),
              session.effectiveStartTs >= -exactDoubleUnixTimestampLimit,
              session.effectiveStartTs <= exactDoubleUnixTimestampLimit,
              session.endTs >= -exactDoubleUnixTimestampLimit,
              session.endTs <= exactDoubleUnixTimestampLimit
        else { return nil }
        let (duration, overflow) = session.endTs.subtractingReportingOverflow(session.effectiveStartTs)
        guard !overflow else { return nil }
        return duration
    }

    /// Seconds of overlap between the two sessions' EFFECTIVE spans (edited onsets honoured,
    /// mirroring how display / day assignment place the block). 0 when disjoint or quarantined.
    static func overlapSeconds(_ a: CachedSleepSession, _ b: CachedSleepSession) -> Int {
        guard duration(of: a) != nil, duration(of: b) != nil else { return 0 }
        let overlapStart = max(a.effectiveStartTs, b.effectiveStartTs)
        let overlapEnd = min(a.endTs, b.endTs)
        guard overlapEnd > overlapStart else { return 0 }
        let (overlap, overflow) = overlapEnd.subtractingReportingOverflow(overlapStart)
        return overflow ? 0 : overlap
    }

    /// True when `a` and `b` are valid overlapping copies of the same night: overlap of at least
    /// `minOverlapSeconds` absolute, OR at least `minOverlapFractionOfShorter` of the shorter
    /// session's duration. Both terms use only (effectiveStartTs, endTs), the only time fields
    /// the data model carries (there is no banked-at column to compare).
    public static func isDuplicate(_ a: CachedSleepSession, _ b: CachedSleepSession) -> Bool {
        guard let aDuration = duration(of: a), let bDuration = duration(of: b) else { return false }
        let overlap = overlapSeconds(a, b)
        guard overlap > 0 else { return false }
        if overlap >= minOverlapSeconds { return true }
        let shorter = min(aDuration, bDuration)
        return Double(overlap) >= minOverlapFractionOfShorter * Double(shorter)
    }

    /// Collapse overlapping duplicates to one canonical survivor per night, deterministically.
    ///
    /// Canonical preference, highest first:
    ///   1. `userEdited`: a hand-corrected VALID night is never dropped (matching the engine's existing
    ///      edited-window upsert guard, where the user's correction always outranks re-detection).
    ///   2. Bank recency: `startTs` in `freshStarts`. The row model has no banked-at column, so
    ///      recency is witnessed by the CALLER passing the keys it banked this pass; the freshly
    ///      detected copy reflects the strap's current timebase and is the truth to keep.
    ///   3. Longest effective duration: the fullest capture of the night.
    ///   4. Latest endTs, then latest startTs: a stable total order so ties break the same way
    ///      on every run and platform.
    ///
    /// Greedy sweep in preference order: a session is kept unless it overlap-duplicates an
    /// already-kept one (valid edited rows are exempt and always kept). Invalid legacy spans are
    /// deliberately absent from BOTH outputs. Read-side callers therefore exclude them, while the
    /// post-upsert heal only deletes `dropped` valid duplicates and cannot silently destroy a
    /// quarantined user's row. The Sleep screen reads those rows separately for repair.
    /// Both outputs are sorted by startTs. Read-side callers with no bank witness pass no `freshStarts`.
    public static func dedupe(_ sessions: [CachedSleepSession], freshStarts: Set<Int> = [])
        -> (kept: [CachedSleepSession], dropped: [CachedSleepSession]) {
        let valid = sessions.filter { duration(of: $0) != nil }
        guard valid.count > 1 else { return (valid, []) }

        func rank(_ s: CachedSleepSession) -> (Int, Int, Int, Int, Int) {
            (s.userEdited ? 1 : 0,
             freshStarts.contains(s.startTs) ? 1 : 0,
             duration(of: s) ?? 0,
             s.endTs,
             s.startTs)
        }

        let ordered = valid.sorted { rank($0) > rank($1) }
        var kept: [CachedSleepSession] = []
        var dropped: [CachedSleepSession] = []
        for s in ordered {
            if !s.userEdited, kept.contains(where: { isDuplicate($0, s) }) {
                dropped.append(s)
            } else {
                kept.append(s)
            }
        }
        return (kept.sorted { $0.startTs < $1.startTs },
                dropped.sorted { $0.startTs < $1.startTs })
    }
}
