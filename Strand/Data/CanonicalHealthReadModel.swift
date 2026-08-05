// Add to Strand/Data. Requires NoopPhase34Core.
// This is the only production Sleep-score selection seam for Today, Sleep, Trends, widgets, Watch, and exports.

import Foundation
import NoopPhase34Core
import WhoopStore

struct PersistedSleepScoreRow: Equatable, Sendable {
    let day: String
    let value: Double
    let sourceId: String
    let model: SleepScoreModel
    let modelVersion: String?
    let observedAt: Int?
    /// Explicit source precedence within one model. The active source receives the highest value.
    let authorityRank: Int
    /// One Repository source-publication generation. Every candidate read in one WAL snapshot receives the
    /// same generation. Do not compare this value with receipt, analysis, or Today-snapshot generations.
    let generation: Int64
    /// True when the canonical score carries a user-edited sleep authority.
    let isUserEditedAuthority: Bool
}

struct CanonicalSleepScorePoint: Equatable, Sendable {
    let day: String
    let value: Double
    let sourceId: String
    let model: SleepScoreModel
    let modelVersion: String?
    let observedAt: Int?
    let generation: Int64
    let isUserEditedAuthority: Bool

    var isImported: Bool { model == .importedWhoop }
    var isComputedV2: Bool { model == .noopV2 }

    /// Metadata-only changes must not make every mounted screen rebuild.
    var presentationIdentity: PresentationIdentity {
        PresentationIdentity(
            day: day,
            value: value,
            sourceId: sourceId,
            model: model,
            modelVersion: modelVersion
        )
    }

    struct PresentationIdentity: Equatable, Sendable {
        let day: String
        let value: Double
        let sourceId: String
        let model: SleepScoreModel
        let modelVersion: String?
    }
}

struct PersistedScalarMetricRow: Equatable, Sendable {
    let day: String
    let value: Double
    let sourceId: String
    let authorityRank: Int
    let generation: Int64
}

struct CanonicalScalarMetricPoint: Equatable, Sendable {
    let day: String
    let value: Double
    let sourceId: String
    let generation: Int64

    var presentationIdentity: PresentationIdentity {
        PresentationIdentity(day: day, value: value, sourceId: sourceId)
    }

    struct PresentationIdentity: Equatable, Sendable {
        let day: String
        let value: Double
        let sourceId: String
    }
}

/// Exact Apple daily row captured in the same WAL snapshot as Trends' daily and metric-series rows.
struct CanonicalAppleDailyPoint: Equatable, Sendable {
    let day: String
    let sourceId: String
    let authorityRank: Int
    let steps: Int?
    let activeKcal: Double?
    let basalKcal: Double?
    let vo2max: Double?
    let avgHr: Int?
    let maxHr: Int?
    let walkingHr: Int?
    let weightKg: Double?
}

struct CanonicalHealthReadModel: Equatable, Sendable {
    static let empty = CanonicalHealthReadModel(
        sleepScoreByDay: [:],
        sleepV2ShadowByDay: [:],
        stressByDay: [:],
        appleDailyByDay: [:],
        sourceGeneration: 0,
        presentationRevision: 0,
        trendsRevision: 0,
        diagnosticRevision: 0
    )

    let sleepScoreByDay: [String: CanonicalSleepScorePoint]
    let sleepV2ShadowByDay: [String: CanonicalSleepScorePoint]
    let stressByDay: [String: CanonicalScalarMetricPoint]
    let appleDailyByDay: [String: CanonicalAppleDailyPoint]
    /// Repository-local generation of the single WAL snapshot used to build this model.
    let sourceGeneration: Int64
    /// Changes only when production-visible Sleep value/source/model changes.
    let presentationRevision: Int64
    /// Changes when any Trends input from this model changes.
    let trendsRevision: Int64
    /// Changes when production or shadow diagnostics change.
    let diagnosticRevision: Int64

    /// Compatibility name for Today/Sleep input keys. Use `presentationRevision` in new code.
    var revision: Int64 { presentationRevision }

    func sleepScore(day: String) -> CanonicalSleepScorePoint? { sleepScoreByDay[day] }
    func stress(day: String) -> CanonicalScalarMetricPoint? { stressByDay[day] }

    func sleepSeries(from: String, through: String) -> [CanonicalSleepScorePoint] {
        sleepScoreByDay.values
            .filter { $0.day >= from && $0.day <= through }
            .sorted { $0.day < $1.day }
    }

    func stressSeries(from: String, through: String) -> [CanonicalScalarMetricPoint] {
        stressByDay.values
            .filter { $0.day >= from && $0.day <= through }
            .sorted { $0.day < $1.day }
    }

    fileprivate var productionPresentation: [String: CanonicalSleepScorePoint.PresentationIdentity] {
        sleepScoreByDay.mapValues(\.presentationIdentity)
    }

    fileprivate var shadowPresentation: [String: CanonicalSleepScorePoint.PresentationIdentity] {
        sleepV2ShadowByDay.mapValues(\.presentationIdentity)
    }

    fileprivate var stressPresentation: [String: CanonicalScalarMetricPoint.PresentationIdentity] {
        stressByDay.mapValues(\.presentationIdentity)
    }
}

enum CanonicalHealthReadModelBuildError: Error {
    case invalidSourceGeneration
    case revisionExhausted
}

enum CanonicalHealthReadModelBuilder {
    static func build(
        mode: SleepPerformanceV2Prefs.Mode,
        sleepRows: [PersistedSleepScoreRow],
        stressRows: [PersistedScalarMetricRow],
        appleRows: [CanonicalAppleDailyPoint],
        previous: CanonicalHealthReadModel,
        sourceGeneration: Int64
    ) throws -> CanonicalHealthReadModel {
        // A detached stale read must never replace a newer Repository generation. Zero is reserved for
        // the empty pre-load model; every real WAL snapshot uses a positive Repository-local generation.
        guard sourceGeneration > 0 else { throw CanonicalHealthReadModelBuildError.invalidSourceGeneration }
        guard sourceGeneration >= previous.sourceGeneration else { return previous }

        let coreMode: SleepScoreMode
        switch mode {
        case .off: coreMode = .off
        case .shadow: coreMode = .shadow
        case .on: coreMode = .on
        }

        // One corrupt historical point must not blank every current surface. Reject it at the canonical
        // boundary and emit the repository diagnostic counter; the source row remains available for repair.
        var candidates: [SleepScoreCandidate] = []
        candidates.reserveCapacity(sleepRows.count)
        for row in sleepRows {
            guard row.value.isFinite, (0 ... 100).contains(row.value),
                  row.generation >= 0, row.authorityRank >= 0,
                  !row.sourceId.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                  let day = try? CivilDay(key: row.day),
                  let candidate = try? SleepScoreCandidate(
                    day: day,
                    value: row.value,
                    sourceId: row.sourceId,
                    model: row.model,
                    modelVersion: row.modelVersion,
                    observedAt: row.observedAt,
                    generation: row.generation,
                    authorityRank: row.authorityRank,
                    isUserEditedAuthority: row.isUserEditedAuthority
                  ) else {
                continue
            }
            candidates.append(candidate)
        }
        let resolved = try CanonicalSleepScoreResolver.resolveSeries(mode: coreMode, candidates: candidates)

        var production: [String: CanonicalSleepScorePoint] = [:]
        var shadow: [String: CanonicalSleepScorePoint] = [:]
        for (day, resolution) in resolved {
            if let value = resolution.production { production[day.key] = value.repositoryPoint }
            if let value = resolution.shadow { shadow[day.key] = value.repositoryPoint }
        }

        let validStressRows = stressRows.filter {
            $0.value.isFinite && $0.generation >= 0 && $0.authorityRank >= 0
                && !$0.sourceId.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                && (try? CivilDay(key: $0.day)) != nil
        }
        let stress = Dictionary(grouping: validStressRows, by: \.day).compactMapValues { rows in
            rows.max { lhs, rhs in
                (lhs.authorityRank, lhs.generation, lhs.sourceId)
                    < (rhs.authorityRank, rhs.generation, rhs.sourceId)
            }.map {
                CanonicalScalarMetricPoint(
                    day: $0.day,
                    value: $0.value,
                    sourceId: $0.sourceId,
                    generation: $0.generation
                )
            }
        }
        let validAppleRows = appleRows.filter {
            $0.authorityRank >= 0
                && !$0.sourceId.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                && (try? CivilDay(key: $0.day)) != nil
        }
        let apple = Dictionary(grouping: validAppleRows, by: \.day).compactMapValues { rows in
            rows.max { lhs, rhs in
                (lhs.authorityRank, lhs.sourceId) < (rhs.authorityRank, rhs.sourceId)
            }
        }

        let productionPresentation = production.mapValues(\.presentationIdentity)
        let shadowPresentation = shadow.mapValues(\.presentationIdentity)
        let productionChanged = productionPresentation != previous.productionPresentation
        let trendsChanged = productionChanged
            || stress.mapValues(\.presentationIdentity) != previous.stressPresentation
            || apple != previous.appleDailyByDay
        let diagnosticsChanged = productionChanged || shadowPresentation != previous.shadowPresentation

        return CanonicalHealthReadModel(
            sleepScoreByDay: production,
            sleepV2ShadowByDay: shadow,
            stressByDay: stress,
            appleDailyByDay: apple,
            sourceGeneration: sourceGeneration,
            presentationRevision: try nextRevision(previous.presentationRevision, when: productionChanged),
            trendsRevision: try nextRevision(previous.trendsRevision, when: trendsChanged),
            diagnosticRevision: try nextRevision(previous.diagnosticRevision, when: diagnosticsChanged)
        )
    }
    private static func nextRevision(_ current: Int64, when changed: Bool) throws -> Int64 {
        guard changed else { return current }
        let (next, overflow) = current.addingReportingOverflow(1)
        guard !overflow else { throw CanonicalHealthReadModelBuildError.revisionExhausted }
        return next
    }

}

private extension SleepScoreCandidate {
    var repositoryPoint: CanonicalSleepScorePoint {
        CanonicalSleepScorePoint(
            day: day.key,
            value: value,
            sourceId: sourceId,
            model: model,
            modelVersion: modelVersion,
            observedAt: observedAt,
            generation: generation,
            isUserEditedAuthority: isUserEditedAuthority
        )
    }
}

/*
Repository.swift integration:

1. Add one stored property:

    @Published private(set) var canonicalHealth = CanonicalHealthReadModel.empty
    private var canonicalHealthSourceGeneration: Int64 = 0

2. Use `WhoopStore.canonicalHealthSurfaceSnapshot(...)`. It reads daily rows, Sleep sessions, Sleep-score
streams, stress, and Apple daily rows in one GRDB read transaction. Do not use several independent async calls.

3. Create candidates from the returned metric rows:

    importedReadIds + key "sleep_performance"                 -> .importedWhoop
    computedReadIds + key Repository.sleepPerformanceV2Key    -> .noopV2
    computedReadIds + key "sleep_performance"                 -> .noopLegacy
    importedReadIds + key "stress"                            -> PersistedScalarMetricRow

Copy each row's explicit `sourcePriority` into `authorityRank`, including Apple daily rows. Active-source
order, not a source-id string or SQL row order, defines precedence. All rows from that read receive
`canonicalHealthSourceGeneration + 1`. Count and log rejected corrupt rows without making the whole model blank.
Only create `.provisionalComposite` for an exact day when all persisted candidates are absent. It is lower
priority than persisted V2 in shadow mode.

4. Build CanonicalHealthReadModel inside the same merge that constructs `days` and `sleeps`. Publish it in the
same MainActor batch. A Sleep score-only change advances `presentationRevision`. Stress/Apple-only changes
advance `trendsRevision` without forcing Today's heavy model to rebuild. Generation/frontier-only changes do
not advance either presentation revision.

5. Rebuild the model when `SleepPerformanceV2Prefs.mode` changes, even when SQLite rows are unchanged.

6. Today, SleepView, TrendsView, WidgetSnapshot, Watch, and reports call
`repo.canonicalHealth.sleepScore(day:)` or the canonical series. Delete local production precedence logic.
*/
