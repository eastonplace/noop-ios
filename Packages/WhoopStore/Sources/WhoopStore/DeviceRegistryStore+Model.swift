import Foundation
import GRDB

public extension DeviceRegistryStore {
    /// Correct a device model without rewriting identity, status, capabilities, or timestamps.
    func setModel(_ id: String, model: String) throws {
        let trimmed = model.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !id.isEmpty, !trimmed.isEmpty else { return }
        try dbQueue.write { db in
            try db.execute(
                sql: "UPDATE pairedDevice SET model = ? WHERE id = ?",
                arguments: [trimmed, id]
            )
        }
    }

    /// Repair only the legacy generation-less `model = "WHOOP"` seed. The predicate lives in the same
    /// transaction as the update, so a concurrent or later specific model can never be overwritten after the
    /// caller's earlier read. Returns true only when exactly one generic row was changed.
    @discardableResult
    func setModelIfGenericWhoop(_ id: String, model: String) throws -> Bool {
        let trimmedId = id.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedModel = model.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedId.isEmpty, !trimmedModel.isEmpty else { return false }
        return try dbQueue.write { db in
            try db.execute(
                sql: """
                    UPDATE pairedDevice
                    SET model = ?
                    WHERE id = ? AND lower(trim(model)) = 'whoop'
                    """,
                arguments: [trimmedModel, trimmedId]
            )
            return db.changesCount == 1
        }
    }
}
