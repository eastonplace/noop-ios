import Foundation

public enum SleepScoreMode: String, Codable, CaseIterable, Sendable {
    case off
    case shadow
    case on
}

public enum SleepScoreModel: String, Codable, CaseIterable, Sendable {
    case importedWhoop
    case noopV2
    case noopLegacy
    case provisionalComposite
}

public struct SleepScoreCandidate: Codable, Equatable, Sendable {
    public let day: CivilDay
    public let value: Double
    public let sourceId: String
    public let model: SleepScoreModel
    public let modelVersion: String?
    public let observedAt: Int?
    public let generation: Int64
    /// Explicit precedence within one model. Higher values win. This preserves active-source order without
    /// relying on lexicographic source IDs or database row order.
    public let authorityRank: Int
    /// True when this score comes from a user-edited or user-bounded sleep session. Imported values for
    /// the old window must not mask the correction on any production surface.
    public let isUserEditedAuthority: Bool

    public init(
        day: CivilDay,
        value: Double,
        sourceId: String,
        model: SleepScoreModel,
        modelVersion: String? = nil,
        observedAt: Int? = nil,
        generation: Int64 = 0,
        authorityRank: Int = 0,
        isUserEditedAuthority: Bool = false
    ) throws {
        guard value.isFinite, (0...100).contains(value), !sourceId.isEmpty,
              generation >= 0, authorityRank >= 0 else {
            throw CanonicalSleepScoreError.invalidCandidate
        }
        self.day = day
        self.value = value
        self.sourceId = sourceId
        self.model = model
        self.modelVersion = modelVersion
        self.observedAt = observedAt
        self.generation = generation
        self.authorityRank = authorityRank
        self.isUserEditedAuthority = isUserEditedAuthority
    }

    private enum CodingKeys: String, CodingKey {
        case day, value, sourceId, model, modelVersion, observedAt, generation, authorityRank
        case isUserEditedAuthority
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(
            day: container.decode(CivilDay.self, forKey: .day),
            value: container.decode(Double.self, forKey: .value),
            sourceId: container.decode(String.self, forKey: .sourceId),
            model: container.decode(SleepScoreModel.self, forKey: .model),
            modelVersion: container.decodeIfPresent(String.self, forKey: .modelVersion),
            observedAt: container.decodeIfPresent(Int.self, forKey: .observedAt),
            generation: container.decodeIfPresent(Int64.self, forKey: .generation) ?? 0,
            authorityRank: container.decodeIfPresent(Int.self, forKey: .authorityRank) ?? 0,
            isUserEditedAuthority: container.decodeIfPresent(
                Bool.self,
                forKey: .isUserEditedAuthority
            ) ?? false
        )
    }
}

public struct CanonicalSleepScoreResolution: Codable, Equatable, Sendable {
    /// The score every production surface must render for this day.
    public let production: SleepScoreCandidate?
    /// A V2 score retained for diagnostics while shadow mode keeps legacy production authority.
    public let shadow: SleepScoreCandidate?

    public init(production: SleepScoreCandidate?, shadow: SleepScoreCandidate?) {
        self.production = production
        self.shadow = shadow
    }
}

public enum CanonicalSleepScoreError: Error, Equatable, Sendable {
    case invalidCandidate
    case mixedDay
}

/// One precedence kernel for Today, Sleep, Trends, widgets, Watch, and exports.
///
/// Imported WHOOP is always authoritative for a day it covers. In shadow mode V2 is retained for comparison,
/// while the production result remains legacy where legacy exists. If no legacy score exists, V2 may fill the
/// otherwise blank production slot: shadow mode must not create a user-visible regression merely because the
/// old reducer did not emit a point.
public enum CanonicalSleepScoreResolver {
    public static func resolve(
        day: CivilDay,
        mode: SleepScoreMode,
        imported: [SleepScoreCandidate] = [],
        v2: [SleepScoreCandidate] = [],
        legacy: [SleepScoreCandidate] = [],
        provisional: [SleepScoreCandidate] = []
    ) throws -> CanonicalSleepScoreResolution {
        let groups = [imported, v2, legacy, provisional]
        guard groups.flatMap({ $0 }).allSatisfy({ $0.day == day }) else {
            throw CanonicalSleepScoreError.mixedDay
        }

        let importedWinner = newest(imported.filter { $0.model == .importedWhoop })
        let v2Winner = newest(v2.filter { $0.model == .noopV2 })
        let legacyWinner = newest(legacy.filter { $0.model == .noopLegacy })
        let provisionalWinner = newest(provisional.filter { $0.model == .provisionalComposite })

        let editedV2 = newest(v2.filter { $0.model == .noopV2 && $0.isUserEditedAuthority })
        let editedLegacy = newest(
            legacy.filter { $0.model == .noopLegacy && $0.isUserEditedAuthority }
        )
        let editedProvisional = newest(
            provisional.filter {
                $0.model == .provisionalComposite && $0.isUserEditedAuthority
            }
        )
        let hasEditedAuthority = editedV2 != nil
            || editedLegacy != nil
            || editedProvisional != nil

        if hasEditedAuthority {
            switch mode {
            case .off:
                if let edited = editedLegacy ?? editedProvisional {
                    return CanonicalSleepScoreResolution(production: edited, shadow: nil)
                }
            case .shadow:
                if let edited = editedLegacy ?? editedV2 ?? editedProvisional {
                    return CanonicalSleepScoreResolution(production: edited, shadow: editedV2)
                }
            case .on:
                if let edited = editedV2 ?? editedLegacy ?? editedProvisional {
                    return CanonicalSleepScoreResolution(production: edited, shadow: nil)
                }
            }
        }

        if let importedWinner {
            return CanonicalSleepScoreResolution(production: importedWinner, shadow: v2Winner)
        }

        switch mode {
        case .off:
            return CanonicalSleepScoreResolution(
                production: legacyWinner ?? provisionalWinner,
                shadow: nil
            )
        case .shadow:
            return CanonicalSleepScoreResolution(
                production: legacyWinner ?? v2Winner ?? provisionalWinner,
                shadow: v2Winner
            )
        case .on:
            return CanonicalSleepScoreResolution(
                production: v2Winner ?? legacyWinner ?? provisionalWinner,
                shadow: nil
            )
        }
    }

    public static func resolveSeries(
        mode: SleepScoreMode,
        candidates: [SleepScoreCandidate]
    ) throws -> [CivilDay: CanonicalSleepScoreResolution] {
        let byDay = Dictionary(grouping: candidates, by: \.day)
        return try Dictionary(uniqueKeysWithValues: byDay.map { day, rows in
            let resolution = try resolve(
                day: day,
                mode: mode,
                imported: rows.filter { $0.model == .importedWhoop },
                v2: rows.filter { $0.model == .noopV2 },
                legacy: rows.filter { $0.model == .noopLegacy },
                provisional: rows.filter { $0.model == .provisionalComposite }
            )
            return (day, resolution)
        })
    }

    private static func newest(_ candidates: [SleepScoreCandidate]) -> SleepScoreCandidate? {
        candidates.max { lhs, rhs in
            let lhsOrder = (
                lhs.isUserEditedAuthority ? 1 : 0,
                lhs.authorityRank,
                lhs.generation,
                lhs.observedAt ?? -1,
                lhs.sourceId
            )
            let rhsOrder = (
                rhs.isUserEditedAuthority ? 1 : 0,
                rhs.authorityRank,
                rhs.generation,
                rhs.observedAt ?? -1,
                rhs.sourceId
            )
            return lhsOrder < rhsOrder
        }
    }
}
