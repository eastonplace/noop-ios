import Foundation

/// Classification of a METADATA frame (packet type 49) for the historical-offload state machine.
public enum HistoricalMeta: Equatable {
    case start
    case end(unix: UInt32, trim: UInt32)
    case complete
    case other
}

/// Classify a parsed METADATA frame into the four cases the Backfiller needs.
///
/// Field mapping (verified against whoop_protocol.json + Schema.swift + PostHooks.swift):
/// - `p.parsed["meta_type"]` → `.string("HISTORY_START(1)"|"HISTORY_END(2)"|"HISTORY_COMPLETE(3)")`
///   Schema.enumName() appends "(rawValue)" to every enum lookup, so the strings have the form
///   "NAME(N)". We match by checking `hasPrefix` to be robust against raw-value changes.
///   (byte offset 6, u8, MetadataType enum, cat="meta" → stored in parsed dict by FieldBuilder)
/// - For HISTORY_END the metadata post-hook additionally stores in p.parsed:
///   `"unix"` → `.int(unix_seconds)` and `"trim_cursor"` → `.int(trim_value)`
/// BLE-2: classify a raw history frame, paying for a full `parseFrame` only when its type byte says it
/// is METADATA (type 49, or the 5/MG alias). Every other frame — the thousands of type-47 records of an
/// offload — is `.other` by definition, so skipping their parse is byte-identical to classifying the full
/// parse (`frameTypeName` mirrors `parseFrame`'s family split and type lookup exactly). `parse` is the
/// injection seam for counting tests.
public func classifyHistoricalMeta(
    frame: [UInt8],
    family: DeviceFamily,
    parse: ([UInt8], DeviceFamily) -> ParsedFrame = { parseFrame($0, family: $1) }
) -> HistoricalMeta {
    guard frameTypeName(frame, family: family) == "METADATA" else { return .other }
    return classifyHistoricalMeta(parse(frame, family))
}

public func classifyHistoricalMeta(_ p: ParsedFrame) -> HistoricalMeta {
    // Integrity gate: only act on a complete, fully checksum-verified envelope. A forged or truncated
    // END/COMPLETE must never advance the durable cursor or make the strap discard history.
    guard p.ok, p.envelopeOK, p.headerCRCOK == true, p.payloadCRCOK == true else { return .other }
    guard p.typeName == "METADATA" else { return .other }
    guard case .string(let metaName)? = p.parsed["meta_type"] else { return .other }
    // Schema.enumName() produces "NAME(rawValue)" — match by prefix so the classifier is
    // insulated from raw-value changes.
    if metaName.hasPrefix("HISTORY_START") {
        return .start
    } else if metaName.hasPrefix("HISTORY_COMPLETE") {
        return .complete
    } else if metaName.hasPrefix("HISTORY_END") {
        guard case .int(let unix)? = p.parsed["unix"],
              case .int(let trim)? = p.parsed["trim_cursor"]
        else { return .other }
        return .end(unix: UInt32(truncatingIfNeeded: unix), trim: UInt32(truncatingIfNeeded: trim))
    } else {
        return .other
    }
}
