#!/usr/bin/env python3
"""Static compatibility contract for the selective RyanBR NOOP v9.1 backend sync.

This audit is intentionally run locally. It is not wired into GitHub Actions.
"""
from pathlib import Path
import sys

ROOT = Path(__file__).resolve().parents[2]


def read(relative: str) -> str:
    path = ROOT / relative
    if not path.exists():
        raise AssertionError(f"missing required file: {relative}")
    return path.read_text(encoding="utf-8")


def require(relative: str, *markers: str) -> None:
    source = read(relative)
    for marker in markers:
        if marker not in source:
            raise AssertionError(f"{relative}: missing contract marker {marker!r}")


def forbid(relative: str, *markers: str) -> None:
    source = read(relative)
    for marker in markers:
        if marker in source:
            raise AssertionError(f"{relative}: forbidden marker {marker!r}")


def require_paths(*paths: str) -> None:
    for relative in paths:
        if not (ROOT / relative).exists():
            raise AssertionError(f"missing required path: {relative}")


try:
    require(
        "README.md",
        "## Upstream backend baseline",
        "Noop iOS 2.1",
        "v9.1.0",
        "authoritative Strain and Sleep models",
        "WHOOP 5.0 v18 byte-82 SpO₂ candidate is diagnostic instrumentation only",
        "docs/RYANBR_9_1_BACKEND_SYNC.md",
    )
    require(
        "docs/RYANBR_9_1_BACKEND_SYNC.md",
        "Release tag: `v9.1.0`",
        "Preserve NOOP iOS's current authoritative Strain implementation",
        "Preserve NOOP iOS's current Sleep scoring",
        "must not populate `spo2Pct`, HealthKit, Recovery, illness detection",
        "GitHub Actions is not used as evidence",
    )

    # Heart-rate recovery: local HR only, eligibility-gated, missing coverage stays nil.
    require(
        "Packages/StrandAnalytics/Sources/StrandAnalytics/HeartRateRecovery.swift",
        "public enum HeartRateRecovery",
        "minimumHighIntensitySeconds = 120",
        "eligibilityLookbackSeconds = 300",
        "measurementToleranceSeconds = 15",
        "minimumSamplesPerReading = 3",
        "maximumContinuousGapSeconds = 10",
        "return result.hasMeasurement ? result : nil",
    )
    require(
        "Packages/StrandAnalytics/Tests/StrandAnalyticsTests/HeartRateRecoveryTests.swift",
        "testCalculatesOneTwoAndFiveMinuteDropsFromRobustReadings",
        "testRequiresSustainedHighIntensityRatherThanOnePeak",
        "testRejectsDisconnectedHighIntensityFragments",
        "testDoesNotCreditPreWorkoutHeartRateTowardEligibility",
        "testReturnsOnlyMeasurementsWithRealCoverage",
        "testAHeartRateRiseRemainsSignedInsteadOfBeingClamped",
    )
    require(
        "Strand/Data/Repository+HeartRateRecovery.swift",
        "func workoutHeartRateRecovery(",
        "HeartRateRecovery.calculate(",
        "Self.workoutHrDeviceId(",
    )
    require(
        "Strand/Screens/WorkoutHeartRateRecoveryCard.swift",
        "struct WorkoutHeartRateRecoveryCard",
        "Checking heart-rate recovery",
        "NOOP does not interpolate it",
    )

    # Real WHOOP journal exports use `Answered yes`, not NOOP's older yes/no header.
    require(
        "Packages/StrandImport/Sources/StrandImport/WhoopV91JournalCompatibility.swift",
        '"answered_yes"',
        '"answered_yes_no"',
        "maximumJournalBytes",
        "WhoopImportResult(",
    )
    require(
        "Packages/StrandImport/Sources/StrandImport/ImportCoordinator.swift",
        "WhoopV91JournalCompatibility.applyingIfNeeded",
        "return .whoopExport(try importWhoopExport(from: url))",
    )
    require(
        "Packages/StrandImport/Tests/StrandImportTests/WhoopV91JournalCompatibilityTests.swift",
        "testExplicitWhoopImportReadsAnsweredYesHeaderVerbatim",
        "testAutoDetectedWhoopImportUsesTheSameCompatibilityPass",
        "Question text,Answered yes,Notes",
    )

    # Existing/imported workout facts always win; only nil computed fields may be filled.
    require(
        "Packages/StrandAnalytics/Sources/StrandAnalytics/WorkoutDetectedBackfill.swift",
        "public enum WorkoutDetectedBackfill",
        "real.energyKcal ?? computed.caloriesKcal",
        "real.avgHr ?? computed.averageHeartRate",
        "real.maxHr ?? computed.peakHeartRate",
        "real.strain ?? computed.strain",
        "strainVersion: fillsStrain ? computed.strainVersion : real.strainVersion",
    )
    require(
        "Packages/StrandAnalytics/Tests/StrandAnalyticsTests/WorkoutDetectedBackfillTests.swift",
        "testFillsOnlyMissingComputedFields",
        "testNeverOverwritesUserOrImportedValues",
        "testExistingStrainKeepsItsVersionWhileOtherFieldsFill",
    )

    # Seeded WHOOP rows are repaired only after the connected family is known.
    require(
        "StrandiOS/App/AppModel+SeededWhoopModel.swift",
        "SeededWhoopModelResolver",
        'return whoop5Detected ? "WHOOP 5.0 / MG" : "WHOOP 4.0"',
        "guard live.connected",
        "registry.setModel",
    )
    require(
        "StrandiOS/App/StrandiOSApp.swift",
        "model.live.$connectSettled.removeDuplicates().dropFirst()",
        "await model.correctSeededWhoopModelIfNeeded()",
    )
    require(
        "StrandiOSTests/SeededWhoopModelTests.swift",
        "testGenericSeedResolvesToWhoop4WhenFiveIsNotDetected",
        "testGenericSeedResolvesToWhoop5FamilyWhenDetected",
        "testSpecificModelIsNeverOverwritten",
    )

    # WHOOP 5 byte 82 remains a diagnostic classification, never a production oxygen metric.
    require(
        "Packages/WhoopProtocol/Sources/WhoopProtocol/Whoop5V18SpO2Candidate.swift",
        "instrumentation only",
        "case percentage(Int)",
        "case saturationSentinel(UInt8)",
        "case diagnosticCode(UInt8)",
        "public static let frameOffset = 82",
        "must never populate `spo2Pct`, HealthKit, Recovery, illness detection",
    )
    require(
        "Packages/WhoopProtocol/Tests/WhoopProtocolTests/Whoop5V18SpO2CandidateTests.swift",
        "testClassifiesInBandPercentagesWithoutPromotingOtherValues",
        "testShortFrameFailsClosed",
        "testNonPercentageCasesNeverExposeCandidatePercentage",
    )
    for root in ("Strand", "StrandiOS", "StrandiOSShared", "StrandiOSWidgets"):
        for path in (ROOT / root).rglob("*.swift"):
            if path.name == "Whoop5V18SpO2Candidate.swift":
                continue
            source = path.read_text(encoding="utf-8")
            if "Whoop5V18SpO2Candidate" in source:
                raise AssertionError(
                    f"{path.relative_to(ROOT)} promotes the experimental byte-82 candidate into app code"
                )

    # Raw IMU helpers preserve exact wire columns; no lossy display conversion is stored.
    require(
        "Packages/WhoopProtocol/Sources/WhoopProtocol/Whoop5RawImu.swift",
        "public static func rawColumns",
        "public static func baseTs",
        "output[column * sampleCount + index]",
    )
    require(
        "Packages/WhoopProtocol/Tests/WhoopProtocolTests/Whoop5RawImuStorageTests.swift",
        "testRawColumnsPreserveWireOrderAndSignedValues",
        "testDecodeAndRawColumnsRejectTrailingOrTruncatedBytes",
    )

    # Unsupported WHOOP services are metadata only and deliberately have no DeviceFamily/commands.
    require(
        "Packages/WhoopProtocol/Sources/WhoopProtocol/WhoopGattServiceFamily.swift",
        "case puffin1150",
        "case monument",
        "case symphony",
        "case .puffin1150, .monument, .symphony: return nil",
        "will not connect or send commands",
        "whoopGattScanDecision",
    )
    require(
        "Packages/WhoopProtocol/Tests/WhoopProtocolTests/WhoopGattServiceFamilyTests.swift",
        "testUnsupportedFamiliesHaveNoConnectableDeviceFamily",
        "testUnsupportedAdvertisementIsRejectedBeforeGatt",
        "testUnknownDifferentServiceIsIgnoredWithoutInventingAFamily",
    )

    # Oura probes are read-only. The 0x22 enable verb must not enter these diagnostic commands.
    require(
        "Packages/OuraProtocol/Sources/OuraProtocol/OuraFeatureStatus.swift",
        "OuraFeatureStatus",
        'bytes: [0x2f, 0x02, 0x20, featureSpO2]',
        'bytes: [0x2f, 0x02, 0x20, featureRealSteps]',
        "status.feature != Int(OuraCommands.featureDaytimeHR)",
    )
    forbid(
        "Packages/OuraProtocol/Sources/OuraProtocol/OuraFeatureStatus.swift",
        "0x22",
    )
    require(
        "Packages/OuraProtocol/Sources/OuraProtocol/OuraWear.swift",
        "public enum OuraWearState",
        "public final class OuraWearTracker",
        "noteLivePulseTimeout",
    )
    require(
        "Packages/OuraProtocol/Tests/OuraProtocolTests/OuraFeatureStatusTests.swift",
        "testStatusQueryCommandsUseReadVerbOnly",
        "testProbeKeepsDaytimeHeartRateAckOutOfDiagnostics",
    )
    require(
        "Packages/OuraProtocol/Tests/OuraProtocolTests/OuraWearTests.swift",
        "testLiveTrackerPulseMeansWorn",
        "testLivePulseTimeoutDowngradesOnlyWornState",
    )

    # The sync is additive and remains iPhone-only.
    for forbidden_path in (
        "StrandAndroid",
        "StrandWatch",
        "StrandMac",
        "NoopAndroid",
        "NoopWatch",
        "NoopMac",
    ):
        if (ROOT / forbidden_path).exists():
            raise AssertionError(f"retired application target restored: {forbidden_path}")

except AssertionError as error:
    print(f"RyanBR v9.1 backend compatibility audit: FAIL\n{error}", file=sys.stderr)
    raise SystemExit(1)

print("RyanBR v9.1 backend compatibility audit: PASS")
