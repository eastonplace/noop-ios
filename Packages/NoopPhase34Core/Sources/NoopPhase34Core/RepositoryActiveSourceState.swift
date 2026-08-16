import Foundation

public struct RepositoryLiveSourceDescriptor: Codable, Equatable, Sendable {
    public let id: String
    public let historyLineage: String
    public let cursorEpoch: Int

    public init(id: String, historyLineage: String, cursorEpoch: Int) throws {
        let normalizedID = id.trimmingCharacters(in: .whitespacesAndNewlines)
        let normalizedLineage = historyLineage.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalizedID.isEmpty, !normalizedLineage.isEmpty, cursorEpoch >= 0 else {
            throw RepositoryLiveSourceStateError.invalidDescriptor
        }
        self.id = normalizedID
        self.historyLineage = normalizedLineage
        self.cursorEpoch = cursorEpoch
    }

    public var lineageComponent: String {
        "live:\(id):\(historyLineage):\(cursorEpoch)"
    }
}

public enum RepositoryLiveSourceState: Equatable, Sendable {
    case none
    case active(RepositoryLiveSourceDescriptor)

    public var id: String? {
        guard case let .active(source) = self else { return nil }
        return source.id
    }

    public var lineageComponent: String {
        switch self {
        case .none: return "no-live-source"
        case let .active(source): return source.lineageComponent
        }
    }
}

public enum RepositoryLiveSourceStateError: Error, Equatable, Sendable {
    case invalidDescriptor
}

public enum ActiveSourceReadPolicy {
    /// The canonical imported namespace remains readable history when no live
    /// source is active. The archived prior live ID must not remain in the union.
    public static func importedReadIds(
        liveState: RepositoryLiveSourceState,
        canonicalDeviceId: String
    ) -> [String] {
        switch liveState {
        case .none:
            return [canonicalDeviceId]
        case let .active(source):
            return source.id == canonicalDeviceId
                ? [source.id]
                : [source.id, canonicalDeviceId]
        }
    }

    public static func computedReadIds(
        liveState: RepositoryLiveSourceState,
        canonicalComputedId: String
    ) -> [String] {
        switch liveState {
        case .none:
            return [canonicalComputedId]
        case let .active(source):
            let liveComputed = ExactAnalysisNamespace.defaultComputedDeviceId(
                forRawDeviceId: source.id
            )
            return liveComputed == canonicalComputedId
                ? [canonicalComputedId]
                : [canonicalComputedId, liveComputed]
        }
    }

    /// Do not synthesize a fallback source merely because every registry row is
    /// archived. Bootstrap fallback is allowed only when the registry table has
    /// never been initialized and the legacy seeded row is genuinely absent.
    public static func admissionSourceIds(
        allRegistryRows: [(id: String, archived: Bool)],
        registryInitialized: Bool,
        legacyBootstrapId: String
    ) -> [String] {
        let valid = allRegistryRows.filter { !$0.archived }.map(\.id)
        if !valid.isEmpty { return valid }
        return registryInitialized ? [] : [legacyBootstrapId]
    }
}

/*
Repository integration:

- Replace the nonoptional active read identity with:

    @Published private(set) var liveSourceState: RepositoryLiveSourceState

- DeviceRegistryStore exposes an active descriptor containing id, historyLineage,
  and historyCursorEpoch from the same registry read.
- `adoptActiveDeviceId(_:)` becomes `setActiveLiveSource(_ descriptor: RepositoryLiveSourceDescriptor?)`.
- `importedReadIds` and `computedReadIds` call ActiveSourceReadPolicy.
- `todayHealthSnapshotContext.sourceLineage` includes
  `liveSourceState.lineageComponent`, not only logical source IDs. A physical
  re-pair of the same logical device therefore creates an incompatible durable context.
- `schedulePostCommitSourceWork(nil)` sets `.none` before refresh.
- SourceCoordinator receives nil and stops all source-owned BLE state.
- Historical admission returns an empty current-context list when all rows are archived,
  while separately appending closed scopes that are still draining committed receipts.
- Do not call a forced 21-day analysis in `.none`; publish canonical history and
  an explicit disconnected/no-live-source state only.
*/
