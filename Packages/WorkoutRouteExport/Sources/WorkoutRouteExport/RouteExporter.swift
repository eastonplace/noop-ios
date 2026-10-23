import Foundation

/// An actual accepted GPS fix. Timestamps are never interpolated from workout duration.
public struct RecordedRoutePoint: Codable, Equatable, Sendable {
    public let latitude: Double
    public let longitude: Double
    public let timestampMs: Int64
    public let horizontalAccuracyM: Double?

    public init(latitude: Double, longitude: Double, timestampMs: Int64,
                horizontalAccuracyM: Double? = nil) {
        self.latitude = latitude
        self.longitude = longitude
        self.timestampMs = timestampMs
        self.horizontalAccuracyM = horizontalAccuracyM
    }

    public var isValid: Bool {
        latitude.isFinite && longitude.isFinite
            && (-90...90).contains(latitude) && (-180...180).contains(longitude)
            && timestampMs > 0 && timestampMs <= 253_402_300_799_999
            && (horizontalAccuracyM.map { $0.isFinite && $0 >= 0 } ?? true)
    }
}

public enum RouteExportFormat: String, CaseIterable, Codable, Sendable {
    case gpx, fit
}

public enum RouteExportError: Error, Equatable, LocalizedError {
    case noRecordedRoute
    case invalidPoint
    case unorderedTimestamps
    case fitValueOutOfRange

    public var errorDescription: String? {
        switch self {
        case .noRecordedRoute:
            "This route has no recorded segment with at least two timestamped GPS points."
        case .invalidPoint:
            "This route contains an invalid GPS measurement and cannot be exported."
        case .unorderedTimestamps:
            "The recorded GPS timestamps are out of order. This route cannot be exported."
        case .fitValueOutOfRange:
            "This route exceeds the FIT format's date, duration, or distance limits. Try GPX."
        }
    }
}

/// Standards-based route-only exports. Segment boundaries survive pauses, lost signals, and restarts.
/// FIT summaries describe the measured GPS portions, not the entire workout or its physiology.
public enum RouteExporter {
    public static func render(_ format: RouteExportFormat, segments: [[RecordedRoutePoint]],
                              name: String, sport: String) throws -> Data {
        try validate(segments)
        switch format {
        case .gpx: return gpx(segments: segments, name: name, sport: sport)
        case .fit: return try FITRouteEncoder.encode(segments: segments, sport: sport)
        }
    }

    /// Validate the whole route before writing anything. Never silently join across a corrupt fix.
    public static func validate(_ segments: [[RecordedRoutePoint]]) throws {
        guard !segments.isEmpty, segments.allSatisfy({ !$0.isEmpty }),
              segments.contains(where: { $0.count >= 2 }) else {
            throw RouteExportError.noRecordedRoute
        }
        var previousTime: Int64?
        for segment in segments {
            for point in segment {
                guard point.isValid else { throw RouteExportError.invalidPoint }
                if let previousTime, point.timestampMs <= previousTime {
                    throw RouteExportError.unorderedTimestamps
                }
                previousTime = point.timestampMs
            }
        }
    }

    public static func distanceMeters(in segments: [[RecordedRoutePoint]]) -> Double {
        segments.reduce(0) { total, segment in
            total + zip(segment, segment.dropFirst()).reduce(0) { $0 + distance($1.0, $1.1) }
        }
    }

    static func distance(_ a: RecordedRoutePoint, _ b: RecordedRoutePoint) -> Double {
        let dLat = (b.latitude - a.latitude) * .pi / 180
        let dLon = (b.longitude - a.longitude) * .pi / 180
        let raw = pow(sin(dLat / 2), 2)
            + cos(a.latitude * .pi / 180) * cos(b.latitude * .pi / 180) * pow(sin(dLon / 2), 2)
        let h = min(1, max(0, raw))
        return 6_371_000 * 2 * atan2(sqrt(h), sqrt(1 - h))
    }

    private static func gpx(segments: [[RecordedRoutePoint]], name: String, sport: String) -> Data {
        let dateFormat = ISO8601DateFormatter()
        dateFormat.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        dateFormat.timeZone = TimeZone(secondsFromGMT: 0)
        func timestamp(_ milliseconds: Int64) -> String {
            dateFormat.string(from: Date(timeIntervalSince1970: Double(milliseconds) / 1_000))
        }
        var lines = [
            "<?xml version=\"1.0\" encoding=\"UTF-8\"?>",
            "<gpx version=\"1.1\" creator=\"NOOP\" xmlns=\"http://www.topografix.com/GPX/1/1\" xmlns:noop=\"https://noop.app/xmlschemas/route/1\">",
            "  <metadata><name>\(xml(name))</name><time>\(timestamp(segments[0][0].timestampMs))</time></metadata>",
            "  <trk><name>\(xml(name))</name><type>\(xml(sport))</type>",
        ]
        for segment in segments {
            lines.append("    <trkseg>")
            for point in segment {
                lines.append("      <trkpt lat=\"\(decimal(point.latitude, places: 8))\" lon=\"\(decimal(point.longitude, places: 8))\">")
                lines.append("        <time>\(timestamp(point.timestampMs))</time>")
                if let accuracy = point.horizontalAccuracyM {
                    // Accuracy is a radius in metres, not the dimensionless GPX hdop value.
                    lines.append("        <extensions><noop:horizontalAccuracyMeters>\(decimal(accuracy, places: 3))</noop:horizontalAccuracyMeters></extensions>")
                }
                lines.append("      </trkpt>")
            }
            lines.append("    </trkseg>")
        }
        lines.append("  </trk>")
        lines.append("</gpx>")
        return Data((lines.joined(separator: "\n") + "\n").utf8)
    }

    private static func decimal(_ value: Double, places: Int) -> String {
        String(format: "%.*f", locale: Locale(identifier: "en_US_POSIX"), places, value)
    }

    private static func xml(_ value: String) -> String {
        // XML 1.0 rejects control characters even when they are escaped.
        let scalars = value.unicodeScalars.filter {
            $0.value == 9 || $0.value == 10 || $0.value == 13
                || (0x20...0xD7FF).contains($0.value)
                || (0xE000...0xFFFD).contains($0.value)
                || (0x10000...0x10FFFF).contains($0.value)
        }
        return String(String.UnicodeScalarView(scalars))
            .replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
            .replacingOccurrences(of: "\"", with: "&quot;")
            .replacingOccurrences(of: "'", with: "&apos;")
    }
}
