import Foundation
import Testing
@testable import NoopPhase34Core

struct HealthKitReadResumePolicyTests {
    private func defaults() -> UserDefaults {
        UserDefaults(suiteName: "HealthKitReadResumePolicyTests.\(UUID().uuidString)")!
    }

    @Test func newInstallDoesNotResumeOrRecordUnfinishedRequest() {
        let policy = HealthKitReadResumePolicy(defaults: defaults())
        #expect(!policy.canAttemptReads)
        #expect(!policy.resumeIfPreviouslyRequested(.shouldRequest))
        #expect(!policy.resumeIfPreviouslyRequested(.unknown))
        #expect(!policy.canAttemptReads)
    }

    @Test func completedReadOnlyOrPartialFlowSurvivesRelaunch() {
        let storage = defaults()
        let first = HealthKitReadResumePolicy(defaults: storage)
        first.recordCompletedRequestFlow()
        let relaunched = HealthKitReadResumePolicy(defaults: storage)
        #expect(relaunched.canAttemptReads)
        // New types can still need a request. Existing read attempts remain eligible without a sheet.
        #expect(relaunched.resumeIfPreviouslyRequested(.shouldRequest))
    }

    @Test func legacyCompletedRequestMigratesWithoutClaimingAnyGrant() {
        let storage = defaults()
        let legacy = HealthKitReadResumePolicy(defaults: storage)
        #expect(legacy.resumeIfPreviouslyRequested(.unnecessary))
        #expect(HealthKitReadResumePolicy(defaults: storage).canAttemptReads)
    }

    @Test func revokedOrLockedReadsDoNotEraseCompletedConsentFlow() {
        let storage = defaults()
        let policy = HealthKitReadResumePolicy(defaults: storage)
        policy.recordCompletedRequestFlow()
        // Completion means reads may be attempted; it never asserts that HealthKit will return data.
        #expect(policy.resumeIfPreviouslyRequested(.unknown))
        #expect(HealthKitReadResumePolicy(defaults: storage).canAttemptReads)
    }
}
