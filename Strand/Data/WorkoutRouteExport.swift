import Foundation
import CoreTransferable
import UniformTypeIdentifiers
import WorkoutRouteExport

/// A system share item. The system asks for its data only when sharing; no permanent export copy is kept.
struct WorkoutRouteExportFile: Transferable, Sendable {
    let data: Data
    let filename: String

    static var transferRepresentation: some TransferRepresentation {
        DataRepresentation(exportedContentType: .data) { file in file.data }
            .suggestedFileName { $0.filename }
    }
}

/// Shared by workout detail and Shortcuts. Only saved, validated measurements can cross this boundary.
enum WorkoutRouteExportService {
    struct Resolved: Sendable {
        let startTs: Int
        let sport: String
        let route: WorkoutRoute
    }

    static func file(format: RouteExportFormat, route: WorkoutRoute,
                     startTs: Int, sport: String) throws -> WorkoutRouteExportFile {
        guard route.hasExportableMeasurements, let segments = route.pointSegments,
              let first = segments.first?.first,
              startTs > 0, Int64(startTs) <= first.timestampMs / 1_000 else {
            throw RouteExportError.noRecordedRoute
        }
        let data = try RouteExporter.render(format, segments: segments,
                                            name: "NOOP \(sport) route", sport: sport)
        return WorkoutRouteExportFile(data: data, filename: "noop-route-\(startTs).\(format.rawValue)")
    }

    static func newestExportableRoute(from map: [String: WorkoutRoute]) -> Resolved? {
        map.compactMap { key, route -> Resolved? in
            guard route.hasExportableMeasurements, let parsed = parseKey(key),
                  let first = route.pointSegments?.first?.first,
                  Int64(parsed.startTs) <= first.timestampMs / 1_000 else { return nil }
            return Resolved(startTs: parsed.startTs, sport: parsed.sport, route: route)
        }.sorted {
            $0.startTs == $1.startTs ? $0.sport < $1.sport : $0.startTs > $1.startTs
        }.first
    }

    static func parseKey(_ key: String) -> (startTs: Int, sport: String)? {
        let parts = key.split(separator: "|", maxSplits: 1, omittingEmptySubsequences: false)
        guard parts.count == 2, let startTs = Int(parts[0]), startTs > 0,
              !parts[1].trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
        return (startTs, String(parts[1]))
    }
}
