import Foundation

/// BLE-4: the two different "realtime" wants, kept apart.
///
/// `wantsRealtime` used to stand for both of them, so turning on Continuous HRV capture (which only needs
/// the lightweight TOGGLE_REALTIME_HR / 0x2A37 R-R stream) also made the keep-alive and the post-bond arm
/// re-send the heavy R10/R11 raw burst every 30 s, which the design scopes to a visible Live screen.
///
/// - `wantsHrToggle`: TOGGLE_REALTIME_HR [1] should be held armed. A Live screen OR continuous capture
///   (already window-gated by the caller) wants it.
/// - `wantsRawBurst`: SEND_R10_R11_REALTIME [1] should be (re-)sent. Only a Live screen wants it, and
///   never once the #80 marginal-radio fallback has tripped.
public struct RealtimeArmPolicy: Equatable, Sendable {
    public let wantsHrToggle: Bool
    public let wantsRawBurst: Bool

    public init(screenWantsRealtime: Bool, continuousCaptureWantsNow: Bool, standardHRFallback: Bool) {
        wantsHrToggle = screenWantsRealtime || continuousCaptureWantsNow
        wantsRawBurst = screenWantsRealtime && !standardHRFallback
    }
}

/// BLE-4: which live frames the Collector buffers. `extractStreams` turns only REALTIME_DATA, EVENT and
/// COMMAND_RESPONSE into rows, so every other live frame (chiefly the ~2/s type-43 R10/R11 raw stream)
/// contributes nothing decoded. Those are worth holding only while raw capture will persist them.
public enum LiveFrameRetention {
    /// The live packet types `extractStreams` decodes into rows. Keep in step with `extractStreams`.
    public static let decodedTypeNames: Set<String> = ["REALTIME_DATA", "EVENT", "COMMAND_RESPONSE"]

    public static func shouldBuffer(typeName: String, rawCaptureActive: Bool) -> Bool {
        rawCaptureActive || decodedTypeNames.contains(typeName)
    }
}

/// BLE-4: a strap EVENT means "I may have new data" and kicks a rate-limited sync, except the
/// BLE_REALTIME_HR_ON/OFF echo of our own realtime toggle, which fires on every arm and says nothing about
/// banked history.
public enum StrapEventSyncPolicy {
    public static func shouldTriggerSync(eventName: String) -> Bool {
        !eventName.hasPrefix("BLE_REALTIME_HR")
    }
}
