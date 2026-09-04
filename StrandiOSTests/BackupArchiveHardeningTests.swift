import XCTest
import SQLite3
import ZIPFoundation
@testable import NOOP

final class BackupArchiveHardeningTests: XCTestCase {
    private var temporaryDirectory: URL!

    override func setUpWithError() throws {
        temporaryDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("noop-backup-hardening-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: temporaryDirectory,
                                                withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        if let temporaryDirectory {
            try? FileManager.default.removeItem(at: temporaryDirectory)
        }
    }

    func testFailedAtomicBackupWritePreservesExistingArchive() throws {
        let source = temporaryDirectory.appendingPathComponent("source.sqlite")
        try Data("new database".utf8).write(to: source)
        let destination = temporaryDirectory.appendingPathComponent("existing.noopbak")
        let original = Data("last known good backup".utf8)
        try original.write(to: destination)

        XCTAssertThrowsError(try DataBackup.writeBackupForTesting(
            databaseAt: source,
            to: destination,
            fault: .beforeInstall
        ))
        XCTAssertEqual(try Data(contentsOf: destination), original)
        XCTAssertFalse(
            try FileManager.default.contentsOfDirectory(atPath: temporaryDirectory.path)
                .contains { $0.hasSuffix(".tmp") }
        )
    }

    func testExportOutcomeWarnsOnlyAboveDatabaseRestoreCeiling() throws {
        let database = try makeValidDatabase()
        let destination = temporaryDirectory.appendingPathComponent("export.noopbak")
        try DataBackup.writeBackupForTesting(databaseAt: database, to: destination)
        let bytes = try XCTUnwrap(
            (try FileManager.default.attributesOfItem(atPath: database.path)[.size] as? NSNumber)?.uint64Value
        )

        var belowLimit = DataBackup.ArchiveRestoreLimits()
        belowLimit.maxDatabaseBytes = bytes + 1
        guard case .exported(let belowURL) = DataBackup.exportOutcomeForTesting(
            destination: destination, archiveAt: destination, limits: belowLimit
        ) else { return XCTFail("Database below the limit should export normally") }
        XCTAssertEqual(belowURL, destination)

        var aboveLimit = belowLimit
        aboveLimit.maxDatabaseBytes = bytes - 1
        guard case .exportedOversize(let warningURL, let measured, let limit) = DataBackup.exportOutcomeForTesting(
            destination: destination, archiveAt: destination, limits: aboveLimit
        ) else { return XCTFail("Database above the limit should return an oversize success") }
        XCTAssertEqual(warningURL, destination)
        XCTAssertEqual(measured, bytes)
        XCTAssertEqual(limit, bytes - 1)
        XCTAssertTrue(FileManager.default.fileExists(atPath: warningURL.path))
        XCTAssertTrue(DataBackup.isSuccessfulExport(.exported(warningURL)))
        XCTAssertTrue(DataBackup.isSuccessfulExport(.exportedOversize(warningURL, bytes: measured, limit: limit)))
    }

    func testExportOutcomeUsesWrittenArchiveAndFailsClosedWhenArchiveIsNotImportable() throws {
        let database = try makeValidDatabase()
        let archive = temporaryDirectory.appendingPathComponent("actual.noopbak")
        try DataBackup.writeBackupForTesting(databaseAt: database, to: archive)
        let writtenArchive = try Archive(url: archive, accessMode: .read)
        let archivedBytes = try XCTUnwrap(
            writtenArchive.first(where: { $0.path == "noop-backup.sqlite" })?.uncompressedSize
        )

        // Mutating the live source after export must not change classification of the written archive.
        let handle = try FileHandle(forWritingTo: database)
        try handle.seekToEnd()
        try handle.write(contentsOf: Data(repeating: 0, count: 8_192))
        try handle.close()
        var limits = DataBackup.ArchiveRestoreLimits()
        limits.maxDatabaseBytes = archivedBytes + 1
        guard case .exported = DataBackup.exportOutcomeForTesting(
            destination: archive, archiveAt: archive, limits: limits
        ) else { return XCTFail("classification must use the archive entry, not the live database") }

        limits.maxArchiveCompressedBytes = 1
        guard case .failure(let message) = DataBackup.exportOutcomeForTesting(
            destination: archive, archiveAt: archive, limits: limits
        ) else { return XCTFail("an archive import would reject must not report export success") }
        XCTAssertTrue(message.localizedCaseInsensitiveContains("cannot import"))
    }

    func testOversizeArchiveRequiresExplicitApprovalThenRestores() throws {
        let database = try makeValidDatabase()
        let archive = temporaryDirectory.appendingPathComponent("oversize.noopbak")
        try DataBackup.writeBackupForTesting(databaseAt: database, to: archive)
        let bytes = try XCTUnwrap(
            (try FileManager.default.attributesOfItem(atPath: database.path)[.size] as? NSNumber)?.uint64Value
        )
        var limits = DataBackup.ArchiveRestoreLimits()
        limits.maxDatabaseBytes = max(1, bytes - 3)
        limits.maxSettingsBytes = 1
        limits.maxTotalUncompressedBytes = bytes
        limits.maxExpansionRatio = 10_000
        XCTAssertGreaterThan(
            bytes - limits.maxDatabaseBytes,
            limits.maxSettingsBytes,
            "the override regression must exceed the old normal-limit-plus-settings sliver"
        )

        let refused = DataBackup.restore(
            from: archive,
            toDatabaseAt: temporaryDirectory.appendingPathComponent("refused.sqlite").path,
            limits: limits
        )
        guard case .restoreTooLarge(let name, let limit) = refused else {
            return XCTFail("Restore must stop at the database ceiling before approval")
        }
        XCTAssertEqual(name, "noop-backup.sqlite")
        XCTAssertEqual(limit, limits.maxDatabaseBytes)

        let destination = temporaryDirectory.appendingPathComponent("approved.sqlite")
        let approved = DataBackup.restore(
            from: archive,
            toDatabaseAt: destination.path,
            allowOversize: true,
            limits: limits
        )
        guard case .imported = approved else { return XCTFail("Approved oversize backup should restore") }
        XCTAssertTrue(FileManager.default.fileExists(atPath: destination.path))
    }

    func testDefaultApprovedRestoreCeilingIsSeparateFromNormalDatabaseLimit() {
        let limits = DataBackup.ArchiveRestoreLimits()
        XCTAssertGreaterThan(
            limits.maxTotalUncompressedBytes,
            limits.maxDatabaseBytes + limits.maxSettingsBytes
        )
    }

    func testOversizePlainDatabaseRequiresExplicitApprovalForSupportedLegacyExtensions() throws {
        let database = try makeValidDatabase()
        let bytes = try XCTUnwrap(
            (try FileManager.default.attributesOfItem(atPath: database.path)[.size] as? NSNumber)?.uint64Value
        )
        var limits = DataBackup.ArchiveRestoreLimits()
        limits.maxDatabaseBytes = max(1, bytes - 1)

        for fileExtension in ["sqlite", "database"] {
            let source = temporaryDirectory.appendingPathComponent("legacy-source.\(fileExtension)")
            try FileManager.default.copyItem(at: database, to: source)

            let refused = DataBackup.restore(
                from: source,
                toDatabaseAt: temporaryDirectory.appendingPathComponent("refused.\(fileExtension)").path,
                limits: limits
            )
            guard case .restoreTooLarge(let name, let limit) = refused else {
                return XCTFail("A plain .\(fileExtension) database above the ceiling must require approval")
            }
            XCTAssertEqual(name, source.lastPathComponent)
            XCTAssertEqual(limit, limits.maxDatabaseBytes)

            let destination = temporaryDirectory.appendingPathComponent("approved.\(fileExtension)")
            let approved = DataBackup.restore(
                from: source,
                toDatabaseAt: destination.path,
                allowOversize: true,
                limits: limits
            )
            guard case .imported = approved else {
                return XCTFail("An explicitly approved plain .\(fileExtension) database should restore")
            }
            XCTAssertTrue(FileManager.default.fileExists(atPath: destination.path))
        }
    }

    func testOversizeApprovalKeepsCompressionRatioGuard() throws {
        let archive = try makeArchive(entries: [
            ("noop-backup.sqlite", Data(repeating: 0, count: 64 * 1024), .deflate),
        ])
        var limits = DataBackup.ArchiveRestoreLimits()
        limits.maxDatabaseBytes = 1
        limits.maxTotalUncompressedBytes = 128 * 1024
        limits.maxExpansionRatio = 2
        let result = DataBackup.restore(
            from: archive,
            toDatabaseAt: temporaryDirectory.appendingPathComponent("ratio.sqlite").path,
            allowOversize: true,
            limits: limits
        )
        guard case .failure(let message) = result else {
            return XCTFail("Oversize approval must not disable expansion-ratio protection")
        }
        XCTAssertTrue(message.localizedCaseInsensitiveContains("suspicious compression ratio"))
    }

    func testOversizeApprovalDoesNotBypassAbsoluteTotalLimit() throws {
        let database = try makeValidDatabase()
        let bytes = try XCTUnwrap(
            (try FileManager.default.attributesOfItem(atPath: database.path)[.size] as? NSNumber)?.uint64Value
        )
        let archive = temporaryDirectory.appendingPathComponent("absolute-limit.noopbak")
        try DataBackup.writeBackupForTesting(databaseAt: database, to: archive)
        var limits = DataBackup.ArchiveRestoreLimits()
        limits.maxDatabaseBytes = max(1, bytes - 1)
        limits.maxTotalUncompressedBytes = max(1, bytes - 1)
        limits.maxExpansionRatio = 10_000

        let archived = DataBackup.restore(
            from: archive,
            toDatabaseAt: temporaryDirectory.appendingPathComponent("archive-too-large.sqlite").path,
            allowOversize: true,
            limits: limits
        )
        guard case .failure(let archiveMessage) = archived else {
            return XCTFail("approval must not bypass the archive total-uncompressed ceiling")
        }
        XCTAssertTrue(archiveMessage.localizedCaseInsensitiveContains("expands beyond"))

        let plain = DataBackup.restore(
            from: database,
            toDatabaseAt: temporaryDirectory.appendingPathComponent("plain-too-large.sqlite").path,
            allowOversize: true,
            limits: limits
        )
        guard case .failure(let plainMessage) = plain else {
            return XCTFail("approval must not bypass the plain database absolute ceiling")
        }
        XCTAssertTrue(plainMessage.localizedCaseInsensitiveContains("expands beyond"))
    }

    func testOversizeApprovalStillRejectsInvalidDatabase() throws {
        let archive = try makeArchive(entries: [
            ("noop-backup.sqlite", Data(repeating: 0x41, count: 4_096), .none),
        ])
        var limits = DataBackup.ArchiveRestoreLimits()
        limits.maxDatabaseBytes = 1
        limits.maxTotalUncompressedBytes = 8_192
        limits.maxExpansionRatio = 10_000
        let result = DataBackup.restore(
            from: archive,
            toDatabaseAt: temporaryDirectory.appendingPathComponent("invalid.sqlite").path,
            allowOversize: true,
            limits: limits
        )
        guard case .failure(let message) = result else {
            return XCTFail("Oversize approval must still reject a non-SQLite replacement")
        }
        XCTAssertTrue(message.localizedCaseInsensitiveContains("isn't a NOOP backup"))
    }

    func testFreshInstallPostSwapFailureRemovesDamagedDatabase() throws {
        let source = try makeValidDatabase()
        let destination = temporaryDirectory.appendingPathComponent("fresh-live.sqlite")

        let result = DataBackup.restore(
            from: source,
            toDatabaseAt: destination.path,
            fault: .postSwapValidation
        )

        guard case .failure(let message) = result else {
            return XCTFail("Forced post-swap validation must fail")
        }
        XCTAssertTrue(message.localizedCaseInsensitiveContains("damaged file was removed"))
        XCTAssertFalse(FileManager.default.fileExists(atPath: destination.path))
    }

    @MainActor
    func testFreshInstallLifecycleFailureRemovesReplacementAndReopensEmptyStore() async throws {
        let source = try makeValidDatabase()
        let destination = temporaryDirectory.appendingPathComponent("fresh-live.sqlite")
        var reopenAttempts = 0
        let lifecycle = DataBackup.RestoreLifecycle(
            quiesce: {},
            reopenAndMigrate: {
                reopenAttempts += 1
                if reopenAttempts == 1 { throw CocoaError(.fileReadCorruptFile) }
            }
        )

        let result = await DataBackup.restore(
            from: source, toDatabaseAt: destination.path, lifecycle: lifecycle
        )

        guard case .failure(let message) = result else {
            return XCTFail("A lifecycle reopen failure must fail the restore")
        }
        XCTAssertTrue(message.localizedCaseInsensitiveContains("removed it"))
        XCTAssertEqual(reopenAttempts, 2)
        XCTAssertFalse(FileManager.default.fileExists(atPath: destination.path))
    }

    @MainActor
    func testFailedLifecycleRestoreLeavesExistingSettingsUntouched() async throws {
        let source = try makeValidDatabase()
        let archive = temporaryDirectory.appendingPathComponent("with-settings.noopbak")
        try DataBackup.writeBackupForTesting(
            databaseAt: source, to: archive, settings: ["profile.sex": "imported"]
        )
        let destination = temporaryDirectory.appendingPathComponent("existing-live.sqlite")
        _ = try makeValidDatabase().copyTo(destination)
        let defaultsName = "test.restore-settings.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: defaultsName))
        defaults.removePersistentDomain(forName: defaultsName)
        defaults.set("original", forKey: "profile.sex")
        var reopenAttempts = 0
        let lifecycle = DataBackup.RestoreLifecycle(
            quiesce: {},
            reopenAndMigrate: {
                reopenAttempts += 1
                if reopenAttempts == 1 { throw CocoaError(.fileReadCorruptFile) }
            }
        )

        _ = await DataBackup.restore(
            from: archive, toDatabaseAt: destination.path, lifecycle: lifecycle,
            settingsDefaults: defaults
        )

        XCTAssertEqual(reopenAttempts, 2)
        XCTAssertEqual(defaults.string(forKey: "profile.sex"), "original")
    }

    func testMalformedLegacyWALFailsFinalPostInstallValidation() throws {
        let source = try makeValidDatabase()
        try Data("not a sqlite wal".utf8).write(to: URL(fileURLWithPath: source.path + "-wal"))
        let destination = temporaryDirectory.appendingPathComponent("legacy-live.sqlite")

        let result = DataBackup.restore(from: source, toDatabaseAt: destination.path)

        guard case .failure = result else {
            return XCTFail("A malformed legacy WAL must not be accepted after the main database check")
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: destination.path))
    }

    func testValidHeaderButZeroFrameLegacyWALFailsClosed() throws {
        let source = try makeValidDatabase()
        var header = Data([0x37, 0x7f, 0x06, 0x82])
        header.append(contentsOf: Array(repeating: 0, count: 4))
        header.append(0x10); header.append(0x00) // 4 KiB page size
        header.append(contentsOf: Array(repeating: 0, count: 22))
        XCTAssertEqual(header.count, 32)
        try header.write(to: URL(fileURLWithPath: source.path + "-wal"))
        let destination = temporaryDirectory.appendingPathComponent("legacy-live.sqlite")

        let result = DataBackup.restore(from: source, toDatabaseAt: destination.path)

        guard case .failure(let message) = result else {
            return XCTFail("An unverifiable legacy WAL must never be attached to a live restore")
        }
        XCTAssertTrue(message.localizedCaseInsensitiveContains("wal"))
        XCTAssertFalse(FileManager.default.fileExists(atPath: destination.path))
    }

    @MainActor
    func testFreshInstallLifecycleReportsReplacementRemovalFailure() async throws {
        let source = try makeValidDatabase()
        let destination = temporaryDirectory.appendingPathComponent("fresh-live.sqlite")
        var reopenAttempts = 0
        let lifecycle = DataBackup.RestoreLifecycle(
            quiesce: {},
            reopenAndMigrate: {
                reopenAttempts += 1
                if reopenAttempts == 1 { throw CocoaError(.fileReadCorruptFile) }
            }
        )

        let result = await DataBackup.restore(
            from: source, toDatabaseAt: destination.path, lifecycle: lifecycle,
            fault: .replacementRemoval
        )

        guard case .failure(let message) = result else {
            return XCTFail("A failed replacement deletion must fail the lifecycle")
        }
        XCTAssertTrue(message.localizedCaseInsensitiveContains("could not reopen an empty store"))
        XCTAssertEqual(reopenAttempts, 1)
    }

    func testCanonicalEntriesExtractWithoutPathFlattening() throws {
        let archive = try makeArchive(entries: [
            ("noop-backup.sqlite", Data("database".utf8), .none),
            ("settings.json", Data("{}".utf8), .deflate),
        ])
        let output = try makeOutputDirectory()

        try DataBackup.extractBackupZip(at: archive, into: output)

        XCTAssertEqual(try Data(contentsOf: output.appendingPathComponent("noop-backup.sqlite")),
                       Data("database".utf8))
        XCTAssertEqual(try Data(contentsOf: output.appendingPathComponent("settings.json")),
                       Data("{}".utf8))
    }

    func testRejectsUnexpectedEntryBeforeWritingAnything() throws {
        let archive = try makeArchive(entries: [
            ("noop-backup.sqlite", Data("database".utf8), .none),
            ("notes.txt", Data("not allowed".utf8), .none),
        ])
        try assertRejected(archive, containing: "unexpected entry")
    }

    func testRejectedArchiveLeavesExistingDatabaseByteForByteUntouched() throws {
        let archive = try makeArchive(entries: [
            ("noop-backup.sqlite", Data("database".utf8), .none),
            ("payload.bin", Data("not allowed".utf8), .none),
        ])
        let liveDatabase = temporaryDirectory.appendingPathComponent("live.sqlite")
        let original = Data("existing database sentinel".utf8)
        try original.write(to: liveDatabase)

        let result = DataBackup.restore(from: archive, toDatabaseAt: liveDatabase.path)

        guard case .failure(let message) = result else {
            return XCTFail("Hostile archive must fail without reaching the database swap")
        }
        XCTAssertTrue(message.localizedCaseInsensitiveContains("unexpected entry"))
        XCTAssertEqual(try Data(contentsOf: liveDatabase), original)
    }

    func testRejectsNestedCanonicalNameInsteadOfFlatteningIt() throws {
        let archive = try makeArchive(entries: [
            ("nested/noop-backup.sqlite", Data("database".utf8), .none),
        ])
        try assertRejected(archive, containing: "unexpected entry")
    }

    func testRejectsDuplicateFlattenedNames() throws {
        let archive = try makeArchive(entries: [
            ("noop-backup.sqlite", Data("first".utf8), .none),
            ("nested/noop-backup.sqlite", Data("second".utf8), .none),
        ])
        try assertRejected(archive, containing: "duplicate or ambiguous")
    }

    func testRejectsExcessiveEntryCount() throws {
        let archive = try makeArchive(entries: [
            ("noop-backup.sqlite", Data("database".utf8), .none),
            ("settings.json", Data("{}".utf8), .none),
            ("extra", Data("x".utf8), .none),
        ])
        try assertRejected(archive, containing: "can contain only")
    }

    func testRejectsCompressedInputOverBudget() throws {
        let archive = try makeArchive(entries: [
            ("noop-backup.sqlite", Data("database".utf8), .none),
        ])
        var limits = DataBackup.ArchiveRestoreLimits()
        limits.maxArchiveCompressedBytes = 1
        try assertRejected(archive, limits: limits, containing: "larger than")
    }

    func testRejectsAggregateUncompressedSizeOverBudget() throws {
        let archive = try makeArchive(entries: [
            ("noop-backup.sqlite", Data(repeating: 0x41, count: 8), .none),
            ("settings.json", Data(repeating: 0x42, count: 8), .none),
        ])
        var limits = DataBackup.ArchiveRestoreLimits()
        limits.maxTotalUncompressedBytes = 15
        try assertRejected(archive, limits: limits, containing: "expands beyond")
    }

    func testRejectsSuspiciousCompressionRatio() throws {
        let archive = try makeArchive(entries: [
            ("noop-backup.sqlite", Data(repeating: 0, count: 64 * 1024), .deflate),
        ])
        var limits = DataBackup.ArchiveRestoreLimits()
        limits.maxExpansionRatio = 2
        try assertRejected(archive, limits: limits, containing: "suspicious compression ratio")
    }

    func testRejectsTruncatedArchive() throws {
        let archive = try makeArchive(entries: [
            ("noop-backup.sqlite", Data("database".utf8), .none),
        ])
        let handle = try FileHandle(forWritingTo: archive)
        let size = try handle.seekToEnd()
        try handle.truncate(atOffset: size / 2)
        try handle.close()

        let output = try makeOutputDirectory()
        XCTAssertThrowsError(try DataBackup.extractBackupZip(at: archive, into: output))
        XCTAssertTrue(try FileManager.default.contentsOfDirectory(atPath: output.path).isEmpty)
    }

    private func makeValidDatabase() throws -> URL {
        let url = temporaryDirectory.appendingPathComponent("valid-\(UUID().uuidString).sqlite")
        var db: OpaquePointer?
        XCTAssertEqual(sqlite3_open(url.path, &db), SQLITE_OK)
        defer { sqlite3_close(db) }
        XCTAssertEqual(
            sqlite3_exec(
                db,
                "CREATE TABLE grdb_migrations(identifier TEXT PRIMARY KEY);",
                nil,
                nil,
                nil
            ),
            SQLITE_OK
        )
        return url
    }

    private func makeArchive(entries: [(String, Data, CompressionMethod)]) throws -> URL {
        let url = temporaryDirectory.appendingPathComponent("fixture-\(UUID().uuidString).noopbak")
        let archive = try Archive(url: url, accessMode: .create)
        for (path, data, compression) in entries {
            try archive.addEntry(with: path, type: .file,
                                 uncompressedSize: Int64(data.count),
                                 compressionMethod: compression) { position, size in
                let start = data.startIndex + Int(position)
                return data.subdata(in: start ..< start + size)
            }
        }
        return url
    }

    private func makeOutputDirectory() throws -> URL {
        let output = temporaryDirectory.appendingPathComponent("output-\(UUID().uuidString)",
                                                                isDirectory: true)
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        return output
    }

    private func assertRejected(_ archive: URL,
                                limits: DataBackup.ArchiveRestoreLimits = .init(),
                                containing expectedMessage: String,
                                file: StaticString = #filePath,
                                line: UInt = #line) throws {
        let output = try makeOutputDirectory()
        XCTAssertThrowsError(
            try DataBackup.extractBackupZip(at: archive, into: output, limits: limits),
            file: file,
            line: line
        ) { error in
            XCTAssertTrue(error.localizedDescription.localizedCaseInsensitiveContains(expectedMessage),
                          "Unexpected error: \(error)", file: file, line: line)
        }
        XCTAssertTrue(try FileManager.default.contentsOfDirectory(atPath: output.path).isEmpty,
                      "A rejected archive must not write partial output", file: file, line: line)
    }
}

private extension URL {
    func copyTo(_ destination: URL) throws -> URL {
        try FileManager.default.copyItem(at: self, to: destination)
        return destination
    }
}
