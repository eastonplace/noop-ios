import XCTest
@testable import WhoopProtocol

/// CORE-09: the reject-archive replay is keyed on `WhoopDecoderSchema.version`. This pins the schema's
/// historical layout table to that version: if the table changes, bump the version (so the archive is
/// replayed through the new decoder) and update the pin below. Layouts decoded in code (PostHooks /
/// HistoricalStreams mapped-raw versions) are not in the table, so a change there must bump it by hand.
final class WhoopDecoderSchemaTests: XCTestCase {

    /// The decodable layout versions per packet at `WhoopDecoderSchema.version == 1`.
    private let pinnedLayoutsAtVersion1: [String: [Int]] = ["HISTORICAL_DATA": [5, 7, 9, 12, 24]]

    func testLayoutTableMatchesTheDecoderSchemaVersion() {
        let schema = loadSchema()
        var layouts: [String: [Int]] = [:]
        for (name, spec) in schema.packets where !spec.versions.isEmpty {
            layouts[name] = spec.versions.keys.compactMap(Int.init)
                .filter { schema.resolvedVersion(packet: spec, $0) != nil }
                .sorted()
        }
        XCTAssertEqual(WhoopDecoderSchema.version, 1)
        XCTAssertEqual(layouts, pinnedLayoutsAtVersion1,
                       "the historical layout table changed: bump WhoopDecoderSchema.version and update this pin")
    }
}
