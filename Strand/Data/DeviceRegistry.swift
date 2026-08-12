import Foundation
import Combine
import NoopPhase34Core
import WhoopStore

enum DeviceRegistryMutationError: Error, Equatable {
    case readFailed
    case writeFailed
    case activeDeviceArchivedWithoutReplacement
}

// MARK: - DeviceRegistry
//
// Observable @MainActor cache over the synchronous `DeviceRegistryStore` (device-foundation
// Task 5). The UI observes this for the paired-device list + the currently active device; the
// app's `deviceId` is sourced from `activeDeviceId` so it's "the active device's id" rather than
// the hardcoded "my-whoop" literal. Behaviour is unchanged today — migration v15 seeds a single
// 'my-whoop' row as `.active`, so the active id is still "my-whoop".
//
// `DeviceRegistryStore` is synchronous (its own GRDB queue, internally serialized), so the reads
// here are plain synchronous calls; we keep failures non-fatal and fall back to the seeded defaults.
@MainActor
final class DeviceRegistry: ObservableObject {
    /// All paired devices (any status), oldest-added first — the store's `all()` ordering.
    @Published private(set) var devices: [PairedDevice] = []
    /// The active device's id. `nil` is a real state after archiving the active source without a replacement.
    @Published private(set) var activeDeviceId: String?

    private let store: DeviceRegistryStore

    init(store: DeviceRegistryStore) {
        self.store = store
    }

    /// Load the device list and active id from the store. A transition cannot continue on stale cached state.
    func reload() throws {
        let rows: [PairedDevice]
        do { rows = try store.all() }
        catch { throw DeviceRegistryMutationError.readFailed }
        devices = rows
        activeDeviceId = rows.first(where: { $0.status == .active })?.id
    }

    // MARK: - UI mutations (Devices screen)
    //
    // Each op delegates to the synchronous store, then `reload()`s so the published `devices` /
    // `activeDeviceId` reflect the change and the UI updates. Best-effort: a store failure leaves the
    // published state untouched (we never crash the UI on a write error).

    /// Add or upsert a paired device (the Add wizard's chosen strap). Refreshes the published list.
    func add(_ device: PairedDevice) throws {
        do { try store.add(device) }
        catch { throw DeviceRegistryMutationError.writeFailed }
        try reload()
    }

    /// Make `id` the single active device. The store demotes whatever was active in the same
    /// transaction (invariant I1); changing `activeDeviceId` drives the `SourceCoordinator` to run the
    /// right live source.
    func setActive(_ id: String) throws {
        do { try store.setActive(id) }
        catch { throw DeviceRegistryMutationError.writeFailed }
        try reload()
        guard activeDeviceId == id else { throw DeviceRegistryMutationError.writeFailed }
    }

    /// Rename a device. `name` nil/empty clears the nickname so it falls back to brand+model.
    func rename(_ id: String, to name: String?) throws {
        let trimmed = name?.trimmingCharacters(in: .whitespacesAndNewlines)
        do { try store.rename(id, nickname: (trimmed?.isEmpty == false) ? trimmed : nil) }
        catch { throw DeviceRegistryMutationError.writeFailed }
        try reload()
    }

    /// Adopt (or clear, when nil) the stable BLE identity for a device — the
    /// CBPeripheral.identifier.uuidString on iOS/Mac. Lets NOOP tell physical straps apart and map a
    /// connected peripheral back to its registry row. Refreshes the published list. Best-effort.
    @discardableResult
    func setPeripheralId(_ id: String, peripheralId: String?) throws -> Bool {
        let changed: Bool
        do { changed = try store.setPeripheralId(id, peripheralId: peripheralId) }
        catch { throw DeviceRegistryMutationError.writeFailed }
        try reload()
        return changed
    }

    /// Capture the complete durable scope before a physical peripheral replacement changes the lineage.
    func historicalCursorScope(for id: String) throws -> HistoricalCursorScope {
        do { return try store.historicalCursorScope(for: id) }
        catch { throw DeviceRegistryMutationError.readFailed }
    }

    /// Read the physical identity fence that belongs to the registry row. Repository context keys use
    /// this descriptor, not only the logical source id, so a same-id re-pair cannot reuse the old Today
    /// snapshot or admit a receipt under the wrong lineage.
    func sourceDescriptor(for id: String) throws -> RepositoryLiveSourceDescriptor {
        do {
            let lineage = try store.historyLineage(for: id) ?? "device:\(id)"
            let epoch = max(0, try store.historyCursorEpoch(for: id) ?? 0)
            return try RepositoryLiveSourceDescriptor(
                id: id,
                historyLineage: lineage,
                cursorEpoch: epoch)
        } catch {
            throw DeviceRegistryMutationError.readFailed
        }
    }

    /// Find the paired device that has adopted a given BLE peripheral, if any. A plain read of the
    /// store (no reload) — returns nil on any error or when no row has adopted that peripheral yet.
    func device(forPeripheralId peripheralId: String) throws -> PairedDevice? {
        do { return try store.device(forPeripheralId: peripheralId) }
        catch { throw DeviceRegistryMutationError.readFailed }
    }
}
