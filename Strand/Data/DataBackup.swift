import Foundation
#if canImport(AppKit)
import AppKit
#elseif canImport(UIKit)
import UIKit
#endif
import SQLite3
import UniformTypeIdentifiers
import WhoopStore
import ZIPFoundation

/// Full-database EXPORT / IMPORT for device migration.
///
/// NOOP keeps everything in one SQLite file (`<AppSupport>/OpenWhoop/whoop.sqlite`, plus the
/// `-wal`/`-shm` WAL sidecars while the store is open). Export checkpoints the WAL (so the
/// single file is whole), then wraps the SQLite in a ZIP written as `.noopbak`, alongside a
/// small `settings.json` entry (#1000) carrying the whitelisted profile/display settings (see
/// `BackupSettings`) so a restore also brings back weight/height/units, not just the rows.
/// ZIP deflate typically cuts a 100 MB+ SQLite backup to 10–20 MB. The format is a standard
/// ZIP — users can rename `.noopbak` → `.zip` and extract the SQLite manually on any OS.
///
/// Import detects the format by magic bytes: ZIP (`PK\x03\x04`) or legacy plain SQLite. ZIP
/// backups are extracted to a temp dir, validated, then swapped in exactly like a plain import.
/// Old `.sqlite` / `.noopdb` backups keep working.
///
/// Sandbox-safe: relies on the `com.apple.security.files.user-selected.read-write` entitlement and
/// security-scoped access on the panel-returned URLs. Every path is best-effort — failures surface
/// as a `.failure` result and never crash.
enum DataBackup {

    struct RestoreLifecycle {
        let quiesce: @MainActor () async throws -> Void
        let reopenAndMigrate: @MainActor () async throws -> Void
    }

    enum RestoreFault: Equatable {
        case replacementCopy
        case postSwapValidation
    }

    enum BackupResult {
        case exported(URL)
        case imported(sidecar: URL)
        case cancelled
        case failure(String)
    }

    @MainActor
    static func runExport(checkpoint: @Sendable @escaping () async -> Bool) async -> BackupResult {
        let dbPath: String
        do { dbPath = try StorePaths.defaultDatabasePath() }
        catch { return .failure(String(localized: "Couldn't locate the NOOP database. \(error.localizedDescription)")) }
        let dbURL = URL(fileURLWithPath: dbPath)
        guard FileManager.default.fileExists(atPath: dbPath) else {
            return .failure(String(localized: "There's no NOOP data to export yet. Import or record some first."))
        }
        guard await checkpoint() else {
            return .failure(String(localized: "Couldn't safely export right now. Recent changes are still in the database's write-ahead log. Close any in-flight sync, then try again."))
        }

        #if os(macOS)
        let panel = NSSavePanel()
        panel.title = String(localized: "Export NOOP backup")
        panel.prompt = String(localized: "Export")
        panel.canCreateDirectories = true
        panel.nameFieldStringValue = defaultBackupName()
        panel.allowedContentTypes = backupContentTypes()
        panel.isExtensionHidden = false
        guard panel.runModal() == .OK, let dest = panel.url else { return .cancelled }
        let scoped = dest.startAccessingSecurityScopedResource()
        defer { if scoped { dest.stopAccessingSecurityScopedResource() } }
        do {
            if FileManager.default.fileExists(atPath: dest.path) { try FileManager.default.removeItem(at: dest) }
            try await Task.detached(priority: .utility) {
                try writeVerifiedBackupZip(dbURL: dbURL, to: dest, settingsJSON: currentSettingsJSON())
            }.value
            return .exported(dest)
        } catch {
            return .failure(String(localized: "Export failed: \(error.localizedDescription)"))
        }
        #else
        let staged = FileManager.default.temporaryDirectory.appendingPathComponent(defaultBackupName())
        do {
            if FileManager.default.fileExists(atPath: staged.path) { try FileManager.default.removeItem(at: staged) }
            try await Task.detached(priority: .utility) {
                try writeVerifiedBackupZip(dbURL: dbURL, to: staged, settingsJSON: currentSettingsJSON())
            }.value
        } catch {
            return .failure(String(localized: "Export failed: \(error.localizedDescription)"))
        }
        guard let dest = await DocumentPicker.export(staged) else { return .cancelled }
        return .exported(dest)
        #endif
    }

    private struct ExportIntegrityFailure: LocalizedError {
        let complaint: String
        var errorDescription: String? {
            String(localized: "the NOOP database failed its integrity check (SQLite reports: \(complaint)). A backup of it would not restore. Export the WHOOP-format CSV (Settings → Export data) to save what's still readable.")
        }
    }

    private static func writeVerifiedBackupZip(dbURL: URL, to dest: URL, settingsJSON: Data?) throws {
        if let complaint = DatabaseIntegrity.quickCheckFailure(atPath: dbURL.path) {
            throw ExportIntegrityFailure(complaint: complaint)
        }
        try writeBackupZip(dbURL: dbURL, to: dest, settingsJSON: settingsJSON)
    }

    private static func writeBackupZip(dbURL: URL, to dest: URL, settingsJSON: Data?) throws {
        let archive = try Archive(url: dest, accessMode: .create)
        try archive.addEntry(with: backupEntryName, fileURL: dbURL, compressionMethod: .deflate)
        guard let settingsJSON else { return }
        let tmpJSON = FileManager.default.temporaryDirectory
            .appendingPathComponent("noop-settings-\(UUID().uuidString).json")
        try settingsJSON.write(to: tmpJSON)
        defer { try? FileManager.default.removeItem(at: tmpJSON) }
        try archive.addEntry(with: BackupSettings.entryName, fileURL: tmpJSON, compressionMethod: .deflate)
    }

    private static func currentSettingsJSON() -> Data? {
        BackupSettings.encode(BackupSettings.snapshot(from: .standard))
    }

    static func writeBackup(checkpoint: @Sendable @escaping () async -> Bool, to dest: URL) async -> BackupResult {
        let dbPath: String
        do { dbPath = try StorePaths.defaultDatabasePath() }
        catch { return .failure(String(localized: "Couldn't locate the NOOP database. \(error.localizedDescription)")) }
        let dbURL = URL(fileURLWithPath: dbPath)
        guard FileManager.default.fileExists(atPath: dbPath) else {
            return .failure(String(localized: "There's no NOOP data to export yet."))
        }
        guard await checkpoint() else {
            return .failure(String(localized: "Couldn't safely back up right now. Recent changes are still in the write-ahead log."))
        }
        do {
            if FileManager.default.fileExists(atPath: dest.path) { try FileManager.default.removeItem(at: dest) }
            try writeVerifiedBackupZip(dbURL: dbURL, to: dest, settingsJSON: currentSettingsJSON())
            return .exported(dest)
        } catch {
            return .failure(String(localized: "Backup failed: \(error.localizedDescription)"))
        }
    }

    static func writeBackupForTesting(databaseAt dbURL: URL, to dest: URL,
                                      settings: [String: Any]? = nil) throws {
        if FileManager.default.fileExists(atPath: dest.path) { try FileManager.default.removeItem(at: dest) }
        try writeBackupZip(dbURL: dbURL, to: dest,
                           settingsJSON: settings.flatMap { BackupSettings.encode($0) })
    }

    @MainActor
    static func runImport(lifecycle: RestoreLifecycle) async -> BackupResult {
        let dbPath: String
        do { dbPath = try StorePaths.defaultDatabasePath() }
        catch { return .failure(String(localized: "Couldn't locate the NOOP database. \(error.localizedDescription)")) }
        #if os(macOS)
        let panel = NSOpenPanel()
        panel.title = String(localized: "Import NOOP backup")
        panel.prompt = String(localized: "Import")
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.canChooseFiles = true
        panel.allowedContentTypes = backupContentTypes()
        guard panel.runModal() == .OK, let pickedSource = panel.url else { return .cancelled }
        let scoped = pickedSource.startAccessingSecurityScopedResource()
        defer { if scoped { pickedSource.stopAccessingSecurityScopedResource() } }
        #else
        guard let pickedSource = await DocumentPicker.importFile(backupContentTypes()) else { return .cancelled }
        #endif
        do { try await lifecycle.quiesce() }
        catch { return .failure(String(localized: "Couldn't pause the local database safely. Nothing was replaced. \(error.localizedDescription)")) }
        let result = await Task.detached(priority: .utility) {
            restore(from: pickedSource, toDatabaseAt: dbPath)
        }.value
        return await finishRestore(result, databasePath: dbPath, lifecycle: lifecycle)
    }

    @MainActor
    static func restore(from pickedSource: URL, lifecycle: RestoreLifecycle) async -> BackupResult {
        let dbPath: String
        do { dbPath = try StorePaths.defaultDatabasePath() }
        catch { return .failure(String(localized: "Couldn't locate the NOOP database. \(error.localizedDescription)")) }
        return await restore(from: pickedSource, toDatabaseAt: dbPath, lifecycle: lifecycle)
    }

    @MainActor
    static func restore(from pickedSource: URL, toDatabaseAt dbPath: String,
                        lifecycle: RestoreLifecycle) async -> BackupResult {
        do { try await lifecycle.quiesce() }
        catch { return .failure(String(localized: "Couldn't pause the local database safely. Nothing was replaced. \(error.localizedDescription)")) }
        let result = await Task.detached(priority: .utility) {
            restore(from: pickedSource, toDatabaseAt: dbPath)
        }.value
        return await finishRestore(result, databasePath: dbPath, lifecycle: lifecycle)
    }

    @MainActor
    private static func finishRestore(_ result: BackupResult, databasePath: String,
                                      lifecycle: RestoreLifecycle) async -> BackupResult {
        switch result {
        case .imported(let safetyCopy):
            do {
                try await lifecycle.reopenAndMigrate()
                return result
            } catch {
                do {
                    try await lifecycle.quiesce()
                    try await Task.detached(priority: .utility) {
                        try rollback(from: safetyCopy, toDatabaseAt: databasePath)
                    }.value
                    try await lifecycle.reopenAndMigrate()
                    return .failure(String(localized: "The replacement database could not be opened or migrated, so NOOP restored your previous data automatically. \(error.localizedDescription)"))
                } catch {
                    return .failure(String(localized: "The replacement failed and automatic rollback could not reopen the previous database. The safety copy is at \(safetyCopy.path). \(error.localizedDescription)"))
                }
            }
        case .failure, .cancelled, .exported:
            do {
                try await lifecycle.reopenAndMigrate()
                return result
            } catch {
                return .failure(String(localized: "The restore did not complete, and NOOP could not reopen the existing database. \(error.localizedDescription)"))
            }
        }
    }

    static func restore(from pickedSource: URL) -> BackupResult {
        let dbPath: String
        do { dbPath = try StorePaths.defaultDatabasePath() }
        catch { return .failure(String(localized: "Couldn't locate the NOOP database. \(error.localizedDescription)")) }
        return restore(from: pickedSource, toDatabaseAt: dbPath)
    }

    static func restore(from pickedSource: URL, toDatabaseAt dbPath: String,
                        settingsDefaults: UserDefaults = .standard,
                        fault: RestoreFault? = nil) -> BackupResult {
        let fm = FileManager.default
        let source: URL
        let extractedDir: URL?

        if isZipFile(at: pickedSource) {
            let tmpExtract = fm.temporaryDirectory
                .appendingPathComponent("noop-import-\(UUID().uuidString)", isDirectory: true)
            do {
                if fm.fileExists(atPath: tmpExtract.path) { try fm.removeItem(at: tmpExtract) }
                try fm.createDirectory(at: tmpExtract, withIntermediateDirectories: true)
                try extractBackupZip(at: pickedSource, into: tmpExtract)
            } catch {
                try? fm.removeItem(at: tmpExtract)
                return .failure(String(localized: "Couldn't open the backup archive: \(error.localizedDescription)"))
            }
            let sqliteEntry = tmpExtract.appendingPathComponent(backupEntryName)
            guard fm.fileExists(atPath: sqliteEntry.path) else {
                try? fm.removeItem(at: tmpExtract)
                return .failure(String(localized: "The backup archive doesn't contain a database file."))
            }
            source = sqliteEntry
            extractedDir = tmpExtract
        } else {
            source = pickedSource
            extractedDir = nil
        }
        defer { if let extractedDir { try? fm.removeItem(at: extractedDir) } }

        guard isSQLiteFile(at: source) else {
            return .failure(String(localized: "That file isn't a NOOP backup. It doesn't look like a SQLite database."))
        }
        let backupTables = sqliteTableNames(at: source)
        let origin = backupOrigin(of: backupTables)
        let holdsData = backupTables.contains("device") || backupTables.contains("hrSample")
        if origin == .android || (origin == .unknown && holdsData) {
            return .failure(String(localized: "This isn't a NOOP backup from this app. It's missing the migration bookkeeping a NOOP backup carries, and restoring it would strand your store."))
        }

        let legacySidecarsPresent = extractedDir == nil
            && (fm.fileExists(atPath: source.path + "-wal") || fm.fileExists(atPath: source.path + "-shm"))
        if !legacySidecarsPresent,
           let complaint = DatabaseIntegrity.quickCheckFailure(atPath: source.path) {
            return .failure(String(localized: "This backup file is damaged and can't be restored (SQLite reports: \(complaint)). Your current data was left untouched."))
        }

        let dbURL = URL(fileURLWithPath: dbPath)
        do {
            try preflightRestoreCapacity(source: source, pickedSource: pickedSource, databaseURL: dbURL,
                                         extractedDirectory: extractedDir, fileManager: fm)
            var sidecar = dbURL.deletingLastPathComponent()
                .appendingPathComponent("whoop-replaced-\(timestamp()).sqlite")
            if fm.fileExists(atPath: dbURL.path) {
                if fm.fileExists(atPath: sidecar.path) { try fm.removeItem(at: sidecar) }
                try onlineBackup(fromDatabaseAt: dbURL.path, to: sidecar.path)
            } else {
                sidecar = dbURL
            }

            let incoming = dbURL.deletingLastPathComponent()
                .appendingPathComponent(".noop-restore-\(UUID().uuidString).sqlite")
            defer { removeIfPresent(incoming) }
            if fault == .replacementCopy { throw RestoreFailure.simulatedReplacementCopy }
            try fm.copyItem(at: source, to: incoming)
            if let complaint = DatabaseIntegrity.quickCheckFailure(atPath: incoming.path), !legacySidecarsPresent {
                throw RestoreFailure.invalidReplacement(complaint)
            }
            removeIfPresent(URL(fileURLWithPath: dbPath + "-wal"))
            removeIfPresent(URL(fileURLWithPath: dbPath + "-shm"))
            try atomicInstall(incoming, at: dbURL)

            let forcedComplaint = fault == .postSwapValidation ? "simulated post-swap failure" : nil
            if let complaint = forcedComplaint ?? DatabaseIntegrity.quickCheckFailure(atPath: dbURL.path) {
                if sidecar != dbURL, fm.fileExists(atPath: sidecar.path) {
                    try? rollback(from: sidecar, toDatabaseAt: dbPath)
                    return .failure(String(localized: "Import failed its post-restore integrity check (SQLite reports: \(complaint)). Your previous data was rolled back automatically."))
                }
                return .failure(String(localized: "Import failed its post-restore integrity check (SQLite reports: \(complaint))."))
            }

            if extractedDir == nil {
                restoreSidecar(from: source, toMainPath: dbPath, suffix: "-wal")
                restoreSidecar(from: source, toMainPath: dbPath, suffix: "-shm")
            }
            if let extractedDir {
                let settingsURL = extractedDir.appendingPathComponent(BackupSettings.entryName)
                if let data = try? Data(contentsOf: settingsURL) {
                    BackupSettings.apply(BackupSettings.decode(data), to: settingsDefaults)
                }
            }
            UserDefaults.standard.set(Date().timeIntervalSince1970, forKey: "backup.lastRestoreAt")
            return .imported(sidecar: sidecar)
        } catch {
            return .failure(String(localized: "Import failed. Your existing data was kept. \(error.localizedDescription)"))
        }
    }

    private enum RestoreFailure: LocalizedError {
        case simulatedReplacementCopy
        case invalidReplacement(String)
        case sqliteBackup(String)
        case insufficientCapacity(required: UInt64, available: UInt64)

        var errorDescription: String? {
            switch self {
            case .simulatedReplacementCopy:
                return "Simulated replacement-copy failure."
            case .invalidReplacement(let complaint):
                return "The staged replacement failed its integrity check: \(complaint)"
            case .sqliteBackup(let complaint):
                return "The pre-restore safety snapshot failed: \(complaint)"
            case .insufficientCapacity(let required, let available):
                return "Not enough free storage to restore safely. Required \(required.formatted(.byteCount(style: .file))), available \(available.formatted(.byteCount(style: .file)))."
            }
        }
    }

    private static func onlineBackup(fromDatabaseAt sourcePath: String, to destinationPath: String) throws {
        removeIfPresent(URL(fileURLWithPath: destinationPath))
        var source: OpaquePointer?
        var destination: OpaquePointer?
        guard sqlite3_open_v2(sourcePath, &source, SQLITE_OPEN_READONLY, nil) == SQLITE_OK else {
            let message = source.map { String(cString: sqlite3_errmsg($0)) } ?? "could not open source"
            sqlite3_close(source)
            throw RestoreFailure.sqliteBackup(message)
        }
        defer { sqlite3_close(source) }
        guard sqlite3_open(destinationPath, &destination) == SQLITE_OK else {
            let message = destination.map { String(cString: sqlite3_errmsg($0)) } ?? "could not create destination"
            sqlite3_close(destination)
            throw RestoreFailure.sqliteBackup(message)
        }
        defer { sqlite3_close(destination) }
        guard let backup = sqlite3_backup_init(destination, "main", source, "main") else {
            throw RestoreFailure.sqliteBackup(String(cString: sqlite3_errmsg(destination)))
        }
        let step = sqlite3_backup_step(backup, -1)
        let finish = sqlite3_backup_finish(backup)
        guard step == SQLITE_DONE, finish == SQLITE_OK else {
            throw RestoreFailure.sqliteBackup(String(cString: sqlite3_errmsg(destination)))
        }
    }

    private static func atomicInstall(_ staged: URL, at destination: URL) throws {
        if FileManager.default.fileExists(atPath: destination.path) {
            _ = try FileManager.default.replaceItemAt(destination, withItemAt: staged,
                                                      backupItemName: nil, options: [])
        } else {
            try FileManager.default.moveItem(at: staged, to: destination)
        }
    }

    private static func rollback(from safetyCopy: URL, toDatabaseAt dbPath: String) throws {
        let destination = URL(fileURLWithPath: dbPath)
        let staged = destination.deletingLastPathComponent()
            .appendingPathComponent(".noop-rollback-\(UUID().uuidString).sqlite")
        defer { removeIfPresent(staged) }
        try FileManager.default.copyItem(at: safetyCopy, to: staged)
        removeIfPresent(URL(fileURLWithPath: dbPath + "-wal"))
        removeIfPresent(URL(fileURLWithPath: dbPath + "-shm"))
        try atomicInstall(staged, at: destination)
    }

    private static let backupEntryName = "noop-backup.sqlite"

    struct ArchiveRestoreLimits: Sendable {
        var maxArchiveCompressedBytes: UInt64 = 1_073_741_824
        var maxEntryCount = 2
        var maxTotalUncompressedBytes: UInt64 = 4_294_967_296
        var maxDatabaseBytes: UInt64 = 4_294_967_296
        var maxSettingsBytes: UInt64 = 1_048_576
        var maxExpansionRatio: UInt64 = 200
    }

    private enum BackupArchiveError: LocalizedError {
        case compressedInputTooLarge
        case tooManyEntries
        case duplicateName(String)
        case unexpectedEntry(String)
        case entryTooLarge(String)
        case totalTooLarge
        case suspiciousExpansion(String)
        case extractedSizeMismatch(String)

        var errorDescription: String? {
            switch self {
            case .compressedInputTooLarge:
                return "The selected archive is larger than NOOP's backup limit."
            case .tooManyEntries:
                return "A NOOP backup can contain only noop-backup.sqlite and settings.json."
            case .duplicateName(let name):
                return "The archive contains duplicate or ambiguous entries named \(name)."
            case .unexpectedEntry(let path):
                return "The archive contains an unexpected entry: \(path)."
            case .entryTooLarge(let path):
                return "The archive entry \(path) exceeds NOOP's restore limit."
            case .totalTooLarge:
                return "The archive expands beyond NOOP's restore limit."
            case .suspiciousExpansion(let path):
                return "The archive entry \(path) has a suspicious compression ratio."
            case .extractedSizeMismatch(let path):
                return "The archive entry \(path) expanded beyond its declared size."
            }
        }
    }

    private static func defaultBackupName() -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd"
        return "NOOP-backup-\(formatter.string(from: Date())).noopbak"
    }

    private static func timestamp() -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd-HHmmss"
        return formatter.string(from: Date())
    }

    private static func backupContentTypes() -> [UTType] {
        var types: [UTType] = []
        if let noopbak = UTType(filenameExtension: "noopbak") { types.append(noopbak) }
        types.append(.zip)
        if let sqlite = UTType(filenameExtension: "sqlite") { types.append(sqlite) }
        types.append(.database)
        types.append(.data)
        return types
    }

    enum BackupOrigin: Equatable { case mac, android, unknown }

    static func backupOrigin(of tableNames: Set<String>) -> BackupOrigin {
        if tableNames.contains("grdb_migrations") { return .mac }
        if tableNames.contains("room_master_table") { return .android }
        if tableNames.contains("android_metadata") && tableNames.contains("sqlite_sequence") {
            return .android
        }
        return .unknown
    }

    private static func sqliteTableNames(at url: URL) -> Set<String> {
        var db: OpaquePointer?
        guard sqlite3_open_v2(url.path, &db, SQLITE_OPEN_READONLY, nil) == SQLITE_OK else {
            sqlite3_close(db)
            return []
        }
        defer { sqlite3_close(db) }
        var stmt: OpaquePointer?
        let sql = "SELECT name FROM sqlite_master WHERE type = 'table'"
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return [] }
        defer { sqlite3_finalize(stmt) }
        var names = Set<String>()
        while sqlite3_step(stmt) == SQLITE_ROW {
            if let c = sqlite3_column_text(stmt, 0) { names.insert(String(cString: c)) }
        }
        return names
    }

    private static func isZipFile(at url: URL) -> Bool {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return false }
        defer { try? handle.close() }
        guard let head = try? handle.read(upToCount: 4), head.count >= 4 else { return false }
        return head[0] == 0x50 && head[1] == 0x4B && head[2] == 0x03 && head[3] == 0x04
    }

    static func extractBackupZip(at zipURL: URL, into destDir: URL,
                                 limits: ArchiveRestoreLimits = ArchiveRestoreLimits()) throws {
        let attributes = try FileManager.default.attributesOfItem(atPath: zipURL.path)
        let archiveBytes = (attributes[.size] as? NSNumber)?.uint64Value ?? 0
        guard archiveBytes <= limits.maxArchiveCompressedBytes else {
            throw BackupArchiveError.compressedInputTooLarge
        }

        let archive = try Archive(url: zipURL, accessMode: .read)
        var entries: [Entry] = []
        entries.reserveCapacity(limits.maxEntryCount)
        var flattenedNames = Set<String>()
        var declaredTotal: UInt64 = 0

        for entry in archive {
            guard entries.count < limits.maxEntryCount else {
                throw BackupArchiveError.tooManyEntries
            }
            let flattened = (entry.path as NSString).lastPathComponent
            guard flattenedNames.insert(flattened).inserted else {
                throw BackupArchiveError.duplicateName(flattened)
            }
            guard entry.type == .file,
                  entry.path == backupEntryName || entry.path == BackupSettings.entryName else {
                throw BackupArchiveError.unexpectedEntry(entry.path)
            }
            let perEntryLimit = entry.path == backupEntryName
                ? limits.maxDatabaseBytes : limits.maxSettingsBytes
            guard entry.uncompressedSize <= perEntryLimit else {
                throw BackupArchiveError.entryTooLarge(entry.path)
            }
            guard declaredTotal <= limits.maxTotalUncompressedBytes - min(
                entry.uncompressedSize, limits.maxTotalUncompressedBytes
            ), declaredTotal + entry.uncompressedSize <= limits.maxTotalUncompressedBytes else {
                throw BackupArchiveError.totalTooLarge
            }
            declaredTotal += entry.uncompressedSize
            if entry.uncompressedSize > 0 {
                guard entry.compressedSize > 0 else {
                    throw BackupArchiveError.suspiciousExpansion(entry.path)
                }
                let product = entry.compressedSize.multipliedReportingOverflow(
                    by: limits.maxExpansionRatio
                )
                guard !product.overflow, entry.uncompressedSize <= product.partialValue else {
                    throw BackupArchiveError.suspiciousExpansion(entry.path)
                }
            }
            entries.append(entry)
        }

        let available = availableCapacity(at: destDir)
        guard available >= declaredTotal else {
            throw RestoreFailure.insufficientCapacity(required: declaredTotal, available: available)
        }

        var extractedTotal: UInt64 = 0
        for entry in entries {
            let out = destDir.appendingPathComponent(entry.path)
            guard FileManager.default.createFile(atPath: out.path, contents: nil) else {
                throw CocoaError(.fileWriteUnknown, userInfo: [NSFilePathErrorKey: out.path])
            }
            let handle = try FileHandle(forWritingTo: out)
            defer { try? handle.close() }
            var entryBytes: UInt64 = 0
            do {
                _ = try archive.extract(entry) { chunk in
                    let chunkBytes = UInt64(chunk.count)
                    guard entryBytes <= entry.uncompressedSize - min(chunkBytes, entry.uncompressedSize),
                          entryBytes + chunkBytes <= entry.uncompressedSize else {
                        throw BackupArchiveError.extractedSizeMismatch(entry.path)
                    }
                    guard extractedTotal <= limits.maxTotalUncompressedBytes - min(
                        chunkBytes, limits.maxTotalUncompressedBytes
                    ), extractedTotal + chunkBytes <= limits.maxTotalUncompressedBytes else {
                        throw BackupArchiveError.totalTooLarge
                    }
                    try handle.write(contentsOf: chunk)
                    entryBytes += chunkBytes
                    extractedTotal += chunkBytes
                }
                guard entryBytes == entry.uncompressedSize else {
                    throw BackupArchiveError.extractedSizeMismatch(entry.path)
                }
            } catch {
                try? FileManager.default.removeItem(at: out)
                throw error
            }
        }
    }

    private static func preflightRestoreCapacity(source: URL, pickedSource: URL, databaseURL: URL,
                                                 extractedDirectory: URL?, fileManager: FileManager) throws {
        let sourceBytes = fileSize(source, fileManager: fileManager)
        let liveBytes = fileSize(databaseURL, fileManager: fileManager)
        let archiveBytes = extractedDirectory == nil
            ? 0 : fileSize(pickedSource, fileManager: fileManager)
        let required = saturatingAdd(
            saturatingMultiply(sourceBytes, by: 2),
            saturatingMultiply(liveBytes, by: 2),
            archiveBytes
        )
        let available = availableCapacity(at: databaseURL.deletingLastPathComponent())
        guard available >= required else {
            throw RestoreFailure.insufficientCapacity(required: required, available: available)
        }
    }

    private static func saturatingMultiply(_ value: UInt64, by factor: UInt64) -> UInt64 {
        let result = value.multipliedReportingOverflow(by: factor)
        return result.overflow ? .max : result.partialValue
    }

    private static func saturatingAdd(_ values: UInt64...) -> UInt64 {
        values.reduce(0) { total, value in
            let result = total.addingReportingOverflow(value)
            return result.overflow ? .max : result.partialValue
        }
    }

    private static func fileSize(_ url: URL, fileManager: FileManager) -> UInt64 {
        ((try? fileManager.attributesOfItem(atPath: url.path)[.size]) as? NSNumber)?.uint64Value ?? 0
    }

    private static func availableCapacity(at url: URL) -> UInt64 {
        let values = try? url.resourceValues(forKeys: [
            .volumeAvailableCapacityForImportantUsageKey,
            .volumeAvailableCapacityKey,
        ])
        if let important = values?.volumeAvailableCapacityForImportantUsage, important > 0 {
            return UInt64(important)
        }
        if let ordinary = values?.volumeAvailableCapacity, ordinary > 0 {
            return UInt64(ordinary)
        }
        return .max
    }

    private static func isSQLiteFile(at url: URL) -> Bool {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return false }
        defer { try? handle.close() }
        guard let head = try? handle.read(upToCount: 16), head.count >= 16 else { return false }
        return Array(head) == Array("SQLite format 3".utf8) + [0x00]
    }

    private static func removeIfPresent(_ url: URL) {
        if FileManager.default.fileExists(atPath: url.path) {
            try? FileManager.default.removeItem(at: url)
        }
    }

    private static func restoreSidecar(from source: URL, toMainPath dbPath: String, suffix: String) {
        let src = URL(fileURLWithPath: source.path + suffix)
        guard FileManager.default.fileExists(atPath: src.path) else { return }
        let dst = URL(fileURLWithPath: dbPath + suffix)
        if FileManager.default.fileExists(atPath: dst.path) { try? FileManager.default.removeItem(at: dst) }
        try? FileManager.default.copyItem(at: src, to: dst)
    }
}
