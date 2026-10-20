#!/usr/bin/env python3
"""Measure the shipped queries against deterministic synthetic overnight data."""
import json, pathlib, sqlite3, statistics, time
from test_rr_reconciliation_sql import RRReconciliationSQLTests, literal, POLICY

fixture=RRReconciliationSQLTests()
fixture.setUp()
db=fixture.db
start=1_700_006_400  # UTC hour boundary
rows=(( "strap", start+day*86400+sec, 800+(sec%9)+transport*100, 0,
        "whoop4_historical" if transport==0 else "whoop4_standard_2a37", 0, None)
      for day in range(21) for sec in range(8*3600) for transport in (0,1))
t=time.perf_counter()
db.executemany("INSERT INTO rrInterval VALUES (?,?,?,?,?,?,?)", rows)
db.commit()
load_seconds=time.perf_counter()-t
def measure(sql,args,repeats=3):
    times=[]; count=0
    for _ in range(repeats):
        begin=time.perf_counter()
        result=list(db.execute(sql,args))
        times.append(time.perf_counter()-begin);count=len(result)
    return {"median_seconds":statistics.median(times),"samples_seconds":times,"returned_rows":count}
end=start+20*86400+8*3600
hour_args={"d":"strap","f":start,"t":start+8*3600-1,"lim":200000}
all_args={"d":"strap","f":start,"t":end}
result={
  "sqlite_version":sqlite3.sqlite_version,"synthetic_rows":db.execute("SELECT COUNT(*) FROM rrInterval").fetchone()[0],
  "nights":21,"load_seconds":load_seconds,
  "one_night_scoring":measure(literal(POLICY,"whoop4ScoringSQL"),hour_args),
  "one_night_rr_witness":measure(literal(POLICY.with_name("RRScoringFingerprint.swift"),"rrScoringFingerprintSQL"),hour_args),
  "twenty_one_night_rr_witness":measure(literal(POLICY.with_name("RRScoringFingerprint.swift"),"rrScoringFingerprintSQL"),all_args),
  "one_night_query_plan":[r[3] for r in db.execute("EXPLAIN QUERY PLAN "+literal(POLICY,"whoop4ScoringSQL"),hour_args)],
  "limitations":"Synthetic Linux SQLite timings. Not an iPhone energy, disk, or migration benchmark."
}
print(json.dumps(result,indent=2))
fixture.tearDown()
