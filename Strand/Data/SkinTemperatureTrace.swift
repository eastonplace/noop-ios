import Foundation

/// Privacy-safe provenance for one skin-temperature persistence or analysis step.
/// Device identifiers and raw values are intentionally excluded from exported trace lines.
struct SkinTemperatureTrace: Equatable, Sendable {
    enum Stage: String, Sendable {
        case persistence
        case analysis
    }

    enum Source: String, Sendable {
        case wearable
        case importFile
        case unknown
    }

    let stage: Stage
    let source: Source
    let family: String
    let day: String
    let queryFrom: Int
    let queryTo: Int
    let sampleCount: Int
    let firstTimestamp: Int?
    let lastTimestamp: Int?
    let persistenceOutcome: String?
    let insertedCount: Int?
    let conversionCount: Int?
    let isAvailable: Bool?

    var line: String {
        func value(_ value: Int?) -> String { value.map(String.init) ?? "none" }
        func value(_ value: Bool?) -> String { value.map(String.init) ?? "unknown" }

        return "skinTempTrace stage=\(stage.rawValue) source=\(source.rawValue) family=\(family) "
            + "day=\(day) queryFrom=\(queryFrom) queryTo=\(queryTo) samples=\(sampleCount) "
            + "firstTs=\(value(firstTimestamp)) lastTs=\(value(lastTimestamp)) "
            + "persistence=\(persistenceOutcome ?? "notApplicable") inserted=\(value(insertedCount)) "
            + "converted=\(value(conversionCount)) available=\(value(isAvailable))"
    }

    static func localDay(for timestamp: Int, timeZone: TimeZone = .autoupdatingCurrent) -> String {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        let components = calendar.dateComponents(
            [.year, .month, .day],
            from: Date(timeIntervalSince1970: TimeInterval(timestamp)))
        guard let year = components.year, let month = components.month, let day = components.day else {
            return "unknown"
        }
        return String(format: "%04d-%02d-%02d", year, month, day)
    }
}
