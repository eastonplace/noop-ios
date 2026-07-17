#!/usr/bin/env bash
set -Eeuo pipefail
IFS=$'\n\t'

TARGET_REPO="eastonplace-ai/noop"
TARGET_SHA="42b868f5d7c580d55848592a3aaacb2e0ea11963"
COMMON_BASE="f099af097f88827b987fadaf0843326c0c793f8e"
UPSTREAM_STABLE="25eb933a2563d490583ecd4c0051dff581874bb8"
R22_HOTFIX="f5f64977b9a83b2e74dccfee21daaeb5e7089a45"
WORKOUT_HOTFIX="6a285e258c2443a2be64cbcb5eda9796878670e4"
UPSTREAM_URL="https://github.com/ryanbr/noop.git"
UPSTREAM_REMOTE="nuke"
WORK_BRANCH="codex/reconcile-nuke-9.0.1"

die() { printf 'ERROR: %s\n' "$*" >&2; exit 1; }
need() { command -v "$1" >/dev/null 2>&1 || die "missing command: $1"; }

for tool in git python3; do need "$tool"; done
git rev-parse --git-dir >/dev/null 2>&1 || die "run from repository root"

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

git fetch --prune "$UPSTREAM_REMOTE" \
  "+refs/tags/v9.0.1:refs/tags/nuke-v9.0.1"

for sha in "$UPSTREAM_STABLE" "$R22_HOTFIX" "$WORKOUT_HOTFIX"; do
  git cat-file -e "$sha^{commit}" 2>/dev/null || git fetch "$UPSTREAM_REMOTE" "$sha"
done

[[ "$(git rev-parse nuke-v9.0.1^{commit})" == "$UPSTREAM_STABLE" ]] ||
  die "v9.0.1 moved from audited SHA"
git merge-base --is-ancestor "$COMMON_BASE" "$UPSTREAM_STABLE" ||
  die "audited base is not an ancestor of stable upstream"

git merge-base --is-ancestor "$TARGET_SHA" HEAD ||
  die "branch does not descend from audited target: $(git rev-parse HEAD)"
[[ "$(git branch --show-current)" == "$WORK_BRANCH" ]] ||
  die "run from $WORK_BRANCH"

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
# The private target has newer migration coverage. Merge the package fixtures
# semantically after the import instead of replacing that file wholesale.

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

git diff --cached --check
printf '\nImplementation staged on %s\n' "$WORK_BRANCH"
printf 'Target:   %s\n' "$TARGET_SHA"
printf 'Stable:   %s\n' "$UPSTREAM_STABLE"
printf 'Hotfixes: %s %s\n' "$R22_HOTFIX" "$WORKOUT_HOTFIX"
git diff --cached --stat
git status --short
