#!/usr/bin/env python3
from __future__ import annotations
import re, subprocess, sys
from pathlib import Path

root = Path(sys.argv[1]).resolve()
allowed_exact = {
    'Packages/NoopPhase34Core/Sources/NoopPhase34Core/HistoricalPipelineCoordinator.swift',
    'Packages/NoopPhase34Core/Sources/NoopPhase34Core/HistoricalAnalysisWork.swift',
    'Packages/NoopPhase34Core/Sources/NoopPhase34Core/HistoricalAnalysisWorkReducer.swift',
    'Packages/NoopPhase34Core/Sources/NoopPhase34Core/ExternalPublicationOutbox.swift',
    'Packages/NoopPhase34Core/Sources/NoopPhase34Core/CanonicalSleepScore.swift',
    'Packages/NoopPhase34Core/Tests/NoopPhase34CoreTests/BlockedPipelineTests.swift',
    'Strand/Data/ExactDayAnalysisIntegration.swift',
    'Strand/Data/RepositoryPostAnalysisSnapshotBuilder.swift',
    'Strand/App/PR28HistoricalPipelineErrors.swift',
    'Strand/App/AppModel.swift',
    'Strand/App/ExternalPublicationWorker.swift',
    'StrandiOS/Health/HealthKitBridge.swift',
    'StrandiOS/App/StrandiOSApp.swift',
    'Strand/Data/Repository.swift',
    'Packages/WhoopStore/Sources/WhoopStore/HistoricalReceiptAdmissionStore.swift',
    'Packages/WhoopStore/Sources/WhoopStore/DeviceRegistryStore.swift',
    'Packages/WhoopStore/Sources/WhoopStore/DeviceRegistry.swift',
    'Packages/WhoopStore/Sources/WhoopStore/RawOutboxStore.swift',
    'Packages/WhoopStore/Sources/WhoopStore/RawPacketOutboxStore.swift',
    'Packages/WhoopStore/Sources/WhoopStore/RawOutbox.swift',
    'Packages/WhoopStore/Sources/WhoopStore/HistoricalCursorHardeningPatch.swift',
    'Packages/WhoopStore/Sources/WhoopStore/RawOutboxHardeningPatch.swift',
    'Tools/qa/audit_pr28_root_fix.py',
    'Tools/qa/validate_pr28_diff_boundary.py',
}

def git(*args: str) -> str:
    p = subprocess.run(['git', *args], cwd=root, text=True, stdout=subprocess.PIPE, stderr=subprocess.STDOUT)
    if p.returncode:
        print(p.stdout, file=sys.stderr)
        raise SystemExit(p.returncode)
    return p.stdout

files = [x for x in git('diff', '--name-only').splitlines() if x]
unexpected = [x for x in files if x not in allowed_exact]
if unexpected:
    print('Unexpected changed files:', *unexpected, sep='\n  ', file=sys.stderr)
    raise SystemExit(1)
# The recovered bundle is applied on top of the already-integrated Phase 3/4 branch. Its
# root fix therefore includes the 16 existing integration paths plus five required new/deleted
# artifacts listed above. Keep this exact count so unrelated files cannot enter the patch.
if len(files) != 21:
    print(f'Unexpected changed-file count: {len(files)}; expected 21', file=sys.stderr)
    raise SystemExit(1)

numstat = git('diff', '--numstat').splitlines()
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
if added > 5000 or deleted > 3000:
    print(f'Diff budget exceeded: +{added}/-{deleted}', file=sys.stderr)
    raise SystemExit(1)

patch = git('diff', '--no-ext-diff', '--unified=0')
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
