import Foundation

/// Experimental classification of WHOOP 5.0 historical-v18 byte 82.
///
/// RyanBR NOOP v9.1 carries this byte as a contested, decompile-supported SpO₂ candidate. Cross-device
/// evidence remains split. NOOP iOS therefore keeps it separate from the canonical blood-oxygen metric and
/// may surface it only as an explicitly labelled experimental reading. It must never populate `spo2Pct`,
/// HealthKit, Recovery, illness detection, or any unqualified medical/health claim.
public enum Whoop5V18SpO2Candidate: Equatable, Sendable {
    case absent
    case percentage(Int)
    case saturationSentinel(UInt8)
    case diagnosticCode(UInt8)

    public static let frameOffset = 82

    /// Marker carried in the existing raw SpO₂ stream's IR slot for a compact experimental percentage row.
    /// Real WHOOP 4 red/IR ADC rows are non-negative channel pairs, so this impossible negative value keeps
    /// the two representations unambiguous without changing the durable schema. The canonical `spo2Pct`
    /// column remains untouched.
    public static let persistedMarkerIR = -82

    public static func decode(frame: [UInt8]) -> Self? {
        guard frame.indices.contains(frameOffset) else { return nil }
        return decode(raw: frame[frameOffset])
    }

    public static func decode(raw: UInt8) -> Self {
        switch raw {
        case 0:
            return .absent
        case 70...100:
            return .percentage(Int(raw))
        case _ where raw & 0x80 != 0:
            return .saturationSentinel(raw)
        default:
            return .diagnosticCode(raw)
        }
    }

    /// Convenience for correlation and experimental presentation. Sentinels and diagnostic codes stay nil.
    public var candidatePercentage: Int? {
        guard case .percentage(let value) = self else { return nil }
        return value
    }

    /// Build the compact row used by the local-only experimental pipeline. Values are accepted only while
    /// the same v18 record reports the band asleep. The caller supplies a minute-bucket timestamp so the
    /// one-second stream cannot grow the database by tens of thousands of rows per night.
    public static func experimentalSample(
        minuteTimestamp: Int,
        raw: UInt8,
        sleepState: Int?
    ) -> SpO2Sample? {
        guard minuteTimestamp > 0,
              sleepState == 2,
              let percentage = decode(raw: raw).candidatePercentage
        else { return nil }
        return SpO2Sample(
            ts: minuteTimestamp,
            red: percentage,
            ir: persistedMarkerIR,
            unit: "experimental_pct"
        )
    }

    /// Recover the experimental percentage from the durable daily red/IR pair. This deliberately rejects
    /// ordinary raw ADC rows and any malformed/out-of-band value.
    public static func persistedPercentage(red: Int?, ir: Int?) -> Double? {
        guard ir == persistedMarkerIR,
              let red,
              (70...100).contains(red)
        else { return nil }
        return Double(red)
    }
}
