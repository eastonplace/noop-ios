import Foundation

/// Minimal FIT activity writer using standard FIT 2.0 message definitions, little-endian fields,
/// a 14-byte header and both CRCs. Field IDs/scales follow Garmin's public FIT profile.
/// See https://developer.garmin.com/fit/articles/file-types/activity.html.
enum FITRouteEncoder {
    static let epochOffsetSeconds: Int64 = 631_065_600 // 1989-12-31 00:00:00 UTC

    private struct Field {
        let number: UInt8
        let size: UInt8
        let type: UInt8
        init(_ number: UInt8, _ size: UInt8, _ type: UInt8) {
            self.number = number; self.size = size; self.type = type
        }
    }

    static func encode(segments: [[RecordedRoutePoint]], sport: String) throws -> Data {
        let first = segments[0][0]
        let last = segments[segments.count - 1].last!
        let start = try timestamp(first.timestampMs)
        let end = try timestamp(last.timestampMs)
        let elapsed = try unsigned(Double(last.timestampMs - first.timestampMs))
        let timer = try unsigned(segments.reduce(0.0) {
            $0 + Double($1.last!.timestampMs - $1.first!.timestampMs)
        })
        let distance = try unsigned(RouteExporter.distanceMeters(in: segments) * 100)
        let sportID = sportNumber(sport)
        var payload = Data()

        // file_id (0): development manufacturer 255 is the profile's unassigned/development ID.
        definition(0, global: 0, fields: [Field(0, 1, 0), Field(1, 2, 0x84),
            Field(4, 4, 0x86), Field(8, 5, 7)], into: &payload)
        payload.append(0); payload.append(4); payload.little(UInt16(255)); payload.little(start)
        payload.append(contentsOf: [78, 79, 79, 80, 0]) // NOOP, zero-terminated

        // device_info (23): identify the creator without inventing a hardware serial or product ID.
        definition(6, global: 23, fields: [Field(253, 4, 0x86), Field(0, 1, 2),
            Field(2, 2, 0x84), Field(27, 5, 7)], into: &payload)
        payload.append(6); payload.little(start); payload.append(0); payload.little(UInt16(255))
        payload.append(contentsOf: [78, 79, 79, 80, 0])

        definition(1, global: 20, fields: [Field(253, 4, 0x86), Field(0, 4, 0x85),
            Field(1, 4, 0x85), Field(5, 4, 0x86), Field(31, 1, 2)], into: &payload)
        definition(2, global: 21, fields: [Field(253, 4, 0x86), Field(0, 1, 0),
            Field(1, 1, 0), Field(4, 1, 2)], into: &payload)

        var cumulativeDistance = 0.0
        for segment in segments {
            // Each segment starts/stops the timer. No distance is added across a pause/recovery gap.
            event(timestamp: try timestamp(segment[0].timestampMs), type: 0, into: &payload)
            var previous: RecordedRoutePoint?
            for point in segment {
                if let previous { cumulativeDistance += RouteExporter.distance(previous, point) }
                payload.append(1)
                payload.little(try timestamp(point.timestampMs))
                payload.little(semicircles(point.latitude))
                payload.little(semicircles(point.longitude))
                payload.little(try unsigned(cumulativeDistance * 100))
                if let accuracy = point.horizontalAccuracyM, accuracy.rounded() < 255 {
                    payload.append(UInt8(accuracy.rounded()))
                } else {
                    payload.append(0xFF) // Missing/unrepresentable, never a fabricated zero.
                }
                previous = point
            }
            event(timestamp: try timestamp(segment.last!.timestampMs), type: 4, into: &payload)
        }

        // A single lap spans the GPS recording, including its pauses. Required summary fields match
        // the session; timer time excludes gaps while elapsed time retains them.
        definition(3, global: 19, fields: [Field(254, 2, 0x84), Field(253, 4, 0x86),
            Field(0, 1, 0), Field(1, 1, 0), Field(2, 4, 0x86), Field(7, 4, 0x86),
            Field(8, 4, 0x86), Field(9, 4, 0x86), Field(25, 1, 0)], into: &payload)
        payload.append(3); payload.little(UInt16(0)); payload.little(end)
        payload.append(9); payload.append(1); payload.little(start); payload.little(elapsed)
        payload.little(timer); payload.little(distance); payload.append(sportID)

        definition(4, global: 18, fields: [Field(254, 2, 0x84), Field(253, 4, 0x86),
            Field(0, 1, 0), Field(1, 1, 0), Field(2, 4, 0x86), Field(5, 1, 0),
            Field(7, 4, 0x86), Field(8, 4, 0x86), Field(9, 4, 0x86),
            Field(25, 2, 0x84), Field(26, 2, 0x84)], into: &payload)
        payload.append(4); payload.little(UInt16(0)); payload.little(end)
        payload.append(8); payload.append(1); payload.little(start); payload.append(sportID)
        payload.little(elapsed); payload.little(timer); payload.little(distance)
        payload.little(UInt16(0)); payload.little(UInt16(1))

        definition(5, global: 34, fields: [Field(253, 4, 0x86), Field(0, 4, 0x86),
            Field(1, 2, 0x84), Field(2, 1, 0), Field(3, 1, 0), Field(4, 1, 0)], into: &payload)
        payload.append(5); payload.little(end); payload.little(timer)
        payload.little(UInt16(1)); payload.append(0); payload.append(26); payload.append(1)

        guard payload.count < Int(UInt32.max) else { throw RouteExportError.fitValueOutOfRange }
        var file = Data([14, 0x20]) // Header length, FIT protocol 2.0.
        file.little(UInt16(2_100)) // Standard profile 21.00 fields only.
        file.little(UInt32(payload.count))
        file.append(contentsOf: [46, 70, 73, 84]) // .FIT
        file.little(crc(file))
        file.append(payload)
        file.little(crc(file))
        return file
    }

    private static func definition(_ local: UInt8, global: UInt16, fields: [Field], into data: inout Data) {
        data.append(0x40 | local); data.append(0); data.append(0) // Definition, reserved, LE architecture.
        data.little(global); data.append(UInt8(fields.count))
        for field in fields { data.append(field.number); data.append(field.size); data.append(field.type) }
    }

    private static func event(timestamp: UInt32, type: UInt8, into data: inout Data) {
        data.append(2); data.little(timestamp); data.append(0); data.append(type); data.append(0)
    }

    private static func timestamp(_ milliseconds: Int64) throws -> UInt32 {
        let seconds = milliseconds / 1_000 - epochOffsetSeconds
        guard seconds >= 0, seconds < Int64(UInt32.max) else { throw RouteExportError.fitValueOutOfRange }
        return UInt32(seconds)
    }

    private static func unsigned(_ scaled: Double) throws -> UInt32 {
        let value = scaled.rounded()
        guard value.isFinite, value >= 0, value < Double(UInt32.max) else {
            throw RouteExportError.fitValueOutOfRange
        }
        return UInt32(value)
    }

    private static func semicircles(_ degrees: Double) -> Int32 {
        let value = (degrees * (2_147_483_648.0 / 180)).rounded()
        // +180° and -180° are the same meridian. Avoid overflow and FIT's signed invalid sentinel.
        if value >= Double(Int32.max) { return Int32.min }
        return Int32(value)
    }

    private static func sportNumber(_ name: String) -> UInt8 {
        switch name.lowercased().trimmingCharacters(in: .whitespacesAndNewlines) {
        case "run", "running", "trail running": 1
        case "ride", "cycling", "biking", "mountain biking": 2
        case "walk", "walking": 11
        case "hike", "hiking": 17
        case "rowing": 15
        case "swimming", "open water swimming", "open-water swim": 5
        default: 0 // Generic, rather than claiming a sport that was not recorded.
        }
    }

    /// CRC-16/ARC, initial zero, reflected polynomial 0xA001, as specified by FIT.
    static func crc(_ data: Data) -> UInt16 {
        let table: [UInt16] = [0x0000, 0xCC01, 0xD801, 0x1400, 0xF001, 0x3C00, 0x2800, 0xE401,
                               0xA001, 0x6C00, 0x7800, 0xB401, 0x5000, 0x9C01, 0x8801, 0x4400]
        var result: UInt16 = 0
        for byte in data {
            result = (result >> 4) ^ table[Int((result ^ UInt16(byte)) & 0xF)]
            result = (result >> 4) ^ table[Int((result ^ UInt16(byte >> 4)) & 0xF)]
        }
        return result
    }
}

private extension Data {
    mutating func little<T: FixedWidthInteger>(_ value: T) {
        var value = value.littleEndian
        Swift.withUnsafeBytes(of: &value) { append(contentsOf: $0) }
    }
}
