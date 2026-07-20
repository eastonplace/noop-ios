import XCTest
@testable import NOOP

final class HealthKitWritebackFingerprintTests: XCTestCase {
    private func freshDefaults() -> UserDefaults {
        let suite = "test.healthkit.fingerprint.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        return defaults
    }

    func testSuccessfulIdenticalPlanSkipsForSixHoursThenExpires() {
        let defaults = freshDefaults()
        let start = Date(timeIntervalSince1970: 1_000)
        let fingerprint = HealthKitWritebackFingerprint.fingerprint(["day=2026-07-17", "rhr=52"])

        XCTAssertTrue(HealthKitWritebackFingerprint.shouldWrite(
            .vitals, fingerprint: fingerprint, now: start, defaults: defaults))
        HealthKitWritebackFingerprint.markSuccess(
            .vitals, fingerprint: fingerprint, at: start, defaults: defaults)
        XCTAssertFalse(HealthKitWritebackFingerprint.shouldWrite(
            .vitals, fingerprint: fingerprint,
            now: start.addingTimeInterval(6 * 3_600 - 1), defaults: defaults))
        XCTAssertTrue(HealthKitWritebackFingerprint.shouldWrite(
            .vitals, fingerprint: fingerprint,
            now: start.addingTimeInterval(6 * 3_600), defaults: defaults))
    }

    func testChangedPlanAndFailedUnmarkedPlanRetryImmediately() {
        let defaults = freshDefaults()
        let start = Date(timeIntervalSince1970: 1_000)
        let first = HealthKitWritebackFingerprint.fingerprint(["a"])
        let changed = HealthKitWritebackFingerprint.fingerprint(["b"])

        HealthKitWritebackFingerprint.markSuccess(
            .sleep, fingerprint: first, at: start, defaults: defaults)
        XCTAssertTrue(HealthKitWritebackFingerprint.shouldWrite(
            .sleep, fingerprint: changed, now: start.addingTimeInterval(1), defaults: defaults))
        XCTAssertTrue(HealthKitWritebackFingerprint.shouldWrite(
            .heartRate, fingerprint: first, now: start.addingTimeInterval(1), defaults: defaults))
    }

    func testComponentsAreIndependentAndResetClearsEverySuccess() {
        let defaults = freshDefaults()
        let start = Date(timeIntervalSince1970: 1_000)
        let fingerprint = HealthKitWritebackFingerprint.fingerprint(["same"])
        HealthKitWritebackFingerprint.markSuccess(
            .vitals, fingerprint: fingerprint, at: start, defaults: defaults)

        XCTAssertFalse(HealthKitWritebackFingerprint.shouldWrite(
            .vitals, fingerprint: fingerprint, now: start, defaults: defaults))
        XCTAssertTrue(HealthKitWritebackFingerprint.shouldWrite(
            .workouts, fingerprint: fingerprint, now: start, defaults: defaults))

        HealthKitWritebackFingerprint.reset(defaults: defaults)
        XCTAssertTrue(HealthKitWritebackFingerprint.shouldWrite(
            .vitals, fingerprint: fingerprint, now: start, defaults: defaults))
    }

    func testFingerprintIsStableAndOrderSensitive() {
        XCTAssertEqual(
            HealthKitWritebackFingerprint.fingerprint(["a", "b"]),
            HealthKitWritebackFingerprint.fingerprint(["a", "b"]))
        XCTAssertNotEqual(
            HealthKitWritebackFingerprint.fingerprint(["a", "b"]),
            HealthKitWritebackFingerprint.fingerprint(["b", "a"]))
    }
}
