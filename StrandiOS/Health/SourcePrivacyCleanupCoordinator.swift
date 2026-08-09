#if os(iOS)
import Foundation
import NoopPhase34Core
import WhoopStore

enum SourcePrivacyCleanupCoordinatorError: Error, Equatable, Sendable {
    case storeUnavailable
    case missingGroup(UUID)
    case conflictingGroup(UUID)
    case quarantinedGroup(UUID)
    case authorizationUnavailable(UUID)
    case pending(UUID)
    case leaseReleaseFailed(UUID)
}

enum SourcePrivacyCleanupTransitionHandoffPolicy {
    static func completesTransition(
        after error: SourcePrivacyCleanupCoordinatorError
    ) -> Bool {
        if case .authorizationUnavailable = error { return true }
        return false
    }
}

enum SourcePrivacyCleanupIndependentDrainPolicy {
    static func shouldDrain(
        latestTransition: SourceTransitionRecoveryRecord?
    ) -> Bool {
        latestTransition == nil
    }
}

/// Drains one bounded HealthKit privacy page for one durable category row.
///
/// A call returns only after all four rows are complete. Normal pending and
/// quarantine states keep source-transition recovery coupled. A persisted
/// authorization deferral may hand off to the independent recovery drain.
@MainActor
final class SourcePrivacyCleanupCoordinator {
    typealias StoreProvider = @MainActor @Sendable () async -> WhoopStore?
    typealias ChunkProcessor = @MainActor @Sendable (
        HealthKitSourceDeletionChunkRequest
    ) async throws -> HealthKitSourceDeletionChunkResult

    private struct DurableEnvelope: Equatable, Sendable {
        let cleanupWorkId: UUID
        let transitionId: UUID
        let sourceDeviceId: String
        let remainingImportedIds: Set<String>
        let remainingComputedIds: Set<String>
        let firstDay: CivilDay
        let throughDay: CivilDay
        let timeZoneIdentifier: String
    }

    private enum InvariantFailure: Error {
        case invalidEnvelope
        case invalidCursor
        case invalidResult
    }

    private let storeProvider: StoreProvider
    private let processChunk: ChunkProcessor
    private let owner: String
    private let leaseDuration: TimeInterval
    private let now: @Sendable () -> Date

    convenience init(
        storeProvider: @escaping StoreProvider,
        healthKitBridge: HealthKitBridge
    ) {
        self.init(
            storeProvider: storeProvider,
            processChunk: { [healthKitBridge] request in
                try await healthKitBridge.processSourceDeletionChunk(request)
            }
        )
    }

    /// Internal seam for deterministic tests. Production injects HealthKitBridge.
    init(
        storeProvider: @escaping StoreProvider,
        owner: String? = nil,
        leaseDuration: TimeInterval = 90,
        now: @escaping @Sendable () -> Date = { Date() },
        processChunk: @escaping ChunkProcessor
    ) {
        self.storeProvider = storeProvider
        self.processChunk = processChunk
        let suppliedOwner = owner?.trimmingCharacters(in: .whitespacesAndNewlines)
        self.owner = suppliedOwner.flatMap { $0.isEmpty ? nil : $0 }
            ?? "source-privacy-cleanup-\(UUID().uuidString.lowercased())"
        self.leaseDuration = min(5 * 60, max(15, leaseDuration))
        self.now = now
    }

    func drain(cleanupWorkId: UUID) async throws {
        try Task.checkCancellation()
        guard let store = await storeProvider() else {
            throw SourcePrivacyCleanupCoordinatorError.storeUnavailable
        }

        var initial = try await loadValidatedGroup(
            cleanupWorkId: cleanupWorkId,
            store: store
        )
        if initial.group.hasQuarantinedWork {
            try await rearmQuarantinedGroup(
                cleanupWorkId: cleanupWorkId,
                store: store
            )
            initial = try await loadValidatedGroup(
                cleanupWorkId: cleanupWorkId,
                store: store
            )
        }
        try Self.requireDrainable(initial.group, cleanupWorkId: cleanupWorkId)
        if initial.group.completedSuccessfully { return }

        let leaseNow = now()
        guard let work = try await store.leaseNextSourcePrivacyCleanupWork(
            owner: owner,
            now: leaseNow,
            leaseDuration: leaseDuration,
            cleanupWorkId: cleanupWorkId
        ) else {
            let current = try await loadValidatedGroup(
                cleanupWorkId: cleanupWorkId,
                store: store
            )
            try Self.requireDrainable(current.group, cleanupWorkId: cleanupWorkId)
            if current.group.completedSuccessfully { return }
            if current.group.hasAuthorizationBlockedWork {
                throw SourcePrivacyCleanupCoordinatorError.authorizationUnavailable(
                    cleanupWorkId
                )
            }
            throw SourcePrivacyCleanupCoordinatorError.pending(cleanupWorkId)
        }

        guard work.state == .running,
              work.leaseOwner == owner,
              Self.matches(work, envelope: initial.envelope) else {
            throw SourcePrivacyCleanupCoordinatorError.conflictingGroup(cleanupWorkId)
        }

        let request: HealthKitSourceDeletionChunkRequest
        do {
            request = try Self.makeRequest(work: work, envelope: initial.envelope)
        } catch {
            try await quarantine(
                work,
                store: store,
                cleanupWorkId: cleanupWorkId,
                code: "invalid_durable_cursor"
            )
        }

        let result: HealthKitSourceDeletionChunkResult
        do {
            try Task.checkCancellation()
            result = try await processChunk(request)
        } catch is CancellationError {
            try await cancelLease(
                work,
                store: store,
                cleanupWorkId: cleanupWorkId
            )
            throw CancellationError()
        } catch ExactPublicationError.authorizationUnavailable {
            do {
                _ = try await store.blockSourcePrivacyCleanupWorkForAuthorization(
                    work,
                    owner: owner,
                    now: now()
                )
            } catch {
                throw SourcePrivacyCleanupCoordinatorError.leaseReleaseFailed(
                    cleanupWorkId
                )
            }
            throw SourcePrivacyCleanupCoordinatorError.authorizationUnavailable(cleanupWorkId)
        } catch {
            let failed = try await store.failSourcePrivacyCleanupWork(
                work,
                owner: owner,
                code: Self.retryCode(for: error),
                retryable: true,
                now: now()
            )
            if failed.state == .quarantined {
                try await rearmQuarantinedGroup(
                    cleanupWorkId: cleanupWorkId,
                    store: store
                )
                throw SourcePrivacyCleanupCoordinatorError.pending(cleanupWorkId)
            }
            guard failed.state == .retryable else {
                throw SourcePrivacyCleanupCoordinatorError.conflictingGroup(cleanupWorkId)
            }
            throw SourcePrivacyCleanupCoordinatorError.pending(cleanupWorkId)
        }

        do {
            try Self.validate(result: result, request: request)
        } catch {
            try await quarantine(
                work,
                store: store,
                cleanupWorkId: cleanupWorkId,
                code: "invalid_healthkit_result"
            )
        }

        let continuation: Data?
        do {
            continuation = try result.continuationCursor.map {
                try Self.cursorEncoder.encode($0)
            }
        } catch {
            try await quarantine(
                work,
                store: store,
                cleanupWorkId: cleanupWorkId,
                code: "cursor_encode_failed"
            )
        }

        _ = try await store.persistSourcePrivacyCleanupCursors(
            work,
            owner: owner,
            scanCursor: work.scanCursor,
            cleanupCursor: continuation,
            batchDayCount: result.processedDayCount,
            batchObjectCount: max(result.deletedObjectCount, result.rebuiltObjectCount),
            hasMore: !result.isComplete,
            now: now()
        )

        let current = try await loadValidatedGroup(
            cleanupWorkId: cleanupWorkId,
            store: store
        )
        try Self.requireDrainable(current.group, cleanupWorkId: cleanupWorkId)
        if current.group.completedSuccessfully { return }
        if current.group.hasAuthorizationBlockedWork {
            throw SourcePrivacyCleanupCoordinatorError.authorizationUnavailable(
                cleanupWorkId
            )
        }
        throw SourcePrivacyCleanupCoordinatorError.pending(cleanupWorkId)
    }

    /// Drain one page from the oldest durable group even after its source
    /// transition journal has completed.
    @discardableResult
    func drainOldestUnresolved() async throws -> Bool {
        guard let store = await storeProvider() else {
            throw SourcePrivacyCleanupCoordinatorError.storeUnavailable
        }
        let candidates = try await store.sourcePrivacyCleanupDrainCandidates(
            now: now(),
            limit: 100
        )
        guard let group = candidates.first else {
            return false
        }
        try await drain(cleanupWorkId: group.cleanupWorkId)
        return true
    }

    private func loadValidatedGroup(
        cleanupWorkId: UUID,
        store: WhoopStore
    ) async throws -> (group: SourcePrivacyCleanupGroup, envelope: DurableEnvelope) {
        let group: SourcePrivacyCleanupGroup?
        do {
            group = try await store.sourcePrivacyCleanupGroup(cleanupWorkId: cleanupWorkId)
        } catch let error as SourcePrivacyCleanupStoreError {
            switch error {
            case .missingWork:
                throw SourcePrivacyCleanupCoordinatorError.missingGroup(cleanupWorkId)
            case .invalidWork, .invalidRow, .conflictingReplay,
                 .nothingToRearm, .rearmCooldownActive:
                throw SourcePrivacyCleanupCoordinatorError.conflictingGroup(cleanupWorkId)
            case .leaseLost:
                throw error
            }
        }
        guard let group else {
            throw SourcePrivacyCleanupCoordinatorError.missingGroup(cleanupWorkId)
        }
        do {
            return (group, try Self.validate(group: group, cleanupWorkId: cleanupWorkId))
        } catch {
            throw SourcePrivacyCleanupCoordinatorError.conflictingGroup(cleanupWorkId)
        }
    }

    private func rearmQuarantinedGroup(
        cleanupWorkId: UUID,
        store: WhoopStore
    ) async throws {
        do {
            _ = try await store.rearmQuarantinedSourcePrivacyCleanupGroup(
                cleanupWorkId: cleanupWorkId,
                now: now()
            )
        } catch SourcePrivacyCleanupStoreError.nothingToRearm {
            // Another recovery owner already rearmed the same durable group.
        } catch SourcePrivacyCleanupStoreError.rearmCooldownActive(_) {
            throw SourcePrivacyCleanupCoordinatorError.quarantinedGroup(cleanupWorkId)
        } catch SourcePrivacyCleanupStoreError.missingWork {
            throw SourcePrivacyCleanupCoordinatorError.missingGroup(cleanupWorkId)
        } catch {
            throw SourcePrivacyCleanupCoordinatorError.conflictingGroup(cleanupWorkId)
        }
    }

    private func cancelLease(
        _ work: SourcePrivacyCleanupWork,
        store: WhoopStore,
        cleanupWorkId: UUID
    ) async throws {
        do {
            _ = try await store.cancelSourcePrivacyCleanupLease(
                work,
                owner: owner,
                now: now()
            )
        } catch {
            throw SourcePrivacyCleanupCoordinatorError.leaseReleaseFailed(cleanupWorkId)
        }
    }

    private func quarantine(
        _ work: SourcePrivacyCleanupWork,
        store: WhoopStore,
        cleanupWorkId: UUID,
        code: String
    ) async throws -> Never {
        do {
            _ = try await store.failSourcePrivacyCleanupWork(
                work,
                owner: owner,
                code: code,
                retryable: false,
                now: now()
            )
        } catch {
            throw SourcePrivacyCleanupCoordinatorError.leaseReleaseFailed(cleanupWorkId)
        }
        throw SourcePrivacyCleanupCoordinatorError.quarantinedGroup(cleanupWorkId)
    }

    private static func validate(
        group: SourcePrivacyCleanupGroup,
        cleanupWorkId: UUID
    ) throws -> DurableEnvelope {
        guard group.cleanupWorkId == cleanupWorkId,
              group.work.count == SourcePrivacyCleanupCategory.allCases.count,
              Set(group.work.map(\.category)) == Set(SourcePrivacyCleanupCategory.allCases),
              let first = group.work.first else {
            throw InvariantFailure.invalidEnvelope
        }

        let source = group.sourceDeviceId.trimmingCharacters(in: .whitespacesAndNewlines)
        let imported = Self.normalizedSourceIds(first.remainingImportedIds)
        let computed = Self.normalizedSourceIds(first.remainingComputedIds)
        guard !source.isEmpty,
              source == group.sourceDeviceId,
              group.transitionId == first.transitionId,
              first.cleanupWorkId == cleanupWorkId,
              first.sourceDeviceId == source,
              imported == first.remainingImportedIds,
              computed == first.remainingComputedIds,
              imported.isDisjoint(with: computed),
              imported.allSatisfy({ !$0.hasSuffix("-noop") }),
              computed.allSatisfy({ $0.hasSuffix("-noop") }),
              !imported.contains(source),
              !imported.contains(source + "-noop"),
              !computed.contains(source),
              !computed.contains(source + "-noop"),
              TimeZone(identifier: first.recordedTimeZoneIdentifier) != nil else {
            throw InvariantFailure.invalidEnvelope
        }

        let firstDay: CivilDay
        let throughDay: CivilDay
        do {
            firstDay = try CivilDay(key: first.firstDay)
            throughDay = try CivilDay(key: first.throughDay)
        } catch {
            throw InvariantFailure.invalidEnvelope
        }
        guard firstDay <= throughDay,
              group.work.allSatisfy({ work in
                  work.cleanupWorkId == cleanupWorkId
                    && work.transitionId == group.transitionId
                    && work.sourceDeviceId == source
                    && work.remainingImportedIds == imported
                    && work.remainingComputedIds == computed
                    && work.firstDay == first.firstDay
                    && work.throughDay == first.throughDay
                    && work.recordedTimeZoneIdentifier == first.recordedTimeZoneIdentifier
              }) else {
            throw InvariantFailure.invalidEnvelope
        }

        return DurableEnvelope(
            cleanupWorkId: cleanupWorkId,
            transitionId: group.transitionId,
            sourceDeviceId: source,
            remainingImportedIds: imported,
            remainingComputedIds: computed,
            firstDay: firstDay,
            throughDay: throughDay,
            timeZoneIdentifier: first.recordedTimeZoneIdentifier
        )
    }

    private static func requireDrainable(
        _ group: SourcePrivacyCleanupGroup,
        cleanupWorkId: UUID
    ) throws {
        if group.hasQuarantinedWork {
            throw SourcePrivacyCleanupCoordinatorError.quarantinedGroup(cleanupWorkId)
        }
        if group.isTerminal, !group.completedSuccessfully {
            throw SourcePrivacyCleanupCoordinatorError.conflictingGroup(cleanupWorkId)
        }
    }

    private static func matches(
        _ work: SourcePrivacyCleanupWork,
        envelope: DurableEnvelope
    ) -> Bool {
        work.cleanupWorkId == envelope.cleanupWorkId
            && work.transitionId == envelope.transitionId
            && work.sourceDeviceId == envelope.sourceDeviceId
            && work.remainingImportedIds == envelope.remainingImportedIds
            && work.remainingComputedIds == envelope.remainingComputedIds
            && work.firstDay == envelope.firstDay.key
            && work.throughDay == envelope.throughDay.key
            && work.recordedTimeZoneIdentifier == envelope.timeZoneIdentifier
    }

    private static func makeRequest(
        work: SourcePrivacyCleanupWork,
        envelope: DurableEnvelope
    ) throws -> HealthKitSourceDeletionChunkRequest {
        guard let category = HealthKitSourceDeletionCategory(rawValue: work.category.rawValue) else {
            throw InvariantFailure.invalidEnvelope
        }
        let cursor: HealthKitSourceDeletionCursor?
        do {
            cursor = try work.cleanupCursor.map {
                try cursorDecoder.decode(HealthKitSourceDeletionCursor.self, from: $0)
            }
        } catch {
            throw InvariantFailure.invalidCursor
        }
        guard cursor.map({
            $0.category == category
                && $0.day >= envelope.firstDay
                && $0.day <= envelope.throughDay
                && $0.componentIndex >= 0
        }) ?? true else {
            throw InvariantFailure.invalidCursor
        }
        let request = HealthKitSourceDeletionChunkRequest(
            sourceDeviceId: envelope.sourceDeviceId,
            remainingImportedIds: envelope.remainingImportedIds.sorted(),
            remainingComputedIds: envelope.remainingComputedIds.sorted(),
            category: category,
            firstDay: envelope.firstDay,
            throughDay: envelope.throughDay,
            timeZoneIdentifier: envelope.timeZoneIdentifier,
            cursor: cursor
        )
        do {
            _ = try HealthKitSourceDeletionChunkPlanner.interval(for: request)
        } catch {
            throw InvariantFailure.invalidCursor
        }
        return request
    }

    private static func validate(
        result: HealthKitSourceDeletionChunkResult,
        request: HealthKitSourceDeletionChunkRequest
    ) throws {
        let expected: HealthKitSourceDeletionProcessedInterval
        do {
            expected = try HealthKitSourceDeletionChunkPlanner.interval(for: request)
        } catch {
            throw InvariantFailure.invalidResult
        }
        guard result.processedInterval == expected,
              result.processedInterval.category == request.category,
              (1...HealthKitSourceDeletionChunkPlanner.maximumCivilDays)
                .contains(result.processedDayCount),
              (0...HealthKitSourceDeletionChunkPlanner.maximumObjectsPerQuery)
                .contains(result.deletedObjectCount),
              (0...HealthKitSourceDeletionChunkPlanner.maximumObjectsPerQuery)
                .contains(result.rebuiltObjectCount),
              result.isComplete == (result.continuationCursor == nil),
              !result.isComplete || result.processedInterval.lastDay == request.throughDay else {
            throw InvariantFailure.invalidResult
        }

        let calendar: HealthCalendar
        do {
            calendar = try HealthCalendar(timeZoneIdentifier: request.timeZoneIdentifier)
            let days = try calendar.days(
                from: expected.firstDay,
                through: expected.lastDay,
                limit: HealthKitSourceDeletionChunkPlanner.maximumCivilDays + 1
            )
            guard days.count == result.processedDayCount else {
                throw InvariantFailure.invalidResult
            }
        } catch {
            throw InvariantFailure.invalidResult
        }

        if let continuation = result.continuationCursor {
            guard continuation != request.cursor,
                  continuation.category == request.category,
                  continuation.day >= expected.firstDay,
                  continuation.day <= request.throughDay,
                  continuation.componentIndex >= 0 else {
                throw InvariantFailure.invalidResult
            }
        }
    }

    private static func normalizedSourceIds(_ values: Set<String>) -> Set<String> {
        Set(values.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty })
    }

    private static func retryCode(for error: any Error) -> String {
        switch error {
        case ExactPublicationError.storeUnavailable:
            return "healthkit_store_unavailable"
        case ExactPublicationError.invalidTimeZone,
             HealthKitSourceDeletionChunkError.invalidTimeZone:
            return "healthkit_invalid_time_zone"
        case HealthKitSourceDeletionChunkError.invalidRange:
            return "healthkit_invalid_range"
        case HealthKitSourceDeletionChunkError.invalidCursor:
            return "healthkit_invalid_cursor"
        default:
            return "healthkit_privacy_cleanup_failed"
        }
    }

    private static var cursorDecoder: JSONDecoder { JSONDecoder() }

    private static var cursorEncoder: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return encoder
    }
}
#endif
