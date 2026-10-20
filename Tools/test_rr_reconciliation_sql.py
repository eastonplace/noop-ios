#!/usr/bin/env python3
"""Run the shipped Swift SQL against SQLite. No replica query and no network."""
import os, pathlib, re, sqlite3, unittest
ROOT = pathlib.Path(os.environ.get("NOOP_TEST_REPO", pathlib.Path(__file__).resolve().parents[1]))
POLICY = ROOT / "Packages/WhoopStore/Sources/WhoopStore/RRReadPolicy.swift"
QUALITY = ROOT / "Packages/WhoopStore/Sources/WhoopStore/RRQualityMigration.swift"

def literal(path, name):
    text = path.read_text()
    m = re.search(r"static let " + re.escape(name) + r'\s*=\s*"""\n(.*?)\n\s*"""', text, re.S)
    if not m:
        m = re.search(r"static let " + re.escape(name) + r'\s*=\s*"([^"\n]*)"', text)
    if not m:
        raise AssertionError(f"Production SQL missing: {path.name}.{name}")
    sql = m.group(1)
    if "\\(" in sql:
        raise AssertionError("SQL must be the complete production literal")
    return sql

def scoring_query(kind):
    try:
        return literal(POLICY, kind + "ScoringSQL")
    except AssertionError:
        # The red run executes the old target's real non-WHOOP5 branch.
        if kind != "whoop4" or os.environ.get("NOOP_TEST_ALLOW_BASELINE") != "1":
            raise
        m = re.search(r'return try Row.fetchAll\(db, sql: """\n(.*?)\n\s*""", arguments:', POLICY.read_text(), re.S)
        if not m:
            raise
        return m.group(1).replace("\\(predicate)", "1")

class RRReconciliationSQLTests(unittest.TestCase):
    def setUp(self):
        self.db = sqlite3.connect(":memory:")
        self.db.row_factory = sqlite3.Row
        self.db.executescript("""
          CREATE TABLE rrInterval(
            deviceId TEXT NOT NULL, ts INTEGER NOT NULL, rrMs INTEGER NOT NULL,
            seq INTEGER NOT NULL DEFAULT 0, source TEXT NOT NULL DEFAULT 'legacy',
            sourceOrdinal INTEGER, tsSuspect INTEGER,
            PRIMARY KEY(deviceId,ts,rrMs,seq));
          CREATE TABLE hrSample(deviceId TEXT,ts INTEGER,bpm INTEGER,PRIMARY KEY(deviceId,ts));
          CREATE TABLE pairedDevice(id TEXT PRIMARY KEY,model TEXT,brand TEXT);
          CREATE INDEX idx_rrInterval_source_order ON rrInterval(deviceId,source,ts,sourceOrdinal,rrMs);
        """)
    def tearDown(self):
        self.db.close()
    def rr(self, ts, rr, source, seq=0, suspect=None, device="strap", ordinal=None):
        self.db.execute("INSERT INTO rrInterval(deviceId,ts,rrMs,seq,source,sourceOrdinal,tsSuspect) VALUES (?,?,?,?,?,?,?)",
                        (device,ts,rr,seq,source,seq if ordinal is None else ordinal,suspect))
    def selected(self, kind="whoop4", start=0, end=10800, limit=100):
        return list(self.db.execute(scoring_query(kind),{"d":"strap","f":start,"t":end,"lim":limit}))
    def test_whoop4_never_mixes_transports_within_hour(self):
        self.rr(100,800,"whoop4_historical")
        self.rr(101,810,"whoop4_realtime")
        self.rr(102,820,"whoop4_standard_2a37")
        self.rr(103,830,"legacy")
        self.assertEqual([r["rrMs"] for r in self.selected()], [800])
    def test_source_choice_uses_full_hour_before_exact_slice(self):
        self.rr(50,800,"whoop4_historical")
        self.rr(100,810,"whoop4_standard_2a37")
        self.assertEqual(self.selected(start=100,end=110), [])
    def test_hours_use_independent_provenance_choices(self):
        for row in [(100,800,"whoop4_historical"),(101,810,"whoop4_standard_2a37"),
                    (3700,820,"whoop4_realtime"),(3701,830,"whoop4_standard_2a37"),
                    (7300,840,"whoop4_standard_2a37"),(7301,850,"legacy"),
                    (10900,860,"legacy")]: self.rr(*row)
        self.assertEqual([r["rrMs"] for r in self.selected(end=12000)], [800,820,840,860])
    def test_suspect_history_cannot_hide_good_fallback(self):
        self.rr(100,800,"whoop4_historical",suspect=1)
        self.rr(101,810,"whoop4_realtime")
        self.assertEqual([r["rrMs"] for r in self.selected()], [810])
    def test_limit_applies_after_choice_and_keeps_equal_beats(self):
        for seq in range(8): self.rr(100,800,"whoop4_historical",seq=seq)
        for i in range(20): self.rr(i,810+i,"whoop4_standard_2a37")
        rows=self.selected(limit=5)
        self.assertEqual([r["rrMs"] for r in rows], [800]*5)
        self.assertEqual([r["sourceOrdinal"] for r in rows], list(range(5)))
    def test_unknown_sources_and_other_devices_do_not_choose_train(self):
        self.rr(100,800,"future_transport")
        self.rr(101,810,"whoop5_historical")
        self.rr(102,820,"oura_green_quality")
        self.rr(103,830,"whoop4_historical",device="other")
        self.rr(104,840,"whoop4_standard_2a37")
        self.assertEqual([r["rrMs"] for r in self.selected()], [840])
    def test_whoop5_uses_whole_window_history_and_excludes_filler(self):
        self.rr(100,500,"whoop5_historical",suspect=1)
        self.rr(200,800,"whoop5_standard_2a37")
        self.rr(4000,850,"whoop5_historical")
        self.assertEqual([r["rrMs"] for r in self.selected("whoop5")], [850])
    def test_whoop5_falls_back_when_all_history_is_suspect(self):
        self.rr(100,500,"whoop5_historical",suspect=1)
        self.rr(200,800,"whoop5_standard_2a37")
        self.rr(201,790,"whoop5_realtime")
        self.assertEqual([r["rrMs"] for r in self.selected("whoop5")], [800])
    def test_other_source_policy_retains_existing_oura_behavior(self):
        self.rr(100,800,"oura_green_quality",suspect=1)
        self.rr(101,810,"oura_spo2")
        self.rr(102,820,"standard_ble")
        self.assertEqual([r["rrMs"] for r in self.selected("other")], [800,820])
    def test_fill_marks_only_exact_source_interval_and_hr_condition(self):
        cases=[(100,500,"whoop5_historical",80),(101,500,"whoop5_standard_2a37",99),
               (102,500,"whoop5_standard_2a37",100),(103,501,"whoop5_historical",80),
               (104,499,"whoop5_historical",80),(105,500,"whoop5_realtime",80),
               (106,500,"whoop4_historical",80),(107,500,"legacy",80),
               (108,500,"whoop5_historical",None)]
        for ts,rr,source,hr in cases:
            self.rr(ts,rr,source)
            if hr is not None: self.db.execute("INSERT INTO hrSample VALUES ('strap',?,?)",(ts,hr))
        self.db.execute(literal(QUALITY,"whoop5RrFillFlagSQL"),{"deviceId":"strap","fromTs":0,"toTs":200})
        allrows=list(self.db.execute("SELECT ts,tsSuspect FROM rrInterval ORDER BY ts"))
        self.assertEqual(len(allrows),len(cases))
        self.assertEqual([r["ts"] for r in allrows if r["tsSuspect"]==1],[100,101])
    def test_fill_mark_is_device_scoped_and_idempotent(self):
        self.rr(100,500,"whoop5_historical")
        self.rr(100,500,"whoop5_historical",device="other")
        self.db.executemany("INSERT INTO hrSample VALUES (?,100,80)",[("strap",),("other",)])
        sql=literal(QUALITY,"whoop5RrFillFlagSQL")
        self.db.execute(sql,{"deviceId":"strap","fromTs":100,"toTs":100})
        self.assertEqual(self.db.execute("SELECT changes()").fetchone()[0],1)
        self.db.execute(sql,{"deviceId":"strap","fromTs":100,"toTs":100})
        self.assertEqual(self.db.execute("SELECT changes()").fetchone()[0],0)
        self.assertIsNone(self.db.execute("SELECT tsSuspect FROM rrInterval WHERE deviceId='other'").fetchone()[0])
    def test_migration_marks_existing_rows_and_preserves_previous_marks(self):
        self.rr(100,500,"whoop5_historical")
        self.rr(101,800,"whoop4_historical",suspect=1)
        self.db.execute("INSERT INTO hrSample VALUES ('strap',100,80)")
        self.db.execute(literal(QUALITY,"whoop5RrFillMigrationSQL"))
        self.assertEqual([r[0] for r in self.db.execute("SELECT tsSuspect FROM rrInterval ORDER BY ts")],[1,1])
    def test_forward_channel_translation_keeps_unlabelled_and_named_sources(self):
        self.db.execute("ALTER TABLE rrInterval ADD COLUMN srcChannel INTEGER")
        for channel in (8,9,10,99):
            self.rr(channel,800,"legacy")
            self.db.execute("UPDATE rrInterval SET srcChannel=? WHERE ts=?",(channel,channel))
        self.rr(20,810,"whoop5_historical")
        self.db.execute("UPDATE rrInterval SET srcChannel=8 WHERE ts=20")
        self.db.execute(literal(QUALITY,"whoop4LegacyChannelsSQL"))
        self.assertEqual([r[0] for r in self.db.execute("SELECT source FROM rrInterval ORDER BY ts")],
                         ["whoop4_historical","whoop4_realtime","whoop4_standard_2a37","whoop5_historical","legacy"])
    def test_hour_query_materializes_once_and_uses_device_time_index(self):
        plan="\n".join(str(r[3]) for r in self.db.execute("EXPLAIN QUERY PLAN "+scoring_query("whoop4"),
                                                      {"d":"strap","f":0,"t":10000,"lim":100}))
        self.assertIn("MATERIALIZE",plan)
        self.assertNotIn("CORRELATED",plan)
        self.assertIn("deviceId=?",plan)

    def fingerprint(self, start=100, end=200):
        path = POLICY.with_name("RRScoringFingerprint.swift")
        return [tuple(row) for row in self.db.execute(literal(path, "rrScoringFingerprintSQL"),
                                                     {"d":"strap","f":start,"t":end})]

    def test_rr_witness_changes_when_provenance_changes_without_row_count(self):
        self.rr(100,800,"whoop4_standard_2a37")
        before=self.fingerprint()
        self.db.execute("UPDATE rrInterval SET source='whoop4_historical'")
        self.assertNotEqual(before,self.fingerprint())

    def test_rr_witness_changes_for_quality_and_order_annotations(self):
        self.rr(100,800,"whoop4_historical")
        before=self.fingerprint()
        self.db.execute("UPDATE rrInterval SET tsSuspect=1")
        flagged=self.fingerprint()
        self.assertNotEqual(before,flagged)
        self.db.execute("UPDATE rrInterval SET sourceOrdinal=4")
        self.assertNotEqual(flagged,self.fingerprint())

    def test_rr_witness_includes_full_boundary_hour_and_scopes_owner(self):
        self.rr(100,800,"whoop4_standard_2a37")
        before=self.fingerprint()
        self.rr(50,810,"whoop4_historical",device="other")
        self.assertEqual(before,self.fingerprint())
        self.rr(50,810,"whoop4_historical")
        self.assertNotEqual(before,self.fingerprint())

    def test_rr_witness_changes_for_interior_insert_and_delete(self):
        self.rr(100,800,"whoop4_historical")
        self.rr(150,810,"whoop4_historical")
        before=self.fingerprint()
        self.rr(125,820,"whoop4_historical")
        self.assertNotEqual(before,self.fingerprint())
        self.db.execute("DELETE FROM rrInterval WHERE ts=125")
        self.assertEqual(before,self.fingerprint())

    def test_rr_witness_reads_one_device_time_range_without_correlated_scan(self):
        sql=literal(POLICY.with_name("RRScoringFingerprint.swift"),"rrScoringFingerprintSQL")
        plan="\n".join(r[3] for r in self.db.execute("EXPLAIN QUERY PLAN "+sql,{"d":"strap","f":100,"t":200}))
        self.assertIn("deviceId=?",plan)
        self.assertNotIn("CORRELATED",plan)

if __name__=="__main__":
    unittest.main()
