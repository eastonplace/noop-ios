import Foundation
import WhoopStore

/// Small, display-only projection used while the full repository refresh is still loading.
/// It is deliberately bounded so decoding it cannot become a launch-time history scan.
struct TodayStartupAnchor: Codable, Equatable, Sendable {
    static let schemaVersion = 1
    static let retainedDays = 21
    static let empty = TodayStartupAnchor(days: [], canonicalStrainV2: [],
                                          sleepPerformance: [], vitality: [])

    let version: Int
    let days: [DailyMetric]
    let canonicalStrainV2: [MetricPoint]
    let sleepPerformance: [MetricPoint]
    let vitality: [MetricPoint]

    init(days: [DailyMetric], canonicalStrainV2: [MetricPoint],
         sleepPerformance: [MetricPoint], vitality: [MetricPoint]) {
        version = Self.schemaVersion
        let scoreDays = (canonicalStrainV2 + sleepPerformance + vitality)
            .filter { $0.value.isFinite && (0 ... 100).contains($0.value) }
            .map(\.day)
        let normalizedDays = Self.normalizedDays(days, scoreDays: scoreDays)
        let retainedKeys = Set(normalizedDays.map(\.day))
        self.days = normalizedDays
        self.canonicalStrainV2 = Self.normalizedPoints(
            canonicalStrainV2, retainedKeys: retainedKeys, range: 0 ... 100)
        self.sleepPerformance = Self.normalizedPoints(
            sleepPerformance, retainedKeys: retainedKeys, range: 0 ... 100)
        self.vitality = Self.normalizedPoints(
            vitality, retainedKeys: retainedKeys, range: 0 ... 100)
    }

    func canonicalStrain(for day: String) -> Double? {
        canonicalStrainV2.last(where: { $0.day == day })?.value
    }

    func sleepPerformance(for day: String) -> Double? {
        sleepPerformance.last(where: { $0.day == day })?.value
    }

    func vitality(for day: String) -> Double? {
        vitality.last(where: { $0.day == day })?.value
    }

    private static func normalizedDays(_ rows: [DailyMetric], scoreDays: [String]) -> [DailyMetric] {
        var byDay = Dictionary(rows.map { ($0.day, $0) }, uniquingKeysWith: { _, last in last })
        for key in scoreDays where byDay[key] == nil {
            byDay[key] = DailyMetric(
                day: key, totalSleepMin: nil, efficiency: nil, deepMin: nil, remMin: nil,
                lightMin: nil, disturbances: nil, restingHr: nil, avgHrv: nil,
                recovery: nil, strain: nil, exerciseCount: nil)
        }
        return Array(byDay.values.sorted { $0.day < $1.day }.suffix(retainedDays))
    }

    private static func normalizedPoints(_ rows: [MetricPoint], retainedKeys: Set<String>,
                                         range: ClosedRange<Double>) -> [MetricPoint] {
        var byDay: [String: MetricPoint] = [:]
        for row in rows where retainedKeys.contains(row.day)
            && row.value.isFinite && range.contains(row.value) {
            byDay[row.day] = row
        }
        return byDay.values.sorted { $0.day < $1.day }
    }
}

struct TodayStartupAnchorStore {
    static let key = "today.startupHealthAnchor.v1"
    let defaults: UserDefaults

    func load() -> TodayStartupAnchor {
        guard let data = defaults.data(forKey: Self.key),
              let anchor = try? JSONDecoder().decode(TodayStartupAnchor.self, from: data),
              anchor.version == TodayStartupAnchor.schemaVersion else { return .empty }
        return anchor
    }

    func save(_ anchor: TodayStartupAnchor) {
        guard let data = try? JSONEncoder().encode(anchor) else { return }
        defaults.set(data, forKey: Self.key)
    }
}
