import Foundation
import XCTest
@testable import StrandImport

final class WhoopV91JournalCompatibilityTests: XCTestCase {
    private var directory: URL!

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("whoop-v91-journal-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true
        )
    }

    override func tearDownWithError() throws {
        if let directory { try? FileManager.default.removeItem(at: directory) }
    }

    func testExplicitWhoopImportReadsAnsweredYesHeaderVerbatim() throws {
        try writeJournal()
        let result = try ImportCoordinator().importWhoopExport(from: directory)

        XCTAssertEqual(result.journal.count, 2)
        XCTAssertEqual(result.journal[0].question, "Alcohol")
        XCTAssertEqual(result.journal[0].answer, "TRUE")
        XCTAssertEqual(result.journal[0].notes, "Dinner")
        XCTAssertEqual(result.journal[1].question, "Late meal")
        XCTAssertEqual(result.journal[1].answer, "FALSE")
        XCTAssertEqual(result.summary.recordCount, 2)
        XCTAssertEqual(result.summary.countsByCategory["journal"], 2)
    }

    func testAutoDetectedWhoopImportUsesTheSameCompatibilityPass() throws {
        try writeJournal()
        let detected = try ImportCoordinator().detectAndImport(from: directory)
        guard case .whoopExport(let result) = detected else {
            return XCTFail("journal_entries.csv must auto-detect as a WHOOP export")
        }
        XCTAssertEqual(result.journal.map(\.answer), ["TRUE", "FALSE"])
    }

    private func writeJournal() throws {
        let csv = """
        Question text,Answered yes,Notes
        Alcohol,TRUE,Dinner
        Late meal,FALSE,
        """
        try Data(csv.utf8).write(
            to: directory.appendingPathComponent("journal_entries.csv")
        )
    }
}
