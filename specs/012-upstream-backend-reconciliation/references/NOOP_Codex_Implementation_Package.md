# NOOP Private-Fork Reconciliation — Executable iPhone Implementation Package

**Target repository:** `eastonplace-ai/noop`  
**Target branch snapshot:** `main` at `42b868f5d7c580d55848592a3aaacb2e0ea11963`  
**Upstream repository:** `ryanbr/noop` (called “Nuke/upstream” in this package)  
**Stable upstream boundary:** `v9.0.1` at `25eb933a2563d490583ecd4c0051dff581874bb8`  
**Upstream current `main`:** `e91ef0a149c8686c156b8c7e2ecfeab5dcdfdf1c`  
**Shared merge base:** `f099af097f88827b987fadaf0843326c0c793f8e` (`v8.2.2`)  
**Prepared:** 2026-07-17  
**Scope:** iPhone and shared Swift behavior for WHOOP 4.0 and WHOOP 5.0/MG: protocol, BLE, collection, SQLite, analytics, imports, exports, HealthKit, diagnostics, backup, release/build tooling, and minimal UI adapters needed to expose those behaviors.  
**Excluded:** Android, upstream visual redesign, wholesale screen replacement, upstream `StrandDesign`, localization sweeps, Oura cloud work, macOS-only fixes, and any change that would replace the private Paper interface.

---

## 0. What this file delivers

This is not another planning memo. It is a pinned implementation bundle.

It contains:

1. the exact immutable source commits;
2. a source-status and commit review;
3. a deterministic merge/import script for the repository root;
4. exact private-fork rewrites for every target-owned file that cannot safely be copied wholesale;
5. exact R-R, HRV, migration, sync, power, and multi-WHOOP implementations;
6. a conflict-resolution policy for the small set of files changed on both sides;
7. package, simulator, database, HealthKit, and physical-strap QA gates;
8. a ready-to-run Codex execution contract.

The implementation script intentionally imports upstream backend code from Git history instead of reproducing hundreds of source files inside this document. That is still exact code: it resolves every imported byte from immutable Git objects, limits the import to an explicit allowlist, excludes the private visual layer, applies the two relevant post-`v9.0.1` Apple hotfix commits, and writes the target-specific code shown below.

At the pinned target SHA, the expected outcome is a reviewable working tree on `codex/reconcile-nuke-9.0.1`. Codex's remaining work is execution, build/test diagnosis, conflict resolution only where Git proves both sides edited the same semantic block, and hardware QA. It must not redesign the implementation.

---

## 1. Immutable source status and commit commentary

### 1.1 Target snapshot — use this as the destination

| Field | Value |
|---|---|
| Repository | `eastonplace-ai/noop` |
| Branch | `main` |
| Commit | `42b868f5d7c580d55848592a3aaacb2e0ea11963` |
| Commit title | `Use recovery bands in Trends heatmap` |
| Role in this reconciliation | **Destination snapshot** |
| Version metadata currently in tree | `8.2.2` / build `172` |
| Connector-visible checks | None attached to the exact commit |

**Commentary.** This is the correct target because it is the connected private repository, not the public `NoopApp/noop` fork assumed in the first pass. The latest commit is a private visual follow-up: it adds recovery-band coloring to the Trends heatmap through `StrandDesign` and `TrendsView`. It does not modify the protocol, BLE, storage, analytics, import, Today, Settings, project metadata, or migration adapters audited below. Pinning it nevertheless matters because it is the actual current private `main`, and the private visual changes must survive untouched.

Do not reset this repository to upstream. Do not use the public `NoopApp/noop` repository as the destination. Do not replace its screens or component library.

### 1.2 Shared ancestor — use this as the three-way base

| Field | Value |
|---|---|
| Commit | `f099af097f88827b987fadaf0843326c0c793f8e` |
| Commit title | `chore: AltStore source → 8.2.2 (build 172)` |
| Present in target history | Yes |
| Present in upstream history | Yes |
| Target commits after it | 143 |
| Stable-upstream commits after it | 501 |
| Role | **True merge base** |

**Commentary.** This shared commit is the reason a source-accurate reconciliation is possible. Both repositories descend from the same `8.2.2` tree, so Git can distinguish private changes, upstream changes, and genuine overlapping edits. The script always builds the backend patch as `BASE..UPSTREAM_STABLE` and applies it to `TARGET_SHA` with three-way context.

### 1.3 Stable upstream boundary — use this for released code

| Field | Value |
|---|---|
| Repository | `ryanbr/noop` |
| Tag | `v9.0.1` |
| Commit | `25eb933a2563d490583ecd4c0051dff581874bb8` |
| Commit title | `Release 9.0.1: bump version (patch) + build numbers + What's New` |
| iOS version/build | `9.0.1` / `203` |
| Role | **Released implementation boundary** |
| Connector-visible checks | None attached to the exact commit |

**Commentary.** The release commit itself mostly changes version and changelog metadata. Its ancestry contains the complete released 8.3.0–9.0.1 implementation wave. Pinning it prevents unreleased work from leaking into the private fork while importing every released backend/data fix.

### 1.4 Current upstream `main` — inspect, do not merge wholesale

| Field | Value |
|---|---|
| Commit | `e91ef0a149c8686c156b8c7e2ecfeab5dcdfdf1c` |
| Commit title | `i18n: real <plurals> instead of hand-rolled singular/plural pairs (#541)` |
| Distance from `v9.0.1` | 16 commits ahead, 0 behind |
| Role | **Post-release watchlist** |

The current head is Android-only plural/i18n infrastructure. Most of the 16 post-release commits are Android, Oura, localization, or unrelated experimental work and are outside this request. Two Apple/backend fixes are selected explicitly:

1. `f5f64977b9a83b2e74dccfee21daaeb5e7089a45` — correct `enable_sig12` to ASCII `'1'` (`0x31`);
2. `6a285e258c2443a2be64cbcb5eda9796878670e4` — reconcile workout HR against the recording strap rather than the currently active strap.

### 1.5 Staging snapshot — explicitly rejected

| Field | Value |
|---|---|
| Commit | `7fd6b15fcdea81fd9b90c76cdfb9903881894608` |
| Role | **Do not use** |

The staging commit identifies itself as a disposable staging-version bump that must never be merged into `main`.

---

## 2. Target-specific facts that govern implementation

### 2.1 Private identifiers that must remain intact

```yaml
DEVELOPMENT_TEAM: "479HYY24G2"
APP_GROUP_ID: group.com.eastonplace.noop
NOOPiOS PRODUCT_BUNDLE_IDENTIFIER: com.eastonplace.noop
NOOPiOSWidgets PRODUCT_BUNDLE_IDENTIFIER: com.eastonplace.noop.widgets
```

The upstream `project.yml` is not imported. Only version/build values change.

### 2.2 Private work that must survive

- `Packages/StrandDesign/**` and `Strand/Screens/**` are private visual territory.
- `TodayView.swift` remains the Paper Today screen.
- `SettingsView.swift` remains the Paper settings screen.
- `StorePaths.swift` keeps the private DEBUG/demo database partition.
- `Database.swift` keeps private coaching migrations `v23` and `v24`.
- `CoachingStore.swift`, Paper tests, and the private component library remain untouched.
- Android remains deleted.

### 2.3 Confirmed target gaps at the pinned target

| Gap | Target state | Final state supplied here |
|---|---|---|
| R-R primary key | `(deviceId, ts, rrMs)` | `(deviceId, ts, rrMs, seq)` |
| Equal same-second R-R writes | second equal beat can be dropped | deterministic occurrence `seq` |
| R-R read order | no `seq` ordering | `ts, rrMs, seq` |
| RMSSD/pNN50 after cleaning | crosses removed-beat splice | contiguous original pairs only |
| WHOOP 5/MG raw IMU support | file absent | imported from stable upstream |
| WHOOP 5 config | `enable_sig12` absent | present with final `0x31` |
| Raw v26 PPG persistence | no waveform table | private migration `v28` |
| Daily raw SpO2 cache | absent | private migration `v25` |
| Efficiency scale heal | absent | private migration `v27` |
| Today pull-to-sync | repository refresh only | safe BLE sync then refresh |
| Strap-battery power policy | no private settings controls | Paper-compatible card and prefs |
| Multi-WHOOP workout HR key | active strap only | recording strap for detected rows |
| Version metadata | `8.2.2` / `172` | `9.0.1` / `204` |

### 2.4 Material work already present privately

Do not duplicate private standard-HR/Test Centre hooks, continuous-HRV overnight safeguards, future-clock work, serialized store-open work, coaching tables, Paper data fallbacks, or independently implemented sleep/cache/identity fixes. Three-way merge semantics handle equivalent changes.

---

## 3. Integration model

```text
f099af0  shared 8.2.2 ancestor
   ├── 143 private commits ───────────────► 42b868f target snapshot
   │                                           ├─ preserve Paper UI
   │                                           ├─ preserve private IDs
   │                                           └─ preserve coaching migrations
   │
   └── 501 released upstream commits ─────► 25eb933 v9.0.1
                                               ├─ import backend allowlist
                                               └─ exclude visual/Android/Oura work

Post-release:
  f5f6497  R22 sig12 correction ───────────────┐
  6a285e2  workout recording-strap key ────────┴─ apply after stable
```

### Merge principles

1. Upstream exact for untouched backend files.
2. Three-way merge for backend files changed on both sides.
3. Private exact for screens, design, project identity, `StorePaths`, and migration ordering.
4. Manual overlay for target-owned integration seams.
5. Fail closed on unresolved conflicts or missing rewrite anchors.
6. No generated Xcode project committed.
7. No Android, Oura cloud, Polar, Huami, Garmin, Xiaomi, or upstream redesign files introduced.

---

## 4. One-shot implementation script

Save this block as `reconcile_nuke_9_0_1.sh` in a clean clone of `eastonplace-ai/noop` and run it on macOS with Xcode and XcodeGen installed.

```bash
#!/usr/bin/env bash
set -Eeuo pipefail
IFS=$'\n\t'

TARGET_REPO="eastonplace-ai/noop"
TARGET_SHA="42b868f5d7c580d55848592a3aaacb2e0ea11963"
COMMON_BASE="f099af097f88827b987fadaf0843326c0c793f8e"
UPSTREAM_STABLE="25eb933a2563d490583ecd4c0051dff581874bb8"
UPSTREAM_MAIN="e91ef0a149c8686c156b8c7e2ecfeab5dcdfdf1c"
R22_HOTFIX="f5f64977b9a83b2e74dccfee21daaeb5e7089a45"
WORKOUT_HOTFIX="6a285e258c2443a2be64cbcb5eda9796878670e4"
UPSTREAM_URL="https://github.com/ryanbr/noop.git"
UPSTREAM_REMOTE="nuke"
WORK_BRANCH="codex/reconcile-nuke-9.0.1"

die() { printf 'ERROR: %s\n' "$*" >&2; exit 1; }
need() { command -v "$1" >/dev/null 2>&1 || die "missing command: $1"; }

for tool in git python3 swift xcodebuild xcodegen xcrun; do need "$tool"; done
[[ -d .git ]] || die "run from repository root"

origin_url="$(git remote get-url origin)"
[[ "$origin_url" == *"eastonplace-ai/noop"* ]] ||
  die "origin is not $TARGET_REPO: $origin_url"

git diff --quiet || die "unstaged changes present"
git diff --cached --quiet || die "staged changes present"
[[ -z "$(git status --porcelain)" ]] || die "untracked files present"

git fetch --prune origin main
git cat-file -e "$TARGET_SHA^{commit}" 2>/dev/null || git fetch origin "$TARGET_SHA"
git merge-base --is-ancestor "$COMMON_BASE" "$TARGET_SHA" ||
  die "audited base is not an ancestor of target"

if git remote get-url "$UPSTREAM_REMOTE" >/dev/null 2>&1; then
  git remote set-url "$UPSTREAM_REMOTE" "$UPSTREAM_URL"
else
  git remote add "$UPSTREAM_REMOTE" "$UPSTREAM_URL"
fi

git fetch --prune "$UPSTREAM_REMOTE"   "+refs/heads/main:refs/remotes/$UPSTREAM_REMOTE/main"   "+refs/tags/v9.0.1:refs/tags/nuke-v9.0.1"

for sha in "$UPSTREAM_STABLE" "$R22_HOTFIX" "$WORKOUT_HOTFIX" "$UPSTREAM_MAIN"; do
  git cat-file -e "$sha^{commit}" 2>/dev/null || git fetch "$UPSTREAM_REMOTE" "$sha"
done

[[ "$(git rev-parse nuke-v9.0.1^{commit})" == "$UPSTREAM_STABLE" ]] ||
  die "v9.0.1 moved from audited SHA"
[[ "$(git rev-parse "$UPSTREAM_REMOTE/main")" == "$UPSTREAM_MAIN" ]] ||
  die "upstream main moved; re-audit post-release commits"
git merge-base --is-ancestor "$COMMON_BASE" "$UPSTREAM_STABLE" ||
  die "audited base is not an ancestor of stable upstream"

git switch --detach "$TARGET_SHA"
git switch -c "$WORK_BRANCH"

tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT

git diff --name-only "$COMMON_BASE" "$UPSTREAM_STABLE" > "$tmp/upstream_changed.txt"

python3 - "$tmp/upstream_changed.txt" "$tmp/patch_paths.txt" <<'PY'
from pathlib import Path
import sys

source = Path(sys.argv[1])
dest = Path(sys.argv[2])

package_prefixes = (
    "Packages/WhoopProtocol/",
    "Packages/WhoopStore/",
    "Packages/StrandAnalytics/",
    "Packages/StrandImport/",
)
app_prefixes = (
    "Strand/BLE/",
    "Strand/Collect/",
    "Strand/Data/",
    "Strand/System/",
    "StrandiOS/Health/",
    "StrandiOS/System/",
)
app_exact = {
    "Strand/App/AppModel.swift",
    "Strand/App/GpsWorkoutRecorder.swift",
    "StrandiOS/App/StrandiOSApp.swift",
    "StrandiOS/Widgets/LiveActivityController.swift",
    "StrandiOS/Widgets/WidgetPublish.swift",
    "StrandiOSShared/LiveActivityAttributes.swift",
    "StrandiOSShared/WidgetSnapshot.swift",
    ".github/workflows/swift-packages.yml",
    ".github/workflows/app-build.yml",
}
test_keywords = (
    "Alarm", "Backfill", "Battery", "Clock", "Database", "Health", "Hrv", "HRV",
    "Import", "Migration", "Power", "Raw", "Rr", "RR", "Sleep", "Store", "Sync",
    "Workout", "Whoop",
)
exclude_exact = {
    "Packages/WhoopStore/Sources/WhoopStore/Database.swift",
    "Packages/WhoopStore/Tests/WhoopStoreTests/MigrationTests.swift",
    "Strand/Collect/StorePaths.swift",
    "Strand/Data/AppleDemoSeeder.swift",
    "Strand/System/AppChangelog.swift",
    "Strand/System/UpdateChecker.swift",
    "project.yml",
    "altstore-source.json",
}
exclude_parts = (
    "/Oura", "/Polar", "/Huami", "/Garmin", "/Xiaomi",
    "Packages/StrandDesign/", "Packages/OuraProtocol/",
    "/Localizable.xcstrings",
)

selected = []
for raw in source.read_text().splitlines():
    path = raw.strip()
    if not path or path in exclude_exact or any(x in path for x in exclude_parts):
        continue

    include = path.startswith(package_prefixes) or path.startswith(app_prefixes) or path in app_exact

    if path.startswith(("StrandTests/", "StrandiOSTests/")):
        include = any(key in Path(path).name for key in test_keywords)

    if path.startswith((
        "Strand/Screens/", "Packages/StrandDesign/", "NOOPWatch",
        "StrandiOSWidgets/", "android/", "Strand/Liquid/", "Strand.xcodeproj/",
    )):
        include = False

    if include:
        selected.append(path)

selected = sorted(set(selected))
if not selected:
    raise SystemExit("allowlist resolved to zero paths")
dest.write_text("\n".join(selected) + "\n")
print(f"selected {len(selected)} upstream backend paths")
PY

PATCH_PATHS=()
while IFS= read -r path; do
  PATCH_PATHS+=("$path")
done < "$tmp/patch_paths.txt"

git diff --binary --full-index "$COMMON_BASE" "$UPSTREAM_STABLE" -- \
  "${PATCH_PATHS[@]}" > "$tmp/stable_backend.patch"
[[ -s "$tmp/stable_backend.patch" ]] || die "stable backend patch is empty"

if ! git apply --3way --index "$tmp/stable_backend.patch"; then
  printf '\nThree-way conflicts:\n' >&2
  git diff --name-only --diff-filter=U >&2 || true
  exit 24
fi

git show --format= --binary "$R22_HOTFIX" --   Packages/WhoopProtocol/Sources/WhoopProtocol/Whoop5Config.swift   Packages/WhoopProtocol/Tests/WhoopProtocolTests/Whoop5ConfigTests.swift |
  git apply --3way --index

git show --format= --binary "$WORKOUT_HOTFIX" --   Strand/Data/Repository.swift   StrandTests/WorkoutHrDeviceKeyTests.swift |
  git apply --3way --index

python3 <<'PY'
from pathlib import Path
import re

def read(path):
    return Path(path).read_text()

def write(path, value):
    Path(path).write_text(value)

def replace_once(path, old, new):
    text = read(path)
    if new in text:
        return
    count = text.count(old)
    if count != 1:
        raise SystemExit(f"{path}: expected one anchor, found {count}")
    write(path, text.replace(old, new, 1))

# Private migration numbering: v23/v24 are occupied by coaching.
db_path = "Packages/WhoopStore/Sources/WhoopStore/Database.swift"
db = read(db_path)
if 'registerMigration("v26-rr-seq")' not in db:
    anchor = "        return migrator\n"
    if db.count(anchor) != 1:
        raise SystemExit(f"{db_path}: return-migrator anchor changed")
    migration_block = r'''
        // Private v25 = upstream v23: raw WHOOP 4.0 SpO2 ADC cache.
        migrator.registerMigration("v25-daily-spo2-raw") { db in
            try db.alter(table: "dailyMetric") { t in
                t.add(column: "spo2Red", .integer)
                t.add(column: "spo2Ir", .integer)
            }
        }

        // Private v26 = upstream v24 (#163): equal R-R beat preservation.
        migrator.registerMigration("v26-rr-seq") { db in
            try db.create(table: "rrInterval_new") { t in
                t.column("deviceId", .text).notNull()
                t.column("ts", .integer).notNull()
                t.column("rrMs", .integer).notNull()
                t.column("seq", .integer).notNull().defaults(to: 0)
                t.column("synced", .integer).notNull().defaults(to: 0)
                t.primaryKey(["deviceId", "ts", "rrMs", "seq"])
            }
            try db.execute(sql: """
                INSERT INTO rrInterval_new (deviceId, ts, rrMs, seq, synced)
                SELECT deviceId, ts, rrMs, 0, synced FROM rrInterval
                """)
            try db.execute(sql: "DROP TABLE rrInterval")
            try db.execute(sql: "ALTER TABLE rrInterval_new RENAME TO rrInterval")
        }

        // Private v27 = upstream v26: percentage-to-fraction heal.
        migrator.registerMigration("v27-efficiency-heal") { db in
            try db.execute(sql: """
                UPDATE sleepSession
                SET efficiency = efficiency / 100.0
                WHERE efficiency > 1.5
                """)
            try db.execute(sql: """
                UPDATE dailyMetric
                SET efficiency = efficiency / 100.0
                WHERE efficiency > 1.5
                """)
        }

        // Private v28 = upstream v27 (#156): durable v26 PPG waveform.
        migrator.registerMigration("v28-ppg-waveform") { db in
            try db.create(table: "ppgWaveformSample") { t in
                t.column("deviceId", .text).notNull()
                t.column("ts", .integer).notNull()
                t.column("samples", .blob).notNull()
                t.primaryKey(["deviceId", "ts"])
            }
        }

'''
    db = db.replace(anchor, migration_block + anchor, 1)
    write(db_path, db)

migration_tests = r'''import XCTest
import GRDB
import WhoopProtocol
@testable import WhoopStore

final class MigrationTests: XCTestCase {
    func testInMemoryRunsMigrations() async throws {
        let store = try await WhoopStore.inMemory()
        let tables = try await store.tableNames()
        for table in [
            "device", "hrSample", "rrInterval", "event", "battery", "rawBatch",
            "coachingBehaviorSet", "coachingBehaviorMembership",
            "coachingStack", "coachingStackItem", "coachingStackUse",
            "ppgWaveformSample",
        ] {
            XCTAssertTrue(tables.contains(table), "missing table \(table)")
        }
    }

    func testFileInitRunsMigrations() async throws {
        let path = NSTemporaryDirectory() + "whoopstore-\(UUID().uuidString).sqlite"
        defer {
            for suffix in ["", "-wal", "-shm"] {
                try? FileManager.default.removeItem(atPath: path + suffix)
            }
        }
        let store = try await WhoopStore(path: path)
        let tables = try await store.tableNames()
        XCTAssertTrue(tables.contains("hrSample"))
        XCTAssertTrue(FileManager.default.fileExists(atPath: path))
    }

    func testHrSamplePrimaryKeyIsDeviceIdTs() async throws {
        let store = try await WhoopStore.inMemory()
        let columns = try await store.primaryKeyColumns("hrSample")
        XCTAssertEqual(columns, ["deviceId", "ts"])
    }

    func testRrIntervalPrimaryKeyIncludesSeq() async throws {
        let store = try await WhoopStore.inMemory()
        let columns = try await store.primaryKeyColumns("rrInterval")
        XCTAssertEqual(columns, ["deviceId", "ts", "rrMs", "seq"])
    }

    func testV26AddsSeqColumnToRrInterval() async throws {
        let store = try await WhoopStore.inMemory()
        let columns = try await store.columnNamesForTest(table: "rrInterval")
        XCTAssertTrue(columns.contains("seq"))
    }

    func testV26KeepsEqualSameSecondBeats() async throws {
        let store = try await WhoopStore.inMemory()
        try await store.upsertDevice(id: "dev1", mac: nil, name: nil)
        let inserted = try await store.insert(
            Streams(rr: [
                RRInterval(ts: 100, rrMs: 812),
                RRInterval(ts: 100, rrMs: 812),
            ]),
            deviceId: "dev1")
        XCTAssertEqual(inserted.rr, 2)

        let rows = try await store.rrIntervals(
            deviceId: "dev1", from: 0, to: 1_000, limit: 100)
        XCTAssertEqual(rows.count, 2)
        XCTAssertTrue(rows.allSatisfy { $0.ts == 100 && $0.rrMs == 812 })
    }

    func testV26DistinctSameSecondBeatsRemainIdempotent() async throws {
        let store = try await WhoopStore.inMemory()
        try await store.upsertDevice(id: "dev1", mac: nil, name: nil)
        let batch = Streams(rr: [
            RRInterval(ts: 100, rrMs: 602),
            RRInterval(ts: 100, rrMs: 613),
            RRInterval(ts: 101, rrMs: 602),
        ])

        let first = try await store.insert(batch, deviceId: "dev1")
        let second = try await store.insert(batch, deviceId: "dev1")
        XCTAssertEqual(first.rr, 3)
        XCTAssertEqual(second.rr, 0)
    }

    func testV5AddsSyncedColumnToDecodedTables() async throws {
        let store = try await WhoopStore.inMemory()
        for table in [
            "hrSample", "rrInterval", "event", "battery",
            "spo2Sample", "skinTempSample", "respSample", "gravitySample",
        ] {
            let columns = try await store.columnNamesForTest(table: table)
            XCTAssertTrue(columns.contains("synced"), "\(table) missing synced column")
        }
        XCTAssertEqual(WhoopStoreInfo.schemaVersion, 18)
    }

    func testV13AddsUserEditedColumnToSleepSession() async throws {
        let store = try await WhoopStore.inMemory()
        let columns = try await store.columnNamesForTest(table: "sleepSession")
        XCTAssertTrue(columns.contains("userEdited"))
    }

    func testV14AddsStartTsAdjustedColumnToSleepSession() async throws {
        let store = try await WhoopStore.inMemory()
        let columns = try await store.columnNamesForTest(table: "sleepSession")
        XCTAssertTrue(columns.contains("startTsAdjusted"))
    }

    func testV16AddsPeripheralIdColumnToPairedDevice() async throws {
        let store = try await WhoopStore.inMemory()
        let columns = try await store.columnNamesForTest(table: "pairedDevice")
        XCTAssertTrue(columns.contains("peripheralId"))
    }

    func testPrivateCoachingMigrationsRemainPresent() async throws {
        let store = try await WhoopStore.inMemory()
        let tables = try await store.tableNames()
        for table in [
            "coachingBehaviorSet", "coachingBehaviorMembership",
            "coachingStack", "coachingStackItem", "coachingStackUse",
        ] {
            XCTAssertTrue(tables.contains(table), "private migration lost table \(table)")
        }
    }

    func testV25AddsRawSpo2Columns() async throws {
        let store = try await WhoopStore.inMemory()
        let columns = try await store.columnNamesForTest(table: "dailyMetric")
        XCTAssertTrue(columns.contains("spo2Red"))
        XCTAssertTrue(columns.contains("spo2Ir"))
    }

    func testV27HealsEfficiencyPercentToFraction() async throws {
        let dbQueue = try DatabaseQueue()
        try WhoopStore.makeMigrator().migrate(dbQueue, upTo: "v26-rr-seq")
        try await dbQueue.write { db in
            try db.execute(sql: """
                INSERT INTO sleepSession (deviceId, startTs, endTs, efficiency)
                VALUES ('my-whoop', 100, 200, 90)
                """)
            try db.execute(sql: """
                INSERT INTO sleepSession (deviceId, startTs, endTs, efficiency)
                VALUES ('my-whoop', 300, 400, 0.90)
                """)
            try db.execute(sql: """
                INSERT INTO dailyMetric (deviceId, day, efficiency)
                VALUES ('my-whoop', '2026-01-01', 90)
                """)
            try db.execute(sql: """
                INSERT INTO dailyMetric (deviceId, day, efficiency)
                VALUES ('my-whoop', '2026-01-02', 0.90)
                """)
        }

        try WhoopStore.makeMigrator().migrate(dbQueue)

        try await dbQueue.read { db in
            XCTAssertEqual(
                try Double.fetchOne(
                    db, sql: "SELECT efficiency FROM sleepSession WHERE startTs = 100"),
                0.90)
            XCTAssertEqual(
                try Double.fetchOne(
                    db, sql: "SELECT efficiency FROM sleepSession WHERE startTs = 300"),
                0.90)
            XCTAssertEqual(
                try Double.fetchOne(
                    db, sql: "SELECT efficiency FROM dailyMetric WHERE day = '2026-01-01'"),
                0.90)
            XCTAssertEqual(
                try Double.fetchOne(
                    db, sql: "SELECT efficiency FROM dailyMetric WHERE day = '2026-01-02'"),
                0.90)
        }
    }

    func testV28CreatesPpgWaveformTable() async throws {
        let store = try await WhoopStore.inMemory()
        let tables = try await store.tableNames()
        let primaryKey = try await store.primaryKeyColumns("ppgWaveformSample")
        let columns = try await store.columnNamesForTest(table: "ppgWaveformSample")

        XCTAssertTrue(tables.contains("ppgWaveformSample"))
        XCTAssertEqual(primaryKey, ["deviceId", "ts"])
        XCTAssertTrue(columns.contains("samples"))
    }
}
'''
write("Packages/WhoopStore/Tests/WhoopStoreTests/MigrationTests.swift", migration_tests)

replace_once(
    "Strand/Screens/TodayView.swift",
    "        ScreenScaffold(title: scaffoldTitle, onRefresh: { await repo.refresh() },\n",
    """        ScreenScaffold(
            title: scaffoldTitle,
            onRefresh: {
                model.ble.syncNow()
                await repo.refresh()
            },
""")

settings_path = "Strand/Screens/SettingsView.swift"
settings = read(settings_path)
vars_anchor = (
    "    @AppStorage(PuffinExperiment.continuousHrvOvernightOnlyKey) "
    "private var continuousHrvOvernightOnly = false\n"
)
vars_block = vars_anchor + r'''
    /// Strap-battery-adaptive collection policy (#477). Default off.
    @AppStorage(PuffinExperiment.powerSavingKey)
    private var powerSavingEnabled = false
    @AppStorage(PuffinExperiment.powerSavingBatteryPctKey)
    private var powerSavingPct = 20
    /// Stored inverted so an unset key means the recommended pause is enabled.
    @AppStorage(PuffinExperiment.pauseHrvDisabledKey)
    private var pauseHrvDisabled = false
'''
if "private var powerSavingEnabled" not in settings:
    if settings.count(vars_anchor) != 1:
        raise SystemExit(f"{settings_path}: power variable anchor changed")
    settings = settings.replace(vars_anchor, vars_block, 1)

stack_old = "                    strapCard\n                    featuresCard\n"
stack_new = "                    strapCard\n                    powerSavingCard\n                    featuresCard\n"
if "                    powerSavingCard\n" not in settings:
    if settings.count(stack_old) != 1:
        raise SystemExit(f"{settings_path}: settings stack anchor changed")
    settings = settings.replace(stack_old, stack_new, 1)

power_card = r'''
    // MARK: - Strap power saving (#477)

    private var powerSavingCard: some View {
        SettingsSection(
            icon: "battery.25",
            title: "Power saving",
            blurb: "Ease the load on your strap when its battery is running low. The strap keeps banking data on its own, so nothing is lost — NOOP just talks to it less often to help it last until you can charge it."
        ) {
            VStack(alignment: .leading, spacing: 16) {
                Toggle(isOn: $powerSavingEnabled) {
                    Text("Power saving mode")
                        .font(StrandFont.subhead)
                        .foregroundStyle(StrandPalette.textPrimary)
                }
                .toggleStyle(.switch)
                .tint(StrandPalette.accent)
                .onChangeCompat(of: powerSavingEnabled) { _ in
                    model.applyPowerSaving()
                }

                Text("Slows background strap-sync from every 15 minutes to every 45 minutes while your strap's battery is low. The strap keeps banking data, so the next sync simply retrieves a larger batch.")
                    .font(StrandFont.caption)
                    .foregroundStyle(StrandPalette.textTertiary)
                    .fixedSize(horizontal: false, vertical: true)

                if powerSavingEnabled {
                    Divider().overlay(StrandPalette.hairline)
                    HStack {
                        Text("Kick in at (strap battery)")
                            .font(StrandFont.subhead)
                            .foregroundStyle(StrandPalette.textPrimary)
                        Spacer()
                        Text(verbatim: "\(powerSavingPct)%")
                            .font(StrandFont.subhead)
                            .foregroundStyle(StrandPalette.accent)
                    }
                    Slider(
                        value: Binding(
                            get: { Double(powerSavingPct) },
                            set: { powerSavingPct = Int($0) }),
                        in: 10...30,
                        step: 5,
                        onEditingChanged: { editing in
                            if !editing { model.applyPowerSaving() }
                        })
                    .tint(StrandPalette.accent)

                    Divider().overlay(StrandPalette.hairline)
                    Toggle(
                        isOn: Binding(
                            get: { !pauseHrvDisabled },
                            set: { pauseHrvDisabled = !$0 })) {
                        Text("Pause HRV capture")
                            .font(StrandFont.subhead)
                            .foregroundStyle(StrandPalette.textPrimary)
                    }
                    .toggleStyle(.switch)
                    .tint(StrandPalette.accent)
                    .onChangeCompat(of: pauseHrvDisabled) { _ in
                        model.applyPowerSaving()
                    }

                    Text("While the strap is low and discharging, release the always-on background HRV stream. Opening a Live screen can still request live heart rate, and background HRV re-arms after the strap is charged.")
                        .font(StrandFont.caption)
                        .foregroundStyle(StrandPalette.textTertiary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }

'''
mark_anchor = "    // MARK: - Paper overview\n"
if "private var powerSavingCard: some View" not in settings:
    if settings.count(mark_anchor) != 1:
        raise SystemExit(f"{settings_path}: Paper overview anchor changed")
    settings = settings.replace(mark_anchor, power_card + mark_anchor, 1)
write(settings_path, settings)

project_path = "project.yml"
project = read(project_path)
project = project.replace('MARKETING_VERSION: "8.2.2"', 'MARKETING_VERSION: "9.0.1"', 1)
project = project.replace('CURRENT_PROJECT_VERSION: "172"', 'CURRENT_PROJECT_VERSION: "204"', 1)
for required in (
    'DEVELOPMENT_TEAM: "479HYY24G2"',
    'APP_GROUP_ID: group.com.eastonplace.noop',
    'PRODUCT_BUNDLE_IDENTIFIER: com.eastonplace.noop',
    'PRODUCT_BUNDLE_IDENTIFIER: com.eastonplace.noop.widgets',
):
    if required not in project:
        raise SystemExit(f"{project_path}: private identity lost: {required}")
write(project_path, project)

changelog_path = Path("Strand/System/AppChangelog.swift")
if changelog_path.exists():
    changelog = changelog_path.read_text()
    changelog = re.sub(
        r'(static let currentVersion\s*=\s*")[^"]+(")',
        r'\g<1>9.0.1\2',
        changelog,
        count=1)
    changelog_path.write_text(changelog)
PY

git add -A
[[ -z "$(git diff --name-only --diff-filter=U)" ]] ||
  die "unresolved merge conflicts remain"

# Reject out-of-scope staged files without relying on unsupported regex lookahead.
while IFS= read -r path; do
  case "$path" in
    android/*|Packages/StrandDesign/*|Strand/Liquid/*|StrandiOSWidgets/*)
      die "forbidden file staged: $path" ;;
    Strand/Screens/*)
      [[ "$path" == "Strand/Screens/TodayView.swift" ||
         "$path" == "Strand/Screens/SettingsView.swift" ]] ||
        die "unexpected screen staged: $path" ;;
  esac
  case "$path" in
    *Oura*|*Polar*|*Huami*|*Garmin*|*Xiaomi*)
      die "out-of-scope device/cloud file staged: $path" ;;
  esac
done < <(git diff --cached --name-only)

grep -q 'MARKETING_VERSION: "9.0.1"' project.yml
grep -q 'CURRENT_PROJECT_VERSION: "204"' project.yml
grep -q 'DEVELOPMENT_TEAM: "479HYY24G2"' project.yml
grep -q 'APP_GROUP_ID: group.com.eastonplace.noop' project.yml
grep -q 'PRODUCT_BUNDLE_IDENTIFIER: com.eastonplace.noop$' project.yml
grep -q 'PRODUCT_BUNDLE_IDENTIFIER: com.eastonplace.noop.widgets$' project.yml
grep -q 'v26-rr-seq' Packages/WhoopStore/Sources/WhoopStore/Database.swift
grep -q 'ORDER BY ts ASC, rrMs ASC, seq ASC' Packages/WhoopStore/Sources/WhoopStore/Reads.swift
grep -q 'cleanRRGapAware' Packages/StrandAnalytics/Sources/StrandAnalytics/HRVAnalyzer.swift
grep -q 'Flag("enable_sig12", 0x31)' Packages/WhoopProtocol/Sources/WhoopProtocol/Whoop5Config.swift
grep -q 'model.ble.syncNow()' Strand/Screens/TodayView.swift
grep -q 'workoutHrDeviceId' Strand/Data/Repository.swift

for package in WhoopProtocol WhoopStore StrandAnalytics StrandImport; do
  (cd "Packages/$package" && swift test)
done

xcodegen generate

xcodebuild   -project Strand.xcodeproj   -scheme NOOPiOS   -destination 'generic/platform=iOS Simulator'   CODE_SIGNING_ALLOWED=NO   build

xcodebuild   -project Strand.xcodeproj   -scheme Strand   -destination 'platform=macOS'   CODE_SIGNING_ALLOWED=NO   build

sim_id="$(
  xcrun simctl list devices available -j |
    python3 -c '
import json, sys
data = json.load(sys.stdin)
for runtime in data.get("devices", {}).values():
    for device in runtime:
        if device.get("isAvailable") and device.get("name", "").startswith("iPhone"):
            print(device["udid"])
            raise SystemExit
'
)"
[[ -n "$sim_id" ]] || die "no available iPhone simulator found"

xcodebuild   -project Strand.xcodeproj   -scheme NOOPiOS   -destination "platform=iOS Simulator,id=$sim_id"   CODE_SIGNING_ALLOWED=NO   test

git diff --cached --check
printf '\nImplementation staged on %s\n' "$WORK_BRANCH"
printf 'Target:   %s\n' "$TARGET_SHA"
printf 'Stable:   %s\n' "$UPSTREAM_STABLE"
printf 'Hotfixes: %s %s\n' "$R22_HOTFIX" "$WORKOUT_HOTFIX"
git diff --cached --stat
git status --short
```

### Script result

A successful run leaves the source changes staged but uncommitted. Codex can inspect the final diff, complete physical-device QA, and create the commit/PR with the actual verification record. The script does not publish a release or rewrite `altstore-source.json`, because no private IPA URL exists yet.

---

## 5. Exact private-fork code contracts

The stable import supplies the complete implementation. The following blocks are the canonical final behavior for conflict resolution.


### 5.1 R-R persistence: schema, write key, read order

#### Target migration

```swift
migrator.registerMigration("v26-rr-seq") { db in
    try db.create(table: "rrInterval_new") { t in
        t.column("deviceId", .text).notNull()
        t.column("ts", .integer).notNull()
        t.column("rrMs", .integer).notNull()
        t.column("seq", .integer).notNull().defaults(to: 0)
        t.column("synced", .integer).notNull().defaults(to: 0)
        t.primaryKey(["deviceId", "ts", "rrMs", "seq"])
    }
    try db.execute(sql: """
        INSERT INTO rrInterval_new (deviceId, ts, rrMs, seq, synced)
        SELECT deviceId, ts, rrMs, 0, synced FROM rrInterval
        """)
    try db.execute(sql: "DROP TABLE rrInterval")
    try db.execute(sql: "ALTER TABLE rrInterval_new RENAME TO rrInterval")
}
```

The rebuild is lossless relative to the old schema: every old row was already unique on `(deviceId, ts, rrMs)`, so assigning `seq = 0` preserves every existing row. Already-dropped equal beats cannot be reconstructed; the fix is forward-correct.

#### `StreamStore.swift`

```swift
if !streams.rr.isEmpty {
    let stmt = try db.cachedStatement(sql: """
        INSERT INTO rrInterval (deviceId, ts, rrMs, seq) VALUES (?, ?, ?, ?)
        ON CONFLICT(deviceId, ts, rrMs, seq) DO NOTHING
        """)

    // Number equal (timestamp, value) occurrences deterministically within
    // the decoded batch. Replaying the same batch generates the same keys.
    var seqByTsRr: [Int: [Int: Int]] = [:]

    for interval in streams.rr {
        let seq = seqByTsRr[interval.ts]?[interval.rrMs] ?? 0
        seqByTsRr[interval.ts, default: [:]][interval.rrMs] = seq + 1
        try stmt.execute(arguments: [
            deviceId,
            interval.ts,
            interval.rrMs,
            seq,
        ])
        rr += db.changesCount
    }
}
```

#### `Reads.swift`

```swift
public func rrIntervals(
    deviceId: String,
    from: Int,
    to: Int,
    limit: Int
) async throws -> [RRInterval] {
    try syncRead { db in
        try Row.fetchAll(db, sql: """
            SELECT ts, rrMs FROM rrInterval
            WHERE deviceId = ? AND ts >= ? AND ts <= ?
            ORDER BY ts ASC, rrMs ASC, seq ASC LIMIT ?
            """, arguments: [deviceId, from, to, limit])
            .map { RRInterval(ts: $0["ts"], rrMs: $0["rrMs"]) }
    }
}
```

### 5.2 Gap-aware HRV

The cleaned values remain byte-identical to the old `cleanRR`; only successive-difference metrics learn where a beat was removed.

```swift
public struct CleanSeries: Equatable, Sendable {
    public let nn: [Double]
    public let contiguous: [Bool]
}

public static func cleanRRGapAware(_ rr: [Double]) -> CleanSeries {
    var rangedIndexes: [Int] = []
    var rangedValues: [Double] = []
    rangedIndexes.reserveCapacity(rr.count)
    rangedValues.reserveCapacity(rr.count)

    for index in rr.indices {
        let value = rr[index]
        if value >= rrMinMs && value <= rrMaxMs {
            rangedIndexes.append(index)
            rangedValues.append(value)
        }
    }

    var keptOriginalIndexes: [Int] = []
    var keptValues: [Double] = []
    keptOriginalIndexes.reserveCapacity(rangedValues.count)
    keptValues.reserveCapacity(rangedValues.count)

    if rangedValues.count <= ectopicWindowRadius {
        for index in rangedValues.indices {
            keptOriginalIndexes.append(rangedIndexes[index])
            keptValues.append(rangedValues[index])
        }
    } else {
        for index in rangedValues.indices {
            let lower = max(0, index - ectopicWindowRadius)
            let upper = min(rangedValues.count - 1, index + ectopicWindowRadius)
            var neighbours: [Double] = []
            neighbours.reserveCapacity(upper - lower)

            for neighbourIndex in lower...upper where neighbourIndex != index {
                neighbours.append(rangedValues[neighbourIndex])
            }

            let keep: Bool
            if neighbours.count < 2 {
                keep = true
            } else {
                let localMedian = median(neighbours)
                keep = localMedian <= 0
                    ? true
                    : abs(rangedValues[index] - localMedian) / localMedian <= ectopicThreshold
            }

            if keep {
                keptOriginalIndexes.append(rangedIndexes[index])
                keptValues.append(rangedValues[index])
            }
        }
    }

    var contiguous: [Bool] = []
    contiguous.reserveCapacity(keptValues.count)
    for index in keptValues.indices {
        contiguous.append(
            index > 0 &&
            keptOriginalIndexes[index] == keptOriginalIndexes[index - 1] + 1)
    }

    return CleanSeries(nn: keptValues, contiguous: contiguous)
}

public static func rmssdGapAware(
    _ nn: [Double],
    _ contiguous: [Bool]
) -> Double? {
    precondition(nn.count == contiguous.count)

    var sumSquaredDifferences = 0.0
    var pairCount = 0

    for index in 1..<nn.count where contiguous[index] {
        let difference = nn[index] - nn[index - 1]
        sumSquaredDifferences += difference * difference
        pairCount += 1
    }

    return pairCount == 0
        ? nil
        : (sumSquaredDifferences / Double(pairCount)).squareRoot()
}

public static func pnn50GapAware(
    _ nn: [Double],
    _ contiguous: [Bool]
) -> Double? {
    precondition(nn.count == contiguous.count)

    var nn50 = 0
    var pairCount = 0

    for index in 1..<nn.count where contiguous[index] {
        if abs(nn[index] - nn[index - 1]) > 50 {
            nn50 += 1
        }
        pairCount += 1
    }

    return pairCount == 0
        ? nil
        : Double(nn50) / Double(pairCount) * 100
}
```

The analysis entry point must use it exactly as follows:

```swift
public static func analyze(
    rawRR: [Double],
    maxRejectedFraction: Double? = nil
) -> HRVResult {
    let nInput = rawRR.count
    let cleaned = cleanRRGapAware(rawRR)
    let clean = cleaned.nn

    guard clean.count >= minBeats else {
        return .empty(nInput: nInput)
    }

    if let maxRejectedFraction, nInput > 0 {
        let rejectedFraction = 1.0 - Double(clean.count) / Double(nInput)
        if rejectedFraction > maxRejectedFraction {
            return .empty(nInput: nInput)
        }
    }

    let rmssd = rmssdGapAware(cleaned.nn, cleaned.contiguous)
    let sdnn = sdnnRaw(clean)
    let mean = clean.reduce(0, +) / Double(clean.count)
    let pnn50 = pnn50GapAware(cleaned.nn, cleaned.contiguous)

    return HRVResult(
        rmssd: rmssd,
        sdnn: sdnn,
        meanNN: mean,
        pnn50: pnn50,
        nInput: nInput,
        nClean: clean.count)
}
```

#### Required HRV tests

```swift
func testRangeRejectedBeatDoesNotCreateSyntheticDelta() {
    let input = [800.0, 810.0, 2_500.0, 805.0, 815.0]
    let clean = HRVAnalyzer.cleanRRGapAware(input)

    XCTAssertEqual(clean.nn, [800, 810, 805, 815])
    XCTAssertEqual(clean.contiguous, [false, true, false, true])

    // Valid deltas are +10 and +10. The -5 delta across the removed beat is skipped.
    XCTAssertEqual(
        HRVAnalyzer.rmssdGapAware(clean.nn, clean.contiguous),
        10,
        accuracy: 0.0001)
}

func testEctopicRejectedBeatDoesNotCreateSyntheticPnn50Pair() {
    let input = [800.0, 805.0, 1_300.0, 810.0, 815.0, 820.0]
    let clean = HRVAnalyzer.cleanRRGapAware(input)

    XCTAssertFalse(clean.contiguous[2])
    XCTAssertEqual(
        HRVAnalyzer.pnn50GapAware(clean.nn, clean.contiguous),
        0,
        accuracy: 0.0001)
}

func testGapAwareEqualsRawWhenNothingWasRemoved() {
    let input = [800.0, 810.0, 790.0, 805.0, 815.0]
    let clean = HRVAnalyzer.cleanRRGapAware(input)

    XCTAssertEqual(
        HRVAnalyzer.rmssdGapAware(clean.nn, clean.contiguous),
        HRVAnalyzer.rmssdRaw(input))
}
```

### 5.3 WHOOP 5/MG R22 final flag sequence

Use the stable sequence plus the post-release correction. The last byte must be `0x31`, not the stable release's original `0x32`.

```swift
public static let enableR22Sequence: [Flag] = [
    Flag("enable_r22_packets", 0x32),
    Flag("enable_r22_v2_packets", 0x32),
    Flag("enable_r22_v3_packets", 0x32),
    Flag("enable_r22_v4_packets", 0x31),
    Flag("enable_r22_v5_packets", 0x32),
    Flag("enable_r22_v6_packets", 0x32),
    Flag("enable_r22_v8_packets", 0x32),
    Flag("make_hrfm_visible", 0x32),
    Flag("disable_pip_r26_packets", 0x32),
    Flag("wear_detect_bias", 0x32),
    Flag("hr_ch_switching", 0x32),
    Flag("ir_hw_switching", 0x32),
    Flag("enable_passive_strap_fit_gen5", 0x31),
    Flag("enable_sig11_during_sleep", 0x32),
    Flag("dorset_inhibit_wpt", 0x32),
    Flag("enable_sig12", 0x31),
]
```

Required assertions:

```swift
XCTAssertEqual(Whoop5Config.enableR22Sequence.count, 16)
XCTAssertEqual(Whoop5Config.enableR22Sequence.last?.name, "enable_sig12")
XCTAssertEqual(Whoop5Config.enableR22Sequence.last?.value, 0x31)
```

### 5.4 PPG waveform storage

`StreamStore.swift` must retain the compact little-endian packing helpers imported from upstream:

```swift
static func packPpgSamples(_ samples: [Int]) -> Data {
    var buffer = Data(capacity: samples.count * 2)
    for sample in samples {
        let value = Int16(truncatingIfNeeded: sample)
        buffer.append(UInt8(truncatingIfNeeded: value))
        buffer.append(UInt8(truncatingIfNeeded: value >> 8))
    }
    return buffer
}

static func unpackPpgSamples(_ data: Data) -> [Int] {
    let bytes = [UInt8](data)
    var result: [Int] = []
    result.reserveCapacity(bytes.count / 2)

    var index = 0
    while index + 1 < bytes.count {
        let raw = UInt16(bytes[index]) | (UInt16(bytes[index + 1]) << 8)
        result.append(Int(Int16(bitPattern: raw)))
        index += 2
    }

    return result
}
```

Malformed odd-byte data drops the trailing byte rather than crashing a read path.

### 5.5 Strap-battery power policy

`PuffinExperiment.swift` final keys:

```swift
static let powerSavingKey = "noopPowerSaving"
static let powerSavingBatteryPctKey = "noopPowerSavingBatteryPct"
static let pauseHrvDisabledKey = "noopPowerSavingPauseHrvDisabled"

static var powerSavingEnabled: Bool {
    UserDefaults.standard.bool(forKey: powerSavingKey)
}

static var powerSavingBatteryPct: Int {
    let value = UserDefaults.standard.integer(forKey: powerSavingBatteryPctKey)
    return value == 0 ? 20 : min(30, max(10, value))
}

static var pauseHrvOnPowerSaveEnabled: Bool {
    !UserDefaults.standard.bool(forKey: pauseHrvDisabledKey)
}
```

`AppModel.swift` final adapter:

```swift
func applyPowerSaving() {
    let enabled = PuffinExperiment.powerSavingEnabled
    let threshold = enabled ? PuffinExperiment.powerSavingBatteryPct : 0

    ble.setLowBatteryOffloadThrottle(threshold)
    ble.setPauseCaptureOnPowerSave(
        enabled && PuffinExperiment.pauseHrvOnPowerSaveEnabled,
        thresholdPct: PuffinExperiment.powerSavingBatteryPct)
}
```

It must run:

- once at the end of `AppModel.init`;
- on every bonded-state change;
- after any power-setting mutation.

The BLE policy is based on **strap battery**, only while discharging. Unknown battery and charging both fail open to normal sync/capture behavior.

### 5.6 Today pull-to-sync

The private Paper surface changes by one integration seam:

```swift
ScreenScaffold(
    title: scaffoldTitle,
    onRefresh: {
        model.ble.syncNow()
        await repo.refresh()
    },
    lazy: true,
    topBackground: nil,
    trailing: { todayHeaderStatus }
) {
    // Existing private Paper content remains unchanged.
}
```

`BLEManager.syncNow()` owns all readiness gates. The view must not duplicate checks for connected, bonded, command-ready, or already-backfilling state.

### 5.7 Multi-WHOOP workout reconciliation

Within `reconcileWorkoutHrWithTrace`, resolve the read key per workout row before creating the task:

```swift
let classification = WorkoutSource.classify(rows[index].source)
let wantsStrain =
    (classification == .manual || classification == .detected) &&
    rows[index].strain == nil

let hrDeviceId = Self.workoutHrDeviceId(
    source: rows[index].source,
    activeStrapId: deviceId)

group.addTask { [hrDeviceId] in
    let samples = (
        try? await store.hrSamples(
            deviceId: hrDeviceId,
            from: startTs,
            to: endTs,
            limit: 8_000)
    ) ?? []

    guard samples.count >= minSamples else { return nil }
    // Existing reduction/reconciliation continues.
}
```

Helper:

```swift
nonisolated static func workoutHrDeviceId(
    source: String,
    activeStrapId: String
) -> String {
    guard WorkoutSource.classify(source) == .detected else {
        return activeStrapId
    }

    return source.hasSuffix("-noop")
        ? String(source.dropLast(5))
        : source
}
```

Detected rows carry their computed strap source (`<raw-id>-noop`), so the suffix is removed. Manual/imported rows continue using the active strap because Swift's `WorkoutRow` read model does not carry a separate device ID.

### 5.8 Migration numbering in the private fork

Never paste the upstream migration names/numbers verbatim. The private database already owns `v23` and `v24`.

| Upstream stable migration | Private migration | Included? |
|---|---|---|
| `v23-daily-spo2-raw` | `v25-daily-spo2-raw` | Yes |
| `v24-rr-seq` | `v26-rr-seq` | Yes |
| `v25-oura-raw` | — | No; out of requested scope |
| `v26-efficiency-heal` | `v27-efficiency-heal` | Yes |
| `v27-ppg-waveform` | `v28-ppg-waveform` | Yes |

### 5.9 Versioning

Final private values:

```yaml
MARKETING_VERSION: "9.0.1"
CURRENT_PROJECT_VERSION: "204"
DEVELOPMENT_TEAM: "479HYY24G2"
APP_GROUP_ID: group.com.eastonplace.noop
```

Build `204` is intentional: upstream stable is build `203`; this private integration additionally contains two audited post-release Apple fixes.

Do not update `altstore-source.json` until an actual private `9.0.1` IPA has been built, checksummed, uploaded, and assigned a stable download URL.

---

## 6. Conflict-resolution matrix

The script exits with code `24` if Git proves both repositories changed the same hunk. Resolve only according to this matrix.

| File | Resolution |
|---|---|
| `Packages/WhoopStore/.../Database.swift` | Keep private file and append target migrations `v25`–`v28` exactly. Never take upstream numbering. |
| `.../MigrationTests.swift` | Use the complete target-specific test file written by the script. |
| `Strand/Collect/StorePaths.swift` | Keep private file entirely. |
| `project.yml` | Keep private file; change only version/build. |
| `TodayView.swift` | Keep private Paper implementation; add only `model.ble.syncNow()` to refresh. |
| `SettingsView.swift` | Keep private Paper implementation; add only the power-saving state/card. |
| `BLEManager.swift` | Preserve private Test Centre and standard-HR hooks. Take upstream sync state, post-bond battery retry, clock/alarm readiness, raw WHOOP 5 routing, and power-policy APIs. |
| `LiveState.swift` | Union the properties. Preserve private published diagnostics; take upstream command-ready/sync/battery/raw state. Never remove a private callback. |
| `Repository.swift` | Preserve private Paper/AppleDaily/zone APIs. Take upstream identity, import, export, sleep, HealthKit, workout, and performance logic. Apply `6a285e2` last. |
| `AppModel.swift` | Preserve private subsystems and sinks. Take upstream launch/sync/HealthKit/battery behavior and `applyPowerSaving`. |
| `IntelligenceEngine.swift` | Preserve private diagnostic sink and coaching hooks. Take upstream rescore, baseline, sleep, and cache correctness. |
| `HRZones.swift` | Preserve private computed-zone helper additions; take upstream numerical fixes. |
| `WeeklyDigest.swift` | Preserve private presentation wording only where it does not alter period selection or denominator logic. |
| `MetricCatalog.swift` | Preserve private display labels/order. Take upstream canonical metric keys, compatibility/source rules, and units. |
| `Units.swift` | Preserve private visible formatting; take upstream storage-unit normalization and conversion correctness. |
| `HealthKitBridge.swift` | Preserve private navigation/presentation callbacks. Take upstream authorization handling, idempotent writeback, source filtering, bounded rewrite, and workout metadata. |
| `StrandiOSApp.swift` | Preserve the private root and gates. Take upstream lifecycle, background sync, HealthKit, widget, and scheduled-export hooks only. |
| `GpsWorkoutRecorder.swift` | Preserve private Test Centre diagnostics. Take upstream route lifecycle/correctness fixes. |

### Conflict rejection rules

Reject any resolution that:

- deletes `CoachingStore` or its tables;
- reintroduces Android;
- changes private bundle/App Group/team identifiers;
- replaces Paper screens or `StrandDesign`;
- changes the R-R migration back to upstream `v24`;
- leaves `enable_sig12` at `0x32`;
- computes RMSSD with `rmssdRaw(cleanRR(...))`;
- reads detected workout HR from one global active ID;
- calls repository refresh without requesting sync on a pull gesture;
- makes power saving depend on iPhone Low Power Mode rather than the strap battery.

---

## 7. Backend import ledger

The path-filtered stable patch is the implementation for the remaining released fixes. This ledger explains what each imported area must contain after the merge.

### `Packages/WhoopProtocol`

Bring over:

- bad-clock classification and data-range diagnostics;
- WHOOP 4.0/5.0/MG historical layout additions;
- v18/v19/v21/v26 record coverage;
- v21 accelerometer/gyroscope interpretation correction;
- 100 Hz six-axis raw IMU decoding;
- raw v26 PPG waveform extraction;
- R22 config sequence and payload tests;
- event/console stream decoding and malformed-frame hardening;
- alarm/restart/readback payload modeling;
- typed absence semantics: no fabricated zero samples.

### `Packages/WhoopStore`

Bring over, while retaining private migrations:

- deterministic R-R sequence writes/reads;
- raw PPG waveform packing and store;
- sleep-state, motion, step activity-class, and raw signal persistence;
- range-efficient reads and HR/PPG fallback;
- atomic journal range replacement;
- backup settings and store safety;
- device-era/baseline storage;
- schema and concurrency tests.

### `Packages/StrandAnalytics`

Bring over:

- gap-aware HRV and integrity diagnostics;
- deep-sleep HRV readiness/window behavior;
- baseline re-fold without unnecessary calibration reset;
- per-device baseline eras;
- sleep stage clamps, onset cleanup, motion corroboration, median-HR confirmation, split-night aggregation, confidence;
- recovery-driver additions;
- battery estimator/predictive alerts;
- automatic workout warm-up and dedupe improvements;
- raw IMU feature extraction as instrumentation/advisory data;
- memoization and large-history performance fixes.

### `Packages/StrandImport`

Bring over:

- deterministic fixed-width dedupe;
- streaming/total-byte import budgets and explicit truncation;
- source-aware step aggregation;
- per-workout HR, active energy, distance, and FIT-step fallback;
- atomic WHOOP journal replacement;
- pure HealthKit writeback interval normalization;
- line-ending and corrupt-row hardening.

### `Strand/BLE` and `Strand/Collect`

Bring over:

- one safe `syncNow` gate used by foreground/manual/pull sync;
- connected/bonded/command-ready distinction;
- command notification readiness before alarms/readback;
- restart/reconnect path;
- refused-bond and post-bond timeout states;
- post-bond WHOOP 5/MG battery retry;
- future-clock sync blocking/backoff;
- empty-tail backfill completion;
- adaptive 15/45-minute offload cadence;
- low-battery background-HRV release and automatic re-arm;
- raw IMU/PPG/event/console routing;
- active recording device identity.

### `Strand/Data` and iPhone-only bridges

Bring over:

- serialized store access where not already equivalent;
- WAL-safe backup restore and retention/scheduling;
- active/canonical/recording device resolution;
- active-strapped export rather than empty canonical-only export;
- Apple Health idempotent writeback;
- workout-level metadata and source arbitration;
- source-aware FIT steps without double counting;
- near-linear workout dedupe;
- scheduled export dedupe;
- widget/live-activity publication after background backfill;
- diagnostic export with clock, range, R-R, and sync state.

---

## 8. Release-wave coverage and implementation disposition


The table below records the final-state disposition for every released wave after the shared 8.2.2 ancestor. “Imported” means the immutable `COMMON_BASE..UPSTREAM_STABLE` patch supplies the exact released source. “Adapted” means the stable implementation is imported but a private-fork adapter in Section 4 preserves Paper UI, identifiers, or migration ownership. “Superseded” means a later release changed the behavior and only the later behavior is accepted.

| Release | iPhone/shared backend behavior carried forward | Final disposition in this package |
|---|---|---|
| **8.3.0** | Scheduled local backups, bounded retention, persisted schedule/destination settings, atomic creation, release workflow hardening. | **Imported.** Backup and scheduling code comes from stable `Strand/Data`, `Strand/System`, and the two allowlisted Apple workflows. Upstream visual controls are not copied. `altstore-source.json` remains private and unchanged until a private IPA actually exists. |
| **8.3.1** | WAL-safe restore, configurable backup time, richer local debug export, backup validation. | **Imported.** Restore must accept a valid database whose header reflects WAL mode, must stage/validate before replacing the live store, and must preserve the live store on corruption. |
| **8.3.2** | Imported FIT/GPX/TCX activities in Workouts; canonical-plus-active device reads after re-pair; source-aware dedupe and debug summaries. | **Imported with identity preservation.** Upstream bundle identifiers are rejected. The private application group, team, app bundle, widget bundle, and Paper Workouts presentation remain. |
| **8.3.3** | Alarm lifecycle distinguishes queued, transmitted, acknowledged, and read back; diagnostic payload includes requested/readback values and connection readiness. | **Imported.** No screen replacement. Private UI may display the state, but it may not report “installed” merely because a command entered the queue. |
| **8.3.4** | Empty auto-continue tail is treated as caught up after valid prior pages rather than “never banked” or “charge to 100%.” | **Imported.** Backfill completion semantics come from stable `Backfiller`, policy, and `LiveState`. |
| **8.5.0** | Raw WHOOP 4.0 SpO₂ red/IR cache, source-aware Apple Health steps, charging-aware battery alerts, corrected battery slope windows, total-byte import budgets, and nonvisual memoization/performance work. | **Imported + adapted.** Raw SpO₂ columns are private migration **v25**. Values remain raw ADC means, never a fabricated calibrated percentage. |
| **8.5.1** | Optional deep-sleep HRV window and trace, auto-workout onset warm-up, Fitness Age readiness/history gating. | **Imported, with final 8.6 behavior.** A window change re-scores and re-folds history; it does **not** force an established user through a new cold-start calibration. |
| **8.5.2** | WHOOP journal rows use sleep wake-day ownership; re-import atomically replaces only the imported date interval. | **Imported.** Re-import is idempotent, rows outside the interval survive, and a failed import rolls back the replacement transaction. |
| **8.6.0** | Equal same-second R-R preservation, gap-aware RMSSD/pNN50, R-R coverage/duplicate diagnostics, baseline re-fold, future-clock offload guard, and latest-workout identity corrections. | **Imported + adapted.** R-R schema is private migration **v26**; exact storage and analytics code is pinned in Sections 5.1–5.2. This is a release blocker. |
| **8.6.1** | Non-destructive Restart Strap flow, WHOOP 4.0/5/MG framing, 16th R22 flag, v18 `0x2F` decode/tail visibility, raw alarm response diagnostics, canonical model resolver. | **Imported + post-release correction.** The 16th flag is present and its final value is `0x31`, not the stable release’s superseded `0x32`. |
| **8.6.2** | Idempotent HealthKit writeback for sleep/HR/workouts/vitals, predictive battery warning, refused-bond state, serialized store opening/migration, imported ride HR fallback, stage clipping, pre-onset cleanup, median-HR confirmation, richer-source precedence, resume backfill, honest notification-permission behavior. | **Imported.** Existing private single-flight/store safety is retained where equivalent. Source-scoped HealthKit deletion and the bounded rewrite window are mandatory. |
| **8.7.0** | Shared sync phase/progress/blocker model, future-clock warning/remediation, RTC/date-range logging, alarm re-arm only after command-notification readiness, sparse-motion diagnostics. | **Imported, presentation adapted.** The private Paper surface consumes the model; upstream sync cards and styling remain excluded. |
| **9.0.0** | Strap-battery power policy; Recovery Index and Activity Balance drivers; provenance correction; calibration-count fix; sleep motion/wake corrections and split-night totals; 100 Hz six-axis WHOOP 5/MG IMU; raw v26 PPG; durable event/console capture; per-device baseline eras; active/canonical export; workout/import performance and metadata. | **Imported + adapted.** Power settings are inserted into private `SettingsView`; raw PPG table is private migration **v28**; Oura cloud, Gemini-on-Android, Android keep-alive, localization, and upstream visual redesign are excluded. |
| **9.0.1** | Safe pull-to-sync, post-bond WHOOP 5/MG battery retry, FIT-step fallback, duplicate resting-stress haptic removal, final v21 IMU-channel interpretation. | **Imported + adapted.** Private Today refresh calls `model.ble.syncNow()` before cache refresh. The BLE method remains the single safety gate, so disconnected/unbonded/busy pulls are harmless. |
| **Post-9.0.1 selected** | `enable_sig12 = 0x31`; workout HR reconciles using the recording strap for detected multi-WHOOP sessions. | **Imported from two exact commits only.** The other 14 commits between stable and current upstream `main` are outside scope. |

### Release-wave invariants

The following later behaviors override any earlier implementation encountered during conflict resolution:

1. **HRV window changes do not reset a healthy established baseline.** Re-score recent history and re-fold it.
2. **Power saving keys off the strap battery, not the iPhone battery or iOS Low Power Mode.** It is inactive while charging.
3. **`enable_sig12` is ASCII `'1'` (`0x31`).** The stable 9.0.1 value is superseded by the selected post-release hardware capture.
4. **A detected workout reads HR from its recording strap.** It may not silently fall back to a different currently active strap.
5. **Motion/PPG/band-state fields preserve absence.** Missing wire data stays `nil`/no row; it is never synthesized as zero.
6. **Pull-to-sync delegates to the existing safe BLE gate.** The view does not reproduce connection-state rules.
7. **Imported Apple Health data never loops back into Apple Health.** Writeback is source-scoped and idempotent.
8. **Private schema migrations are append-only.** Existing v23/v24 coaching migrations are never renamed, reordered, or rewritten.

---

## 9. Verification and QA matrix

The implementation script runs the deterministic automated checks available on a Mac. Codex must also complete the stateful database, HealthKit, and real-strap matrix below. A green package build alone is not evidence that CoreBluetooth behavior works.

### 9.1 Source and scope gates

Run from the integration branch after conflict resolution:

```bash
git diff --name-only --diff-filter=U
git diff --cached --check
git status --short

git diff --cached --name-only | grep -E '^(android/|Packages/StrandDesign/|Strand/Liquid/|StrandiOSWidgets/)' && exit 1 || true
git diff --cached --name-only | grep -E '^Strand/Screens/' | grep -Ev '^Strand/Screens/(TodayView|SettingsView)\.swift$' && exit 1 || true

grep -n 'MARKETING_VERSION: "9.0.1"' project.yml
grep -n 'CURRENT_PROJECT_VERSION: "204"' project.yml
grep -n 'DEVELOPMENT_TEAM: "479HYY24G2"' project.yml
grep -n 'APP_GROUP_ID: group.com.eastonplace.noop' project.yml
grep -n 'PRODUCT_BUNDLE_IDENTIFIER: com.eastonplace.noop$' project.yml
grep -n 'PRODUCT_BUNDLE_IDENTIFIER: com.eastonplace.noop.widgets$' project.yml
```

**Pass criteria**

- no unresolved paths;
- no whitespace errors;
- no forbidden platform/design files;
- private identifiers unchanged;
- only `TodayView.swift` and `SettingsView.swift` are touched under `Strand/Screens`;
- generated `Strand.xcodeproj` is not staged.

### 9.2 Swift package tests

```bash
for package in WhoopProtocol WhoopStore StrandAnalytics StrandImport; do
  (cd "Packages/$package" && swift test)
done
```

Required named coverage:

- R-R migration and equal-beat persistence;
- gap-aware cleaning, RMSSD, and pNN50;
- no-gap equivalence;
- WHOOP 5 R22 ordered flag sequence and `enable_sig12 == 0x31`;
- v18/v21/v26 fixture decoding;
- PPG waveform pack/unpack, malformed odd-byte handling, and persistence;
- raw IMU sample decode and feature extraction;
- timestamp/date-range rejection;
- import byte budgets and deterministic dedupe;
- journal wake-day mapping and atomic replacement;
- source-aware steps and FIT fallback;
- backup/restore validation;
- per-device baseline era behavior.

### 9.3 Database upgrade matrix

Test each source database by copying it—not the live user database—into a temporary test container and opening it with the reconciled build.

| Fixture | Required assertion |
|---|---|
| Fresh empty database | All migrations run once; private coaching tables and new v25–v28 state exist. |
| Database created at shared 8.2.2 base | Every old row survives; R-R rows receive `seq = 0`; analytics refresh succeeds. |
| Current private database at v24 | `coachingBehaviorSet`, `coachingBehaviorMembership`, `coachingStack`, `coachingStackItem`, and `coachingStackUse` survive byte-for-byte; v25–v28 append after them. |
| Database with `efficiency = 90` | v27 converts it to `0.90`; an existing `0.90` remains `0.90`; rerunning migrations changes nothing. |
| Database with equal same-second R-R values inserted after upgrade | both rows survive with distinct sequence keys; replaying the identical batch inserts zero additional rows. |
| Valid WAL-mode backup | restore succeeds after staging/checkpoint handling and exposes the same logical row counts. |
| Truncated/corrupt backup | validation rejects it and the live database remains untouched. |
| Large multi-year database | open/migrate is serialized; concurrent callers receive the same opened store and do not race migrations. |

Useful SQLite inspection commands:

```bash
sqlite3 "$DB" 'PRAGMA integrity_check;'
sqlite3 "$DB" 'PRAGMA table_info(rrInterval);'
sqlite3 "$DB" 'SELECT name FROM sqlite_master WHERE type = "table" ORDER BY name;'
sqlite3 "$DB" 'SELECT deviceId, ts, rrMs, seq, COUNT(*) FROM rrInterval GROUP BY 1,2,3,4 HAVING COUNT(*) > 1;'
sqlite3 "$DB" 'SELECT COUNT(*), MIN(ts), MAX(ts) FROM rrInterval;'
```

### 9.4 R-R and HRV numerical fixtures

Run these fixtures through the public pure functions and assert exact values/tolerances in tests:

1. **No gap:** `[800, 810, 805, 815, 800]` — gap-aware RMSSD/pNN50 equals the legacy raw calculation.
2. **Out-of-range middle beat:** `[800, 810, 250, 805, 815]` — the `810 → 805` splice is excluded from successive-difference metrics.
3. **Ectopic middle beat:** a stable series with one value beyond the Malik threshold — both differences crossing the rejected beat are excluded.
4. **Only splices remain:** cleaning leaves enough values for SDNN but no original adjacent pair — RMSSD/pNN50 are `nil`, never zero.
5. **Equal same-second beats:** two `812 ms` intervals at one timestamp survive storage and contribute the genuine zero delta.
6. **Excessive spot rejection:** a short Spot HRV capture exceeding the rejection ceiling returns an empty/insufficient result.
7. **Coverage diagnostic:** physically impossible beat-time-to-wall-time coverage is flagged; exact duplicate count reports the mechanism.
8. **Window preference:** changing whole-night/deep-sleep mode updates recent nightly HRV and the folded baseline without resetting an established calibration epoch.

### 9.5 Import, export, and HealthKit matrix

#### Imports

- Import identical WHOOP export twice; logical row counts and journal answers are unchanged on the second run.
- Import a WHOOP journal range bounded by two existing local days; only rows inside the imported range are replaced.
- Inject a parser/write failure halfway through journal replacement; the transaction rolls back.
- Import Apple Health step records from both iPhone and Apple Watch over the same walk; the result matches Health-style source arbitration rather than the sum.
- Import a FIT walking/running/hiking activity with steps and no better source; steps appear.
- Repeat with trustworthy Apple/strap steps already present; FIT steps do not add again.
- Import a large Health export that exceeds the configured total-byte budget; completion reports truncation/limits explicitly and temp extraction files are reclaimed.
- Import per-workout HR, active energy, and distance; metadata stays attached to the correct workout interval.

#### Exports

- Export a live-BLE-only installation whose raw rows live under a re-added active strap; output is not empty.
- Export with canonical imported history plus a fresh active strap; union logic includes both and deduplicates overlaps.
- Scheduled debug/export jobs emit once per logical schedule occurrence after relaunch, not once per launch.
- Raw sensor export preserves absent columns as empty/absent, not zero.

#### HealthKit writeback

Test these permission combinations independently: all denied, sleep only, heart rate only, workouts only, and all requested types.

Required assertions:

- deterministic external identifiers make a repeated write idempotent;
- a late strap offload rewrites only the bounded recent interval;
- deletion is limited to samples previously written by this app/source;
- Apple Health-origin workouts are never written back;
- denied permission for one type does not block permitted types;
- sleep stages are clamped to the sleep interval;
- one-minute HR samples preserve timestamps/time zone;
- wake-time vitals are written only when a real value exists;
- steps and broad daily calories are not written in a way that duplicates Apple-owned totals.

### 9.6 App build and simulator gates

```bash
xcodegen generate

xcodebuild \
  -project Strand.xcodeproj \
  -scheme NOOPiOS \
  -destination 'generic/platform=iOS Simulator' \
  CODE_SIGNING_ALLOWED=NO \
  build

xcodebuild \
  -project Strand.xcodeproj \
  -scheme Strand \
  -destination 'platform=macOS' \
  CODE_SIGNING_ALLOWED=NO \
  build

xcodebuild \
  -project Strand.xcodeproj \
  -scheme NOOPiOS \
  -destination 'platform=iOS Simulator,name=iPhone 16 Pro' \
  CODE_SIGNING_ALLOWED=NO \
  test
```

Simulator smoke path:

1. launch with an empty store;
2. load deterministic demo data where supported;
3. open Today, Workouts, Sleep, Health, Trends, Data Sources, Storage, and Settings;
4. pull Today while disconnected—no crash, no false sync claim;
5. enable/disable Power saving and relaunch—preferences persist;
6. exercise backup picker/import picker cancellation—no stranded temp data;
7. verify widgets/app group compile with matching version/build;
8. inspect console for main-thread checker, SQLite, HealthKit, and localization exceptions.

### 9.7 Physical WHOOP 4.0 matrix

Record strap model, firmware, iPhone model, iOS version, build SHA, and whether the official WHOOP app was installed/running.

- pair from a clean install;
- relaunch and reconnect without re-pairing;
- live HR/R-R stream for at least ten minutes;
- manual pull-to-sync while connected/bonded/idle;
- pull while disconnected and while a backfill is active;
- history backfill through multiple pages and an empty tail;
- future-clock fixture or controlled clock anomaly: sync blocks/backoffs rather than polluting the store;
- Restart Strap: disconnect/reconnect with no data deletion or unpair;
- smart alarm set → transmit → acknowledge → readback; verify re-arm only after command notifications are ready;
- low-battery policy below threshold while discharging: cadence stretches and background HRV may release;
- connect charger: throttling disengages and background HRV re-arms;
- WHOOP 4.0 step/activity-class behavior where firmware reports it;
- raw SpO₂ ADC fields appear only as raw diagnostics.

### 9.8 Physical WHOOP 5.0/MG matrix

- encrypted bond and reconnect;
- post-bond battery percentage becomes available without app restart and updates thereafter;
- R22 write order exactly matches the 16-entry sequence; `enable_sig12` writes `0x31`;
- live HR/R-R and manual workout capture;
- 100 Hz accelerometer/gyroscope decode using known fixture and real capture;
- v21 channels route to IMU/motion storage, never optical/PPG storage;
- v26 PPG waveform packs, persists, reads, and exports losslessly;
- band sleep-state/event/console streams persist when present and remain absent when not reported;
- pull-to-sync state is honest when deep history remains experimental;
- Restart Strap disconnects/reconnects safely;
- power policy behaves from the strap battery, not iPhone Low Power Mode;
- no high-rate experimental stream becomes a downstream recovery/sleep gate without explicit validated feature policy.

### 9.9 Multi-WHOOP identity matrix

1. Pair strap A and bank HR/workouts.
2. Add strap B and make B active.
3. Confirm canonical imported/computed history remains visible.
4. Create or fixture a detected workout whose `source` is `whoop-a-noop` while B is active.
5. Reconcile the workout; Avg HR/Effort must read raw HR under `whoop-a`, not B.
6. Remove/re-add A with a fresh peripheral identifier; active raw data and canonical history remain visible as a union.
7. Export; neither strap’s valid rows disappear and duplicates do not multiply.
8. Baseline era separation prevents A/B physiological scales from being folded into one incompatible baseline.

### 9.10 Performance and privacy gates

- Profile launch and a 21-day rescore on a multi-year database; UI remains responsive and heavy transforms stay off the main actor.
- Verify a segmented deep offload coalesces dashboard refresh/rescore rather than triggering one full refresh per slice.
- Verify workout dedupe growth is near-linear on a large workout library.
- Verify backup/export/import work runs off the UI thread and cleans temporary files after success, error, and cancellation.
- Search the final diff for network clients, telemetry, analytics SDKs, crash reporters, account/cloud code, firmware blobs, or decompiled proprietary assets. None may be introduced.
- Inspect debug exports for API keys, HealthKit authorization secrets, Apple identifiers, or unrelated user file paths. Secrets must be absent/redacted.

---

## 10. Integration commits and pull-request package

The script leaves one staged implementation. Codex may submit it as one integration commit, but the preferred review shape is four buildable commits on the same branch:

1. **`sync(upstream): import released iPhone backend through 9.0.1`**  
   Immutable stable package/BLE/data/HealthKit/workflow patch, no private adapters.
2. **`fix(store): reconcile private migrations and physiological data integrity`**  
   Private v25–v28 migrations, R-R sequence tests, gap-aware HRV tests, PPG persistence, coaching-table retention.
3. **`fix(ios): preserve Paper UI while wiring sync, power and identity`**  
   Today `syncNow`, private Settings power card, `AppModel` power wiring, selected post-release R22 and workout hotfixes.
4. **`chore(release): bump private iOS build and add verification`**  
   `9.0.1` / build `204`, generated-project exclusion, test/QA evidence, no AltStore URL change.

Do not create commits that leave `WhoopStore` code expecting columns/tables not yet created. When splitting, migration and writer/reader changes must stay in the same buildable commit.

### Pull-request title

```text
Reconcile private iPhone backend with NOOP 9.0.1 + selected Apple hotfixes
```

### Pull-request body template

```markdown
## Source boundaries

- target: eastonplace-ai/noop@42b868f5d7c580d55848592a3aaacb2e0ea11963
- common ancestor: f099af097f88827b987fadaf0843326c0c793f8e
- released upstream: ryanbr/noop@25eb933a2563d490583ecd4c0051dff581874bb8 (v9.0.1)
- selected post-release fixes:
  - f5f64977b9a83b2e74dccfee21daaeb5e7089a45
  - 6a285e258c2443a2be64cbcb5eda9796878670e4

## Preserved private behavior

- Paper UI and component system
- team, bundle IDs and application group
- DEBUG/demo store partition
- private v23/v24 coaching migrations and data
- existing private feature work unless superseded by a documented correctness fix

## Implemented

- [ ] released iPhone/shared backend through 9.0.1
- [ ] R-R sequence migration and gap-aware HRV
- [ ] WHOOP 4.0/5.0/MG sync, alarm, clock and battery fixes
- [ ] HealthKit/import/export/backup hardening
- [ ] WHOOP 5/MG raw IMU/PPG/event/console persistence
- [ ] per-device identity/baseline fixes
- [ ] private Today pull-to-sync and Settings power adapter
- [ ] selected post-release R22/workout hotfixes

## Automated verification

Paste exact command output, not “tests pass.”

## Hardware verification

| Strap | Firmware | Phone/iOS | Scenarios | Result |
|---|---|---|---|---|
| WHOOP 4.0 |  |  |  |  |
| WHOOP 5.0/MG |  |  |  |  |

## Known limits

Only list evidence-based limits. Do not mark CoreBluetooth behavior verified from compilation alone.
```

---

## 11. Codex execution contract

Give Codex the repository plus this Markdown file and use the following instruction verbatim. This turns Codex’s task into execution, conflict resolution against explicit contracts, and QA—not architecture invention.

```text
Work in the connected private repository eastonplace-ai/noop.

The authoritative implementation package is:
noop_private_reconciliation_execution_package.md

Execute it completely. Do not ask for requirements that are already specified in the package, do not redesign the private Paper UI, and do not substitute a fresh plan for implementation.

Pinned source contract:
- target SHA: 42b868f5d7c580d55848592a3aaacb2e0ea11963
- common ancestor: f099af097f88827b987fadaf0843326c0c793f8e
- stable upstream SHA: 25eb933a2563d490583ecd4c0051dff581874bb8
- upstream main observed SHA: e91ef0a149c8686c156b8c7e2ecfeab5dcdfdf1c
- selected post-release commits:
  - f5f64977b9a83b2e74dccfee21daaeb5e7089a45
  - 6a285e258c2443a2be64cbcb5eda9796878670e4

Required workflow:
1. Confirm origin and clean working tree.
2. Save Section 4 as reconcile_nuke_9_0_1.sh and run it from repository root.
3. If the upstream main guard fails, stop changing code and report the new SHA plus the commit list after v9.0.1; do not silently pull new unreleased work.
4. If the script exits 24, resolve every three-way conflict using Sections 5–8 and the conflict matrix. For each conflict inspect all three immutable versions:
   git show f099af097f88827b987fadaf0843326c0c793f8e:<path>
   git show 42b868f5d7c580d55848592a3aaacb2e0ea11963:<path>
   git show 25eb933a2563d490583ecd4c0051dff581874bb8:<path>
5. Keep the private version for visual structure, identifiers, StorePaths demo partition, and v23/v24 coaching ownership. Integrate upstream correctness/data behavior into that structure. Never choose an entire side for Database.swift, AppModel.swift, BLEManager.swift, Repository.swift, TodayView.swift, or SettingsView.swift without semantic review.
6. Do not add Android, upstream StrandDesign, Liquid UI, Oura cloud, localization sweeps, telemetry, accounts, servers, firmware, or decompiled assets.
7. Implement every code contract and release-wave invariant in the package. No TODO, placeholder, dead feature flag, or fake zero value is acceptable.
8. Run all package, simulator, macOS shared-source, database, import, HealthKit, performance, and static scope checks in Section 9 that the environment supports.
9. Perform real WHOOP 4.0 and WHOOP 5.0/MG hardware checks when hardware is available. If a strap is unavailable, mark only those exact checks UNVERIFIED; do not describe compile success as BLE validation.
10. Inspect and explain every staged file. Remove generated Strand.xcodeproj, DerivedData, build products, databases, captures, exports, and user data before committing.
11. Use the preferred four-commit structure in Section 10 when it stays buildable; otherwise use one integration commit and explain why splitting would produce an invalid intermediate schema/code state.
12. Open a draft PR using the provided title/body. Include exact command output, migration fixture results, hardware matrix, and any remaining evidence-based limitation.

Non-negotiable final assertions:
- MARKETING_VERSION is 9.0.1 and CURRENT_PROJECT_VERSION is 204.
- DEVELOPMENT_TEAM remains 479HYY24G2.
- APP_GROUP_ID remains group.com.eastonplace.noop.
- iOS bundle IDs remain com.eastonplace.noop and com.eastonplace.noop.widgets.
- private coaching migrations/tables survive.
- rrInterval primary key is deviceId, ts, rrMs, seq.
- R-R reads order by ts, rrMs, seq.
- RMSSD/pNN50 skip differences across removed beats.
- enable_sig12 is 0x31.
- Today pull-to-sync calls the central BLE syncNow gate.
- power saving uses strap battery and disengages while charging.
- detected workout reconciliation reads the recording strap.
- no forbidden platform/design/cloud files are staged.

Final response must contain:
- branch and final commit SHA(s);
- complete changed-file summary grouped by layer;
- exact automated test/build commands and results;
- database migration fixture results;
- HealthKit/import/export results;
- physical strap results or narrowly labeled UNVERIFIED rows;
- draft PR URL;
- zero vague claims such as “should work.”
```

---

## 12. Source and provenance ledger

### Repository and release anchors

- Target repository: `https://github.com/eastonplace-ai/noop`
- Target commit: `https://github.com/eastonplace-ai/noop/commit/42b868f5d7c580d55848592a3aaacb2e0ea11963`
- Shared ancestor: `https://github.com/ryanbr/noop/commit/f099af097f88827b987fadaf0843326c0c793f8e`
- Stable upstream release: `https://github.com/ryanbr/noop/releases/tag/v9.0.1`
- Stable upstream commit: `https://github.com/ryanbr/noop/commit/25eb933a2563d490583ecd4c0051dff581874bb8`
- Current upstream head observed during this audit: `https://github.com/ryanbr/noop/commit/e91ef0a149c8686c156b8c7e2ecfeab5dcdfdf1c`
- Release history: `https://github.com/ryanbr/noop/releases?page=1`

### Selected post-release commits

- Final R22 `enable_sig12` value: `https://github.com/ryanbr/noop/commit/f5f64977b9a83b2e74dccfee21daaeb5e7089a45`
- Recording-strap workout HR: `https://github.com/ryanbr/noop/commit/6a285e258c2443a2be64cbcb5eda9796878670e4`
- Explicitly excluded staging snapshot: `https://github.com/ryanbr/noop/commit/7fd6b15fcdea81fd9b90c76cdfb9903881894608`

### Critical released source files

- R-R/stream persistence: `Packages/WhoopStore/Sources/WhoopStore/StreamStore.swift`
- R-R ordering and fallback reads: `Packages/WhoopStore/Sources/WhoopStore/Reads.swift`
- Released migration sequence: `Packages/WhoopStore/Sources/WhoopStore/Database.swift`
- Gap-aware HRV: `Packages/StrandAnalytics/Sources/StrandAnalytics/HRVAnalyzer.swift`
- WHOOP 5/MG configuration: `Packages/WhoopProtocol/Sources/WhoopProtocol/Whoop5Config.swift`
- BLE collection/power/sync: `Strand/BLE/BLEManager.swift`, `Strand/BLE/BackfillPolicy.swift`, `Strand/BLE/PuffinExperiment.swift`
- Identity/export/read model: `Strand/Data/Repository.swift`
- App orchestration: `Strand/App/AppModel.swift`
- HealthKit: `StrandiOS/Health/HealthKitBridge.swift`
- Private migration ownership: `Packages/WhoopStore/Sources/WhoopStore/Database.swift` at the target SHA
- Private Paper adapters: `Strand/Screens/TodayView.swift`, `Strand/Screens/SettingsView.swift` at the target SHA

### Provenance rule

No code in this package is inferred from a release-note label alone when an exact source implementation exists. Released backend code is imported byte-for-byte from the immutable stable Git tree; target-owned code is rewritten explicitly in Section 4; selected unreleased fixes are imported from their individual immutable commits. Release notes are used to verify coverage and intent, not as a substitute for code.

---

## 13. Definition of done

The reconciliation is complete only when every applicable box is checked:

### Source and build

- [ ] Integration starts from the exact audited target SHA or the package is re-audited for a newer target.
- [ ] Stable source resolves to the exact audited `v9.0.1` SHA.
- [ ] Only the two selected post-release commits are included.
- [ ] No unresolved conflicts or rejected hunks remain.
- [ ] All four Swift packages pass tests.
- [ ] `NOOPiOS` builds for a generic simulator.
- [ ] Shared `Strand` macOS target builds.
- [ ] iOS test action passes on an available simulator.
- [ ] Generated and user-data artifacts are absent from the commit.

### Data correctness

- [ ] Private coaching migrations/tables survive.
- [ ] Private v25–v28 migrations apply in order.
- [ ] Existing 8.2.2/private databases migrate without data loss.
- [ ] Equal R-R beats survive and replay stays idempotent.
- [ ] Gap-aware HRV tests pass.
- [ ] Efficiency heal is idempotent.
- [ ] Raw PPG/IMU/event/sleep-state absence stays absent.
- [ ] Per-device baseline/identity tests pass.
- [ ] Backup restore handles WAL and rejects corruption atomically.

### iPhone behavior

- [ ] Pull-to-sync is wired through `BLEManager.syncNow()`.
- [ ] WHOOP 5/MG battery retries after bond.
- [ ] Power policy uses strap battery and never throttles while charging.
- [ ] Smart alarm waits for command-notification readiness and verifies readback.
- [ ] Future-clock data cannot pollute the store.
- [ ] HealthKit writeback is idempotent, bounded, and source-scoped.
- [ ] Import/export/step/workout fixtures pass.
- [ ] Multi-WHOOP workout HR uses the recording strap.
- [ ] Widgets/background publication updates after a completed backfill.

### Hardware and release

- [ ] WHOOP 4.0 matrix is recorded with firmware/device/build evidence.
- [ ] WHOOP 5.0/MG matrix is recorded with firmware/device/build evidence.
- [ ] R22 final flag sequence is observed or fixture-verified, with `enable_sig12 = 0x31`.
- [ ] Private team, app group, and bundle IDs are unchanged.
- [ ] Version is `9.0.1`, private build is `204`.
- [ ] `altstore-source.json` is updated only after a signed private IPA exists at its final immutable URL.
- [ ] Draft PR contains exact test output and narrowly labels any hardware-only item that remains unverified.

Until the real-strap rows are recorded, the code may be merge-ready but the BLE portion is not release-verified.
