import Foundation

struct TrendsLoadIdentity: Equatable, Hashable, Sendable {
    let revision: Int
    let anchorDay: String
    let timeZoneIdentifier: String
    let rangeDays: Int
    let weekOffset: Int
}
