import Foundation

public struct HistoricalStreamCounts: Codable, Equatable, Sendable {
    public let hr: Int
    public let rr: Int
    public let events: Int
    public let battery: Int
    public let spo2: Int
    public let skinTemp: Int
    public let respiration: Int
    public let gravity: Int
    public let steps: Int
    public let sleepState: Int
    public let ppgHR: Int
    public let ppgWaveform: Int

    public init(
        hr: Int = 0,
        rr: Int = 0,
        events: Int = 0,
        battery: Int = 0,
        spo2: Int = 0,
        skinTemp: Int = 0,
        respiration: Int = 0,
        gravity: Int = 0,
        steps: Int = 0,
        sleepState: Int = 0,
        ppgHR: Int = 0,
        ppgWaveform: Int = 0
    ) throws {
        let values = [hr, rr, events, battery, spo2, skinTemp, respiration, gravity,
                      steps, sleepState, ppgHR, ppgWaveform]
        guard values.allSatisfy({ $0 >= 0 }) else { throw HistoricalEvidenceError.invalidCount }
        var checkedTotal = 0
        for value in values {
            let (next, overflow) = checkedTotal.addingReportingOverflow(value)
            guard !overflow else { throw HistoricalEvidenceError.invalidCount }
            checkedTotal = next
        }
        self.hr = hr
        self.rr = rr
        self.events = events
        self.battery = battery
        self.spo2 = spo2
        self.skinTemp = skinTemp
        self.respiration = respiration
        self.gravity = gravity
        self.steps = steps
        self.sleepState = sleepState
        self.ppgHR = ppgHR
        self.ppgWaveform = ppgWaveform
    }

    public var total: Int {
        [hr, rr, events, battery, spo2, skinTemp, respiration, gravity,
         steps, sleepState, ppgHR, ppgWaveform].reduce(0, +)
    }
}

/// One contiguous temporal evidence bucket. Receipts may carry several buckets; the analysis planner expands
/// each bucket independently and never fills the empty calendar space between sparse buckets.
public struct HistoricalTimestampBucket: Codable, Equatable, Hashable, Sendable {
    public let minimumTs: Int
    public let maximumTs: Int

    public init(minimumTs: Int, maximumTs: Int) throws {
        guard minimumTs <= maximumTs else { throw HistoricalEvidenceError.invertedBucket }
        self.minimumTs = minimumTs
        self.maximumTs = maximumTs
    }
}

public enum HistoricalHealMode: Codable, Equatable, Sendable {
    case none
    case exactDays(Set<CivilDay>)
    case fullHistoryRepair(reason: String)
}

public struct HistoricalReceiptEvidence: Codable, Equatable, Sendable {
    public let generation: Int64
    /// Time-zone context recorded when this receipt was committed. Work admission groups receipts by this
    /// value so exact civil-day windows are never reinterpreted through the phone's later time zone.
    public let recordedTimeZoneIdentifier: String
    public let decodedRows: HistoricalStreamCounts
    public let insertedRows: HistoricalStreamCounts
    public let timestampBuckets: [HistoricalTimestampBucket]
    public let explicitDays: Set<CivilDay>
    public let healMode: HistoricalHealMode

    public init(
        generation: Int64,
        recordedTimeZoneIdentifier: String,
        decodedRows: HistoricalStreamCounts,
        insertedRows: HistoricalStreamCounts,
        timestampBuckets: [HistoricalTimestampBucket],
        explicitDays: Set<CivilDay> = [],
        healMode: HistoricalHealMode = .none
    ) throws {
        guard generation > 0 else { throw HistoricalEvidenceError.invalidGeneration }
        guard TimeZone(identifier: recordedTimeZoneIdentifier) != nil else {
            throw HistoricalEvidenceError.invalidTimeZone
        }
        if decodedRows.total > 0 && timestampBuckets.isEmpty && explicitDays.isEmpty {
            throw HistoricalEvidenceError.productiveReceiptWithoutTimeEvidence
        }
        self.generation = generation
        self.recordedTimeZoneIdentifier = recordedTimeZoneIdentifier
        self.decodedRows = decodedRows
        self.insertedRows = insertedRows
        self.timestampBuckets = timestampBuckets.sorted {
            ($0.minimumTs, $0.maximumTs) < ($1.minimumTs, $1.maximumTs)
        }
        self.explicitDays = explicitDays
        self.healMode = healMode
    }

    /// Insert counts are diagnostics. Decoded evidence and explicit repairs determine whether scoring is owed.
    public var requiresAnalysis: Bool {
        // Timestamp buckets are range evidence only. A console-only or metadata-only chunk can carry a
        // received range without any physiological row that needs scoring. Decoded rows, explicit day
        // evidence, or an explicit repair obligation are the only analysis triggers.
        if decodedRows.total > 0 || !explicitDays.isEmpty { return true }
        switch healMode {
        case .none: return false
        case .exactDays, .fullHistoryRepair: return true
        }
    }
}

public enum HistoricalEvidenceError: Error, Equatable, Sendable {
    case invalidCount
    case invalidGeneration
    case invalidTimeZone
    case mixedTimeZoneEvidence
    case invertedBucket
    case productiveReceiptWithoutTimeEvidence
    case nonGregorianCalendar
    case tooManyDays
    case invalidBatchLimit
    case unrepresentableDate
}

/// Converts exact sample instants into UTC-day buckets. UTC is only a compression boundary; it is never used
/// as the health-day identity. The consumer later maps every bucket to its recorded local calendar.
public enum HistoricalTimestampBucketBuilder {
    public static func buckets(from timestamps: [Int]) throws -> [HistoricalTimestampBucket] {
        guard !timestamps.isEmpty else { return [] }
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        var ranges: [DateComponents: (minimum: Int, maximum: Int)] = [:]
        for timestamp in Set(timestamps) {
            let date = Date(timeIntervalSince1970: TimeInterval(timestamp))
            guard date.timeIntervalSinceReferenceDate.isFinite else {
                throw HistoricalEvidenceError.unrepresentableDate
            }
            let key = calendar.dateComponents([.year, .month, .day], from: date)
            if let current = ranges[key] {
                ranges[key] = (min(current.minimum, timestamp), max(current.maximum, timestamp))
            } else {
                ranges[key] = (timestamp, timestamp)
            }
        }
        return try ranges.values
            .map { try HistoricalTimestampBucket(minimumTs: $0.minimum, maximumTs: $0.maximum) }
            .sorted { ($0.minimumTs, $0.maximumTs) < ($1.minimumTs, $1.maximumTs) }
    }
}


/// One bounded exact-analysis unit. Large receipt backlogs are split before durable work is written, so one
/// pending item cannot grow without limit or block current-day work behind years of history.
public struct HistoricalExactWorkBatch: Equatable, Sendable {
    public let firstReceiptGeneration: Int64
    public let lastReceiptGeneration: Int64
    public let affectedDays: Set<CivilDay>
    public let timestampBuckets: [HistoricalTimestampBucket]

    public init(
        firstReceiptGeneration: Int64,
        lastReceiptGeneration: Int64,
        affectedDays: Set<CivilDay>,
        timestampBuckets: [HistoricalTimestampBucket]
    ) throws {
        guard firstReceiptGeneration > 0,
              lastReceiptGeneration >= firstReceiptGeneration,
              !affectedDays.isEmpty else {
            throw HistoricalEvidenceError.invalidGeneration
        }
        self.firstReceiptGeneration = firstReceiptGeneration
        self.lastReceiptGeneration = lastReceiptGeneration
        self.affectedDays = affectedDays
        self.timestampBuckets = timestampBuckets.sorted {
            ($0.minimumTs, $0.maximumTs) < ($1.minimumTs, $1.maximumTs)
        }
    }

    public var minimumTs: Int? { timestampBuckets.map(\.minimumTs).min() }
    public var maximumTs: Int? { timestampBuckets.map(\.maximumTs).max() }
}

/// Convert exact receipt evidence into bounded work batches. Evidence is processed in receipt order. A single
/// receipt with many explicit repair days is split safely; each resulting item keeps the same receipt edge.
public enum HistoricalExactWorkBatchPlanner {
    public static func batches(
        for evidence: [HistoricalReceiptEvidence],
        maximumDaysPerBatch: Int = 64
    ) throws -> [HistoricalExactWorkBatch] {
        guard maximumDaysPerBatch > 0 else { throw HistoricalEvidenceError.invalidBatchLimit }
        let exact = evidence
            .filter { item in
                guard item.requiresAnalysis else { return false }
                if case .fullHistoryRepair = item.healMode { return false }
                return true
            }
            .sorted { $0.generation < $1.generation }
        guard !exact.isEmpty else { return [] }
        let timeZones = Set(exact.map(\.recordedTimeZoneIdentifier))
        guard timeZones.count == 1 else { throw HistoricalEvidenceError.mixedTimeZoneEvidence }

        var result: [HistoricalExactWorkBatch] = []
        var currentDays = Set<CivilDay>()
        var currentBuckets: [HistoricalTimestampBucket] = []
        var currentFirst: Int64?
        var currentLast: Int64?

        func flush() throws {
            guard let first = currentFirst, let last = currentLast, !currentDays.isEmpty else { return }
            result.append(try HistoricalExactWorkBatch(
                firstReceiptGeneration: first,
                lastReceiptGeneration: last,
                affectedDays: currentDays,
                timestampBuckets: currentBuckets
            ))
            currentDays.removeAll(keepingCapacity: true)
            currentBuckets.removeAll(keepingCapacity: true)
            currentFirst = nil
            currentLast = nil
        }

        for item in exact {
            let (bucketBudget, bucketOverflow) = item.timestampBuckets.count.multipliedReportingOverflow(by: 3)
            let (evidenceBudget, evidenceOverflow) = item.explicitDays.count.addingReportingOverflow(bucketBudget)
            let (itemBudget, itemBudgetOverflow) = evidenceBudget.addingReportingOverflow(8)
            guard !bucketOverflow, !evidenceOverflow, !itemBudgetOverflow else {
                throw HistoricalEvidenceError.tooManyDays
            }
            let itemDays = try HistoricalAffectedDayPlanner.affectedDays(
                for: [item],
                maximumTotalDays: max(maximumDaysPerBatch, itemBudget)
            ).sorted()
            guard !itemDays.isEmpty else { continue }

            var offset = 0
            while offset < itemDays.count {
                let remainingCapacity = maximumDaysPerBatch - currentDays.count
                if remainingCapacity == 0 { try flush(); continue }
                let upper = min(itemDays.count, offset + remainingCapacity)
                currentDays.formUnion(itemDays[offset..<upper])
                currentBuckets.append(contentsOf: item.timestampBuckets)
                currentFirst = min(currentFirst ?? item.generation, item.generation)
                currentLast = max(currentLast ?? item.generation, item.generation)
                offset = upper
                if currentDays.count == maximumDaysPerBatch { try flush() }
            }
        }
        try flush()
        return result
    }
}


public enum HistoricalAffectedDayPlanner {
    /// Exact expansion: enumerate inside each bucket, then union explicit/heal days. Never enumerate from the
    /// global minimum of all receipts to the global maximum.
    public static func affectedDays(
        for evidence: [HistoricalReceiptEvidence],
        maximumTotalDays: Int = 512
    ) throws -> Set<CivilDay> {
        let timeZones = Set(evidence.map(\.recordedTimeZoneIdentifier))
        guard timeZones.count <= 1 else { throw HistoricalEvidenceError.mixedTimeZoneEvidence }
        guard let timeZoneIdentifier = timeZones.first else { return [] }
        let healthCalendar = try HealthCalendar(timeZoneIdentifier: timeZoneIdentifier)

        var result = Set<CivilDay>()
        for receipt in evidence where receipt.requiresAnalysis {
            result.formUnion(receipt.explicitDays)
            switch receipt.healMode {
            case .none:
                break
            case .exactDays(let days):
                result.formUnion(days)
            case .fullHistoryRepair:
                // A broad repair is intentionally not converted into an accidental exact-day sweep here.
                continue
            }

            for bucket in receipt.timestampBuckets {
                let lower = Date(timeIntervalSince1970: TimeInterval(bucket.minimumTs))
                let upper = Date(timeIntervalSince1970: TimeInterval(bucket.maximumTs))
                let first = try healthCalendar.civilDay(containing: lower)
                let last = try healthCalendar.civilDay(containing: upper)
                let bucketDays = try healthCalendar.days(from: first, through: last, limit: 32)
                result.formUnion(bucketDays)
                result.insert(try healthCalendar.physiologicalDay(containing: lower))
                result.insert(try healthCalendar.physiologicalDay(containing: upper))
                guard result.count <= maximumTotalDays else {
                    throw HistoricalEvidenceError.tooManyDays
                }
            }
        }
        return result
    }
}
