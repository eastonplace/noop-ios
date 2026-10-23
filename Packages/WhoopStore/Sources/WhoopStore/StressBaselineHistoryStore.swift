import Foundation
import GRDB

/// Half-open local-clock hour. The caller resolves calendar/DST boundaries before the store read.
public struct StressBaselineHourWindow: Equatable, Sendable {
    public let startTs: Int
    public let endTs: Int

    public init(startTs: Int, endTs: Int) {
        self.startTs = startTs
        self.endTs = endTs
    }
}

public struct StressBaselineHourSummary: Equatable, Sendable {
    public let startTs: Int
    public let sampleCount: Int
    public let meanHR: Double

    public init(startTs: Int, sampleCount: Int, meanHR: Double) {
        self.startTs = startTs
        self.sampleCount = sampleCount
        self.meanHR = meanHR
    }
}

public enum StressBaselineHistoryReadError: Error, Sendable {
    case invalidWindow
}

extension WhoopStore {
    /// A bounded, read-only reduction for one local day of the optional personal Stress lens.
    ///
    /// Returns at most 25 scalar rows, never a month of raw arrays. SQLite performs the mean/count
    /// reduction on the pool reader. The first source wins each second (active strap before canonical
    /// import), and measured HR wins over PPG within that source, exactly as Repository.hrSamples.
    /// Invalid/off-wrist samples are excluded after source precedence is resolved.
    public nonisolated func stressBaselineHourSummaries(
        deviceIds: [String],
        windows: [StressBaselineHourWindow],
        plausibleBPM: ClosedRange<Int> = 30...240
    ) async throws -> [StressBaselineHourSummary] {
        try Task.checkCancellation()
        var seen = Set<String>()
        let ids = deviceIds.filter { seen.insert($0).inserted }
        guard !ids.isEmpty, !windows.isEmpty else { return [] }
        guard ids.count <= 8, windows.count <= 25,
              windows.allSatisfy({ window in
                  let (duration, overflow) = window.endTs.subtractingReportingOverflow(window.startTs)
                  return !overflow && (1...7_200).contains(duration)
              }),
              zip(windows, windows.dropFirst()).allSatisfy({ $0.0.endTs <= $0.1.startTs }),
              let first = windows.first, let last = windows.last else {
            throw StressBaselineHistoryReadError.invalidWindow
        }
        let (span, overflow) = last.endTs.subtractingReportingOverflow(first.startTs)
        guard !overflow, span <= 27 * 3_600 else {
            throw StressBaselineHistoryReadError.invalidWindow
        }

        let summaries = try await poolRead { db in
            var arguments: [String: DatabaseValue] = [
                "minBPM": plausibleBPM.lowerBound.databaseValue,
                "maxBPM": plausibleBPM.upperBound.databaseValue,
            ]
            // Keep raw fragments typed as String: GRDB also offers SQL interpolation and joined(),
            // whose inferred SQL value would become debug text inside the final String query.
            let bounds: String = windows.enumerated().map { index, window -> String in
                arguments["start\(index)"] = window.startTs.databaseValue
                arguments["end\(index)"] = window.endTs.databaseValue
                return "(\(index), :start\(index), :end\(index))"
            }.joined(separator: ", ")
            var arms: [String] = []
            for (index, id) in ids.enumerated() {
                arguments["device\(index)"] = id.databaseValue
                let higherPriority: String = (0..<index).map { priority -> String in
                    ":device\(priority)"
                }.joined(separator: ", ")
                func excludesHigherPriority(_ alias: String) -> String {
                    guard index > 0 else { return "" }
                    return """
                        AND NOT EXISTS (SELECT 1 FROM hrSample prior
                            WHERE prior.deviceId IN (\(higherPriority)) AND prior.ts = \(alias).ts)
                        AND NOT EXISTS (SELECT 1 FROM ppgHrSample prior
                            WHERE prior.deviceId IN (\(higherPriority)) AND prior.ts = \(alias).ts)
                        """
                }
                arms.append("""
                    SELECT w.slot, h.bpm FROM windows w JOIN hrSample h
                        ON h.deviceId = :device\(index) AND h.ts >= w.lo AND h.ts < w.hi
                    WHERE 1 = 1 \(excludesHigherPriority("h"))
                    """)
                arms.append("""
                    SELECT w.slot, CAST(ROUND(p.bpm) AS INTEGER) AS bpm
                    FROM windows w JOIN ppgHrSample p
                        ON p.deviceId = :device\(index) AND p.ts >= w.lo AND p.ts < w.hi
                    WHERE NOT EXISTS (SELECT 1 FROM hrSample h
                        WHERE h.deviceId = p.deviceId AND h.ts = p.ts)
                    \(excludesHigherPriority("p"))
                    """)
            }
            let rows = try Row.fetchAll(db, sql: """
                WITH windows(slot, lo, hi) AS (VALUES \(bounds)),
                     samples AS (\(arms.joined(separator: " UNION ALL ")))
                SELECT slot, COUNT(*) AS n, AVG(bpm) AS meanHR
                FROM samples WHERE bpm BETWEEN :minBPM AND :maxBPM
                GROUP BY slot ORDER BY slot
                """, arguments: StatementArguments(arguments))
            return rows.map { row in
                let slot: Int = row["slot"]
                return StressBaselineHourSummary(
                    startTs: windows[slot].startTs,
                    sampleCount: row["n"],
                    meanHR: row["meanHR"])
            }
        }
        try Task.checkCancellation()
        return summaries
    }
}
