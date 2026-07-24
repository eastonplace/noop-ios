import Foundation
import WhoopStore

/// RyanBR NOOP v9.1-compatible merge for a real workout that overlaps an already-computed detected bout.
///
/// Only fields absent from the real row are filled. User-entered/imported values, natural-key identity,
/// route metadata, notes, zones, and NOOP iOS's Strain-version marker are preserved verbatim.
public enum WorkoutDetectedBackfill {
    public struct ComputedValues: Equatable, Sendable {
        public let averageHeartRate: Int
        public let peakHeartRate: Int
        public let caloriesKcal: Double?
        public let strain: Double?
        public let strainVersion: Int?

        public init(
            averageHeartRate: Int,
            peakHeartRate: Int,
            caloriesKcal: Double?,
            strain: Double?,
            strainVersion: Int? = nil
        ) {
            self.averageHeartRate = averageHeartRate
            self.peakHeartRate = peakHeartRate
            self.caloriesKcal = caloriesKcal
            self.strain = strain
            self.strainVersion = strainVersion
        }
    }

    public static func applying(
        _ computed: ComputedValues,
        to real: WorkoutRow
    ) -> WorkoutRow {
        let fillsStrain = real.strain == nil && computed.strain != nil
        return WorkoutRow(
            startTs: real.startTs,
            endTs: real.endTs,
            sport: real.sport,
            source: real.source,
            durationS: real.durationS,
            energyKcal: real.energyKcal ?? computed.caloriesKcal,
            avgHr: real.avgHr ?? computed.averageHeartRate,
            maxHr: real.maxHr ?? computed.peakHeartRate,
            strain: real.strain ?? computed.strain,
            distanceM: real.distanceM,
            zonesJSON: real.zonesJSON,
            notes: real.notes,
            strainVersion: fillsStrain ? computed.strainVersion : real.strainVersion
        )
    }
}
