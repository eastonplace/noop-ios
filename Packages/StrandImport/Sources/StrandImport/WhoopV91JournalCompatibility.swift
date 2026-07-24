import Foundation
import ZIPFoundation

/// Compatibility repair for RyanBR NOOP v9.1 / real WHOOP journal exports.
///
/// WHOOP names the Boolean column `Answered yes` (`answered_yes` after normalization), while NOOP's older
/// tolerant parser knew only `answered_yes_no`, `answer`, and `answer_text`. The base parser still recovers
/// the row, question, timestamp, and notes, but silently leaves every answer nil. This narrow second pass
/// reads only the journal CSV and replaces that array without touching cycle, sleep, workout, or summary
/// semantics. TRUE/FALSE casing is preserved verbatim for the existing store mapping.
enum WhoopV91JournalCompatibility {
    /// Real journal exports are small. A 32 MiB ceiling is generous while avoiding a second 256 MiB
    /// materialization on top of the main importer's retained CSV bundle.
    private static let maximumJournalBytes = 32 << 20
    private static let maximumCSVEntriesToInspect = 64
    private static let canonicalFilename = "journal_entries.csv"

    static func applyingIfNeeded(
        to result: WhoopImportResult,
        sourceURL: URL
    ) throws -> WhoopImportResult {
        guard let table = try journalTable(from: sourceURL),
              table.normalizedHeaders.contains("answered_yes")
        else { return result }

        let journal = parse(table)
        guard !journal.isEmpty else { return result }

        return WhoopImportResult(
            cycles: result.cycles,
            sleeps: result.sleeps,
            workouts: result.workouts,
            journal: journal,
            summary: result.summary
        )
    }

    private static func parse(_ table: CSVTable) -> [WhoopJournalRow] {
        var rows: [WhoopJournalRow] = []
        rows.reserveCapacity(table.rows.count)
        for row in table.rows {
            let tz = WhoopTime.tzOffsetMinutes(row.cell("cycle_timezone"))
            var value = WhoopJournalRow()
            value.tzOffsetMin = tz
            value.cycleStart = WhoopTime.parse(
                row.cell("cycle_start_time"),
                offsetMinutes: tz
            )
            value.question = row.cell("question_text", "question")
            value.answer = row.cell(
                "answered_yes",
                "answered_yes_no",
                "answer",
                "answer_text"
            )
            value.notes = row.cell("notes")
            if value.question == nil && value.answer == nil && value.notes == nil { continue }
            rows.append(value)
        }
        return rows
    }

    private static func journalTable(from url: URL) throws -> CSVTable? {
        let fileManager = FileManager.default
        var isDirectory: ObjCBool = false
        guard fileManager.fileExists(atPath: url.path, isDirectory: &isDirectory) else {
            return nil
        }
        return isDirectory.boolValue
            ? journalTable(inFolder: url, fileManager: fileManager)
            : try journalTable(inArchive: url)
    }

    private static func journalTable(
        inFolder folder: URL,
        fileManager: FileManager
    ) -> CSVTable? {
        guard let enumerator = fileManager.enumerator(
            at: folder,
            includingPropertiesForKeys: [.fileSizeKey, .isRegularFileKey],
            options: [.skipsHiddenFiles]
        ) else { return nil }

        var fallback: CSVTable?
        var inspected = 0
        for case let file as URL in enumerator where file.pathExtension.lowercased() == "csv" {
            guard inspected < maximumCSVEntriesToInspect else { break }
            inspected += 1

            let values = try? file.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey])
            guard values?.isRegularFile == true,
                  let size = values?.fileSize,
                  size >= 0,
                  size <= maximumJournalBytes,
                  let data = try? Data(contentsOf: file)
            else { continue }

            let table = CSVTable(data: data)
            guard isAnsweredYesJournal(table) else { continue }
            if file.lastPathComponent.lowercased() == canonicalFilename {
                return table
            }
            if fallback == nil { fallback = table }
        }
        return fallback
    }

    private static func journalTable(inArchive archiveURL: URL) throws -> CSVTable? {
        guard let archive = try? Archive(url: archiveURL, accessMode: .read) else { return nil }

        let candidates = archive.lazy
            .filter { $0.type == .file && $0.path.lowercased().hasSuffix(".csv") }
            .prefix(maximumCSVEntriesToInspect)
            .sorted {
                let lhsExact = ($0.path as NSString).lastPathComponent.lowercased() == canonicalFilename
                let rhsExact = ($1.path as NSString).lastPathComponent.lowercased() == canonicalFilename
                return lhsExact && !rhsExact
            }

        for entry in candidates {
            guard let declared = Int(exactly: entry.uncompressedSize),
                  declared >= 0,
                  declared <= maximumJournalBytes
            else { continue }

            var data = Data()
            data.reserveCapacity(min(declared, 1 << 20))
            var written = 0
            do {
                _ = try archive.extract(entry) { chunk in
                    written += chunk.count
                    guard written <= maximumJournalBytes else { throw CancellationError() }
                    data.append(chunk)
                }
            } catch {
                continue
            }

            let table = CSVTable(data: data)
            if isAnsweredYesJournal(table) { return table }
        }
        return nil
    }

    private static func isAnsweredYesJournal(_ table: CSVTable) -> Bool {
        let headers = Set(table.normalizedHeaders)
        return headers.contains("answered_yes")
            && (headers.contains("question_text") || headers.contains("question"))
    }
}
