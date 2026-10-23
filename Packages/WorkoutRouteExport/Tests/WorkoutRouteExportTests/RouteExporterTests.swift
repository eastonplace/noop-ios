import Foundation
#if canImport(FoundationXML)
import FoundationXML
#endif
import XCTest
@testable import WorkoutRouteExport

final class RouteExporterTests: XCTestCase {
    private let start: Int64 = 1_735_689_600_123

    private func point(_ latitude: Double = 51.5, _ longitude: Double = -0.12,
                       at offset: Int64 = 0, accuracy: Double? = 4.5) -> RecordedRoutePoint {
        RecordedRoutePoint(latitude: latitude, longitude: longitude,
                           timestampMs: start + offset, horizontalAccuracyM: accuracy)
    }

    private var pausedRoute: [[RecordedRoutePoint]] {
        [[point(), point(51.5001, at: 10_000)],
         [point(52, 1, at: 120_000, accuracy: nil), point(52.0001, 1, at: 132_000)]]
    }

    func testGPXParsesAsXMLWithExactTimesAndSeparateSegments() throws {
        let data = try RouteExporter.render(.gpx, segments: pausedRoute,
            name: "Morning & <evening> \"run\"\u{1}", sport: "Running & walking")
        let document = GPXDocument()
        let parser = XMLParser(data: data)
        parser.delegate = document
        XCTAssertTrue(parser.parse(), "\(String(describing: parser.parserError))")
        XCTAssertEqual(document.segmentSizes, [2, 2])
        XCTAssertEqual(document.times, ["2025-01-01T00:00:00.123Z", "2025-01-01T00:00:10.123Z",
                                        "2025-01-01T00:02:00.123Z", "2025-01-01T00:02:12.123Z"])
        XCTAssertEqual(document.accuracies, ["4.500", "4.500", "4.500"])
        XCTAssertEqual(document.names, ["Morning & <evening> \"run\"", "Morning & <evening> \"run\""])
        XCTAssertEqual(document.coordinates.first?.0, "51.50000000")
        XCTAssertEqual(document.coordinates.first?.1, "-0.12000000")
        let text = String(decoding: data, as: UTF8.self)
        XCTAssertFalse(text.contains("<hdop>"), "Accuracy in metres is not dilution of precision")
        XCTAssertFalse(text.contains("<ele>"), "Elevation was never measured")
    }

    func testFITIndependentDecoderVerifiesDefinitionsAndBothCRCs() throws {
        let data = try RouteExporter.render(.fit, segments: pausedRoute, name: "Run", sport: "Running")
        let decoded = try FITDocument(data)
        XCTAssertEqual(decoded.messages.first?.number, 0)
        XCTAssertEqual(decoded.messages.filter { $0.number == 20 }.count, 4)
        XCTAssertEqual(decoded.messages.filter { $0.number == 19 }.count, 1)
        XCTAssertEqual(decoded.messages.filter { $0.number == 18 }.count, 1)
        XCTAssertEqual(decoded.messages.filter { $0.number == 34 }.count, 1)
        XCTAssertEqual(decoded.messages.first?.uint(0), 4, "Activity file")
        XCTAssertEqual(decoded.messages.first?.uint(1), 255, "No borrowed manufacturer identity")
        XCTAssertEqual(decoded.messages.first?.uint(4), UInt64(start / 1_000 - 631_065_600))

        var corrupt = data
        corrupt[corrupt.count - 5] ^= 0x01
        XCTAssertThrowsError(try FITDocument(corrupt))
        XCTAssertThrowsError(try FITDocument(data.dropLast()))
        if let output = ProcessInfo.processInfo.environment["NOOP_ROUTE_EXPORT_FIXTURE"] {
            try data.write(to: URL(fileURLWithPath: output))
        }
    }

    func testFITPauseEventsAndDistanceDoNotBridgeUnrecordedGap() throws {
        let decoded = try FITDocument(RouteExporter.render(.fit, segments: pausedRoute,
                                                           name: "Run", sport: "Running"))
        let records = decoded.messages.filter { $0.number == 20 }
        let events = decoded.messages.filter { $0.number == 21 }
        XCTAssertEqual(events.compactMap { $0.uint(1) }, [0, 4, 0, 4])
        XCTAssertEqual(events.compactMap { $0.uint(253) }, records.compactMap { $0.uint(253) })
        XCTAssertEqual(records[1].uint(5), records[2].uint(5), "The 55 km pause gap adds no distance")
        XCTAssertLessThan(try XCTUnwrap(records.last?.uint(5)), 3_000, "Only about 22 metres were recorded")
        XCTAssertEqual(records[2].uint(31), 255, "Missing accuracy uses FIT's invalid sentinel")
        let session = try XCTUnwrap(decoded.messages.first { $0.number == 18 })
        let lap = try XCTUnwrap(decoded.messages.first { $0.number == 19 })
        XCTAssertEqual(session.uint(7), 132_000, "Elapsed time retains the pause")
        XCTAssertEqual(session.uint(8), 22_000, "Timer time covers only the measured segments")
        XCTAssertEqual(session.uint(9), records.last?.uint(5))
        XCTAssertEqual(session.uint(5), 1, "Running sport enum")
        for field: UInt8 in [2, 7, 8, 9, 253] { XCTAssertEqual(lap.uint(field), session.uint(field)) }
        XCTAssertNil(session.fields[11], "Calories are not inferred")
        XCTAssertNil(session.fields[16], "Average heart rate is not inferred")
        XCTAssertNil(session.fields[17], "Maximum heart rate is not inferred")
    }

    func testFITRecognizesTheWorkoutCatalogOpenWaterSwimLabel() throws {
        let decoded = try FITDocument(RouteExporter.render(.fit, segments: pausedRoute,
                                                           name: "Swim", sport: "Open-water swim"))
        XCTAssertEqual(decoded.messages.first { $0.number == 18 }?.uint(5), 5)
        XCTAssertEqual(decoded.messages.first { $0.number == 19 }?.uint(25), 5)
    }

    func testFITSemicirclesRoundTripCoordinatesAndDatelineDoesNotOverflow() throws {
        let route = [[point(90, 180), point(-90, -180, at: 10_000)]]
        let decoded = try FITDocument(RouteExporter.render(.fit, segments: route, name: "Polar", sport: "Other"))
        let records = decoded.messages.filter { $0.number == 20 }
        XCTAssertEqual(records[0].signed32(0), 1_073_741_824)
        XCTAssertEqual(records[1].signed32(0), -1_073_741_824)
        XCTAssertEqual(records[0].signed32(1), Int32.min)
        XCTAssertEqual(records[1].signed32(1), Int32.min)
        let normal = try FITDocument(RouteExporter.render(.fit, segments: pausedRoute, name: "Run", sport: "Run"))
        let first = try XCTUnwrap(normal.messages.first { $0.number == 20 })
        XCTAssertEqual(Double(try XCTUnwrap(first.signed32(0))) * 180 / 2_147_483_648,
                       51.5, accuracy: 0.000_000_1)
    }

    func testCRCMatchesPublishedARCCheckVectorAndIndependentBitwiseCRC() {
        XCTAssertEqual(FITRouteEncoder.crc(Data("123456789".utf8)), 0xBB3D)
        let bytes = Data((0..<4_096).map { UInt8(truncatingIfNeeded: $0 * 29) })
        XCTAssertEqual(FITRouteEncoder.crc(bytes), FITDocument.crc(bytes))
    }

    func testRecordedPointCodableRoundTripRetainsMissingAccuracy() throws {
        let original = pausedRoute
        XCTAssertEqual(try JSONDecoder().decode([[RecordedRoutePoint]].self,
                         from: JSONEncoder().encode(original)), original)
    }

    func testEmptySinglePointAndDisconnectedSingletonsCannotBeExported() {
        for segments in [[], [[point()]], [[point()], [point(at: 10_000)]], [[], [point(), point(at: 10_000)]]] {
            for format in RouteExportFormat.allCases {
                XCTAssertThrowsError(try RouteExporter.render(format, segments: segments, name: "", sport: "")) {
                    XCTAssertEqual($0 as? RouteExportError, .noRecordedRoute)
                }
            }
        }
    }

    func testInvalidCoordinatesAccuracyAndTimestampAreRejectedBeforeEncoding() {
        let bad = [point(.nan), point(.infinity), point(91), point(0, -181),
                   point(accuracy: .nan), point(accuracy: .infinity), point(accuracy: -1),
                   RecordedRoutePoint(latitude: 1, longitude: 1, timestampMs: 0),
                   RecordedRoutePoint(latitude: 1, longitude: 1, timestampMs: Int64.max)]
        for invalid in bad {
            for format in RouteExportFormat.allCases {
                XCTAssertThrowsError(try RouteExporter.render(format, segments: [[invalid, point(at: 10_000)]],
                                                               name: "Run", sport: "Run")) {
                    XCTAssertEqual($0 as? RouteExportError, .invalidPoint)
                }
            }
        }
    }

    func testTimestampsMustIncreaseAcrossPointsAndSegmentBoundaries() {
        for segments in [[[point(), point()]], [[point(at: 10_000), point()]],
                         [[point(), point(at: 10_000)], [point(at: 5_000), point(at: 20_000)]]] {
            XCTAssertThrowsError(try RouteExporter.validate(segments)) {
                XCTAssertEqual($0 as? RouteExportError, .unorderedTimestamps)
            }
        }
    }

    func testFITDateAndDurationLimitsThrowWithoutClamping() throws {
        let old = [[RecordedRoutePoint(latitude: 1, longitude: 1, timestampMs: 315_532_800_000),
                    RecordedRoutePoint(latitude: 1, longitude: 1.1, timestampMs: 315_532_810_000)]]
        XCTAssertNoThrow(try RouteExporter.render(.gpx, segments: old, name: "Old", sport: "Run"))
        XCTAssertThrowsError(try RouteExporter.render(.fit, segments: old, name: "Old", sport: "Run")) {
            XCTAssertEqual($0 as? RouteExportError, .fitValueOutOfRange)
        }
        XCTAssertThrowsError(try RouteExporter.render(.fit,
            segments: [[point(), point(at: Int64(UInt32.max))]], name: "Long", sport: "Run")) {
            XCTAssertEqual($0 as? RouteExportError, .fitValueOutOfRange)
        }
    }
}

private final class GPXDocument: NSObject, XMLParserDelegate {
    var segmentSizes: [Int] = []
    var times: [String] = []
    var accuracies: [String] = []
    var names: [String] = []
    var coordinates: [(String, String)] = []
    private var path: [String] = []
    private var text = ""

    func parser(_ parser: XMLParser, didStartElement elementName: String, namespaceURI: String?,
                qualifiedName qName: String?, attributes attributeDict: [String: String]) {
        path.append(elementName); text = ""
        if elementName == "trkseg" { segmentSizes.append(0) }
        if elementName == "trkpt" {
            segmentSizes[segmentSizes.count - 1] += 1
            coordinates.append((attributeDict["lat"] ?? "", attributeDict["lon"] ?? ""))
        }
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) { text += string }

    func parser(_ parser: XMLParser, didEndElement elementName: String, namespaceURI: String?,
                qualifiedName qName: String?) {
        if elementName == "time", path.contains("trkpt") { times.append(text) }
        if elementName == "noop:horizontalAccuracyMeters" { accuracies.append(text) }
        if elementName == "name" { names.append(text) }
        _ = path.popLast(); text = ""
    }
}

/// Independent test decoder: parses definitions rather than duplicating the encoder's byte offsets,
/// and checks CRC with a different, bit-at-a-time algorithm.
private struct FITDocument {
    struct Message {
        let number: UInt16
        let fields: [UInt8: Data]
        func uint(_ field: UInt8) -> UInt64? {
            fields[field].map { bytes in bytes.enumerated().reduce(UInt64(0)) { $0 | UInt64($1.element) << ($1.offset * 8) } }
        }
        func signed32(_ field: UInt8) -> Int32? {
            uint(field).map { Int32(bitPattern: UInt32(truncatingIfNeeded: $0)) }
        }
    }
    enum ParseError: Error { case invalid }
    let messages: [Message]

    init(_ data: Data) throws {
        let bytes = Array(data)
        func uint(_ index: Int, _ size: Int) -> Int {
            (0..<size).reduce(0) { $0 | Int(bytes[index + $1]) << ($1 * 8) }
        }
        guard bytes.count >= 16, bytes[0] == 14, Array(bytes[8..<12]) == Array(".FIT".utf8),
              Self.crc(Data(bytes[0..<12])) == UInt16(uint(12, 2)),
              uint(4, 4) + 16 == bytes.count,
              Self.crc(Data(bytes.dropLast(2))) == UInt16(uint(bytes.count - 2, 2)) else { throw ParseError.invalid }
        var offset = 14
        let end = bytes.count - 2
        var definitions: [UInt8: (UInt16, [(UInt8, Int)])] = [:]
        var messages: [Message] = []
        while offset < end {
            let header = bytes[offset]; offset += 1
            guard header & 0x80 == 0 else { throw ParseError.invalid }
            let local = header & 0x0F
            if header & 0x40 != 0 {
                guard offset + 5 <= end, bytes[offset] == 0, bytes[offset + 1] == 0 else { throw ParseError.invalid }
                let number = UInt16(uint(offset + 2, 2))
                let count = Int(bytes[offset + 4]); offset += 5
                guard offset + count * 3 <= end else { throw ParseError.invalid }
                var fields: [(UInt8, Int)] = []
                for _ in 0..<count { fields.append((bytes[offset], Int(bytes[offset + 1]))); offset += 3 }
                definitions[local] = (number, fields)
            } else {
                guard let (number, definition) = definitions[local] else { throw ParseError.invalid }
                var fields: [UInt8: Data] = [:]
                for (number, size) in definition {
                    guard offset + size <= end else { throw ParseError.invalid }
                    fields[number] = Data(bytes[offset..<(offset + size)]); offset += size
                }
                messages.append(Message(number: number, fields: fields))
            }
        }
        guard offset == end else { throw ParseError.invalid }
        self.messages = messages
    }

    static func crc(_ data: Data) -> UInt16 {
        var checksum: UInt16 = 0
        for byte in data {
            checksum ^= UInt16(byte)
            for _ in 0..<8 { checksum = checksum & 1 != 0 ? (checksum >> 1) ^ 0xA001 : checksum >> 1 }
        }
        return checksum
    }
}
