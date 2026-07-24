#if os(iOS)
import Foundation
import WhoopStore

nonisolated enum SeededWhoopModelResolver {
    static func correctedModel(current: String, whoop5Detected: Bool) -> String? {
        guard current.trimmingCharacters(in: .whitespacesAndNewlines)
            .caseInsensitiveCompare("WHOOP") == .orderedSame
        else { return nil }
        return whoop5Detected ? "WHOOP 5.0 / MG" : "WHOOP 4.0"
    }
}

@MainActor
extension AppModel {
    /// Repair the generation-less device row seeded by older stores once the connected transport has
    /// positively selected a WHOOP family. This updates registry metadata only; it does not send a command,
    /// change the active device, or claim support beyond the already-connected path.
    func correctSeededWhoopModelIfNeeded() async {
        // Capture immutable evidence before the only suspension point. A reconnect, family rotation, or
        // disconnect while the store opens must not let a stale task label whichever row happens to be active
        // afterward. The post-await guard proves that the same physical link and family evidence still own it.
        guard live.connected, let expectedPeripheral = ble.connectedPeripheralUUID else { return }
        let expectedWhoop5 = whoop5Detected

        guard let store = await repo.storeHandle() else { return }
        guard live.connected,
              ble.connectedPeripheralUUID == expectedPeripheral,
              whoop5Detected == expectedWhoop5
        else {
            live.append(log: "Device registry model correction deferred because the WHOOP connection changed.")
            return
        }

        let registry = DeviceRegistryStore(dbQueue: store.registryWriter)
        guard let activeId = try? registry.activeDeviceId(),
              let active = try? registry.all().first(where: { $0.id == activeId }),
              let corrected = SeededWhoopModelResolver.correctedModel(
                current: active.model,
                whoop5Detected: expectedWhoop5
              )
        else { return }

        do {
            guard try registry.setModelIfGenericWhoop(activeId, model: corrected) else { return }
            deviceRegistry?.reload()
            live.append(log: "Device registry model corrected to \(corrected) after family detection.")
        } catch {
            live.append(log: "Device registry model correction deferred: \(error.localizedDescription)")
        }
    }
}
#endif
