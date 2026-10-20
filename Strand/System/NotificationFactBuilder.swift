import Foundation
import StrandAnalytics
import WhoopStore

/// Notification evidence is read from canonical records, never dashboard display carry.
/// The recovery repair is absent on this branch. No preference can qualify those inputs.
enum NotificationFactBuilder {
    static let recoveryRepairIntegrated = false
    static func dayKey(_ date: Date, calendar: Calendar = .current) -> String {
        let parts = calendar.dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d-%02d-%02d", parts.year ?? 0, parts.month ?? 0, parts.day ?? 0)
    }
    static func displayStrain(_ stored: Double?) -> Double? {
        guard let stored, stored.isFinite, (0...100).contains(stored) else { return nil }
        return StrainScorerV2.displayValue(fromStored: stored)
    }
    static func workout(_ row: WorkoutRow, source: String, revision: String, now: Date,
                        isLiveCompletion: Bool) -> NotificationRuleFact? {
        let end = Date(timeIntervalSince1970: Double(row.endTs))
        guard isLiveCompletion, row.endTs >= row.startTs, end <= now,
              now.timeIntervalSince(end) <= 3600,
              row.strainVersion == 2, displayStrain(row.strain) != nil,
              ["manual", "noop", "detected", "lifting"].contains(row.source) else { return nil }
        let identity = "\(row.startTs):\(row.sport)"
        return .init(group: .workoutSummary, subjectID: identity, episodeID: "\(source):\(identity)",
            evidenceRevision: revision, sourceContext: source, logicalDay: dayKey(end),
            observedAt: end, expiresAt: end.addingTimeInterval(3600),
            quality: .init(isFinal: true, modelAccepted: row.strainVersion == 2))
    }
    @MainActor
    static func canonicalFacts(repository: Repository, now: Date) -> [NotificationRuleFact] {
        // Explicit dependency gate: exact wake identity/coverage and repaired recovery model
        // are required before morning/target/health-pattern pushes can be enabled.
        guard recoveryRepairIntegrated else { return [] }
        return []
    }
}
