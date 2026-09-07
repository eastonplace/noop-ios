import Foundation

struct WorkoutMetricText: Equatable, Sendable {
    let value: String
    let unit: String
    let label: String
}

enum WorkoutExperienceKind: String, Sendable {
    case outdoorOnFoot, outdoorRide, outdoorSwim, outdoorRow
    case indoorCardio, strength, mobility, timed

    var supportsRoute: Bool {
        switch self {
        case .outdoorOnFoot, .outdoorRide, .outdoorSwim, .outdoorRow: true
        default: false
        }
    }
}

/// Presentation only. Stored sport names and recorder decisions remain unchanged.
enum WorkoutExperiencePolicy {
    static func kind(for sport: String) -> WorkoutExperienceKind {
        switch sport.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
        case "running", "walking", "hiking": .outdoorOnFoot
        case "cycling", "skiing", "snowboarding": .outdoorRide
        case "open-water swim": .outdoorSwim
        case "rowing": .outdoorRow
        case "treadmill run", "treadmill walk", "indoor cycle", "row machine", "pool swim", "elliptical": .indoorCardio
        case "strength", "bodybuilding", "weightlifting": .strength
        case "yoga", "pilates", "stretching": .mobility
        default: .timed
        }
    }

    static func symbol(for sport: String) -> String {
        switch sport.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
        case "walking", "treadmill walk": return "figure.walk"
        case "hiking": return "figure.hiking"
        case "treadmill run": return "figure.run"
        case "row machine": return "figure.rower"
        case "pool swim": return "figure.pool.swim"
        case "elliptical": return "figure.elliptical"
        case "skiing": return "figure.skiing.downhill"
        case "snowboarding": return "figure.snowboarding"
        default: break
        }
        return switch kind(for: sport) {
        case .outdoorOnFoot: "figure.run"
        case .outdoorRide: "figure.outdoor.cycle"
        case .outdoorSwim: "figure.open.water.swim"
        case .outdoorRow: "figure.rower"
        case .indoorCardio: "figure.indoor.cycle"
        case .strength: "dumbbell.fill"
        case .mobility: "figure.mind.and.body"
        case .timed: "figure.mixed.cardio"
        }
    }

    static func hasLiveRoute(sport: String, isRecording: Bool,
                             recordedSession: UUID?, activeSession: UUID) -> Bool {
        kind(for: sport).supportsRoute && isRecording && recordedSession == activeSession
    }

    static func positive(_ value: Double?) -> Double? {
        guard let value, value.isFinite, value > 0, value <= 1_000_000_000 else { return nil }
        return value
    }

    static func elapsed(_ seconds: TimeInterval) -> String {
        guard seconds.isFinite, seconds >= 0, seconds <= 1_000_000_000 else { return "0:00" }
        let total = Int(seconds)
        if total >= 3600 { return String(format: "%d:%02d:%02d", total / 3600, total / 60 % 60, total % 60) }
        return String(format: "%d:%02d", total / 60, total % 60)
    }

    static func distance(_ meters: Double?, imperial: Bool) -> WorkoutMetricText? {
        guard let meters = positive(meters) else { return nil }
        return WorkoutMetricText(value: String(format: "%.2f", meters / (imperial ? 1609.344 : 1000)),
                                 unit: imperial ? "mi" : "km", label: "Distance")
    }

    static func rate(sport: String, meters: Double?, seconds: Double?, imperial: Bool) -> WorkoutMetricText? {
        guard let meters = positive(meters), let seconds = positive(seconds) else { return nil }
        let name = sport.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let kind = name == "pool swim" ? .outdoorSwim : name == "row machine" ? .outdoorRow : kind(for: sport)
        if kind == .outdoorRide || sport.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() == "indoor cycle" {
            let speed = meters / seconds * (imperial ? 2.2369362921 : 3.6)
            guard speed.isFinite, speed <= 1000 else { return nil }
            return .init(value: String(format: "%.1f", speed), unit: imperial ? "mph" : "km/h", label: "Average speed")
        }
        let length: Double
        let unit: String
        switch kind {
        case .outdoorSwim:
            length = imperial ? 91.44 : 100
            unit = imperial ? "/100 yd" : "/100 m"
        case .outdoorRow:
            length = 500
            unit = "/500 m"
        default:
            length = imperial ? 1609.344 : 1000
            unit = imperial ? "/mi" : "/km"
        }
        let pace = seconds / meters * length
        guard pace.isFinite, pace > 0, pace < 360_000 else { return nil }
        return .init(value: elapsed(pace.rounded()), unit: unit, label: "Average pace")
    }

    static func validZones(_ values: [Double]?) -> [Double]? {
        guard let values, values.count == 5,
              values.allSatisfy({ $0.isFinite && $0 >= 0 }),
              values.reduce(0, +).isFinite, values.reduce(0, +) > 0 else { return nil }
        return values
    }
}

struct WorkoutChartSample: Equatable, Sendable, Identifiable {
    let time: Date
    let bpm: Double
    var id: Date { time }
}

struct WorkoutChartPoint: Equatable, Sendable, Identifiable {
    let sample: WorkoutChartSample
    let segment: Int
    var id: Date { sample.time }
}

/// Build once after a read, never on a drag gesture. A mark always represents an actual input sample.
/// A min/max envelope retains peaks, troughs and endpoints within a fixed rendering budget.
struct WorkoutChartProjection: Equatable, Sendable {
    let readings: [WorkoutChartSample]
    let points: [WorkoutChartPoint]
    let gapCount: Int
    let bpmRange: ClosedRange<Double>
    let timeRange: ClosedRange<Date>
    let gapThreshold: TimeInterval

    init(samples: [WorkoutChartSample], start: Date, end: Date,
         maximumPoints: Int = 480, gapThreshold: TimeInterval = 120) {
        let safeStart = start.timeIntervalSince1970.isFinite ? start : Date(timeIntervalSince1970: 0)
        let safeEnd = end.timeIntervalSince1970.isFinite && end > safeStart
            ? end : safeStart.addingTimeInterval(60)
        self.timeRange = safeStart...safeEnd
        self.gapThreshold = gapThreshold.isFinite ? max(1, gapThreshold) : 120
        var byTime: [Date: WorkoutChartSample] = [:]
        for sample in samples where sample.time.timeIntervalSince1970.isFinite
            && sample.time >= safeStart && sample.time <= safeEnd
            && sample.bpm.isFinite && (30...300).contains(sample.bpm) {
            byTime[sample.time] = sample
        }
        let sorted = byTime.values.sorted { $0.time < $1.time }
        self.readings = sorted
        let low = sorted.map(\.bpm).min() ?? 50
        let high = sorted.map(\.bpm).max() ?? 180
        self.bpmRange = max(0, low - 8)...max(low + 8, high + 8)

        var segment = 0
        var all: [WorkoutChartPoint] = []
        all.reserveCapacity(sorted.count)
        for (index, sample) in sorted.enumerated() {
            if index > 0, sample.time.timeIntervalSince(sorted[index - 1].time) > self.gapThreshold { segment += 1 }
            all.append(.init(sample: sample, segment: segment))
        }
        self.gapCount = segment
        let budget = min(2000, max(8, maximumPoints))
        guard all.count > budget else { self.points = all; return }
        let bucketCount = max(1, budget / 4)
        let bucketSize = Int(ceil(Double(all.count) / Double(bucketCount)))
        var selected: [Int] = []
        for first in stride(from: 0, to: all.count, by: bucketSize) {
            let last = min(all.count - 1, first + bucketSize - 1)
            var minimum = first, maximum = first
            for index in first...last {
                if all[index].sample.bpm < all[minimum].sample.bpm { minimum = index }
                if all[index].sample.bpm > all[maximum].sample.bpm { maximum = index }
            }
            selected.append(contentsOf: Set([first, minimum, maximum, last]).sorted())
        }
        self.points = selected.map { all[$0] }
    }

    /// Binary search on the full, sanitized input. Do not snap a crosshair across a recording gap.
    func nearest(to date: Date) -> WorkoutChartSample? {
        nearestIndex(to: date).map { readings[$0] }
    }

    func nearestIndex(to date: Date) -> Int? {
        guard !readings.isEmpty, date.timeIntervalSince1970.isFinite else { return nil }
        var low = 0, high = readings.count
        while low < high {
            let middle = low + (high - low) / 2
            if readings[middle].time < date { low = middle + 1 } else { high = middle }
        }
        let right = min(low, readings.count - 1)
        let left = max(0, low - 1)
        let index = abs(readings[left].time.timeIntervalSince(date)) <= abs(readings[right].time.timeIntervalSince(date))
            ? left : right
        let sample = readings[index]
        return abs(sample.time.timeIntervalSince(date)) <= gapThreshold / 2 ? index : nil
    }
}
