#!/usr/bin/env python3
"""Compile unchanged production day-key helpers; use only synthetic, in-memory data.

Run: python3 calendar-key-probe.py --swiftc /path/to/swiftc --output-dir /tmp/calendar-probe
This creates scratch files only. It does not edit production sources or run the native app.
"""

import argparse
import hashlib
import json
import pathlib
import sqlite3
import subprocess
import tempfile


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--swiftc", default="swiftc")
    parser.add_argument("--output-dir")
    args = parser.parse_args()
    root = pathlib.Path(__file__).resolve().parents[3]
    out = pathlib.Path(args.output_dir or tempfile.mkdtemp(prefix="noop-calendar-probe-"))
    out.mkdir(parents=True, exist_ok=True)
    manifest = []

    def extract(path, signature):
        text = (root / path).read_text()
        start = text.index(signature)
        brace = text.index("{", start)
        depth, end = 1, brace + 1
        while depth:
            depth += (text[end] == "{") - (text[end] == "}")
            end += 1
        body = text[start:end]
        manifest.append({
            "file": path, "start_line": text[:start].count("\n") + 1,
            "signature": signature, "sha256": hashlib.sha256(body.encode()).hexdigest(),
        })
        return body

    engine = "Strand/Data/IntelligenceEngine.swift"
    repo = "Strand/Data/Repository.swift"
    store = "Packages/WhoopStore/Sources/WhoopStore/TimestampHeal.swift"
    parts = [
        "import Foundation", "enum EngineProbe {",
        extract(engine, "struct CivilDayWindow:"),
        extract(engine, "nonisolated static func civilDayWindows("),
        extract(engine, "nonisolated static func civilDayStart("), "}",
        "enum RepoProbe {", "nonisolated static let logicalDayRolloverHour = 4",
        extract(repo, "nonisolated static func localDayKey("),
        extract(repo, "nonisolated static func logicalDay("),
        extract(repo, "nonisolated static func logicalDayKey("),
        extract(repo, "private static let dayFormatter: DateFormatter =") + "()",
        extract(repo, "static func dayString("), "}",
        "enum StoreProbe {", extract(store, "public static func localDayKey("), "}",
        r'''
let timezone = TimeZone(identifier: "Asia/Bangkok")!
NSTimeZone.default = timezone
let reference = Date(timeIntervalSince1970: 1_791_738_000 + 6 * 3_600)
var output: [[String: Any]] = []
for identifier in [Calendar.Identifier.gregorian, .buddhist, .japanese, .hebrew, .islamicCivil] {
    var calendar = Calendar(identifier: identifier)
    calendar.timeZone = timezone
    let windows = EngineProbe.civilDayWindows(reference: reference, startOffset: 0, count: 2, calendar: calendar)
    output.append([
        "calendar": String(describing: identifier),
        "engine_keys": windows.map(\.day),
        "engine_start": windows[0].start,
        "engine_next_start": windows[0].nextStart,
        "repository_local": RepoProbe.localDayKey(reference, calendar: calendar),
        "repository_logical": RepoProbe.logicalDayKey(reference, calendar: calendar),
        "repository_refresh": RepoProbe.dayString(reference),
        "store_local": StoreProbe.localDayKey(reference),
        "gregorian_key_parsed_with_input_calendar": EngineProbe.civilDayStart("2026-10-12", calendar: calendar) as Any
    ])
}
let json = try JSONSerialization.data(withJSONObject: output, options: [.prettyPrinted, .sortedKeys])
print(String(data: json, encoding: .utf8)!)
''',
    ]
    source = out / "daykey-probe.swift"
    source.write_text("\n\n".join(parts))
    executable = out / "daykey-probe"
    subprocess.run([args.swiftc, "-module-cache-path", str(out / "module-cache"),
                    str(source), "-o", str(executable)], check=True)
    rows = json.loads(subprocess.check_output([str(executable)], text=True))
    assert rows[0]["engine_keys"] == ["2026-10-12", "2026-10-11"]
    assert rows[1]["engine_keys"] == ["2569-10-12", "2569-10-11"]
    assert all(row["engine_start"] == 1_791_738_000 for row in rows)
    assert all(row["engine_next_start"] - row["engine_start"] == 86_400 for row in rows)
    assert all(row["repository_refresh"] == row["store_local"] == "2026-10-12" for row in rows)
    assert all(row["repository_local"] == row["repository_logical"] == row["engine_keys"][0] for row in rows)

    # The SQL predicate is extracted verbatim; this is a SQLite contract probe, not a WhoopStore test.
    heal_text = (root / store).read_text()
    start = heal_text.index('"DELETE FROM dailyMetric WHERE day > ?') + 1
    heal_sql = heal_text[start:heal_text.index('"', start)]
    db = sqlite3.connect(":memory:")
    db.executescript("""
        CREATE TABLE dailyMetric(deviceId TEXT, day TEXT, value REAL, PRIMARY KEY(deviceId, day));
        CREATE TABLE journal(deviceId TEXT, day TEXT, question TEXT, answeredYes INTEGER,
            PRIMARY KEY(deviceId, day, question));
        CREATE TABLE metricSeries(deviceId TEXT, day TEXT, key TEXT, value REAL,
            PRIMARY KEY(deviceId, day, key));
    """)
    db.executemany("INSERT INTO dailyMetric VALUES (?, ?, ?)", [
        ("my-whoop", "2026-10-12", 51), ("my-whoop-noop", "2569-10-12", 62)])
    db.executemany("INSERT INTO journal VALUES (?, ?, ?, ?)", [
        ("noop-journal", "2026-10-12", "caffeine", 0),
        ("noop-journal", "2569-10-12", "caffeine", 1)])
    db.execute("INSERT INTO metricSeries VALUES ('hydration', '2569-10-12', 'hydration', 250)")
    db.commit()
    visible = db.execute("SELECT deviceId, day FROM dailyMetric WHERE day >= ? AND day <= ? ORDER BY deviceId",
                         ("2026-10-11", "2026-10-13")).fetchall()
    hydration_after_key_change = db.execute(
        "SELECT value FROM metricSeries WHERE deviceId = 'hydration' AND day = ? AND key = 'hydration'",
        ("2026-10-12",)).fetchall()
    try:
        db.execute("UPDATE journal SET day = ? WHERE deviceId = 'noop-journal' AND day = ?",
                   ("2026-10-12", "2569-10-12"))
    except sqlite3.IntegrityError as error:
        collision = str(error)
        db.rollback()
    else:
        raise AssertionError("expected same-question journal primary-key conflict")
    # Actual floor is utcDayKey(MIN_PLAUSIBLE_UNIX=1_700_000_000), 2023-11-14.
    deleted = db.execute(heal_sql, ("2026-10-12", "2023-11-14")).rowcount
    sql_result = {
        "scope": "synthetic SQLite schemas and exact production heal predicate; no live store",
        "gregorian_refresh_visible_daily_rows": visible,
        "hydration_at_gregorian_key_after_helper_only_change": hydration_after_key_change,
        "naive_journal_rekey_error": collision,
        "heal_sql": heal_sql,
        "heal_deleted_non_gregorian_computed_rows": deleted,
        "remaining_daily_rows": db.execute("SELECT deviceId, day FROM dailyMetric").fetchall(),
    }
    assert visible == [("my-whoop", "2026-10-12")]
    assert hydration_after_key_change == [] and deleted == 1
    result = {
        "swiftc": subprocess.check_output([args.swiftc, "--version"], text=True).strip(),
        "helper_declarations_extracted_without_body_edits": len(manifest),
        "helper_cases": rows,
        "synthetic_sql_checks": sql_result,
    }
    (out / "source-manifest.json").write_text(json.dumps(manifest, indent=2) + "\n")
    (out / "result.json").write_text(json.dumps(result, indent=2) + "\n")
    print(json.dumps(result, indent=2))


if __name__ == "__main__":
    main()
