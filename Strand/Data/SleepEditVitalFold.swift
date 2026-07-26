import Foundation
import WhoopStore

/// Overnight vitals after substituting edited/manual rows into the detector's session set.
/// `didApply` is false when the edits carry no vitals, which keeps ordinary nap logging
/// from perturbing the main night's Charge inputs.
struct SleepEditedVitals: Equatable {
    let restingHr: Int?
    let avgHrv: Double?
    let didApply: Bool
}

enum SleepEditVitalFold {
    /// Replace each detected twin with its edited row, append twinless manual rows, then
    /// fold the real recorded vitals. RHR is the lowest session RHR; HRV is weighted by
    /// each session's effective in-bed duration. Missing values never become zero.
    static func fold(
        detected: [CachedSleepSession],
        edits: [CachedSleepSession],
        fallbackRestingHr: Int?,
        fallbackAvgHrv: Double?
    ) -> SleepEditedVitals {
        // Existing manually-added naps intentionally carry nil RHR/HRV. Only engage the
        // override path when at least one edit was explicitly reprocessed with real vitals.
        guard edits.contains(where: { $0.restingHr != nil || $0.avgHrv != nil }) else {
            return SleepEditedVitals(
                restingHr: fallbackRestingHr,
                avgHrv: fallbackAvgHrv,
                didApply: false)
        }

        let editsByStart = Dictionary(
            edits.map { ($0.startTs, $0) },
            uniquingKeysWith: { first, _ in first })
        let detectedStarts = Set(detected.map(\.startTs))
        let effective = detected.map { editsByStart[$0.startTs] ?? $0 }
            + edits.filter { !detectedStarts.contains($0.startTs) }

        let rhr = effective.compactMap(\.restingHr).min() ?? fallbackRestingHr

        var hrvWeightedSum = 0.0
        var hrvWeight = 0.0
        for session in effective {
            guard let hrv = session.avgHrv else { continue }
            let duration = Double(max(1, session.endTs - session.effectiveStartTs))
            hrvWeightedSum += hrv * duration
            hrvWeight += duration
        }
        let hrv = hrvWeight > 0 ? hrvWeightedSum / hrvWeight : fallbackAvgHrv

        return SleepEditedVitals(restingHr: rhr, avgHrv: hrv, didApply: true)
    }
}
