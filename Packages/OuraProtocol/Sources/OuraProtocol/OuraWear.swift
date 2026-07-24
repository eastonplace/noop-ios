import Foundation

// OuraWear: infer whether the Oura ring is on a finger, on the charger, or idle from signals that are
// present in real captures. This is a read-only v9.1 protocol primitive; it does not invent a server-gated
// step or SpO₂ measurement.

/// The ring's wear / charge state for a live indicator.
public enum OuraWearState: String, Equatable, Sendable, Codable, CaseIterable {
    case worn
    case charging
    case off
    case unknown
}

public enum OuraWear {
    /// True when a STATE string reports the charger being connected.
    public static func isChargerStart(_ state: OuraState) -> Bool {
        let text = (state.text ?? "").lowercased()
        return (text.contains("chg") || text.contains("charg"))
            && (text.contains("detect") || text.contains("start"))
    }

    /// True when a STATE string reports the charger being disconnected.
    public static func isChargerStop(_ state: OuraState) -> Bool {
        let text = (state.text ?? "").lowercased()
        return (text.contains("chg") || text.contains("charg"))
            && (text.contains("stop") || text.contains("end")
                || text.contains("done") || text.contains("remov"))
    }
}

/// Pure live-state accumulator. Callers own watchdog timing and must feed only live-HR pulses—not banked
/// overnight IBI records, which describe past measurements and cannot prove the ring is currently worn.
public final class OuraWearTracker {
    public private(set) var current: OuraWearState = .unknown

    public init() {}

    public func note(state: OuraState) {
        if OuraWear.isChargerStart(state) {
            current = .charging
        } else if OuraWear.isChargerStop(state) {
            current = .off
        }
    }

    public func notePulse() { current = .worn }

    public func noteLivePulseTimeout() {
        if current == .worn { current = .off }
    }

    public func reset() { current = .unknown }
}
