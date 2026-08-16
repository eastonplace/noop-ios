import Foundation

/// Immutable storage ownership for one exact historical work item.
public struct ExactAnalysisNamespace: Equatable, Sendable {
    public let rawDeviceId: String
    public let computedDeviceId: String
    public let importedBaselineDeviceIds: [String]
    public let verificationSourceIds: [String]
    public let historyLineage: String
    public let cursorEpoch: Int

    public static func defaultComputedDeviceId(forRawDeviceId rawDeviceId: String) -> String {
        rawDeviceId.trimmingCharacters(in: .whitespacesAndNewlines) + "-noop"
    }

    public init(
        rawDeviceId: String,
        computedDeviceId: String? = nil,
        importedBaselineDeviceIds: [String]? = nil,
        additionalVerificationSourceIds: [String] = [],
        historyLineage: String,
        cursorEpoch: Int
    ) throws {
        let raw = rawDeviceId.trimmingCharacters(in: .whitespacesAndNewlines)
        let computed = (computedDeviceId ?? Self.defaultComputedDeviceId(forRawDeviceId: raw))
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let lineage = historyLineage.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !raw.isEmpty, !computed.isEmpty, !lineage.isEmpty, cursorEpoch >= 0 else {
            throw ExactAnalysisNamespaceError.invalidIdentity
        }

        let baselines = (importedBaselineDeviceIds ?? [raw])
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
        guard baselines.allSatisfy({ !$0.isEmpty }) else {
            throw ExactAnalysisNamespaceError.invalidIdentity
        }

        self.rawDeviceId = raw
        self.computedDeviceId = computed
        self.importedBaselineDeviceIds = baselines
        var seen = Set<String>()
        self.verificationSourceIds = ([raw, computed] + additionalVerificationSourceIds)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty && seen.insert($0).inserted }
        self.historyLineage = lineage
        self.cursorEpoch = cursorEpoch
    }
}

public enum ExactAnalysisNamespaceError: Error, Equatable, Sendable {
    case invalidIdentity
}

public extension ExactWorkSourceContext {
    var analysisNamespace: ExactAnalysisNamespace {
        get throws {
            try ExactAnalysisNamespace(
                rawDeviceId: deviceId,
                historyLineage: lineage,
                cursorEpoch: cursorEpoch
            )
        }
    }
}
