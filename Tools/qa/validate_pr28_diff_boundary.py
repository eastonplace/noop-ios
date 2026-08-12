#!/usr/bin/env python3
from __future__ import annotations
import re, subprocess, sys
from pathlib import Path

root = Path(sys.argv[1]).resolve()
allowed_exact = {
    '.github/workflows/app-build.yml',
    '.github/workflows/swift-packages.yml',
    'Packages/NoopPhase34Core/Sources/NoopPhase34Core/CooperativeAnalysisCancellation.swift',
    'Packages/NoopPhase34Core/Sources/NoopPhase34Core/ExactWorkSourceContext.swift',
    'Packages/NoopPhase34Core/Sources/NoopPhase34Core/ExternalPublicationOutbox.swift',
    'Packages/NoopPhase34Core/Sources/NoopPhase34Core/HistoricalAnalysisWorkReducer.swift',
    'Packages/NoopPhase34Core/Sources/NoopPhase34Core/LosslessDrainSignalGate.swift',
    'Packages/NoopPhase34Core/Sources/NoopPhase34Core/RepositoryActiveSourceState.swift',
    'Packages/NoopPhase34Core/Sources/NoopPhase34Core/SelectiveExternalPublicationPlan.swift',
    'Packages/NoopPhase34Core/Sources/NoopPhase34Core/SourceTransitionPolicy.swift',
    'Packages/NoopPhase34Core/Sources/NoopPhase34Core/SourceTransitionRecoveryCoordinator.swift',
    'Packages/NoopPhase34Core/Sources/NoopPhase34Core/VerifiedWidgetCorePayload.swift',
    'Packages/NoopPhase34Core/Tests/NoopPhase34CoreTests/PR28Round4HardeningTests.swift',
    'Packages/WhoopStore/Sources/WhoopStore/CanonicalHealthSurfaceIndexedRanges.swift',
    'Packages/WhoopStore/Sources/WhoopStore/DeviceLifecycleHardeningPatch.swift',
    'Packages/WhoopStore/Sources/WhoopStore/DurableJournalMaintenance.swift',
    'Packages/WhoopStore/Sources/WhoopStore/DurableSourceLifecycleStore.swift',
    'Packages/WhoopStore/Sources/WhoopStore/FullHistoryRepairMaintenanceLane.swift',
    'Packages/WhoopStore/Sources/WhoopStore/HealthKitBatchHardening.swift',
    'Packages/WhoopStore/Sources/WhoopStore/HistoricalDataCommitJournal.swift',
    'Packages/WhoopStore/Sources/WhoopStore/HistoricalReceiptAdmissionStore.swift',
    'Packages/WhoopStore/Sources/WhoopStore/HistoricalScopeDrainLifecycle.swift',
    'Packages/WhoopStore/Sources/WhoopStore/PR28V48Migration.swift',
    'Packages/WhoopStore/Sources/WhoopStore/VerifiedExternalProjectionBundleStore.swift',
    'Packages/WhoopStore/Sources/WhoopStore/VerifiedSnapshotCommitStore.swift',
    'Strand/Data/ExactDayAnalysisIntegration.swift',
    'Strand/Data/IntelligenceEngine.swift',
    'Strand/Data/RepositoryAtomicHistoricalPublication.swift',
    'Strand/Data/SparseTrendsLoadPlan.swift',
    'StrandiOS/Widgets/SerializedLiveActivityCommands.swift',
    'StrandiOS/Widgets/WidgetEnrichmentCoordinator.swift',
    'StrandiOSShared/ActiveSinkEpochRecovery.swift',
    'StrandiOSShared/WidgetVerifiedEnvelope.swift',
    'StrandiOSTests/TodayHealthSnapshotHydrationTests.swift',
    'Packages/NoopPhase34Core/Sources/NoopPhase34Core/HistoricalHealthKitMutationPayload.swift',
    'Packages/NoopPhase34Core/Sources/NoopPhase34Core/HistoricalPipelineCoordinator.swift',
    'Packages/NoopPhase34Core/Sources/NoopPhase34Core/PipelineQuiescence.swift',
    'Packages/NoopPhase34Core/Tests/NoopPhase34CoreTests/PR28RootFixRegressionTests.swift',
    'Packages/WhoopStore/Sources/WhoopStore/AnalysisMutationJournalStore.swift',
    'Packages/WhoopStore/Sources/WhoopStore/CanonicalHealthSurfaceStore.swift',
    'Packages/WhoopStore/Sources/WhoopStore/Database.swift',
    'Packages/WhoopStore/Sources/WhoopStore/DeviceRegistryStore.swift',
    'Packages/WhoopStore/Sources/WhoopStore/ExternalPublicationOutboxStore.swift',
    'Packages/WhoopStore/Sources/WhoopStore/HealthKitMutationWatermarkStore.swift',
    'Packages/WhoopStore/Sources/WhoopStore/HealthKitSleepKeyLedger.swift',
    'Packages/WhoopStore/Sources/WhoopStore/PR28V47Migration.swift',
    'Packages/WhoopStore/Sources/WhoopStore/WhoopStore.swift',
    'Packages/WhoopStore/Tests/WhoopStoreTests/LabMarkerStoreTests.swift',
    'Packages/WhoopStore/Tests/WhoopStoreTests/MetricsCacheTests.swift',
    'Packages/WhoopStore/Tests/WhoopStoreTests/MigrationTests.swift',
    'Packages/WhoopStore/Tests/WhoopStoreTests/PR28RootFixMigrationTests.swift',
    'Packages/WhoopStore/Tests/WhoopStoreTests/ScaffoldTests.swift',
    'Packages/WhoopStore/Tests/WhoopStoreTests/SleepMotionStateTests.swift',
    'Packages/WhoopStore/Tests/WhoopStoreTests/SleepRecoveryStoreTests.swift',
    'Strand/App/AppModel.swift',
    'Strand/App/ExternalPublicationWorker.swift',
    'Strand/App/HistoricalPipelineRuntime.swift',
    'Strand/App/SourceTransitionFence.swift',
    'Strand/BLE/SourceCoordinator.swift',
    'Strand/Data/AppleWatchDevice.swift',
    'Strand/Data/CanonicalTrendsRangeLoader.swift',
    'Strand/Data/DeviceRegistry.swift',
    'Strand/Data/Repository.swift',
    'Strand/Data/RepositoryExactAuthoritativeMerge.swift',
    'Strand/Data/RepositoryHistoricalSnapshotWindows.swift',
    'Strand/Data/TrendsBounds.swift',
    'Strand/Screens/DevicesView.swift',
    'Strand/Screens/TrendsSnapshotModels.swift',
    'Strand/Screens/TrendsView+WeeklyReview.swift',
    'Strand/Screens/TrendsView.swift',
    'StrandiOS/App/AppModel+SeededWhoopModel.swift',
    'StrandiOS/App/StrandiOSApp.swift',
    'StrandiOS/Health/HealthKitBridge.swift',
    'StrandiOS/Widgets/LiveActivityController.swift',
    'StrandiOS/Widgets/SerializedLiveActivityPublication.swift',
    'StrandiOS/Widgets/WidgetCorePublication.swift',
    'StrandiOS/Widgets/WidgetPublish.swift',
    'StrandiOSShared/ActiveVerifiedSinkEpoch.swift',
    'StrandiOSShared/WidgetSnapshot.swift',
    'StrandiOSWidgets/NOOPWidget.swift',
    'StrandiOSTests/PR28Round3RootFixTests.swift',
    'Tools/qa/validate_pr28_diff_boundary.py',
    'Tools/qa/trends_snapshot_contract_audit.py',
}

def git(*args: str) -> str:
    p = subprocess.run(['git', *args], cwd=root, text=True, stdout=subprocess.PIPE, stderr=subprocess.STDOUT)
    if p.returncode:
        print(p.stdout, file=sys.stderr)
        raise SystemExit(p.returncode)
    return p.stdout

files = sorted(set(
    [x for x in git('diff', '--name-only').splitlines() if x]
    + [x for x in git('ls-files', '--others', '--exclude-standard').splitlines() if x]
))
unexpected = [x for x in files if x not in allowed_exact]
if unexpected:
    print('Unexpected changed files:', *unexpected, sep='\n  ', file=sys.stderr)
    raise SystemExit(1)
# The allowlist is the complete PR28 surface, not a requirement that every file in
# the surface changes in every hardening round. Only changed files must be members.

numstat = git('diff', '--numstat').splitlines()
tracked_numstat_paths = {line.split('\t', 2)[-1] for line in numstat}
added = deleted = 0
for line in numstat:
    a, d, path = line.split('\t', 2)
    if a == '-' or d == '-':
        print(f'Binary diff is not allowed: {path}', file=sys.stderr)
        raise SystemExit(1)
    ai, di = int(a), int(d)
    added += ai; deleted += di
    if di > 900:
        print(f'Large deletion needs manual review: {path} ({di} lines)', file=sys.stderr)
        raise SystemExit(1)

for path in files:
    if path in tracked_numstat_paths:
        continue
    data = (root / path).read_bytes()
    if b'\x00' in data:
        print(f'Binary diff is not allowed: {path}', file=sys.stderr)
        raise SystemExit(1)
    added += data.count(b'\n') + (1 if data and not data.endswith(b'\n') else 0)
# Round 4 carries the bounded reference implementations for the WAL, drain,
# lifecycle, sink, maintenance, and CI contracts. Keep the guard, but size it
# for this single implementation batch rather than the smaller Round-3 patch.
if added > 7000 or deleted > 3000:
    print(f'Diff budget exceeded: +{added}/-{deleted}', file=sys.stderr)
    raise SystemExit(1)

patch = git('diff', '--no-ext-diff', '--unified=0')
for path in files:
    if path in tracked_numstat_paths:
        continue
    patch += '\n' + (root / path).read_text(encoding='utf-8')
# Build conflict markers at runtime so this validator can itself be included in the audited diff.
for token in ('<' * 7, '=' * 7, '>' * 7, '<' + '#code#' + '>', 'IMPLEMENT' + ' ME'):
    if token in patch:
        print(f'Forbidden token in diff: {token}', file=sys.stderr)
        raise SystemExit(1)
user_defaults = 'User' + 'Defaults'
health_terms = '(?:recovery|sleep|strain|health)'
if re.search(r'^\+.*' + user_defaults + r'.*' + health_terms, patch, re.I | re.M):
    print(f'A new {user_defaults} health cache was added.', file=sys.stderr)
    raise SystemExit(1)
broad_window = '(?:4000|4_000)'
history_terms = '(?:day|history)'
if re.search(r'^\+.*' + broad_window + r'.*' + history_terms, patch, re.I | re.M):
    print('A new broad 4,000-day path was added.', file=sys.stderr)
    raise SystemExit(1)
print(f'Diff boundary passed: {len(files)} files, +{added}/-{deleted}.')
