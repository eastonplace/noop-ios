import Foundation

/// Admission for asynchronous connection events. A CoreBluetooth callback proves what happened to
/// its peripheral; it does not prove that the app still wants that peripheral as its active source.
/// Shared by WHOOP 4.0 and 5/MG without changing either family's sampling or recovery cadence.
public enum ConnectionIntentPolicy {
    public static func allowsSystemReconnect(intentionalDisconnect: Bool) -> Bool {
        !intentionalDisconnect
    }

    public static func acceptsConnectedPeripheral(
        callbackPeripheralID: UUID,
        requestedPeripheralID: UUID?,
        preferredPeripheralID: UUID?,
        intentionalDisconnect: Bool
    ) -> Bool {
        guard !intentionalDisconnect,
              callbackPeripheralID == requestedPeripheralID else { return false }
        return preferredPeripheralID == nil || preferredPeripheralID == callbackPeripheralID
    }

    public static func acceptsFailedConnection(
        callbackPeripheralID: UUID,
        requestedPeripheralID: UUID?,
        preferredPeripheralID: UUID?,
        intentionalDisconnect: Bool,
        requestedLinkState: ReconnectPolicy.LinkState
    ) -> Bool {
        guard acceptsConnectedPeripheral(
            callbackPeripheralID: callbackPeripheralID,
            requestedPeripheralID: requestedPeripheralID,
            preferredPeripheralID: preferredPeripheralID,
            intentionalDisconnect: intentionalDisconnect) else { return false }
        // A reused peripheral may already have a newer attempt or live connection. A delayed failure
        // must not clear that connection's characteristic ownership or advance its reconnect ladder.
        switch requestedLinkState {
        case .disconnected: return true
        case .none, .connecting, .connected, .disconnecting: return false
        }
    }

    public static func removalAffectsConnection(
        removedPeripheralID: UUID?,
        currentPeripheralID: UUID?,
        preferredPeripheralID: UUID?,
        isActiveDevice: Bool
    ) -> Bool {
        if isActiveDevice { return true }
        guard let removedPeripheralID else { return false }
        return removedPeripheralID == currentPeripheralID || removedPeripheralID == preferredPeripheralID
    }
}
