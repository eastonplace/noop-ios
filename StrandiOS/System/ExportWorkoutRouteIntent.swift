#if os(iOS)
import Foundation
import AppIntents
import UniformTypeIdentifiers
import WorkoutRouteExport

enum RouteExportFormatChoice: String, AppEnum, CaseIterable {
    case gpx, fit

    static let typeDisplayRepresentation = TypeDisplayRepresentation(name: "Route Format")
    static let caseDisplayRepresentations: [RouteExportFormatChoice: DisplayRepresentation] = [
        .gpx: DisplayRepresentation(title: "GPX"),
        .fit: DisplayRepresentation(title: "FIT", subtitle: "GPS route and distance; no heart-rate or calorie summary"),
    ]

    var exportFormat: RouteExportFormat { self == .gpx ? .gpx : .fit }
}

enum RouteExportIntentError: Swift.Error, CustomLocalizedStringResourceConvertible {
    case noExportableRoute

    var localizedStringResource: LocalizedStringResource {
        "NOOP has no saved route with timestamped GPS points to export. Older routes remain viewable in the app."
    }
}

/// Discoverable as an action in Shortcuts. NOOP already uses the ten AppShortcutsProvider slots;
/// this action does not remove an existing Siri phrase or exceed that limit.
struct ExportWorkoutRouteIntent: AppIntent {
    static let title: LocalizedStringResource = "Export Workout Route"
    static let description = IntentDescription(
        "Get the most recent saved route with timestamped GPS points as a GPX or FIT file. Only measured portions are exported. FIT includes GPS distance, without heart-rate or calorie summaries.")
    static let openAppWhenRun = false

    @Parameter(title: "Format", default: .gpx)
    var format: RouteExportFormatChoice

    static var parameterSummary: some ParameterSummary {
        Summary("Export the latest recorded route as \(\.$format)")
    }

    func perform() async throws -> some IntentResult & ReturnsValue<IntentFile> & ProvidesDialog {
        guard let newest = WorkoutRouteExportService.newestExportableRoute(from: RouteStore.loadMap()) else {
            throw RouteExportIntentError.noExportableRoute
        }
        let file = try WorkoutRouteExportService.file(format: format.exportFormat, route: newest.route,
                                                       startTs: newest.startTs, sport: newest.sport)
        let dialog: IntentDialog = format == .fit
            ? "Exported your latest timestamped route as FIT, without heart-rate or calorie summaries."
            : "Exported your latest timestamped route as GPX."
        return .result(value: IntentFile(data: file.data, filename: file.filename, type: .data), dialog: dialog)
    }
}
#endif
