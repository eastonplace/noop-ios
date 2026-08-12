#!/usr/bin/env python3
"""Static contract for the WHOOP-only RyanBR NOOP v9.1 compatibility sync.

This audit is intentionally local-only. It checks durable source boundaries and focused
regression tests; it does not use GitHub Actions as build or compiler evidence.
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


try:
    require(
        "README.md",
        "## Upstream backend baseline",
        "NOOP iOS 2.1",
        "WHOOP backend behavior",
        "Oura transport work is not part of the NOOP iOS 2.1 release gate",
        "v9.1.0",
        "authoritative Strain and Sleep models",
        "separate, explicitly labelled experimental beta value",
        "never populates canonical Blood O₂, HealthKit, Charge, illness detection",
        "docs/RYANBR_9_1_BACKEND_SYNC.md",
    )
    require(
        "docs/RYANBR_9_1_BACKEND_SYNC.md",
        "Release tag: `v9.1.0`",
        "WHOOP",
        "Oura work is explicitly **out of scope for the 2.1 release gate**",
        "Preserve NOOP iOS's current authoritative Strain implementation",
        "Preserve NOOP iOS's current Sleep scoring",
        "SpO₂ Candidate (Beta)",
        "must never populate canonical `spo2Pct`, HealthKit, Recovery, illness detection",
        "GitHub Actions is not used as evidence",
    )

    # Heart-rate recovery: one contiguous effort run, deterministic same-second collapse,
    # plausible profile/timestamp bounds, real post-workout coverage, and bounded progressive refresh.
    require(
        "Packages/StrandAnalytics/Sources/StrandAnalytics/HeartRateRecovery.swift",
        "public enum HeartRateRecovery",
        "minimumHighIntensitySeconds = 120",
        "eligibilityLookbackSeconds = 300",
        "measurementToleranceSeconds = 15",
        "minimumSamplesPerReading = 3",
        "maximumContinuousGapSeconds = 10",
        "plausibleMaxHeartRateRange = 30.0...300.0",
        "private static func canonicalSeconds",
        "private static func longestSustainedSeconds",
        "currentRun = 0",
        "addingReportingOverflow",
        "subtractingReportingOverflow",
        "return result.hasMeasurement ? result : nil",
    )
    require(
        "Packages/StrandAnalytics/Tests/StrandAnalyticsTests/HeartRateRecoveryTests.swift",
        "testCalculatesOneTwoAndFiveMinuteDropsFromRobustReadings",
        "testRequiresSustainedHighIntensityRatherThanOnePeak",
        "testRejectsDisconnectedHighIntensityFragments",
        "testDenseHighIntensityBurstsDoNotAddTogetherAcrossLowHeartRateBreaks",
        "testDoesNotCreditPreWorkoutHeartRateTowardEligibility",
        "testReturnsOnlyMeasurementsWithRealCoverage",
        "testDuplicateCallbacksAtOneSecondDoNotFakeCoverage",
        "testAHeartRateRiseRemainsSignedInsteadOfBeingClamped",
        "testRejectsNonFiniteOrImplausibleMaxHeartRate",
        "testExtremeWorkoutTimestampsFailClosedWithoutArithmeticOverflow",
    )
    require(
        "Strand/Data/Repository+HeartRateRecovery.swift",
        "func workoutHeartRateRecovery(",
        "HeartRateRecovery.calculate(",
        "Self.workoutHrDeviceId(",
        "addingReportingOverflow",
        "subtractingReportingOverflow",
        "limit: 10_000",
    )
    require(
        "Strand/Screens/WorkoutHeartRateRecoveryCard.swift",
        "struct WorkoutHeartRateRecoveryCard",
        "loadAsCoverageArrives",
        "maximumRefreshHorizon = 6 * 60",
        "addingReportingOverflow",
        "subtractingReportingOverflow",
        "workout.source",
        "maxHR.bitPattern",
        "NOOP does not interpolate it",
    )

    # Real WHOOP journal exports use `Answered yes`, not NOOP's older yes/no header. The compatibility
    # pass stays bounded, prefers the canonical file, and builds the selected CSV table only once.
    require(
        "Packages/StrandImport/Sources/StrandImport/WhoopV91JournalCompatibility.swift",
        '"answered_yes"',
        '"answered_yes_no"',
        "maximumJournalBytes = 32 << 20",
        "maximumCSVEntriesToInspect = 64",
        'canonicalFilename = "journal_entries.csv"',
        "let table = CSVTable(data: data)",
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
        "testCanonicalJournalWinsOverAnotherAnsweredYesCSV",
        "Question text,Answered yes,Notes",
    )

    # Existing/imported workout facts always win; only valid, non-contradictory nil fields may be filled.
    require(
        "Packages/StrandAnalytics/Sources/StrandAnalytics/WorkoutDetectedBackfill.swift",
        "public enum WorkoutDetectedBackfill",
        "maximumCaloriesKcal = 100_000.0",
        "private static func validCalories",
        "private static func validStoredStrain",
        "(0...100).contains($0)",
        "average > peak",
        "let averageFill",
        "let peakFill",
        "computed.strainVersion != nil",
        "strainVersion: fillsStrain ? computed.strainVersion : real.strainVersion",
    )
    require(
        "Packages/StrandAnalytics/Tests/StrandAnalyticsTests/WorkoutDetectedBackfillTests.swift",
        "testFillsOnlyMissingComputedFields",
        "testNeverOverwritesUserOrImportedValues",
        "testExistingStrainKeepsItsVersionWhileOtherFieldsFill",
        "testExtremeFiniteCaloriesAreRejectedRatherThanClamped",
        "testOutOfRangeOrUnversionedStrainIsNotBackfilled",
        "testContradictoryComputedHeartRatesAreRejectedTogether",
        "testComputedPeerCannotContradictExistingRealHeartRate",
    )

    # Seeded WHOOP rows are repaired only under stable physical/family evidence and an atomic generic-row predicate.
    require(
        "Packages/WhoopStore/Sources/WhoopStore/DeviceRegistryStore+Model.swift",
        "setModelIfGenericWhoop",
        "lower(trim(model)) = 'whoop'",
        "return db.changesCount == 1",
    )
    require(
        "StrandiOS/App/AppModel+SeededWhoopModel.swift",
        "SeededWhoopModelResolver",
        'return whoop5Detected ? "WHOOP 5.0 / MG" : "WHOOP 4.0"',
        "expectedPeripheral",
        "expectedWhoop5",
        "ble.connectedPeripheralUUID == expectedPeripheral",
        'active.brand.caseInsensitiveCompare("WHOOP")',
        "active.peripheralId.map",
        "registry.setModelIfGenericWhoop",
    )
    require(
        "StrandiOS/App/StrandiOSApp.swift",
        "model.live.$connectSettled.removeDuplicates().dropFirst()",
        "await model.correctSeededWhoopModelIfNeeded()",
    )
    require(
        "Packages/WhoopStore/Tests/WhoopStoreTests/DeviceRegistryStoreTests.swift",
        "testGenericWhoopModelRepairIsAtomicAndNeverOverwritesSpecificModels",
    )
    require(
        "StrandiOSTests/SeededWhoopModelTests.swift",
        "testGenericSeedResolvesToWhoop4WhenFiveIsNotDetected",
        "testGenericSeedResolvesToWhoop5FamilyWhenDetected",
        "testSpecificModelIsNeverOverwritten",
    )

    # WHOOP 5 byte 82 is a separate explicitly-beta surface, never the canonical/medical metric.
    require(
        "Packages/WhoopProtocol/Sources/WhoopProtocol/Whoop5V18SpO2Candidate.swift",
        "separate from the canonical blood-oxygen metric",
        "case percentage(Int)",
        "case saturationSentinel(UInt8)",
        "case diagnosticCode(UInt8)",
        "public static let frameOffset = 82",
        "public static let persistedMarkerIR = -82",
        "public static func experimentalSample(",
        "sleepState == 2",
        "public static func persistedPercentage",
        "must never populate `spo2Pct`",
    )
    require(
        "Packages/WhoopProtocol/Sources/WhoopProtocol/HistoricalStreams.swift",
        'p["aux_byte_82"]?.intValue',
        "experimentalSpO2Minutes: [Int: (sum: Int, count: Int)]",
        "one order-independent minute mean",
        "Whoop5V18SpO2Candidate.experimentalSample(",
        "Double(aggregate.sum) / Double(aggregate.count)",
        "out.spo2.append(sample)",
    )
    require(
        "Packages/WhoopProtocol/Tests/WhoopProtocolTests/Whoop5V18SpO2CandidateTests.swift",
        "testClassifiesInBandPercentagesWithoutPromotingOtherValues",
        "testShortFrameFailsClosed",
        "testNonPercentageCasesNeverExposeCandidatePercentage",
        "testExperimentalSampleRequiresAsleepStateAndInBandValue",
        "testPersistedMarkerNeverLooksLikeOrdinaryRawChannels",
    )
    require(
        "Packages/WhoopProtocol/Tests/WhoopProtocolTests/Whoop5ExperimentalSpO2PipelineTests.swift",
        "testSleepingInBandCandidateReachesCompactSpO2Stream",
        "testSameMinuteCandidatesProduceOneOrderIndependentMean",
        "testAwakeOrSentinelValuesNeverReachExperimentalStream",
        "persistedMarkerIR",
    )
    require(
        "Strand/Screens/VitalSignsSummary.swift",
        "SpO₂ Candidate (Beta)",
        "Experimental; may be inaccurate",
        "WHOOP 5/MG",
        "Whoop5V18SpO2Candidate.persistedPercentage",
        "It may be inaccurate and is not used for scoring, HealthKit, or medical decisions",
        "band: .noData",
        'format: { String(format: "≈%.0f", $0) }',
        "private static func isPlausibleVital",
        "private static func wholeNumber",
        "Never place the candidate into the canonical Blood O₂ tile",
    )

    # App references are allowed only in the single presentation resolver. No scoring, HealthKit, widget,
    # Trends, or other surface may quietly treat the candidate as validated physiology.
    allowed_candidate_app_path = Path("Strand/Screens/VitalSignsSummary.swift")
    for root in ("Strand", "StrandiOS", "StrandiOSShared", "StrandiOSWidgets"):
        base = ROOT / root
        if not base.exists():
            continue
        for path in base.rglob("*.swift"):
            source = path.read_text(encoding="utf-8")
            relative = path.relative_to(ROOT)
            if "Whoop5V18SpO2Candidate" in source and relative != allowed_candidate_app_path:
                raise AssertionError(
                    f"{relative} promotes the experimental byte-82 candidate outside its beta presentation boundary"
                )
            if "spo2_candidate_82" in source and relative != allowed_candidate_app_path:
                raise AssertionError(
                    f"{relative} consumes the experimental candidate outside its beta presentation boundary"
                )
    forbid(
        "Strand/Screens/VitalSignsSummary.swift",
        "spo2Pct: candidate",
        'label: String(localized: "Blood O₂"),\n                    unit: "%",\n                    value: candidateSpO2Row',
        "banding: VitalBands.Result(band: .inRange",
        "String(Int($0.rounded()))",
    )

    # Raw IMU helpers share one full-shape gate; a long unrelated frame cannot yield an IMU timestamp.
    require(
        "Packages/WhoopProtocol/Sources/WhoopProtocol/Whoop5RawImu.swift",
        "public static func rawColumns",
        "public static func baseTs",
        "private static func isValidBuffer",
        "guard isValidBuffer(f) else { return nil }",
        "output[column * sampleCount + index]",
    )
    require(
        "Packages/WhoopProtocol/Tests/WhoopProtocolTests/Whoop5RawImuStorageTests.swift",
        "testRawColumnsPreserveWireOrderAndSignedValues",
        "testBaseTimestampRequiresTheCompleteImuShape",
        "testDecodeAndRawColumnsRejectTrailingOrTruncatedBytes",
    )

    # Unsupported WHOOP services are metadata only and the selected family itself must be connectable.
    require(
        "Packages/WhoopProtocol/Sources/WhoopProtocol/WhoopGattServiceFamily.swift",
        "case puffin1150",
        "case monument",
        "case symphony",
        "case .puffin1150, .monument, .symphony: return nil",
        "will not connect or send commands",
        "guard selected.isConnectable else",
        "whoopGattScanDecision",
    )
    require(
        "Packages/WhoopProtocol/Tests/WhoopProtocolTests/WhoopGattServiceFamilyTests.swift",
        "testUnsupportedFamiliesHaveNoConnectableDeviceFamily",
        "testUnsupportedAdvertisementIsRejectedBeforeGatt",
        "testUnsupportedSelectedFamilyNeverConnectsEvenWhenAdvertisedOrServicesAreOmitted",
        "testUnknownSelectedFamilyFailsClosedEvenWhenServicesAreOmitted",
        "testUnknownDifferentServiceIsIgnoredWithoutInventingAFamily",
    )

    # GET_CLOCK retry and Data Range fallback stay bounded, plausible, overflow-safe, and one-shot.
    require(
        "Packages/WhoopProtocol/Sources/WhoopProtocol/StrapClockRecoveryPlanner.swift",
        "defaultMaximumRetries = 3",
        "maximumFutureSkewSeconds = 300",
        "fallbackIssued",
        "guard !fallbackIssued",
        "addingReportingOverflow(Self.maximumFutureSkewSeconds)",
        "newestBankedUnix <= latestAllowedUnix",
        "fallbackIssued = true",
        "guard !hasPreciseCorrelation else { return .none }",
    )
    require(
        "Packages/WhoopProtocol/Tests/WhoopProtocolTests/StrapClockRecoveryPlannerTests.swift",
        "testRetriesAreBoundedThenDataRangeFallbackInstallsOnce",
        "testPreciseCorrelationSuppressesRetriesAndFallback",
        "testFallbackFailsClosedWithoutValidDataRange",
        "testFutureDataRangeMarkerFailsClosed",
        "testExtremeWallClockFailsClosedWithoutIntegerOverflow",
        "testResetRearmsFirstRetryAndFallback",
    )

    # The 2.1 delta remains additive and iPhone-only. Oura-specific v9.1 additions are deliberately absent;
    # the retained Oura package itself remains because it is part of the 2.0 repository and test matrix.
    for forbidden_path in (
        "StrandAndroid",
        "StrandWatch",
        "StrandMac",
        "NoopAndroid",
        "NoopWatch",
        "NoopMac",
        "Packages/OuraProtocol/Sources/OuraProtocol/OuraFeatureStatus.swift",
        "Packages/OuraProtocol/Sources/OuraProtocol/OuraIBITimestampPolicy.swift",
        "Packages/OuraProtocol/Sources/OuraProtocol/OuraWear.swift",
        "Packages/OuraProtocol/Tests/OuraProtocolTests/OuraFeatureStatusTests.swift",
        "Packages/OuraProtocol/Tests/OuraProtocolTests/OuraIBITimestampPolicyTests.swift",
        "Packages/OuraProtocol/Tests/OuraProtocolTests/OuraWearTests.swift",
    ):
        if (ROOT / forbidden_path).exists():
            raise AssertionError(f"out-of-scope or retired path restored: {forbidden_path}")

except AssertionError as error:
    print(f"RyanBR v9.1 WHOOP compatibility audit: FAIL\n{error}", file=sys.stderr)
    raise SystemExit(1)

print("RyanBR v9.1 WHOOP compatibility audit: PASS")
