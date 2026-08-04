// Verified external surfaces consume the single durable projection.

#if os(iOS)
import Foundation
import NoopPhase34Core

struct ExternalSurfaceProjection: Equatable {
    let contextId: String
    let deviceId: String
    let generation: Int64
    let logicalDayKey: String
    let recovery: Int?
    let effort: Double?
    let sleepScore: Int?

    static func recoveryValue(_ value: Double) -> Int? {
        guard value.isFinite, (0...100).contains(value),
              value.rounded() >= Double(Int.min), value.rounded() <= Double(Int.max)
        else { return nil }
        return Int(value.rounded())
    }

    static func effortValue(_ value: Double) -> Double? {
        value.isFinite ? value : nil
    }

    init(_ projection: VerifiedHealthProjection) {
        contextId = projection.contextId
        deviceId = projection.deviceId
        generation = projection.generation
        logicalDayKey = projection.logicalDay.key
        recovery = projection.visibleMetric(.recovery).flatMap { Self.recoveryValue($0.value) }
        effort = projection.visibleMetric(.strain).flatMap { Self.effortValue($0.value) }
        sleepScore = projection.visibleMetric(.sleepScore).flatMap { Int(exactly: $0.value.rounded()) }
    }
}
#endif
