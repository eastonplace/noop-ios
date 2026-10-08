import Foundation

/// Deep links the workout Live Activities carry back into the app. Lives in the shared folder so the app
/// (which parses them) and the widget extension (which attaches them with `widgetURL`) cannot drift apart.
///
///   noop://workout/active   the in-flight run
///   noop://lift/active      the in-flight lift
enum WorkoutDeepLink: Equatable, Sendable {
    case activeRun
    case activeLift

    static let scheme = "noop"

    var url: URL {
        switch self {
        case .activeRun: URL(string: "\(Self.scheme)://workout/active")!
        case .activeLift: URL(string: "\(Self.scheme)://lift/active")!
        }
    }

    init?(url: URL) {
        guard url.scheme?.lowercased() == Self.scheme, url.path == "/active" else { return nil }
        switch url.host?.lowercased() {
        case "workout": self = .activeRun
        case "lift": self = .activeLift
        default: return nil
        }
    }
}
