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
        case replacementRemoval
    }

    enum BackupWriteFault: Equatable {
        case beforeInstall
    }

    enum BackupResult: Sendable {
        case exported(URL)
        /// Export succeeded, but the live SQLite file is above the normal database-entry restore ceiling.
        case exportedOversize(URL, bytes: UInt64, limit: UInt64)
        /// The optional safety copy exists only when a previous database was present. Restored settings
        /// stay staged until the lifecycle has reopened and migrated the replacement successfully.
        case imported(safetyCopy: URL?, stagedSettings: Data?)
        case cancelled
        /// Restore stopped only at the normal database-entry size ceiling. The caller can ask for an
        /// explicit override; every other archive and restore guard remains active.
        case restoreTooLarge(name: String, limit: UInt64)
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
            try await Task.detached(priority: .utility) {
                try writeVerifiedBackupZip(dbURL: dbURL, to: dest, settingsJSON: currentSettingsJSON())
            }.value
            return exportOutcome(dest, archiveAt: dest)
        } catch {
            return .failure(String(localized: "Export failed: \(error.localizedDescription)"))
        }
        #else
        let stagingDirectory = FileManager.default.temporaryDirectory.appendingPathComponent(
            "noop-export-\(UUID().uuidString)", isDirectory: true
        )
        let staged = stagingDirectory.appendingPathComponent(defaultBackupName())
        defer { try? FileManager.default.removeItem(at: stagingDirectory) }
        do {
            try FileManager.default.createDirectory(at: stagingDirectory, withIntermediateDirectories: true)
            try await Task.detached(priority: .utility) {
                try writeVerifiedBackupZip(dbURL: dbURL, to: staged, settingsJSON: currentSettingsJSON())
            }.value
        } catch {
            return .failure(String(localized: "Export failed: \(error.localizedDescription)"))
        }
        guard let dest = await DocumentPicker.export(staged) else { return .cancelled }
        return exportOutcome(dest, archiveAt: staged)
        #endif
    }

    private static func exportOutcome(
        _ destination: URL,
        archiveAt archiveURL: URL,
        limits: ArchiveRestoreLimits = ArchiveRestoreLimits()
    ) -> BackupResult {
        do {
            // Classify the bytes that were actually written, through the same static archive guards
            // import uses. A live database can change after checkpoint and is not proof of this file.
            let validated = try validateBackupArchive(
                at: archiveURL,
                limits: limits,
                allowOversizeDatabase: true
            )
            guard validated.databaseBytes > limits.maxDatabaseBytes else {
                return .exported(destination)
            }
            return .exportedOversize(
                destination,
                bytes: validated.databaseBytes,
                limit: limits.maxDatabaseBytes
            )
        } catch {
            return .failure(String(localized: "Backup was saved, but NOOP cannot import it: \(error.localizedDescription)"))
        }
    }

    static func exportOutcomeForTesting(
        destination: URL,
        archiveAt archiveURL: URL,
        limits: ArchiveRestoreLimits
    ) -> BackupResult {
        exportOutcome(destination, archiveAt: archiveURL, limits: limits)
    }

    static func isSuccessfulExport(_ result: BackupResult) -> Bool {
        switch result {
        case .exported, .exportedOversize: return true
        default: return false
        }
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
        try writeBackupZipAtomically(dbURL: dbURL, to: dest, settingsJSON: settingsJSON)
    }

    private static func writeBackupZipAtomically(
        dbURL: URL,
        to destination: URL,
        settingsJSON: Data?,
        fault: BackupWriteFault? = nil
    ) throws {
        let fileManager = FileManager.default
        let staged = destination.deletingLastPathComponent().appendingPathComponent(
            ".\(destination.lastPathComponent).\(UUID().uuidString).tmp"
        )
        defer { removeIfPresent(staged) }
        try writeBackupZip(dbURL: dbURL, to: staged, settingsJSON: settingsJSON)
        #if os(iOS)
        try? fileManager.setAttributes(
            [.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication],
            ofItemAtPath: staged.path
        )
        #endif
        if fault == .beforeInstall { throw CocoaError(.fileWriteUnknown) }
        try atomicInstall(staged, at: destination)
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
            try writeVerifiedBackupZip(dbURL: dbURL, to: dest, settingsJSON: currentSettingsJSON())
            return exportOutcome(dest, archiveAt: dest)
        } catch {
            return .failure(String(localized: "Backup failed: \(error.localizedDescription)"))
        }
    }

    static func writeBackupForTesting(
        databaseAt dbURL: URL,
        to dest: URL,
        settings: [String: Any]? = nil,
        fault: BackupWriteFault? = nil
    ) throws {
        try writeBackupZipAtomically(
            dbURL: dbURL,
            to: dest,
            settingsJSON: settings.flatMap { BackupSettings.encode($0) },
            fault: fault
        )
    }

    @MainActor
    static func runImport(lifecycle: RestoreLifecycle, allowOversize: Bool = false) async -> BackupResult {
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
            restore(from: pickedSource, toDatabaseAt: dbPath, allowOversize: allowOversize)
        }.value
        return await finishRestore(result, databasePath: dbPath, lifecycle: lifecycle)
    }

    @MainActor
    static func restore(from pickedSource: URL, lifecycle: RestoreLifecycle,
                        allowOversize: Bool = false) async -> BackupResult {
        let dbPath: String
        do { dbPath = try StorePaths.defaultDatabasePath() }
        catch { return .failure(String(localized: "Couldn't locate the NOOP database. \(error.localizedDescription)")) }
        return await restore(from: pickedSource, toDatabaseAt: dbPath, lifecycle: lifecycle,
                             allowOversize: allowOversize)
    }

    @MainActor
    static func restore(from pickedSource: URL, toDatabaseAt dbPath: String,
                        lifecycle: RestoreLifecycle,
                        settingsDefaults: UserDefaults = .standard,
                        fault: RestoreFault? = nil,
                        allowOversize: Bool = false,
                        limits: ArchiveRestoreLimits = ArchiveRestoreLimits()) async -> BackupResult {
        do { try await lifecycle.quiesce() }
        catch { return .failure(String(localized: "Couldn't pause the local database safely. Nothing was replaced. \(error.localizedDescription)")) }
        let result = await Task.detached(priority: .utility) {
            restore(from: pickedSource, toDatabaseAt: dbPath, fault: fault,
                    allowOversize: allowOversize, limits: limits)
        }.value
        return await finishRestore(result, databasePath: dbPath, lifecycle: lifecycle,
                                   settingsDefaults: settingsDefaults, fault: fault)
    }

    @MainActor
    private static func finishRestore(_ result: BackupResult, databasePath: String,
                                      lifecycle: RestoreLifecycle,
                                      settingsDefaults: UserDefaults = .standard,
                                      fault: RestoreFault? = nil) async -> BackupResult {
        switch result {
        case .imported(let safetyCopy, let stagedSettings):
            do {
                try await lifecycle.reopenAndMigrate()
                if let stagedSettings {
                    BackupSettings.apply(BackupSettings.decode(stagedSettings), to: settingsDefaults)
                }
                settingsDefaults.set(Date().timeIntervalSince1970, forKey: "backup.lastRestoreAt")
                return result
            } catch {
                do {
                    try await lifecycle.quiesce()
                    if let safetyCopy {
                        try await Task.detached(priority: .utility) {
                            try rollback(from: safetyCopy, toDatabaseAt: databasePath)
                        }.value
                    } else {
                        try await Task.detached(priority: .utility) {
                            try removeReplacement(at: databasePath, fault: fault)
                        }.value
                    }
                    try await lifecycle.reopenAndMigrate()
                    if safetyCopy == nil {
                        return .failure(String(localized: "The replacement database could not be opened or migrated, so NOOP removed it and reopened an empty store. \(error.localizedDescription)"))
                    }
                    return .failure(String(localized: "The replacement database could not be opened or migrated, so NOOP restored your previous data automatically. \(error.localizedDescription)"))
                } catch {
                    if let safetyCopy {
                        return .failure(String(localized: "The replacement failed and automatic rollback could not reopen the previous database. The safety copy is at \(safetyCopy.path). \(error.localizedDescription)"))
                    }
                    return .failure(String(localized: "The replacement failed and NOOP could not reopen an empty store. \(error.localizedDescription)"))
                }
            }
        case .failure, .cancelled, .exported, .exportedOversize, .restoreTooLarge:
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
                        fault: RestoreFault? = nil,
                        allowOversize: Bool = false,
                        limits: ArchiveRestoreLimits = ArchiveRestoreLimits()) -> BackupResult {
        let fm = FileManager.default
        let source: URL
        let extractedDir: URL?

        if isZipFile(at: pickedSource) {
            let tmpExtract = fm.temporaryDirectory
                .appendingPathComponent("noop-import-\(UUID().uuidString)", isDirectory: true)
            do {
                if fm.fileExists(atPath: tmpExtract.path) { try fm.removeItem(at: tmpExtract) }
                try fm.createDirectory(at: tmpExtract, withIntermediateDirectories: true)
                try extractBackupZip(at: pickedSource, into: tmpExtract,
                                     limits: limits, allowOversizeDatabase: allowOversize)
            } catch let archiveError as BackupArchiveError {
                try? fm.removeItem(at: tmpExtract)
                if case .entryTooLarge(let path) = archiveError, path == backupEntryName {
                    return .restoreTooLarge(name: path, limit: limits.maxDatabaseBytes)
                }
                return .failure(String(localized: "Couldn't open the backup archive: \(archiveError.localizedDescription)"))
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
            do {
                let databaseBytes = try fileSize(pickedSource, fileManager: fm)
                guard databaseBytes <= limits.maxTotalUncompressedBytes else {
                    return .failure(BackupArchiveError.totalTooLarge.localizedDescription)
                }
                if databaseBytes > limits.maxDatabaseBytes, !allowOversize {
                    return .restoreTooLarge(
                        name: pickedSource.lastPathComponent,
                        limit: limits.maxDatabaseBytes
                    )
                }
            } catch {
                return .failure(String(localized: "Couldn't inspect the selected backup: \(error.localizedDescription)"))
            }
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

        let legacyWALPresent = extractedDir == nil
            && fm.fileExists(atPath: source.path + "-wal")
        if legacyWALPresent {
            do {
                try validateLegacyWAL(at: URL(fileURLWithPath: source.path + "-wal"))
                return .failure(String(localized: "This legacy backup has a WAL sidecar. NOOP cannot prove that a legacy WAL is complete, so it was not restored. Export a new .noopbak backup from the source device instead; your current data was left untouched."))
            } catch {
                return .failure(String(localized: "This legacy backup has a malformed WAL sidecar and can't be restored. Your current data was left untouched. \(error.localizedDescription)"))
            }
        }
        if !legacyWALPresent,
           let complaint = DatabaseIntegrity.quickCheckFailure(atPath: source.path) {
            return .failure(String(localized: "This backup file is damaged and can't be restored (SQLite reports: \(complaint)). Your current data was left untouched."))
        }

        let dbURL = URL(fileURLWithPath: dbPath)
        do {
            try preflightRestoreCapacity(source: source, pickedSource: pickedSource, databaseURL: dbURL,
                                         extractedDirectory: extractedDir, fileManager: fm)
            var safetyCopy: URL?
            let replacementSidecar = dbURL.deletingLastPathComponent()
                .appendingPathComponent("whoop-replaced-\(timestamp()).sqlite")
            if fm.fileExists(atPath: dbURL.path) {
                if fm.fileExists(atPath: replacementSidecar.path) { try fm.removeItem(at: replacementSidecar) }
                try onlineBackup(fromDatabaseAt: dbURL.path, to: replacementSidecar.path)
                safetyCopy = replacementSidecar
            }

            let incoming = dbURL.deletingLastPathComponent()
                .appendingPathComponent(".noop-restore-\(UUID().uuidString).sqlite")
            defer { removeIfPresent(incoming) }
            if fault == .replacementCopy { throw RestoreFailure.simulatedReplacementCopy }
            try fm.copyItem(at: source, to: incoming)
            if let complaint = DatabaseIntegrity.quickCheckFailure(atPath: incoming.path), !legacyWALPresent {
                throw RestoreFailure.invalidReplacement(complaint)
            }
            removeIfPresent(URL(fileURLWithPath: dbPath + "-wal"))
            removeIfPresent(URL(fileURLWithPath: dbPath + "-shm"))
            try atomicInstall(incoming, at: dbURL)

            let forcedComplaint = fault == .postSwapValidation ? "simulated post-swap failure" : nil
            if let complaint = forcedComplaint ?? DatabaseIntegrity.quickCheckFailure(atPath: dbURL.path) {
                if let safetyCopy, fm.fileExists(atPath: safetyCopy.path) {
                    do {
                        try rollback(from: safetyCopy, toDatabaseAt: dbPath)
                        return .failure(String(localized: "Import failed its post-restore integrity check (SQLite reports: \(complaint)). Your previous data was rolled back automatically."))
                    } catch {
                        return .failure(String(localized: "Import failed its post-restore integrity check (SQLite reports: \(complaint)), and automatic rollback failed. The safety copy remains at \(safetyCopy.path). \(error.localizedDescription)"))
                    }
                }
                removeIfPresent(dbURL)
                removeIfPresent(URL(fileURLWithPath: dbPath + "-wal"))
                removeIfPresent(URL(fileURLWithPath: dbPath + "-shm"))
                guard !fm.fileExists(atPath: dbURL.path) else {
                    return .failure(String(localized: "Import failed its post-restore integrity check (SQLite reports: \(complaint)), and the damaged fresh database could not be removed."))
                }
                return .failure(String(localized: "Import failed its post-restore integrity check (SQLite reports: \(complaint)). The damaged file was removed; there was no previous database to roll back."))
            }

            let stagedSettings: Data?
            if let extractedDir {
                let settingsURL = extractedDir.appendingPathComponent(BackupSettings.entryName)
                stagedSettings = try? Data(contentsOf: settingsURL)
            } else {
                stagedSettings = nil
            }
            return .imported(safetyCopy: safetyCopy, stagedSettings: stagedSettings)
        } catch {
            return .failure(String(localized: "Import failed. Your existing data was kept. \(error.localizedDescription)"))
        }
    }

    private enum RestoreFailure: LocalizedError {
        case simulatedReplacementCopy
        case replacementRemovalFailed
        case invalidReplacement(String)
        case sqliteBackup(String)
        case insufficientCapacity(required: UInt64, available: UInt64)

        var errorDescription: String? {
            switch self {
            case .simulatedReplacementCopy:
                return "Simulated replacement-copy failure."
            case .replacementRemovalFailed:
                return "NOOP could not remove the rejected replacement database."
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

    private static func removeReplacement(at dbPath: String, fault: RestoreFault? = nil) throws {
        if fault == .replacementRemoval { throw RestoreFailure.replacementRemovalFailed }
        let fileManager = FileManager.default
        let urls = [
            URL(fileURLWithPath: dbPath),
            URL(fileURLWithPath: dbPath + "-wal"),
            URL(fileURLWithPath: dbPath + "-shm"),
        ]
        for url in urls where fileManager.fileExists(atPath: url.path) {
            try fileManager.removeItem(at: url)
        }
        guard urls.allSatisfy({ !fileManager.fileExists(atPath: $0.path) }) else {
            throw RestoreFailure.replacementRemovalFailed
        }
    }

    private static let backupEntryName = "noop-backup.sqlite"

    struct ArchiveRestoreLimits: Sendable {
        static let defaultMaxDatabaseBytes: UInt64 = 4_294_967_296
        static let defaultMaxSettingsBytes: UInt64 = 1_048_576
        /// Absolute streamed-extraction ceiling after the user explicitly approves a large restore.
        /// Capacity preflight still requires enough room for extraction, validation, swap, and rollback.
        static let defaultMaxApprovedDatabaseBytes: UInt64 = 17_179_869_184
        var maxArchiveCompressedBytes: UInt64 = 1_073_741_824
        var maxEntryCount = 2
        // The normal 4 GiB database limit produces the explicit warning. Approval bypasses only that
        // threshold; this separate 16 GiB hard ceiling plus the settings allowance always remains active.
        var maxTotalUncompressedBytes: UInt64 = defaultMaxApprovedDatabaseBytes + defaultMaxSettingsBytes
        var maxDatabaseBytes: UInt64 = defaultMaxDatabaseBytes
        var maxSettingsBytes: UInt64 = defaultMaxSettingsBytes
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
        case missingDatabase

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
            case .missingDatabase:
                return "The archive does not contain noop-backup.sqlite."
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

    private struct ValidatedBackupArchive {
        let archive: Archive
        let entries: [Entry]
        let declaredTotal: UInt64
        let databaseBytes: UInt64
    }

    private static func validateBackupArchive(
        at zipURL: URL,
        limits: ArchiveRestoreLimits,
        allowOversizeDatabase: Bool
    ) throws -> ValidatedBackupArchive {
        let attributes = try FileManager.default.attributesOfItem(atPath: zipURL.path)
        guard let archiveSize = attributes[.size] as? NSNumber else {
            throw CocoaError(.fileReadUnknown, userInfo: [NSFilePathErrorKey: zipURL.path])
        }
        let archiveBytes = archiveSize.uint64Value
        guard archiveBytes <= limits.maxArchiveCompressedBytes else {
            throw BackupArchiveError.compressedInputTooLarge
        }

        let archive = try Archive(url: zipURL, accessMode: .read)
        guard limits.maxEntryCount > 0 else { throw BackupArchiveError.tooManyEntries }
        var entries: [Entry] = []
        var flattenedNames = Set<String>()
        var declaredActualTotal: UInt64 = 0
        var databaseBytes: UInt64?

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
            if entry.uncompressedSize > perEntryLimit {
                guard entry.path == backupEntryName, allowOversizeDatabase else {
                    throw BackupArchiveError.entryTooLarge(entry.path)
                }
            }
            if entry.path == backupEntryName { databaseBytes = entry.uncompressedSize }
            let actualAdd = declaredActualTotal.addingReportingOverflow(entry.uncompressedSize)
            guard !actualAdd.overflow,
                  actualAdd.partialValue <= limits.maxTotalUncompressedBytes else {
                throw BackupArchiveError.totalTooLarge
            }
            declaredActualTotal = actualAdd.partialValue
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

        guard let databaseBytes else { throw BackupArchiveError.missingDatabase }
        return ValidatedBackupArchive(
            archive: archive,
            entries: entries,
            declaredTotal: declaredActualTotal,
            databaseBytes: databaseBytes
        )
    }

    static func extractBackupZip(at zipURL: URL, into destDir: URL,
                                 limits: ArchiveRestoreLimits = ArchiveRestoreLimits(),
                                 allowOversizeDatabase: Bool = false) throws {
        let validated = try validateBackupArchive(
            at: zipURL,
            limits: limits,
            allowOversizeDatabase: allowOversizeDatabase
        )

        let available = try availableCapacity(at: destDir)
        guard available >= validated.declaredTotal else {
            throw RestoreFailure.insufficientCapacity(required: validated.declaredTotal, available: available)
        }

        var extractedTotal: UInt64 = 0
        var extractedURLs: [URL] = []
        do {
            for entry in validated.entries {
                let out = destDir.appendingPathComponent(entry.path)
                guard FileManager.default.createFile(atPath: out.path, contents: nil) else {
                    throw CocoaError(.fileWriteUnknown, userInfo: [NSFilePathErrorKey: out.path])
                }
                extractedURLs.append(out)
                let handle = try FileHandle(forWritingTo: out)
                defer { try? handle.close() }
                var entryBytes: UInt64 = 0
                _ = try validated.archive.extract(entry) { chunk in
                    let chunkBytes = UInt64(chunk.count)
                    let entryAdd = entryBytes.addingReportingOverflow(chunkBytes)
                    guard !entryAdd.overflow, entryAdd.partialValue <= entry.uncompressedSize else {
                        throw BackupArchiveError.extractedSizeMismatch(entry.path)
                    }
                    let totalAdd = extractedTotal.addingReportingOverflow(chunkBytes)
                    guard !totalAdd.overflow, totalAdd.partialValue <= validated.declaredTotal else {
                        throw BackupArchiveError.totalTooLarge
                    }
                    try handle.write(contentsOf: chunk)
                    entryBytes = entryAdd.partialValue
                    extractedTotal = totalAdd.partialValue
                }
                guard entryBytes == entry.uncompressedSize else {
                    throw BackupArchiveError.extractedSizeMismatch(entry.path)
                }
            }
            guard extractedTotal == validated.declaredTotal else {
                throw BackupArchiveError.totalTooLarge
            }
        } catch {
            for url in extractedURLs { try? FileManager.default.removeItem(at: url) }
            throw error
        }
    }

    private static func preflightRestoreCapacity(source: URL, pickedSource: URL, databaseURL: URL,
                                                 extractedDirectory: URL?, fileManager: FileManager) throws {
        let sourceBytes = try fileSize(source, fileManager: fileManager)
        let walBytes = extractedDirectory == nil
            ? try fileSize(URL(fileURLWithPath: source.path + "-wal"), fileManager: fileManager)
            : 0
        let liveBytes = try fileSize(databaseURL, fileManager: fileManager)
        let archiveBytes = extractedDirectory == nil
            ? 0 : try fileSize(pickedSource, fileManager: fileManager)
        let required = saturatingAdd(
            saturatingMultiply(sourceBytes, by: 2),
            saturatingMultiply(walBytes, by: 2),
            saturatingMultiply(liveBytes, by: 2),
            archiveBytes
        )
        let available = try availableCapacity(at: databaseURL.deletingLastPathComponent())
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

    private static func fileSize(_ url: URL, fileManager: FileManager) throws -> UInt64 {
        guard fileManager.fileExists(atPath: url.path) else { return 0 }
        let attributes = try fileManager.attributesOfItem(atPath: url.path)
        guard let size = attributes[.size] as? NSNumber else {
            throw CocoaError(.fileReadUnknown, userInfo: [NSFilePathErrorKey: url.path])
        }
        return size.uint64Value
    }

    private static func availableCapacity(at url: URL) throws -> UInt64 {
        let values = try url.resourceValues(forKeys: [
            .volumeAvailableCapacityForImportantUsageKey,
            .volumeAvailableCapacityKey,
        ])
        if let important = values.volumeAvailableCapacityForImportantUsage, important > 0 {
            return UInt64(important)
        }
        if let ordinary = values.volumeAvailableCapacity, ordinary > 0 {
            return UInt64(ordinary)
        }
        throw CocoaError(.fileReadUnknown, userInfo: [NSFilePathErrorKey: url.path])
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

    /// A legacy sidecar lacks authenticated expected length. Validate enough to report corrupt input,
    /// then fail closed above rather than risking a silent, incomplete recovery.
    private static func validateLegacyWAL(at url: URL) throws {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        let header = try handle.read(upToCount: 32) ?? Data()
        let magic = Array(header.prefix(4))
        guard header.count >= 32,
              magic == [0x37, 0x7f, 0x06, 0x82]
                || magic == [0x37, 0x7f, 0x06, 0x83]
        else {
            throw RestoreFailure.invalidReplacement("legacy WAL header is malformed")
        }
        let pageSizeField = Int(header[8]) << 8 | Int(header[9])
        let pageSize = pageSizeField == 1 ? 65_536 : pageSizeField
        guard pageSize >= 512, pageSize <= 65_536, pageSize.nonzeroBitCount == 1 else {
            throw RestoreFailure.invalidReplacement("legacy WAL has an invalid page size")
        }
        let size = try fileSize(url, fileManager: .default)
        let frameSize = UInt64(24 + pageSize)
        guard size > 32, (size - 32).isMultiple(of: frameSize) else {
            throw RestoreFailure.invalidReplacement("legacy WAL is truncated or contains no complete frames")
        }
    }
}
