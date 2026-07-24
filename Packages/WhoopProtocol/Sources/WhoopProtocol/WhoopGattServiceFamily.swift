import Foundation

/// WHOOP custom GATT service families visible in advertisements.
///
/// Only WHOOP 4.0 and the fd4b WHOOP 5.0/MG family are connectable. The other v9.1 service families
/// remain diagnostic-only until their framing is mapped and validated on owned hardware. No command,
/// CLIENT_HELLO, or characteristic write is provided for an unsupported family.
public enum WhoopGattServiceFamily: String, Sendable, CaseIterable {
    case whoop4
    case maverickGooseFD4B
    case puffin1150
    case monument
    case symphony

    public var displayName: String {
        switch self {
        case .whoop4: return "WHOOP 4.0"
        case .maverickGooseFD4B: return "WHOOP 5.0 / MG fd4b (Maverick/Goose)"
        case .puffin1150: return "WHOOP PUFFIN service 1150"
        case .monument: return "WHOOP MONUMENT"
        case .symphony: return "WHOOP SYMPHONY"
        }
    }

    public var serviceUUIDString: String {
        switch self {
        case .whoop4: return DeviceFamily.whoop4.serviceUUIDString
        case .maverickGooseFD4B: return DeviceFamily.whoop5.serviceUUIDString
        case .puffin1150: return "11500001-6215-11ee-8c99-0242ac120002"
        case .monument: return "8a580001-2fe8-4796-9267-b87a2b0c8234"
        case .symphony: return "59830001-5955-419b-bb8d-c8262926af23"
        }
    }

    public var characteristicUUIDStrings: [String] {
        switch self {
        case .whoop4: return DeviceFamily.whoop4.characteristicUUIDStrings
        case .maverickGooseFD4B: return DeviceFamily.whoop5.characteristicUUIDStrings
        case .puffin1150:
            return Self.unsupportedCharacteristics(
                prefix: "1150",
                suffix: "6215-11ee-8c99-0242ac120002"
            )
        case .monument:
            return Self.unsupportedCharacteristics(
                prefix: "8a58",
                suffix: "2fe8-4796-9267-b87a2b0c8234"
            )
        case .symphony:
            return Self.unsupportedCharacteristics(
                prefix: "5983",
                suffix: "5955-419b-bb8d-c8262926af23"
            )
        }
    }

    public var connectableDeviceFamily: DeviceFamily? {
        switch self {
        case .whoop4: return .whoop4
        case .maverickGooseFD4B: return .whoop5
        case .puffin1150, .monument, .symphony: return nil
        }
    }

    public var isConnectable: Bool { connectableDeviceFamily != nil }

    public var diagnosticUnsupportedMessage: String {
        "\(displayName) detected but unsupported; NOOP will not connect or send commands."
    }

    public static var unsupportedFamilies: [Self] {
        allCases.filter { !$0.isConnectable }
    }

    public static var unsupportedServiceUUIDStrings: [String] {
        unsupportedFamilies.map(\.serviceUUIDString)
    }

    public static func forServiceUUIDString(_ uuid: String?) -> Self? {
        guard let normalized = uuid?.lowercased() else { return nil }
        return allCases.first { $0.serviceUUIDString == normalized }
    }

    public static func firstUnsupported(in serviceUUIDStrings: [String]) -> Self? {
        serviceUUIDStrings
            .compactMap(forServiceUUIDString)
            .first { !$0.isConnectable }
    }

    private static func unsupportedCharacteristics(
        prefix: String,
        suffix: String
    ) -> [String] {
        ["0002", "0003", "0004", "0005", "0007"].map {
            "\(prefix)\($0)-\(suffix)"
        }
    }
}

public struct WhoopGattScanDecision: Equatable, Sendable {
    public let shouldConnect: Bool
    public let unsupportedFamily: WhoopGattServiceFamily?

    public init(
        shouldConnect: Bool,
        unsupportedFamily: WhoopGattServiceFamily? = nil
    ) {
        self.shouldConnect = shouldConnect
        self.unsupportedFamily = unsupportedFamily
    }
}

/// Decide whether an advertisement found by a broadened diagnostic scan may enter GATT.
///
/// Empty advertised-service lists preserve the existing connect path because some CoreBluetooth callbacks
/// omit service UUIDs even when the service-filtered scan matched. When UUIDs are present, only the selected
/// supported family connects; an unsupported family is returned solely for logging.
public func whoopGattScanDecision(
    selectedServiceUUIDString: String,
    advertisedServiceUUIDStrings: [String]
) -> WhoopGattScanDecision {
    let advertised = Set(advertisedServiceUUIDStrings.map { $0.lowercased() })
    if advertised.isEmpty || advertised.contains(selectedServiceUUIDString.lowercased()) {
        return WhoopGattScanDecision(shouldConnect: true)
    }
    return WhoopGattScanDecision(
        shouldConnect: false,
        unsupportedFamily: WhoopGattServiceFamily.firstUnsupported(in: Array(advertised))
    )
}
