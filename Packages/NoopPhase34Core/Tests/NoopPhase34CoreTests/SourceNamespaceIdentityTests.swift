import Testing
@testable import NoopPhase34Core

@Test func exactNamespaceNormalizesEveryOwnedIdentifier() throws {
    let namespace = try ExactAnalysisNamespace(
        rawDeviceId: " strap-a ",
        importedBaselineDeviceIds: [" baseline-a ", "baseline-b"],
        additionalVerificationSourceIds: [" extra-a "],
        historyLineage: " lineage-a ",
        cursorEpoch: 4
    )

    #expect(namespace.rawDeviceId == "strap-a")
    #expect(namespace.computedDeviceId == "strap-a-noop")
    #expect(namespace.importedBaselineDeviceIds == ["baseline-a", "baseline-b"])
    #expect(namespace.verificationSourceIds == ["strap-a", "strap-a-noop", "extra-a"])
    #expect(namespace.historyLineage == "lineage-a")
}

@Test func repositoryDescriptorNormalizesAtTheConstructionBoundary() throws {
    let descriptor = try RepositoryLiveSourceDescriptor(
        id: " strap-a ",
        historyLineage: " lineage-a ",
        cursorEpoch: 4
    )

    #expect(descriptor.id == "strap-a")
    #expect(descriptor.historyLineage == "lineage-a")
    #expect(descriptor.lineageComponent == "live:strap-a:lineage-a:4")
}

@Test func repositoryComputedReadsUseTheExactNamespaceConvention() throws {
    let descriptor = try RepositoryLiveSourceDescriptor(
        id: "strap-a",
        historyLineage: "lineage-a",
        cursorEpoch: 4
    )

    #expect(ActiveSourceReadPolicy.computedReadIds(
        liveState: .active(descriptor),
        canonicalComputedId: "canonical-noop"
    ) == ["canonical-noop", "strap-a-noop"])
}
