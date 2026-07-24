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
    private static let maximumJournalBytes = 256 << 20

    static func applyingIfNeeded(
        to result: WhoopImportResult,
        sourceURL: URL
    ) throws -> WhoopImportResult {
        guard let data = try journalData(from: sourceURL) else { return result }
        let table = CSVTable(data: data)
        guard table.normalizedHeaders.contains("answered_yes") else { return result }
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

    private static func journalData(from url: URL) throws -> Data? {
        let fileManager = FileManager.default
        var isDirectory: ObjCBool = false
        guard fileManager.fileExists(atPath: url.path, isDirectory: &isDirectory) else {
            return nil
        }
        return isDirectory.boolValue
            ? journalData(inFolder: url, fileManager: fileManager)
            : try journalData(inArchive: url)
    }

    private static func journalData(
        inFolder folder: URL,
        fileManager: FileManager
    ) -> Data? {
        guard let enumerator = fileManager.enumerator(
            at: folder,
            includingPropertiesForKeys: [.fileSizeKey, .isRegularFileKey],
            options: [.skipsHiddenFiles]
        ) else { return nil }

        for case let file as URL in enumerator where file.pathExtension.lowercased() == "csv" {
            let values = try? file.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey])
            guard values?.isRegularFile == true,
                  let size = values?.fileSize,
                  size <= maximumJournalBytes,
                  let data = try? Data(contentsOf: file),
                  isAnsweredYesJournal(data)
            else { continue }
            return data
        }
        return nil
    }

    private static func journalData(inArchive archiveURL: URL) throws -> Data? {
        guard let archive = try? Archive(url: archiveURL, accessMode: .read) else { return nil }
        for entry in archive where entry.type == .file && entry.path.lowercased().hasSuffix(".csv") {
            guard let declared = Int(exactly: entry.uncompressedSize),
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
            if isAnsweredYesJournal(data) { return data }
        }
        return nil
    }

    private static func isAnsweredYesJournal(_ data: Data) -> Bool {
        let headers = Set(CSVTable(data: data).normalizedHeaders)
        return headers.contains("answered_yes")
            && (headers.contains("question_text") || headers.contains("question"))
    }
}
