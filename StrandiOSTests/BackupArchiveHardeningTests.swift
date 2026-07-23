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
