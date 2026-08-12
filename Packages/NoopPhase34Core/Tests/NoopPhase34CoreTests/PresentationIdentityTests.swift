import Foundation
import Testing
@testable import NoopPhase34Core

@Test func metadataChangesDoNotChangePresentationIdentity() throws {
    let day = try CivilDay(key: "2026-08-03")
    let one = try VerifiedHealthMetric(
        kind: .recovery,
        value: 82,
        metricDay: day,
        sourceId: "my-whoop-noop",
        algorithmVersion: "recovery-v2",
        generation: 10,
        observedAt: 100,
        rawFrontierTs: 100,
        freshness: .fresh
    )
    let two = try VerifiedHealthMetric(
        kind: .recovery,
        value: 82,
        metricDay: day,
        sourceId: "my-whoop-noop",
        algorithmVersion: "recovery-v2",
        generation: 11,
        observedAt: 200,
        rawFrontierTs: 200,
        freshness: .fresh
    )
    let p1 = try VerifiedHealthProjection(contextId: "ctx", deviceId: "device", generation: 10, logicalDay: day, metrics: [.recovery: one])
    let p2 = try VerifiedHealthProjection(contextId: "ctx", deviceId: "device", generation: 11, logicalDay: day, metrics: [.recovery: two])
    #expect(p1.presentationIdentity == p2.presentationIdentity)
}

@Test func priorDayStrainIsNotVisibleAsCurrent() throws {
    let prior = try CivilDay(key: "2026-08-02")
    let current = try CivilDay(key: "2026-08-03")
    let strain = try VerifiedHealthMetric(
        kind: .strain,
        value: 55,
        metricDay: prior,
        sourceId: "my-whoop-noop",
        algorithmVersion: "strain-v2",
        generation: 5,
        freshness: .stale
    )
    let projection = try VerifiedHealthProjection(contextId: "ctx", deviceId: "device", generation: 5, logicalDay: current, metrics: [.strain: strain])
    #expect(projection.visibleMetric(.strain) == nil)
    #expect(projection.presentationIdentity.metrics[.strain]?.value == nil)
}

@Test func verifiedMetricDecoderRejectsInvalidValue() throws {
    let data = Data(#"{"kind":"recovery","value":120,"metricDay":{"year":2026,"month":8,"day":3},"sourceId":"source","algorithmVersion":"v1","generation":1,"freshness":"fresh"}"#.utf8)
    #expect(throws: DecodingError.self) {
        _ = try JSONDecoder().decode(VerifiedHealthMetric.self, from: data)
    }
}

@Test func verifiedProjectionDecoderRejectsZeroGeneration() throws {
    let data = Data(#"{"contextId":"ctx","deviceId":"device","generation":0,"logicalDay":{"year":2026,"month":8,"day":3},"metrics":[]}"#.utf8)
    #expect(throws: DecodingError.self) {
        _ = try JSONDecoder().decode(VerifiedHealthProjection.self, from: data)
    }
}
