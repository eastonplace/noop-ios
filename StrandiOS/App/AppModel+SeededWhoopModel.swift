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
        guard live.connected, let store = await repo.storeHandle() else { return }
        let registry = DeviceRegistryStore(dbQueue: store.registryWriter)
        guard let activeId = try? registry.activeDeviceId(),
              let active = try? registry.all().first(where: { $0.id == activeId }),
              let corrected = SeededWhoopModelResolver.correctedModel(
                current: active.model,
                whoop5Detected: whoop5Detected
              )
        else { return }
        do {
            try registry.setModel(activeId, model: corrected)
            deviceRegistry?.reload()
            live.append(log: "Device registry model corrected to \(corrected) after family detection.")
        } catch {
            live.append(log: "Device registry model correction deferred: \(error.localizedDescription)")
        }
    }
}
#endif
