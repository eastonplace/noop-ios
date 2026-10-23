import Foundation

/// Long-horizon training-load model using exponentially weighted daily load.
///
/// Complements `ReadinessEngine`'s existing rolling-mean ACWR and Foster monotony without replacing
/// either and WITHOUT feeding the Readiness level. It keeps chronic load (CTL), acute load (ATL), and
/// their difference (TSB / "form") in the SAME units as the supplied daily load. NOOP currently supplies
/// daily Effort/strain, so these values are not TRIMP and must not be relabelled as such.
///
/// Model:
///   alpha = 1 - exp(-1 / tauDays)
///   state[t] = state[t-1] + alpha * (load[t] - state[t-1])
///   TSB[t] = CTL[t] - ATL[t]
///
/// Standard time constants are 42 days (chronic/fitness) and 7 days (acute/fatigue) — the classic
/// Banister-style fitness-fatigue horizons. The first `primeDays` observations are averaged to seed both
/// states, avoiding the artificial low bias of zero-seeding a new wearer.
///
/// Short gaps (AN-13): up to `maxGapDays` consecutive missing rows or nil loads are stepped with zero
/// load, so the averages decay through a day or two off-wrist instead of the whole model resetting for
/// weeks. A longer gap ends the run; older history before it is ignored. Calendar time is never
/// compressed, gap days are never reported as measured rest days (no point is emitted for them), and
/// `coverage` says how much of the modeled span was observed. A real rest day is a row whose load is 0.
public enum TrainingLoadEngine {
    public struct Configuration: Sendable, Equatable {
        public let chronicTimeConstantDays: Double
        public let acuteTimeConstantDays: Double
        public let primeDays: Int
        public let minimumDays: Int
        public let establishedDays: Int
        /// Longest run of consecutive missing or nil days stepped with zero load; one more ends the run.
        public let maxGapDays: Int

        public init(chronicTimeConstantDays: Double = 42,
                    acuteTimeConstantDays: Double = 7,
                    primeDays: Int = 7,
                    minimumDays: Int = 14,
                    establishedDays: Int = 42,
                    maxGapDays: Int = 2) {
            self.chronicTimeConstantDays = chronicTimeConstantDays
            self.acuteTimeConstantDays = acuteTimeConstantDays
            self.primeDays = primeDays
            self.minimumDays = minimumDays
            self.establishedDays = establishedDays
            self.maxGapDays = maxGapDays
        }

        public static let standard = Configuration()

        fileprivate var isValid: Bool {
            chronicTimeConstantDays.isFinite && chronicTimeConstantDays > 0
                && acuteTimeConstantDays.isFinite && acuteTimeConstantDays > 0
                && primeDays > 0
                && minimumDays >= primeDays
                && establishedDays >= minimumDays
                && maxGapDays >= 0
        }
    }

    /// Calendar-day input. `load == nil` means the day has no usable load observation; that differs from
    /// `load == 0`, a measured rest day that stays in the model.
    public struct DailyLoad: Sendable, Equatable {
        public let day: String       // strict Gregorian YYYY-MM-DD
        public let load: Double?

        public init(day: String, load: Double?) {
            self.day = day
            self.load = load
        }
    }

    public enum State: String, Sendable, Equatable, Codable {
        /// No trustworthy model is emitted yet. See `unavailableReason` and `contiguousDays`.
        case unavailable
        /// Minimum history is present, but the chronic 42-day state is still calibrating.
        case building
        /// At least the configured established-history window is contiguous and observed.
        case established
    }

    public enum UnavailableReason: String, Sendable, Equatable, Codable {
        case noData
        case missingTargetDay
        case notEnoughContiguousDays
        case invalidConfiguration
        case invalidDay
        case duplicateDay
        case invalidLoad
    }

    /// One chart-ready modeled day. The first point is the final priming day; CTL/ATL have no defined
    /// pre-seed state before then.
    public struct Point: Sendable, Equatable, Codable {
        public let day: String
        public let load: Double
        public let chronicLoad: Double
        public let acuteLoad: Double
        public let balance: Double

        public var ctl: Double { chronicLoad }
        public var atl: Double { acuteLoad }
        public var tsb: Double { balance }
    }

    public struct Result: Sendable, Equatable {
        public let state: State
        public let unavailableReason: UnavailableReason?
        /// Observed days in the modeled run ending on the target. Gaps of up to `maxGapDays` don't end the
        /// run but don't count here; the minimum and established thresholds read this count.
        public let contiguousDays: Int
        /// Calendar days from `startDay` through `endDay`, tolerated gap days included.
        public let spanDays: Int
        public let startDay: String?
        public let endDay: String?
        /// One point per observed day; gap days only decay the state.
        public let points: [Point]

        /// Share of the modeled span with an observed load (1 = no gaps); nil when nothing was modeled.
        public var coverage: Double? {
            spanDays > 0 ? Double(contiguousDays) / Double(spanDays) : nil
        }

        /// Latest modeled chronic load (CTL), in the same units as input load.
        public var chronicLoad: Double? { points.last?.chronicLoad }
        /// Latest modeled acute load (ATL), in the same units as input load.
        public var acuteLoad: Double? { points.last?.acuteLoad }
        /// Latest CTL - ATL balance (TSB / form), in the same units as input load.
        public var balance: Double? { points.last?.balance }

        public var ctl: Double? { chronicLoad }
        public var atl: Double? { acuteLoad }
        public var tsb: Double? { balance }
        public var isAvailable: Bool { state != .unavailable }
    }

    /// Evaluate the latest day in the input, or an explicit target day. Inputs may be in any order.
    ///
    /// The run ending on the (observed) target is modeled. Gaps of up to `maxGapDays` inside it decay the
    /// state with zero load; history before a longer gap is ignored rather than compressing calendar time.
    public static func evaluate(days: [DailyLoad],
                                through targetDay: String? = nil,
                                configuration: Configuration = .standard) -> Result {
        guard configuration.isValid else {
            return unavailable(.invalidConfiguration, contiguousDays: 0)
        }
        guard !days.isEmpty else { return unavailable(.noData, contiguousDays: 0) }

        var parsed: [(day: String, ordinal: Int, load: Double?)] = []
        parsed.reserveCapacity(days.count)
        var seen = Set<Int>()
        for item in days {
            guard let ordinal = dayOrdinal(item.day) else {
                return unavailable(.invalidDay, contiguousDays: 0)
            }
            guard seen.insert(ordinal).inserted else {
                return unavailable(.duplicateDay, contiguousDays: 0)
            }
            if let load = item.load, (!load.isFinite || load < 0) {
                return unavailable(.invalidLoad, contiguousDays: 0)
            }
            parsed.append((item.day, ordinal, item.load))
        }
        parsed.sort { $0.ordinal < $1.ordinal }

        let targetOrdinal: Int
        if let targetDay {
            guard let ordinal = dayOrdinal(targetDay) else {
                return unavailable(.invalidDay, contiguousDays: 0)
            }
            targetOrdinal = ordinal
        } else {
            targetOrdinal = parsed.last!.ordinal
        }

        guard let targetIndex = parsed.lastIndex(where: { $0.ordinal == targetOrdinal }) else {
            return unavailable(.missingTargetDay, contiguousDays: 0)
        }

        // Walk back from the target one calendar day at a time. An unobserved target models nothing; a
        // stored zero stays a measured day; up to `maxGapDays` consecutive missing/nil days are kept as
        // zero-load steps and one more ends the run. Future rows never affect this target's model.
        var loadByOrdinal: [Int: Double?] = [:]
        for item in parsed[...targetIndex] { loadByOrdinal[item.ordinal] = item.load }
        let earliestOrdinal = parsed[0].ordinal
        var runReversed: [(ordinal: Int, load: Double?)] = []
        var gap = 0
        var ordinal = targetOrdinal
        while ordinal >= earliestOrdinal {
            if let load = loadByOrdinal[ordinal] ?? nil {
                runReversed.append((ordinal, load))
                gap = 0
            } else {
                if runReversed.isEmpty { break }
                gap += 1
                if gap > configuration.maxGapDays { break }
                runReversed.append((ordinal, nil))
            }
            ordinal -= 1
        }
        while runReversed.last.map({ $0.load == nil }) == true { runReversed.removeLast() }
        let ordered = Array(runReversed.reversed())
        let observed = ordered.compactMap { item in item.load.map { (ordinal: item.ordinal, load: $0) } }
        let contiguousDays = observed.count
        let startDay = ordered.first.map { dayString(ordinal: $0.ordinal) }
        let endDay = ordered.last.map { dayString(ordinal: $0.ordinal) }
        guard contiguousDays >= configuration.minimumDays else {
            return unavailable(.notEnoughContiguousDays,
                               contiguousDays: contiguousDays,
                               spanDays: ordered.count,
                               startDay: startDay,
                               endDay: endDay)
        }

        // Seed from the first `primeDays` observations (gap days inside the priming window are skipped,
        // not averaged in as zero), then step every later calendar day, gap days with zero load.
        let seedDay = observed[configuration.primeDays - 1]
        let primingLoads = observed.prefix(configuration.primeDays).map(\.load)
        let primingSum = primingLoads.reduce(0.0, +)
        // Accepted finite loads can still overflow when summed. Preserve ordinary model arithmetic,
        // and use a scaled mean only for that overflow path.
        guard let seed = primingSum.isFinite
            ? primingSum / Double(configuration.primeDays)
            : StableStatistics.mean(primingLoads) else {
            return unavailable(.invalidLoad, contiguousDays: contiguousDays)
        }
        let alphaChronic = smoothingFactor(timeConstantDays: configuration.chronicTimeConstantDays)
        let alphaAcute = smoothingFactor(timeConstantDays: configuration.acuteTimeConstantDays)

        var chronic = seed
        var acute = seed
        var points: [Point] = []
        points.reserveCapacity(contiguousDays - configuration.primeDays + 1)
        points.append(Point(day: dayString(ordinal: seedDay.ordinal), load: seedDay.load,
                            chronicLoad: chronic, acuteLoad: acute, balance: chronic - acute))

        for item in ordered where item.ordinal > seedDay.ordinal {
            let load = item.load ?? 0
            (acute, chronic) = advance(acute: acute, chronic: chronic, load: load,
                                       alphaAcute: alphaAcute, alphaChronic: alphaChronic)
            if let observedLoad = item.load {
                points.append(Point(day: dayString(ordinal: item.ordinal), load: observedLoad,
                                    chronicLoad: chronic, acuteLoad: acute, balance: chronic - acute))
            }
        }

        return Result(
            state: contiguousDays >= configuration.establishedDays ? .established : .building,
            unavailableReason: nil,
            contiguousDays: contiguousDays,
            spanDays: ordered.count,
            startDay: startDay,
            endDay: endDay,
            points: points
        )
    }

    // MARK: - One step of the model

    /// The per-day smoothing factor `alpha = 1 - exp(-1 / tau)` for a time constant in days. `evaluate` and `step` both
    /// read it here, so a projection can never drift from the model it projects.
    public static func smoothingFactor(timeConstantDays: Double) -> Double {
        1 - exp(-1 / timeConstantDays)
    }

    /// The model's own one-day update, for a projection: the acute and chronic state after a day with `load`, in the
    /// same units as the state. This is exactly the step `evaluate` takes for every day after the seed, so a "what if
    /// tomorrow" built on it reuses the engine's math instead of restating it. Pure; nothing is stored.
    public static func step(acute: Double, chronic: Double, load: Double,
                            configuration: Configuration = .standard) -> (acute: Double, chronic: Double) {
        advance(acute: acute, chronic: chronic, load: load,
                alphaAcute: smoothingFactor(timeConstantDays: configuration.acuteTimeConstantDays),
                alphaChronic: smoothingFactor(timeConstantDays: configuration.chronicTimeConstantDays))
    }

    private static func advance(acute: Double, chronic: Double, load: Double,
                                alphaAcute: Double, alphaChronic: Double) -> (acute: Double, chronic: Double) {
        (acute + alphaAcute * (load - acute), chronic + alphaChronic * (load - chronic))
    }

    /// Convenience for already-dense load arrays used by analytics tests and non-calendar callers. Day
    /// labels are synthetic but deterministic; the model math is identical to `evaluate(days:)`.
    public static func evaluateDense(_ loads: [Double],
                                     configuration: Configuration = .standard) -> Result {
        let baseOrdinal = dayOrdinal("2000-01-01")!
        let days = loads.enumerated().map { offset, load in
            DailyLoad(day: dayString(ordinal: baseOrdinal + offset), load: load)
        }
        return evaluate(days: days, configuration: configuration)
    }

    private static func unavailable(_ reason: UnavailableReason,
                                    contiguousDays: Int,
                                    spanDays: Int = 0,
                                    startDay: String? = nil,
                                    endDay: String? = nil) -> Result {
        Result(state: .unavailable, unavailableReason: reason, contiguousDays: contiguousDays,
               spanDays: spanDays, startDay: startDay, endDay: endDay, points: [])
    }

    // MARK: - Strict, timezone-free Gregorian calendar helpers

    /// Gregorian date -> day ordinal using Howard Hinnant's civil-date transform. Integer-only and
    /// timezone-free so the Swift/Kotlin twins cannot drift around DST or locale boundaries.
    private static func dayOrdinal(_ value: String) -> Int? {
        let parts = value.split(separator: "-", omittingEmptySubsequences: false)
        guard parts.count == 3,
              parts[0].count == 4, parts[1].count == 2, parts[2].count == 2,
              let year = Int(parts[0]), let month = Int(parts[1]), let day = Int(parts[2]),
              year >= 1, (1...12).contains(month) else { return nil }
        let daysInMonth: [Int] = [31, isLeapYear(year) ? 29 : 28, 31, 30, 31, 30, 31, 31, 30, 31, 30, 31]
        guard (1...daysInMonth[month - 1]).contains(day) else { return nil }

        let adjustedYear = year - (month <= 2 ? 1 : 0)
        let era = floorDiv(adjustedYear, 400)
        let yearOfEra = adjustedYear - era * 400
        let shiftedMonth = month + (month > 2 ? -3 : 9)
        let dayOfYear = (153 * shiftedMonth + 2) / 5 + day - 1
        let dayOfEra = yearOfEra * 365 + yearOfEra / 4 - yearOfEra / 100 + dayOfYear
        return era * 146_097 + dayOfEra - 719_468
    }

    private static func dayString(ordinal: Int) -> String {
        let z = ordinal + 719_468
        let era = floorDiv(z, 146_097)
        let dayOfEra = z - era * 146_097
        let yearOfEra = (dayOfEra - dayOfEra / 1_460 + dayOfEra / 36_524 - dayOfEra / 146_096) / 365
        var year = yearOfEra + era * 400
        let dayOfYear = dayOfEra - (365 * yearOfEra + yearOfEra / 4 - yearOfEra / 100)
        let monthPrime = (5 * dayOfYear + 2) / 153
        let day = dayOfYear - (153 * monthPrime + 2) / 5 + 1
        let month = monthPrime + (monthPrime < 10 ? 3 : -9)
        year += month <= 2 ? 1 : 0
        return String(format: "%04d-%02d-%02d", year, month, day)
    }

    private static func isLeapYear(_ year: Int) -> Bool {
        year % 4 == 0 && (year % 100 != 0 || year % 400 == 0)
    }

    private static func floorDiv(_ value: Int, _ divisor: Int) -> Int {
        let quotient = value / divisor
        let remainder = value % divisor
        return remainder < 0 ? quotient - 1 : quotient
    }
}
