#!/usr/bin/env python3
from release_qa_patch_common import replace_once, regex_once, insert_before_last
import re

# ---------------------------------------------------------------------------
# Backup restore: honest rollback failures, clean fresh-install failure, full extraction cleanup.
# ---------------------------------------------------------------------------
replace_once(
    "Strand/Data/DataBackup.swift",
    '''    enum RestoreFault: Equatable {\n        case replacementCopy\n        case postSwapValidation\n    }\n''',
    '''    enum RestoreFault: Equatable {\n        case replacementCopy\n        case postSwapValidation\n        case rollback\n    }\n''',
)
replace_once(
    "Strand/Data/DataBackup.swift",
    '''            let forcedComplaint = fault == .postSwapValidation ? "simulated post-swap failure" : nil\n            if let complaint = forcedComplaint ?? DatabaseIntegrity.quickCheckFailure(atPath: dbURL.path) {\n                if sidecar != dbURL, fm.fileExists(atPath: sidecar.path) {\n                    try? rollback(from: sidecar, toDatabaseAt: dbPath)\n                    return .failure(String(localized: "Import failed its post-restore integrity check (SQLite reports: \\(complaint)). Your previous data was rolled back automatically."))\n                }\n                return .failure(String(localized: "Import failed its post-restore integrity check (SQLite reports: \\(complaint))."))\n            }\n''',
    '''            let forcedComplaint = fault == .postSwapValidation || fault == .rollback\n                ? "simulated post-swap failure" : nil\n            if let complaint = forcedComplaint ?? DatabaseIntegrity.quickCheckFailure(atPath: dbURL.path) {\n                if sidecar != dbURL, fm.fileExists(atPath: sidecar.path) {\n                    do {\n                        if fault == .rollback { throw RestoreFailure.simulatedRollback }\n                        try rollback(from: sidecar, toDatabaseAt: dbPath)\n                        return .failure(String(localized: "Import failed its post-restore integrity check (SQLite reports: \\(complaint)). Your previous data was rolled back automatically."))\n                    } catch {\n                        return .failure(String(localized: "Import failed its post-restore integrity check (SQLite reports: \\(complaint)), and automatic rollback also failed. The pre-restore safety copy remains at \\(sidecar.path). \\(error.localizedDescription)"))\n                    }\n                }\n                do {\n                    if fm.fileExists(atPath: dbURL.path) { try fm.removeItem(at: dbURL) }\n                    let wal = URL(fileURLWithPath: dbPath + "-wal")\n                    let shm = URL(fileURLWithPath: dbPath + "-shm")\n                    if fm.fileExists(atPath: wal.path) { try fm.removeItem(at: wal) }\n                    if fm.fileExists(atPath: shm.path) { try fm.removeItem(at: shm) }\n                    return .failure(String(localized: "Import failed its post-restore integrity check (SQLite reports: \\(complaint)). The rejected replacement was removed; there was no previous database to restore."))\n                } catch {\n                    return .failure(String(localized: "Import failed its post-restore integrity check (SQLite reports: \\(complaint)), and NOOP could not remove the rejected replacement. \\(error.localizedDescription)"))\n                }\n            }\n''',
)
replace_once(
    "Strand/Data/DataBackup.swift",
    '''        case simulatedReplacementCopy\n        case invalidReplacement(String)\n''',
    '''        case simulatedReplacementCopy\n        case simulatedRollback\n        case invalidReplacement(String)\n''',
)
replace_once(
    "Strand/Data/DataBackup.swift",
    '''            case .simulatedReplacementCopy:\n                return "Simulated replacement-copy failure."\n            case .invalidReplacement(let complaint):\n''',
    '''            case .simulatedReplacementCopy:\n                return "Simulated replacement-copy failure."\n            case .simulatedRollback:\n                return "Simulated rollback failure."\n            case .invalidReplacement(let complaint):\n''',
)
replace_once(
    "Strand/Data/DataBackup.swift",
    '''        var extractedTotal: UInt64 = 0\n        for entry in entries {\n            let out = destDir.appendingPathComponent(entry.path)\n            guard FileManager.default.createFile(atPath: out.path, contents: nil) else {\n                throw CocoaError(.fileWriteUnknown, userInfo: [NSFilePathErrorKey: out.path])\n            }\n            let handle = try FileHandle(forWritingTo: out)\n            defer { try? handle.close() }\n            var entryBytes: UInt64 = 0\n            do {\n                _ = try archive.extract(entry) { chunk in\n                    let chunkBytes = UInt64(chunk.count)\n                    guard entryBytes <= entry.uncompressedSize - min(chunkBytes, entry.uncompressedSize),\n                          entryBytes + chunkBytes <= entry.uncompressedSize else {\n                        throw BackupArchiveError.extractedSizeMismatch(entry.path)\n                    }\n                    guard extractedTotal <= limits.maxTotalUncompressedBytes - min(\n                        chunkBytes, limits.maxTotalUncompressedBytes\n                    ), extractedTotal + chunkBytes <= limits.maxTotalUncompressedBytes else {\n                        throw BackupArchiveError.totalTooLarge\n                    }\n                    try handle.write(contentsOf: chunk)\n                    entryBytes += chunkBytes\n                    extractedTotal += chunkBytes\n                }\n                guard entryBytes == entry.uncompressedSize else {\n                    throw BackupArchiveError.extractedSizeMismatch(entry.path)\n                }\n            } catch {\n                try? FileManager.default.removeItem(at: out)\n                throw error\n            }\n        }\n''',
    '''        var extractedTotal: UInt64 = 0\n        var writtenOutputs: [URL] = []\n        do {\n            for entry in entries {\n                let out = destDir.appendingPathComponent(entry.path)\n                guard FileManager.default.createFile(atPath: out.path, contents: nil) else {\n                    throw CocoaError(.fileWriteUnknown, userInfo: [NSFilePathErrorKey: out.path])\n                }\n                writtenOutputs.append(out)\n                let handle = try FileHandle(forWritingTo: out)\n                defer { try? handle.close() }\n                var entryBytes: UInt64 = 0\n                _ = try archive.extract(entry) { chunk in\n                    let chunkBytes = UInt64(chunk.count)\n                    guard entryBytes <= entry.uncompressedSize - min(chunkBytes, entry.uncompressedSize),\n                          entryBytes + chunkBytes <= entry.uncompressedSize else {\n                        throw BackupArchiveError.extractedSizeMismatch(entry.path)\n                    }\n                    guard extractedTotal <= limits.maxTotalUncompressedBytes - min(\n                        chunkBytes, limits.maxTotalUncompressedBytes\n                    ), extractedTotal + chunkBytes <= limits.maxTotalUncompressedBytes else {\n                        throw BackupArchiveError.totalTooLarge\n                    }\n                    try handle.write(contentsOf: chunk)\n                    entryBytes += chunkBytes\n                    extractedTotal += chunkBytes\n                }\n                guard entryBytes == entry.uncompressedSize else {\n                    throw BackupArchiveError.extractedSizeMismatch(entry.path)\n                }\n            }\n        } catch {\n            for output in writtenOutputs { try? FileManager.default.removeItem(at: output) }\n            throw error\n        }\n''',
)

backup_tests = "StrandiOSTests/BackupArchiveHardeningTests.swift"
replace_once(backup_tests, "import ZIPFoundation\n", "import ZIPFoundation\nimport SQLite3\n")
backup_test_insertion = r'''
    func testFreshInstallPostSwapFailureRemovesRejectedDatabase() throws {
        let source = temporaryDirectory.appendingPathComponent("fresh-source.sqlite")
        try makeSQLite(at: source, sentinel: "incoming")
        let live = temporaryDirectory.appendingPathComponent("fresh-live.sqlite")

        let result = DataBackup.restore(
            from: source,
            toDatabaseAt: live.path,
            fault: .postSwapValidation
        )

        guard case .failure(let message) = result else {
            return XCTFail("Injected post-swap failure must fail")
        }
        XCTAssertTrue(message.localizedCaseInsensitiveContains("rejected replacement was removed"))
        XCTAssertFalse(FileManager.default.fileExists(atPath: live.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: live.path + "-wal"))
        XCTAssertFalse(FileManager.default.fileExists(atPath: live.path + "-shm"))
    }

    func testRollbackFailureIsReportedHonestlyAndKeepsSafetyCopy() throws {
        let source = temporaryDirectory.appendingPathComponent("rollback-source.sqlite")
        let live = temporaryDirectory.appendingPathComponent("rollback-live.sqlite")
        try makeSQLite(at: source, sentinel: "incoming")
        try makeSQLite(at: live, sentinel: "original")

        let result = DataBackup.restore(
            from: source,
            toDatabaseAt: live.path,
            fault: .rollback
        )

        guard case .failure(let message) = result else {
            return XCTFail("Injected rollback failure must fail")
        }
        XCTAssertTrue(message.localizedCaseInsensitiveContains("rollback also failed"))
        XCTAssertTrue(message.localizedCaseInsensitiveContains("safety copy"))
        let sidecars = try FileManager.default.contentsOfDirectory(
            at: temporaryDirectory,
            includingPropertiesForKeys: nil
        ).filter { $0.lastPathComponent.hasPrefix("whoop-replaced-") }
        XCTAssertEqual(sidecars.count, 1)
        XCTAssertEqual(try sqliteSentinel(at: sidecars[0]), "original")
    }

    private func makeSQLite(at url: URL, sentinel: String) throws {
        var db: OpaquePointer?
        XCTAssertEqual(sqlite3_open(url.path, &db), SQLITE_OK)
        defer { sqlite3_close(db) }
        XCTAssertEqual(sqlite3_exec(
            db,
            "CREATE TABLE grdb_migrations(identifier TEXT PRIMARY KEY); " +
            "CREATE TABLE qa_sentinel(value TEXT NOT NULL); " +
            "INSERT INTO qa_sentinel(value) VALUES ('\(sentinel)');",
            nil,
            nil,
            nil
        ), SQLITE_OK)
    }

    private func sqliteSentinel(at url: URL) throws -> String {
        var db: OpaquePointer?
        guard sqlite3_open_v2(url.path, &db, SQLITE_OPEN_READONLY, nil) == SQLITE_OK else {
            throw CocoaError(.fileReadCorruptFile)
        }
        defer { sqlite3_close(db) }
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, "SELECT value FROM qa_sentinel LIMIT 1", -1, &statement, nil) == SQLITE_OK else {
            throw CocoaError(.fileReadCorruptFile)
        }
        defer { sqlite3_finalize(statement) }
        guard sqlite3_step(statement) == SQLITE_ROW,
              let bytes = sqlite3_column_text(statement, 0) else {
            throw CocoaError(.fileReadCorruptFile)
        }
        return String(cString: bytes)
    }

'''
insert_before_last(backup_tests, "}\n", backup_test_insertion)

print("Applied backup QA fixes")
