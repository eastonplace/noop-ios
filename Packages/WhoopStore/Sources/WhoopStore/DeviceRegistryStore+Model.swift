import Foundation
import GRDB

public extension DeviceRegistryStore {
    /// Correct the generation label of an existing paired-device row without rewriting identity, status,
    /// capabilities, or timestamps. Used to repair the legacy seeded `model = "WHOOP"` row after the live
    /// transport has identified the connected family.
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
}
