import XCTest
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
