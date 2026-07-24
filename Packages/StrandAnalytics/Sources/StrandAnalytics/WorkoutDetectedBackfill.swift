import Foundation
import WhoopStore

/// RyanBR NOOP v9.1-compatible merge for a real workout that overlaps an already-computed detected bout.
///
/// Only fields absent from the real row are filled. User-entered/imported values, natural-key identity,
/// route metadata, notes, zones, and NOOP iOS's Strain-version marker are preserved verbatim.
public enum WorkoutDetectedBackfill {
    public struct ComputedValues: Equatable, Sendable {
        public let averageHeartRate: Int?
        public let peakHeartRate: Int?
        public let caloriesKcal: Double?
        public let strain: Double?
        public let strainVersion: Int?

        public init(
            averageHeartRate: Int?,
            peakHeartRate: Int?,
            caloriesKcal: Double?,
            strain: Double?,
            strainVersion: Int? = nil
        ) {
            let average = Self.validHeartRate(averageHeartRate)
            let peak = Self.validHeartRate(peakHeartRate)
            if let average, let peak, average > peak {
                // A contradictory detector result must not manufacture an impossible real-workout row.
                self.averageHeartRate = nil
                self.peakHeartRate = nil
            } else {
                self.averageHeartRate = average
                self.peakHeartRate = peak
            }

            self.caloriesKcal = Self.validNonnegative(caloriesKcal)

            let validStrain = Self.validStoredStrain(strain)
            let validVersion = strainVersion.flatMap { $0 > 0 ? $0 : nil }
            // A computed score without provenance is not safe to attach to a real/imported row. The current
            // NOOP scorer supplies its explicit version, so this fails closed only for malformed callers.
            if validStrain != nil, validVersion != nil {
                self.strain = validStrain
                self.strainVersion = validVersion
            } else {
                self.strain = nil
                self.strainVersion = nil
            }
        }

        private static func validHeartRate(_ value: Int?) -> Int? {
            value.flatMap { (30...250).contains($0) ? $0 : nil }
        }

        private static func validNonnegative(_ value: Double?) -> Double? {
            value.flatMap { $0.isFinite && $0 >= 0 ? $0 : nil }
        }

        private static func validStoredStrain(_ value: Double?) -> Double? {
            value.flatMap { $0.isFinite && (0...100).contains($0) ? $0 : nil }
        }
    }

    public static func applying(
        _ computed: ComputedValues,
        to real: WorkoutRow
    ) -> WorkoutRow {
        let averageFill: Int? = {
            guard real.avgHr == nil, let candidate = computed.averageHeartRate else { return nil }
            let upperBound = real.maxHr ?? computed.peakHeartRate ?? Int.max
            return candidate <= upperBound ? candidate : nil
        }()
        let peakFill: Int? = {
            guard real.maxHr == nil, let candidate = computed.peakHeartRate else { return nil }
            let lowerBound = real.avgHr ?? averageFill ?? computed.averageHeartRate ?? Int.min
            return candidate >= lowerBound ? candidate : nil
        }()

        let fillsStrain = real.strain == nil
            && computed.strain != nil
            && computed.strainVersion != nil

        return WorkoutRow(
            startTs: real.startTs,
            endTs: real.endTs,
            sport: real.sport,
            source: real.source,
            durationS: real.durationS,
            energyKcal: real.energyKcal ?? computed.caloriesKcal,
            avgHr: real.avgHr ?? averageFill,
            maxHr: real.maxHr ?? peakFill,
            strain: fillsStrain ? computed.strain : real.strain,
            distanceM: real.distanceM,
            zonesJSON: real.zonesJSON,
            notes: real.notes,
            strainVersion: fillsStrain ? computed.strainVersion : real.strainVersion
        )
    }
}
