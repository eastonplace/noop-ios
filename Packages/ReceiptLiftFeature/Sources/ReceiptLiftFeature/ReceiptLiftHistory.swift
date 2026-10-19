import Foundation

/// Read-only access to the lift history that is already stored in the app database.
///
/// The app database keeps the whole lift envelope as one blob. Strength Strain needs the completed sessions
/// as `ReceiptLiftWorkout`s without starting a coordinator, so this decodes the blob the same way
/// `ReceiptLiftDatabase.load()` does and maps it with the very same function the save path uses.
public enum ReceiptLiftHistory {
    /// Read-only and nonisolated. Decodes the stored envelope exactly like `ReceiptLiftDatabase.load`
    /// (`JSONDecoder`, `.iso8601`, `schemaVersion == LiftDataEnvelope.currentSchemaVersion`, otherwise throws)
    /// and returns the completed sessions mapped by `ReceiptLiftDatabase.workouts(_:)`.
    public static func completedWorkouts(fromStateData data: Data) throws -> [ReceiptLiftWorkout] {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let envelope = try decoder.decode(LiftDataEnvelope.self, from: data)
        guard envelope.schemaVersion == LiftDataEnvelope.currentSchemaVersion else {
            throw LiftPersistenceError.unsupportedSchema(envelope.schemaVersion)
        }
        return ReceiptLiftDatabase.workouts(envelope)
    }
}
