import Foundation

/// Provenance-preserving Strain read model. Storage remains on NOOP's 0...100 axis;
/// presentation packages apply the shared 0...21 `StrainScale` at the UI boundary.
public struct ResolvedStrain: Equatable, Sendable {
    public enum Origin: String, Equatable, Sendable {
        case liveDayV2
        case computedDailyV2
        case computedWorkoutV2
        case importedWhoop
        case legacy
    }

    public let day: String?
    public let storedValue: Double
    public let version: Int?
    public let origin: Origin
    public let sourceId: String
    public let asOf: Date?
    public let rawFrontierTs: Int?

    public init(day: String?, storedValue: Double, version: Int?, origin: Origin,
                sourceId: String, asOf: Date? = nil, rawFrontierTs: Int? = nil) {
        self.day = day
        self.storedValue = storedValue
        self.version = version
        self.origin = origin
        self.sourceId = sourceId
        self.asOf = asOf
        self.rawFrontierTs = rawFrontierTs
    }
}

/// One source row plus the raw-data frontier used to compare persisted and live freshness.
public struct DailyStrainCandidate: Equatable {
    public let metric: DailyMetric
    public let sourceId: String
    public let asOf: Date?
    public let rawFrontierTs: Int?

    public init(metric: DailyMetric, sourceId: String, asOf: Date? = nil,
                rawFrontierTs: Int? = nil) {
        self.metric = metric
        self.sourceId = sourceId
        self.asOf = asOf
        self.rawFrontierTs = rawFrontierTs
    }
}

/// Pure source and freshness selection. Imported and legacy values are deliberately
/// excluded from the canonical NOOP chain and remain available as explicit comparisons.
public enum StrainResolver {
    public static func freshest(persisted: ResolvedStrain?, live: ResolvedStrain?, day: String) -> ResolvedStrain? {
        guard let live, live.day == day, live.version == 2, live.origin == .liveDayV2,
              let liveFrontier = live.rawFrontierTs else { return persisted }
        guard let persisted else { return live }
        guard persisted.day == day, persisted.version == 2,
              persisted.origin == .computedDailyV2 else { return live }
        guard let persistedFrontier = persisted.rawFrontierTs else { return live }
        return liveFrontier >= persistedFrontier ? live : persisted
    }

    public static func canonicalDay(
        day: String,
        computedRows: [DailyStrainCandidate],
        importedRows: [DailyStrainCandidate],
        live: ResolvedStrain?
    ) -> ResolvedStrain? {
        _ = importedRows // Explicitly excluded from the NOOP headline chain.
        let persistedCandidate = computedRows
            .filter { $0.metric.day == day && $0.metric.strainVersion == 2 && $0.metric.strain != nil }
            .max { lhs, rhs in
                (lhs.rawFrontierTs ?? Int.min, lhs.asOf ?? .distantPast)
                    < (rhs.rawFrontierTs ?? Int.min, rhs.asOf ?? .distantPast)
            }

        let persisted = persistedCandidate.flatMap { candidate -> ResolvedStrain? in
            guard let stored = candidate.metric.strain else { return nil }
            return ResolvedStrain(day: day, storedValue: stored, version: 2,
                                  origin: .computedDailyV2, sourceId: candidate.sourceId,
                                  asOf: candidate.asOf, rawFrontierTs: candidate.rawFrontierTs)
        }

        return freshest(persisted: persisted, live: live, day: day)
    }

    public static func canonicalWorkout(_ row: WorkoutRow) -> ResolvedStrain? {
        guard row.strainVersion == 2, let stored = row.strain else { return nil }
        return ResolvedStrain(day: nil, storedValue: stored, version: 2,
                              origin: .computedWorkoutV2, sourceId: row.source,
                              asOf: Date(timeIntervalSince1970: TimeInterval(row.endTs)),
                              rawFrontierTs: row.endTs)
    }

    public static func importedComparison(
        day: String,
        importedRows: [DailyStrainCandidate]
    ) -> ResolvedStrain? {
        guard let candidate = importedRows.last(where: { $0.metric.day == day && $0.metric.strain != nil }),
              let stored = candidate.metric.strain else { return nil }
        return ResolvedStrain(day: day, storedValue: stored,
                              version: candidate.metric.strainVersion,
                              origin: .importedWhoop, sourceId: candidate.sourceId,
                              asOf: candidate.asOf, rawFrontierTs: candidate.rawFrontierTs)
    }
}

public extension DailyMetric {
    /// Copy with explicit tri-state optionals: omitted preserves, `.some(nil)` clears,
    /// and `.some(value)` replaces. This prevents new fields from silently falling back
    /// to memberwise-initializer defaults in merge/edit paths.
    func replacing(
        day: String? = nil,
        totalSleepMin: Double?? = nil, efficiency: Double?? = nil,
        deepMin: Double?? = nil, remMin: Double?? = nil, lightMin: Double?? = nil,
        disturbances: Int?? = nil, restingHr: Int?? = nil, avgHrv: Double?? = nil,
        recovery: Double?? = nil, strain: Double?? = nil, exerciseCount: Int?? = nil,
        spo2Pct: Double?? = nil, skinTempDevC: Double?? = nil, respRateBpm: Double?? = nil,
        steps: Int?? = nil, activeKcalEst: Double?? = nil,
        spo2Red: Int?? = nil, spo2Ir: Int?? = nil, strainVersion: Int?? = nil
    ) -> DailyMetric {
        DailyMetric(
            day: day ?? self.day,
            totalSleepMin: totalSleepMin ?? self.totalSleepMin,
            efficiency: efficiency ?? self.efficiency,
            deepMin: deepMin ?? self.deepMin,
            remMin: remMin ?? self.remMin,
            lightMin: lightMin ?? self.lightMin,
            disturbances: disturbances ?? self.disturbances,
            restingHr: restingHr ?? self.restingHr,
            avgHrv: avgHrv ?? self.avgHrv,
            recovery: recovery ?? self.recovery,
            strain: strain ?? self.strain,
            exerciseCount: exerciseCount ?? self.exerciseCount,
            spo2Pct: spo2Pct ?? self.spo2Pct,
            skinTempDevC: skinTempDevC ?? self.skinTempDevC,
            respRateBpm: respRateBpm ?? self.respRateBpm,
            steps: steps ?? self.steps,
            activeKcalEst: activeKcalEst ?? self.activeKcalEst,
            spo2Red: spo2Red ?? self.spo2Red,
            spo2Ir: spo2Ir ?? self.spo2Ir,
            strainVersion: strainVersion ?? self.strainVersion
        )
    }
}

public extension WorkoutRow {
    func replacing(
        startTs: Int? = nil, endTs: Int? = nil, sport: String? = nil, source: String? = nil,
        durationS: Double?? = nil, energyKcal: Double?? = nil,
        avgHr: Int?? = nil, maxHr: Int?? = nil, strain: Double?? = nil,
        distanceM: Double?? = nil, zonesJSON: String?? = nil, notes: String?? = nil,
        strainVersion: Int?? = nil
    ) -> WorkoutRow {
        WorkoutRow(
            startTs: startTs ?? self.startTs, endTs: endTs ?? self.endTs,
            sport: sport ?? self.sport, source: source ?? self.source,
            durationS: durationS ?? self.durationS,
            energyKcal: energyKcal ?? self.energyKcal,
            avgHr: avgHr ?? self.avgHr, maxHr: maxHr ?? self.maxHr,
            strain: strain ?? self.strain, distanceM: distanceM ?? self.distanceM,
            zonesJSON: zonesJSON ?? self.zonesJSON, notes: notes ?? self.notes,
            strainVersion: strainVersion ?? self.strainVersion
        )
    }
}
