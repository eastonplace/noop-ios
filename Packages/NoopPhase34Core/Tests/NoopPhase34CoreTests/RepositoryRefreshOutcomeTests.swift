import Testing
@testable import NoopPhase34Core

@Test func snapshotFailureDoesNotTurnAuthoritativeRefreshIntoFailure() throws {
    let outcome = RepositoryRefreshOutcome(
        authoritativeDataPublished: true,
        changedDays: [try CivilDay(key: "2026-08-03")],
        snapshotStatus: .failed
    )
    #expect(outcome.succeeded)
    #expect(outcome.shouldRetrySnapshot)
}
