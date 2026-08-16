import Foundation

/// The data coverage a Stress surface can honestly present.
///
/// This is shared by the detail screen and the Today module so a daily baseline and a
/// same-day signal cannot drift into different labels or empty-state behavior.
public enum StressPresentationMode: Equatable, Sendable {
    case combined
    case intradayOnly
    case dailyOnly
    case baselineCalibration
    case empty

    public var hasLoadedContent: Bool {
        switch self {
        case .combined, .intradayOnly, .dailyOnly:
            return true
        case .baselineCalibration, .empty:
            return false
        }
    }

    public var lacksSameDaySignal: Bool {
        self == .dailyOnly
    }
}
