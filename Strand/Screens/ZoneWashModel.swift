import Foundation
import StrandDesign

/// Which zone's colour the live screen washes behind its number. The wash is a mood, not a reading, so it does not flicker
/// with every beat: a new zone is shown only once the heart rate is well inside it (at least `marginBPM` beyond the boundary)
/// and has stayed there for `dwellSeconds`. With nothing to show (a paused or ending workout, a quiet strap, no reading)
/// the wash is neutral, and the first zone after that is shown at once.
struct ZoneWashModel: Equatable, Sendable {
    /// How far past the boundary a reading must be, in bpm, before it counts as being in the new zone.
    static let marginBPM: Double = 3
    /// How long it has to stay there, in seconds.
    static let dwellSeconds: TimeInterval = 5

    /// The zone the wash shows: 0 rest, 1 steady, 2 push, nil for neutral.
    private(set) var displayedZone: Int?
    private var candidateZone: Int?
    private var candidateSince: Date?

    /// Feeds one look at the heart rate and returns the zone the wash should show.
    /// - Parameters:
    ///   - bpm: The latest reading, if any.
    ///   - isNeutral: The wash must be quiet: paused, ending, or the strap has gone quiet.
    @discardableResult
    mutating func update(bpm: Int?, thresholds: HRZoneStyle.Thresholds, now: Date, isNeutral: Bool) -> Int? {
        guard !isNeutral, let bpm else {
            displayedZone = nil
            clearCandidate()
            return nil
        }
        let reading = Double(bpm)
        let raw = thresholds.zone(for: reading)
        guard let shown = displayedZone else {
            displayedZone = raw
            clearCandidate()
            return raw
        }
        guard raw != shown, Self.isClear(of: shown, reading: reading, zone: raw, thresholds: thresholds) else {
            clearCandidate()
            return shown
        }
        if candidateZone != raw {
            candidateZone = raw
            candidateSince = now
        }
        if let since = candidateSince, now.timeIntervalSince(since) >= Self.dwellSeconds {
            displayedZone = raw
            clearCandidate()
        }
        return displayedZone
    }

    private mutating func clearCandidate() {
        candidateZone = nil
        candidateSince = nil
    }

    /// Whether `reading` is at least `marginBPM` past the boundary between the zone shown and the zone it is in.
    private static func isClear(of shown: Int, reading: Double, zone: Int, thresholds: HRZoneStyle.Thresholds) -> Bool {
        if zone > shown {
            // Moving up: past the lower edge of the new zone.
            let edge = zone == 1 ? thresholds.rest : thresholds.steady
            return reading >= edge + marginBPM
        }
        // Moving down: below the upper edge of the new zone.
        let edge = zone == 0 ? thresholds.rest : thresholds.steady
        return reading <= edge - marginBPM
    }
}
