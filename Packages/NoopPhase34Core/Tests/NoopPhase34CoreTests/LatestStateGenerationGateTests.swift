import Testing
@testable import NoopPhase34Core

@Test func latestStateGateRejectsOlderGeneration() {
    #expect(!LatestStateGenerationGate.accepts(incoming: 9, current: 10))
    #expect(LatestStateGenerationGate.accepts(incoming: 10, current: 10))
    #expect(LatestStateGenerationGate.accepts(incoming: 11, current: 10))
    #expect(LatestStateGenerationGate.accepts(incoming: 1, current: nil))
}
