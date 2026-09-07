import Foundation
import Testing
#if canImport(NOOP)
@testable import NOOP
#else
@testable import ExperiencePolicies
#endif

@Suite("Workout experience")
struct WorkoutExperiencePolicyTests {
    @Test(arguments: ["Treadmill run", "Treadmill walk", "Indoor cycle", "Row machine", "Pool swim", "Elliptical"])
    func indoorHasNoRoute(_ sport: String) {
        let id = UUID()
        #expect(WorkoutExperiencePolicy.kind(for: sport) == .indoorCardio)
        #expect(!WorkoutExperiencePolicy.hasLiveRoute(sport: sport, isRecording: true,
                                                      recordedSession: id, activeSession: id))
    }
    @Test func routeBelongsToThisSession() {
        let id = UUID()
        #expect(WorkoutExperiencePolicy.hasLiveRoute(sport: "Running", isRecording: true,
                                                     recordedSession: id, activeSession: id))
        #expect(!WorkoutExperiencePolicy.hasLiveRoute(sport: "Running", isRecording: true,
                                                      recordedSession: UUID(), activeSession: id))
        #expect(!WorkoutExperiencePolicy.hasLiveRoute(sport: "Running", isRecording: false,
                                                      recordedSession: id, activeSession: id))
    }
    @Test func activityNamesOnlyNormalizeForPresentation() {
        #expect(WorkoutExperiencePolicy.kind(for: "  BODYBUILDING\n") == .strength)
        #expect(WorkoutExperiencePolicy.kind(for: "Yoga") == .mobility)
        #expect(WorkoutExperiencePolicy.kind(for: "Cycling") == .outdoorRide)
        #expect(WorkoutExperiencePolicy.kind(for: "My own workout") == .timed)
    }
    @Test func elapsedIncludesHoursAndClampsInvalidInputs() {
        #expect(WorkoutExperiencePolicy.elapsed(3661) == "1:01:01")
        #expect(WorkoutExperiencePolicy.elapsed(-2) == "0:00")
        #expect(WorkoutExperiencePolicy.elapsed(.infinity) == "0:00")
        #expect(WorkoutExperiencePolicy.positive(.nan) == nil)
    }
    @Test func paceUnitsMatchTheActivity() {
        let run = WorkoutExperiencePolicy.rate(sport: "Running", meters: 1000, seconds: 300, imperial: false)
        #expect(run == WorkoutMetricText(value: "5:00", unit: "/km", label: "Average pace"))
        let swim = WorkoutExperiencePolicy.rate(sport: "Open-water swim", meters: 1000, seconds: 1200, imperial: false)
        #expect(swim?.value == "2:00")
        #expect(swim?.unit == "/100 m")
        let ride = WorkoutExperiencePolicy.rate(sport: "Cycling", meters: 20000, seconds: 3600, imperial: false)
        #expect(ride?.value == "20.0")
        #expect(ride?.unit == "km/h")
        #expect(WorkoutExperiencePolicy.rate(sport: "Running", meters: 0, seconds: 300, imperial: false) == nil)
    }
    @Test func chartKeepsTimestampsAndGaps() {
        let p = projection([(0, 80), (10, 90), (500, 120), (510, 100)], gap: 60)
        #expect(p.points.map(\.sample.time) == [0, 10, 500, 510].map(date))
        #expect(p.points.map(\.segment) == [0, 0, 1, 1])
        #expect(p.gapCount == 1)
        #expect(p.nearest(to: date(250)) == nil)
        #expect(p.nearest(to: date(8))?.bpm == 90)
    }
    @Test func chartRejectsInvalidAndResolvesDuplicateSeconds() {
        let p = projection([(2, 80), (0, .nan), (2, 91), (3, 500), (5, 100)])
        #expect(p.readings.count == 2)
        #expect(p.readings.first?.bpm == 91)
        #expect(p.readings.last?.time == date(5))
    }
    @Test func chartIsBoundedAndKeepsExtrema() {
        var readings = (0..<10000).map { WorkoutChartSample(time: date($0), bpm: Double(80 + $0 % 40)) }
        readings[4321] = .init(time: date(4321), bpm: 230)
        readings[6789] = .init(time: date(6789), bpm: 35)
        let p = WorkoutChartProjection(samples: readings, start: date(0), end: date(10000), maximumPoints: 480)
        #expect(p.points.count <= 480)
        #expect(p.points.first?.sample == readings.first)
        #expect(p.points.last?.sample == readings.last)
        #expect(p.points.contains { $0.sample.bpm == 230 })
        #expect(p.points.contains { $0.sample.bpm == 35 })
    }
    @Test func emptyAndSingleSampleHaveSafeDomains() {
        let empty = projection([])
        #expect(empty.bpmRange.lowerBound < empty.bpmRange.upperBound)
        #expect(empty.timeRange.lowerBound < empty.timeRange.upperBound)
        let one = projection([(1, 90)])
        #expect(one.points.count == 1)
        #expect(one.bpmRange.contains(90))
    }
    @Test func badZoneDataStaysAbsent() {
        #expect(WorkoutExperiencePolicy.validZones([1, 2]) == nil)
        #expect(WorkoutExperiencePolicy.validZones([0, 0, 0, 0, 0]) == nil)
        #expect(WorkoutExperiencePolicy.validZones([1, 2, .nan, 4, 5]) == nil)
        #expect(WorkoutExperiencePolicy.validZones([1, 2, 3, 4, 5]) != nil)
    }
    private func date(_ second: Int) -> Date { Date(timeIntervalSince1970: TimeInterval(1000 + second)) }
    private func projection(_ pairs: [(Int, Double)], gap: TimeInterval = 120) -> WorkoutChartProjection {
        WorkoutChartProjection(samples: pairs.map { .init(time: date($0.0), bpm: $0.1) },
                               start: date(0), end: date(1000), gapThreshold: gap)
    }
}
