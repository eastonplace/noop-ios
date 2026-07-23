#!/usr/bin/env python3
from release_qa_patch_common import replace_once, regex_once, insert_before_last
import re

# ---------------------------------------------------------------------------
# Trends: nonfinite values must never reach means, ranges, charts, or snapshots.
# ---------------------------------------------------------------------------
trends_models = "Strand/Screens/TrendsSnapshotModels.swift"
replace_once(
    trends_models,
    '''        source = series\n        latest = series.last?.value\n        let currentMean = Self.mean(series)\n        let previousMean = Self.mean(previousSeries)\n        delta = currentMean.flatMap { current in previousMean.map { current - $0 } }\n        spark = TrendPointExtremaSampler.sample(series, maximumCount: 30)\n        currentCount = series.count\n        previousCount = previousSeries.count\n''',
    '''        let finiteSeries = series.filter {\n            $0.value.isFinite && $0.date.timeIntervalSinceReferenceDate.isFinite\n        }\n        let finitePreviousSeries = previousSeries.filter {\n            $0.value.isFinite && $0.date.timeIntervalSinceReferenceDate.isFinite\n        }\n        source = finiteSeries\n        latest = finiteSeries.last?.value\n        let currentMean = Self.mean(finiteSeries)\n        let previousMean = Self.mean(finitePreviousSeries)\n        delta = currentMean.flatMap { current in previousMean.map { current - $0 } }\n        spark = TrendPointExtremaSampler.sample(finiteSeries, maximumCount: 30)\n        currentCount = finiteSeries.count\n        previousCount = finitePreviousSeries.count\n''',
)
replace_once(
    trends_models,
    '''                guard let value = day.recovery, let date = date(day.day) else { return nil }\n''',
    '''                guard let value = day.recovery, value.isFinite,\n                      let date = date(day.day) else { return nil }\n''',
)
replace_once(
    trends_models,
    '''                guard let stored = day.strain, let date = date(day.day) else { return nil }\n                return TrendPoint(date: date, value: StrainScale.displayValue(fromStored: stored))\n''',
    '''                guard let stored = day.strain, stored.isFinite,\n                      let date = date(day.day) else { return nil }\n                let value = StrainScale.displayValue(fromStored: stored)\n                return value.isFinite ? TrendPoint(date: date, value: value) : nil\n''',
)
replace_once(
    trends_models,
    '''                guard let value = sleepByDay[day.day], let date = date(day.day) else { return nil }\n''',
    '''                guard let value = sleepByDay[day.day], value.isFinite,\n                      let date = date(day.day) else { return nil }\n''',
)
replace_once(
    trends_models,
    '''                guard let value = day.avgHrv, let date = date(day.day) else { return nil }\n''',
    '''                guard let value = day.avgHrv, value.isFinite,\n                      let date = date(day.day) else { return nil }\n''',
)
replace_once(
    trends_models,
    '''        switch metric {\n        case .recovery: day.recovery\n        case .strain: day.strain.map(StrainScale.displayValue(fromStored:))\n        case .sleepPerformance: data.sleepPerfByDay[day.day]\n        case .sleepDuration: day.totalSleepMin.map { $0 / 60 }\n        case .hrv: day.avgHrv\n        case .restingHR: day.restingHr.map(Double.init)\n        case .respiratory: day.respRateBpm\n        case .spo2: day.spo2Pct\n        case .skinTemp: day.skinTempDevC\n        case .steps: day.steps.map(Double.init) ?? data.appleByDay[day.day]?.steps.map(Double.init)\n        case .calories: day.activeKcalEst ?? data.appleByDay[day.day]?.activeKcal\n        case .stress: data.stressByDay[day.day]\n        }\n    }\n}\n''',
    '''        switch metric {\n        case .recovery: finite(day.recovery)\n        case .strain: finite(day.strain.map(StrainScale.displayValue(fromStored:)))\n        case .sleepPerformance: finite(data.sleepPerfByDay[day.day])\n        case .sleepDuration: finite(day.totalSleepMin.map { $0 / 60 })\n        case .hrv: finite(day.avgHrv)\n        case .restingHR: finite(day.restingHr.map(Double.init))\n        case .respiratory: finite(day.respRateBpm)\n        case .spo2: finite(day.spo2Pct)\n        case .skinTemp: finite(day.skinTempDevC)\n        case .steps:\n            finite(day.steps.map(Double.init) ?? data.appleByDay[day.day]?.steps.map(Double.init))\n        case .calories: finite(day.activeKcalEst ?? data.appleByDay[day.day]?.activeKcal)\n        case .stress: finite(data.stressByDay[day.day])\n        }\n    }\n\n    private static func finite(_ value: Double?) -> Double? {\n        value.flatMap { $0.isFinite ? $0 : nil }\n    }\n}\n''',
)

trends_test_insertion = r'''
    func testTrendSummaryDropsNonFiniteValuesBeforeMeansAndCounts() throws {
        let presentation = TrendSummaryPresentation(
            series: [
                TrendPoint(date: Date(timeIntervalSince1970: 1), value: .nan),
                TrendPoint(date: Date(timeIntervalSince1970: 2), value: 42),
                TrendPoint(date: Date(timeIntervalSince1970: 3), value: .infinity),
            ],
            previousSeries: [
                TrendPoint(date: Date(timeIntervalSince1970: 0), value: 40),
                TrendPoint(date: Date(timeIntervalSince1970: 1), value: -.infinity),
            ],
            goodDirection: .higher,
            expectedCount: 1
        )

        XCTAssertEqual(presentation.source.map(\.value), [42])
        XCTAssertEqual(presentation.currentCount, 1)
        XCTAssertEqual(presentation.previousCount, 1)
        XCTAssertEqual(presentation.latest, 42)
        XCTAssertEqual(try XCTUnwrap(presentation.delta), 2)
    }

    func testSnapshotDropsNonFiniteMetricValuesBeforeBuildingRanges() throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        let anchor = try XCTUnwrap(calendar.date(from: DateComponents(
            year: 2026, month: 7, day: 22
        )))
        let day = DailyMetric(
            day: "2026-07-22",
            totalSleepMin: 420,
            efficiency: 0.9,
            deepMin: 90,
            remMin: 110,
            lightMin: 200,
            disturbances: 6,
            restingHr: 52,
            avgHrv: .infinity,
            recovery: .nan,
            strain: 9,
            exerciseCount: 1
        )
        let loaded = TrendsLoadedData(
            revision: 9,
            anchorDay: day.day,
            timeZoneIdentifier: "UTC",
            canonicalDays: [day],
            sleepPerfByDay: [day.day: .infinity],
            stressByDay: [day.day: .nan],
            appleDays: []
        )
        let snapshot = try XCTUnwrap(TrendsScreenSnapshot.build(
            key: key(revision: 9),
            data: loaded,
            metric: .recovery,
            range: .week,
            weekOffset: 0,
            referenceDate: anchor,
            calendar: calendar,
            effortDisplayFactor: 1
        ))

        XCTAssertTrue(snapshot.selectedPoints.isEmpty)
        XCTAssertTrue(snapshot.currentSeries.recovery.isEmpty)
        XCTAssertTrue(snapshot.currentSeries.hrv.isEmpty)
        XCTAssertTrue(snapshot.baseline.isFinite)
        XCTAssertTrue(snapshot.typical.lowerBound.isFinite)
        XCTAssertTrue(snapshot.typical.upperBound.isFinite)
    }

'''
insert_before_last("StrandiOSTests/TrendsSnapshotTests.swift", "}\n", trends_test_insertion)
replace_once(
    "Tools/qa/trends_snapshot_contract_audit.py",
    '''        "guard accepts(snapshotKey: snapshot?.key, currentKey: key)",\n    )\n''',
    '''        "guard accepts(snapshotKey: snapshot?.key, currentKey: key)",\n        "$0.value.isFinite",\n        "private static func finite(_ value: Double?)",\n    )\n''',
)
replace_once(
    "Tools/qa/trends_snapshot_contract_audit.py",
    '''        "testFourThousandDaySnapshotKeepsRenderInputsBounded",\n    )\n''',
    '''        "testFourThousandDaySnapshotKeepsRenderInputsBounded",\n        "testTrendSummaryDropsNonFiniteValuesBeforeMeansAndCounts",\n        "testSnapshotDropsNonFiniteMetricValuesBeforeBuildingRanges",\n    )\n''',
)

print("Applied Trends QA fixes")
