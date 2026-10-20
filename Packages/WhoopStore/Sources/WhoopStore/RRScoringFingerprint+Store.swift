extension WhoopStore {
    /// Read the R-R cache witness from one reader snapshot. Errors must bypass cache reuse.
    public nonisolated func rrScoringFingerprint(deviceId: String, from: Int, to: Int) async throws -> String {
        try await poolRead { db in
            try RRScoringFingerprint.read(db: db, deviceId: deviceId, from: from, to: to)
        }
    }
}
