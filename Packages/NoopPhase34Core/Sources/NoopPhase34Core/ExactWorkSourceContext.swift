import Foundation

public struct ExactWorkSourceContext: Equatable, Sendable {
    public let sourceId: String
    public let deviceId: String
    public let lineage: String
    public let cursorEpoch: Int

    public init(work: HistoricalAnalysisWork) {
        sourceId = work.scope.sourceId
        deviceId = work.scope.deviceId
        lineage = work.scope.deviceLineageId
        cursorEpoch = work.scope.cursorEpoch
    }
}

public enum ExactDayOwnerDecision: Equatable, Sendable {
    case analyze(deviceId: String)
    case supersededByLockedOwner(deviceId: String)
}

public enum ExactDayOwnerPolicy {
    /// Exact committed work is owned by the source that committed the receipt, not whichever source became
    /// active before the deferred analysis ran. An explicit locked day owner remains authoritative.
    public static func decide(
        workSourceDeviceId: String,
        persistedOwner: (deviceId: String, locked: Bool)?
    ) -> ExactDayOwnerDecision {
        if let persistedOwner, persistedOwner.locked,
           persistedOwner.deviceId != workSourceDeviceId {
            return .supersededByLockedOwner(deviceId: persistedOwner.deviceId)
        }
        return .analyze(deviceId: workSourceDeviceId)
    }
}

/*
Intelligence integration:

- Add `sourceContext: ExactWorkSourceContext` to ExactCommittedAnalysisRequest.
- Exact committed analysis must not call the ordinary active-source owner resolver.
- For each affected day, read `dayOwnership`; call ExactDayOwnerPolicy.
- `.analyze(deviceId:)` forces the raw/import source for that exact scorer pass and records ownership before
  persistence. `.supersededByLockedOwner` completes the work as an explicit no-op for that day.
- Repository historical verification includes the work source and computed sibling in its sparse WAL read,
  while current Today windows still use the current active/canonical union.
- Ordinary non-receipt refreshes keep the existing active-source arbitration.
*/
