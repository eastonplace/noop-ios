import Foundation
import XCTest
import ZIPFoundation
@testable import StrandImport

final class RoutineSpreadsheetImporterTests: XCTestCase {
    func testCSVPreservesOrderQuotedCommasNewlinesAndEscapedQuotes() throws {
        let text = "\u{FEFF}routine,exercise,sets,reps,rest_sec,rpe,weight_kg,notes\r\n"
            + "Push,\"Press, seated\",3,8-12,90,8.5,22.5,\"Keep \"\"ribs down\"\"\nthen press\"\r\n"
            + "Pull,Row,4,10,120,8,40,\r\n"
            + "Push,Fly,2,15,60,7,10,Slow\r\n"
        let result = try RoutineSpreadsheetImporter.parse(data: Data(text.utf8))
        XCTAssertEqual(result.routines.map(\.name), ["Push", "Pull"])
        XCTAssertEqual(result.routines[0].exercises.map(\.name), ["Press, seated", "Fly"])
        let line = result.routines[0].exercises[0]
        XCTAssertEqual(line.sets, 3)
        XCTAssertEqual(line.reps, "8-12")
        XCTAssertEqual(line.restSeconds, 90)
        XCTAssertEqual(line.rpe, 8.5)
        XCTAssertEqual(line.load?.value, 22.5)
        XCTAssertEqual(line.load?.unit, .kilograms)
        XCTAssertEqual(line.notes, "Keep \"ribs down\"\nthen press")
    }

    func testOptionalCellsStayUnplannedAndOnlyExerciseHeaderIsRequired() throws {
        let result = try parse("exercise,sets,reps,weight_kg,rpe\nPush up,,,,\n")
        XCTAssertEqual(result.routines[0].name, "Imported routine")
        let line = result.routines[0].exercises[0]
        XCTAssertNil(line.sets)
        XCTAssertNil(line.reps)
        XCTAssertNil(line.load)
        XCTAssertNil(line.rpe)
    }

    func testSemicolonCSVDecimalCommaAndExplicitUnits() throws {
        let result = try parse("routine;exercise;sets;reps;rest;weight_lb;rpe\nA;Row;3.0;8;1.5 min;135 lb;8,5\n")
        let line = result.routines[0].exercises[0]
        XCTAssertEqual(line.sets, 3)
        XCTAssertEqual(line.restSeconds, 90)
        XCTAssertEqual(line.load?.value, 135)
        XCTAssertEqual(line.load?.unit, .pounds)
        XCTAssertEqual(line.rpe, 8.5)
    }

    func testMalformedCSVIsRejectedInsteadOfImportingAPartialRoutine() {
        for text in [
            "exercise,sets\nBench,3\n\"Unfinished,4",
            "exercise,sets\nBench,3,extra",
            "exercise,sets\nBench,3\n,4",
            "exercise,sets\nBe\"nch,3",
            "exercise,sets\n\"Bench\"oops,3"
        ] {
            XCTAssertThrowsError(try parse(text), text)
        }
    }

    func testInvalidPrescriptionsNeverBecomeBlankOrRoundedValues() {
        let invalid: [(String, String)] = [
            ("sets", "3.4"), ("sets", "0"), ("sets", "-2"), ("sets", "101"),
            ("sets", "3x5"), ("reps", "12-8"), ("reps", "0"), ("reps", "8abc"),
            ("weight_kg", "-5"), ("weight_kg", "nan"), ("weight_kg", "inf"),
            ("weight_kg", "1e309"), ("weight_kg", "50000"), ("weight_kg", "50 lb"),
            ("rpe", "0"), ("rpe", "10.5"), ("rpe", "8 then 9"),
            ("rest_sec", "-1"), ("rest_sec", "2.5"), ("rest_sec", "99999")
        ]
        for (column, value) in invalid {
            XCTAssertThrowsError(try parse("exercise,\(column)\nBench,\(value)\n"), "\(column)=\(value)")
        }
    }

    func testAmbiguousColumnsRepeatedExerciseAndConflictingRoutineMetadataAreRejected() {
        for text in [
            "exercise,sets,target_sets\nBench,3,4",
            "exercise,weight_kg,weight_lb\nBench,50,100",
            "routine,exercise\nPush,Bench Press\nPush,bench-press",
            "routine,routine_note,exercise\nPush,First,Bench\nPush,Different,Fly",
            "routine,training_mode,exercise\nPush,strength,Bench\nPush,endurance,Fly"
        ] {
            XCTAssertThrowsError(try parse(text), text)
        }
    }

    func testExtraColumnsAreDisclosedAndNotUsedAsPrescriptions() throws {
        let result = try parse("exercise,sets,tempo\nBench,3,3010\n")
        XCTAssertEqual(result.routines[0].exercises[0].sets, 3)
        XCTAssertTrue(result.warnings.contains { $0.contains("tempo") })
    }

    func testReportsTheActualSparseWorksheetRowAndRejectsFormulaCells() throws {
        let workbook = try xlsx(sheet: """
        <worksheet xmlns="http://schemas.openxmlformats.org/spreadsheetml/2006/main"><sheetData>
        <row r="1"><c r="A1" t="inlineStr"><is><t>exercise</t></is></c><c r="C1" t="inlineStr"><is><t>sets</t></is></c></row>
        <row r="12"><c r="A12" t="inlineStr"><is><t>Bench</t></is></c><c r="C12"><v>3.5</v></c></row>
        </sheetData></worksheet>
        """)
        XCTAssertThrowsError(try RoutineSpreadsheetImporter.parse(data: workbook)) { error in
            XCTAssertTrue(error.localizedDescription.contains("12"), error.localizedDescription)
        }
        let formula = try xlsx(sheet: """
        <worksheet><sheetData><row r="1"><c r="A1" t="inlineStr"><is><t>exercise</t></is></c></row>
        <row r="2"><c r="A2" t="str"><f>CONCAT("Bench", " press")</f><v>Bench press</v></c></row>
        </sheetData></worksheet>
        """)
        XCTAssertThrowsError(try RoutineSpreadsheetImporter.parse(data: formula))
    }

    func testXLSXSharedStringsRichTextSparseCellsAndWorkbookRelationships() throws {
        let shared = """
        <sst xmlns="http://schemas.openxmlformats.org/spreadsheetml/2006/main" count="5" uniqueCount="5">
        <si><t>routine</t></si><si><t>exercise</t></si><si><t>sets</t></si>
        <si><t>Upper</t></si><si><r><t>Bench </t></r><r><t>press</t></r></si></sst>
        """
        let sheet = """
        <worksheet xmlns="http://schemas.openxmlformats.org/spreadsheetml/2006/main"><sheetData>
        <row r="1"><c r="A1" t="s"><v>0</v></c><c r="C1" t="s"><v>1</v></c><c r="E1" t="s"><v>2</v></c></row>
        <row r="4"><c r="A4" t="s"><v>3</v></c><c r="C4" t="s"><v>4</v></c><c r="E4"><v>3</v></c></row>
        </sheetData></worksheet>
        """
        let data = try xlsx(sheet: sheet, shared: shared, sheetPath: "xl/worksheets/plan7.xml")
        let result = try RoutineSpreadsheetImporter.parse(data: data)
        XCTAssertEqual(result.routines.count, 1)
        XCTAssertEqual(result.routines[0].name, "Upper")
        XCTAssertEqual(result.routines[0].exercises[0].name, "Bench press")
        XCTAssertEqual(result.routines[0].exercises[0].sets, 3)
        XCTAssertEqual(result.routines[0].exercises[0].sourceRow, 4)
    }

    func testRejectsCorruptXLSXInvalidSharedStringReferencesAndExternalRelationships() throws {
        XCTAssertThrowsError(try RoutineSpreadsheetImporter.parse(data: Data([0x50, 0x4b, 0x03, 0x04])))
        let invalidString = try xlsx(sheet: "<worksheet><sheetData><row r=\"1\"><c r=\"A1\" t=\"s\"><v>99</v></c></row></sheetData></worksheet>")
        XCTAssertThrowsError(try RoutineSpreadsheetImporter.parse(data: invalidString))
        let external = try archive([
            ("xl/workbook.xml", "<workbook xmlns:r=\"urn:relations\"><sheets><sheet name=\"Plan\" sheetId=\"1\" r:id=\"rId1\"/></sheets></workbook>"),
            ("xl/_rels/workbook.xml.rels", "<Relationships><Relationship Id=\"rId1\" Type=\"http://schemas.openxmlformats.org/officeDocument/2006/relationships/worksheet\" Target=\"https://example.invalid/plan.xml\" TargetMode=\"External\"/></Relationships>")
        ])
        XCTAssertThrowsError(try RoutineSpreadsheetImporter.parse(data: external))
    }

    func testRejectsXMLDeclarationsThatCouldExpandEntities() throws {
        let data = try xlsx(sheet: "<!DOCTYPE worksheet [<!ENTITY exercise \"Bench\">]><worksheet><sheetData/></worksheet>")
        XCTAssertThrowsError(try RoutineSpreadsheetImporter.parse(data: data))
    }

    func testRejectsAValidXMLPartWithACorruptedZipChecksum() throws {
        var data = try xlsx(sheet: "<worksheet><sheetData><row r=\"1\"><c r=\"A1\" t=\"inlineStr\"><is><t>exercise</t></is></c></row><row r=\"2\"><c r=\"A2\" t=\"inlineStr\"><is><t>Bench</t></is></c></row></sheetData></worksheet>")
        let centralHeader = try XCTUnwrap(data.range(of: Data([0x50, 0x4b, 0x01, 0x02])))
        data[centralHeader.lowerBound + 16] ^= 0xff
        XCTAssertThrowsError(try RoutineSpreadsheetImporter.parse(data: data))
    }

    func testRejectsAnInvalidRowReferenceInsteadOfInventingARowNumber() throws {
        let data = try xlsx(sheet: "<worksheet><sheetData><row r=\"bad\"><c r=\"A1\" t=\"inlineStr\"><is><t>exercise</t></is></c></row><row r=\"2\"><c r=\"A2\" t=\"inlineStr\"><is><t>Bench</t></is></c></row></sheetData></worksheet>")
        XCTAssertThrowsError(try RoutineSpreadsheetImporter.parse(data: data))
    }

    func testBoundsFileRowsColumnsAndDecompressionBeforeProducingAPreview() throws {
        XCTAssertThrowsError(try RoutineSpreadsheetImporter.parse(data: Data(repeating: 32, count: RoutineSpreadsheetImporter.maxFileBytes + 1)))
        XCTAssertThrowsError(try parse("exercise\n" + Array(repeating: "Bench", count: 5_001).joined(separator: "\n")))
        let hugePart = try xlsx(sheet: "<worksheet>" + String(repeating: " ", count: 8 * 1_024 * 1_024) + "</worksheet>")
        XCTAssertThrowsError(try RoutineSpreadsheetImporter.parse(data: hugePart))
        let wide = try xlsx(sheet: "<worksheet><sheetData><row r=\"1\"><c r=\"XFD1\" t=\"inlineStr\"><is><t>exercise</t></is></c></row></sheetData></worksheet>")
        XCTAssertThrowsError(try RoutineSpreadsheetImporter.parse(data: wide))
    }

    private func parse(_ csv: String) throws -> RoutineSpreadsheetDocument {
        try RoutineSpreadsheetImporter.parse(data: Data(csv.utf8))
    }

    private func xlsx(sheet: String, shared: String? = nil, sheetPath: String = "xl/worksheets/sheet1.xml") throws -> Data {
        var entries = [
            ("xl/workbook.xml", "<workbook xmlns:r=\"http://schemas.openxmlformats.org/officeDocument/2006/relationships\"><sheets><sheet name=\"Plan\" sheetId=\"1\" r:id=\"rId1\"/></sheets></workbook>"),
            ("xl/_rels/workbook.xml.rels", "<Relationships><Relationship Id=\"rId1\" Type=\"http://schemas.openxmlformats.org/officeDocument/2006/relationships/worksheet\" Target=\"\(sheetPath.dropFirst(3))\"/></Relationships>"),
            (sheetPath, sheet)
        ]
        if let shared { entries.append(("xl/sharedStrings.xml", shared)) }
        return try archive(entries)
    }

    private func archive(_ entries: [(String, String)]) throws -> Data {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString).appendingPathExtension("xlsx")
        defer { try? FileManager.default.removeItem(at: url) }
        let archive = try Archive(url: url, accessMode: .create)
        for (path, string) in entries {
            let data = Data(string.utf8)
            try archive.addEntry(with: path, type: .file, uncompressedSize: Int64(data.count), compressionMethod: .deflate) { position, size in
                data.subdata(in: Int(position)..<(Int(position) + size))
            }
        }
        return try Data(contentsOf: url)
    }
}
