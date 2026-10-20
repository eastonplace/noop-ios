import Foundation
import XCTest
@testable import NOOP

/// The sentences Strength Strain adds or changes: exactly the wording the owner approved, and none of the old
/// "heart rate only" claims left behind. Every one is read through `StrainCopy`, the one place the views take it from.
@MainActor
final class StrainCopyTests: XCTestCase {

    // MARK: Workout detail

    func testWorkoutDetailSentences() {
        XCTAssertEqual(StrainCopy.liftSplit(heartRate: "10.0", combined: "15.1"),
                       "Heart rate only 10.0 → With your sets 15.1")
        XCTAssertEqual(StrainCopy.liftIncluded, "Includes your logged sets")
        XCTAssertEqual(StrainCopy.liftNoSets, "Log sets to count lifting")
        XCTAssertEqual(StrainCopy.liftNotScored, "Not scored yet · wear your strap during lifts")
        XCTAssertEqual(StrainCopy.liftScoring, "Scoring…")
        XCTAssertEqual(StrainCopy.liftImported, "Imported lifts only have totals, so this is heart rate only.")
        XCTAssertEqual(StrainCopy.liftSpoken(combined: "15.1", heartRate: "10.0", add: "5.1"),
                       "Strain 15.1 of 21. Heart rate only 10.0. Your sets add 5.1.")
    }

    // MARK: Strain day detail

    func testTheCurveNamesLiftingOnlyWhenTheDayHasSome() {
        XCTAssertEqual(StrainCopy.curveReadoutCaption(isToday: true, lifting: true), "Heart rate + lifting so far")
        XCTAssertEqual(StrainCopy.curveReadoutCaption(isToday: false, lifting: true), "Heart rate + lifting that day")
        XCTAssertEqual(StrainCopy.curveReadoutCaption(isToday: true, lifting: false), "Cardio load so far")
        XCTAssertEqual(StrainCopy.curveReadoutCaption(isToday: false, lifting: false), "Cardio load that day")
        XCTAssertEqual(StrainCopy.curveSummary(start: "2.0", end: "9.5", time: "6:00 PM", lifting: true),
                       "Heart rate and lifting load through the day, from 2.0 to 9.5 by 6:00 PM.")
        XCTAssertEqual(StrainCopy.curveSummary(start: "2.0", end: "9.5", time: "6:00 PM", lifting: false),
                       "Cardio load through the day, from 2.0 to 9.5 by 6:00 PM.")
    }

    func testTheLiftingRowAndThePill() {
        XCTAssertEqual(StrainCopy.liftingRowLabel, "Lifting")
        XCTAssertEqual(StrainCopy.liftingRowDetail(add: "5.1"), "Logged working sets add 5.1")
        XCTAssertEqual(StrainCopy.liftingRowSpoken(label: "Lifting", add: "5.1"), "Lifting, adds 5.1")
        XCTAssertEqual(StrainCopy.decidesScore, "Decides score")
        XCTAssertNotEqual(StrainCopy.decidesScore, "Sets score", "a set is also a lifting set")
    }

    // MARK: Method, guide and explainers

    func testHowNoopWorksNamesBothLoads() {
        XCTAssertEqual(
            StrainCopy.strainMethod,
            "Heart-rate load in the Banister TRIMP family (time in each heart-rate zone, harder zones weighted more), plus a muscular load from the working sets you log: reps × weight, how hard each set was and how much muscle the lift uses. Both are added before the 0–21 curve.")
        XCTAssertEqual(StrainCopy.strainFamily, "HR ZONES + LOGGED SETS")
        XCTAssertNotEqual(StrainCopy.strainFamily, "BANISTER TRIMP / HR ZONES")
    }

    func testTheScoringGuideSaysWhatTheSetsAddAndWhatTheyDoNot() {
        let body = StrainCopy.scoringGuideStrainBody
        XCTAssertFalse(body.contains("muscular load is not yet included"))
        XCTAssertTrue(body.contains("Logged lifting sets add a muscular load"))
        XCTAssertTrue(body.contains("your RPE, 8 if you didn't pick one"))
        XCTAssertTrue(body.contains("measured against your body weight"))
        XCTAssertTrue(body.contains("Bodyweight moves count the share of your body you lift."))
        XCTAssertTrue(body.contains("Warm-ups don't count"))
        XCTAssertTrue(body.contains("imported lifts only have totals, so they stay heart rate only"))
        XCTAssertTrue(body.contains("Fitness Age and VO2max still use heart rate only."))
        XCTAssertTrue(body.hasSuffix("This is NOOP's own transparent score, not WHOOP's proprietary formula."))
        XCTAssertEqual(StrainCopy.scoringGuideStrainHeadline, "Strain: how hard did your heart and muscles work?")
    }

    func testTheIntelligenceExplainerCountsTheLoggedSets() {
        let text = StrainCopy.intelligenceExplainer(scaleMax: "21")
        XCTAssertTrue(text.contains("Strain is a 0-21 load from time in heart-rate zones, plus the working sets you log on lifting days."))
        XCTAssertFalse(text.contains("cardiovascular load from time in heart-rate zones"))
        XCTAssertTrue(text.contains("(~55%)"), "the percentages print as percentages, not as format escapes")
        XCTAssertTrue(StrainCopy.intelligenceExplainer(scaleMax: "100").contains("Strain is a 0-100 load"))
    }

    // MARK: Other places that called Strain heart rate only

    func testTheMetricCatalogAndTheReportNoLongerCallStrainHeartRateOnly() throws {
        let strain = try XCTUnwrap(MetricCatalog.all.first { $0.key == "strain" })
        XCTAssertEqual(strain.description, "Load for the day from heart rate plus the working sets you log, on a 0-21 scale.")
        XCTAssertEqual(strain.description, StrainCopy.metricStrainDescription)

        let sleepNeed = try XCTUnwrap(MetricCatalog.all.first { $0.key == "noop_sleep_need_v2_min" })
        XCTAssertEqual(sleepNeed.description, StrainCopy.metricSleepNeedDescription)
        XCTAssertTrue(StrainCopy.metricSleepNeedDescription.contains("yesterday's heart-rate Strain"),
                      "Sleep Need still reads heart-rate Strain only")

        XCTAssertTrue(StrainCopy.trendsReportLegend.contains("Strain is a load from heart rate plus the working sets you log"))
        XCTAssertFalse(StrainCopy.trendsReportLegend.contains("cardiovascular load derived from heart rate"))
    }

    func testTheCoachPromptDescribesTheDailyLoadAsHeartRatePlusLoggedSets() {
        let prompt = AICoachEngine.defaultSystemPrompt
        XCTAssertTrue(prompt.contains("effort is the daily load score (heart rate plus the working sets the user logs in Strength)"))
        XCTAssertFalse(prompt.contains("cardiovascular load score"))
    }

    // MARK: Nothing old is left in the new copy

    func testNoNewStringKeepsTheOldHeartRateOnlyClaims() {
        let all = [
            StrainCopy.strainMethod, StrainCopy.strainFamily, StrainCopy.scoringGuideStrainHeadline,
            StrainCopy.scoringGuideStrainBody, StrainCopy.intelligenceExplainer(scaleMax: "21"),
            StrainCopy.metricStrainDescription, StrainCopy.metricSleepNeedDescription, StrainCopy.trendsReportLegend,
            AICoachEngine.defaultSystemPrompt,
        ]
        for text in all {
            XCTAssertFalse(text.contains("muscular load is not yet included"), text)
            XCTAssertFalse(text.contains("BANISTER TRIMP / HR ZONES"), text)
            XCTAssertFalse(text.contains("Sets score"), text)
        }
    }
}
