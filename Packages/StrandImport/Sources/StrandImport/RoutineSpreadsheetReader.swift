import Foundation
#if canImport(FoundationXML)
import FoundationXML
#endif
import ZIPFoundation

enum RoutineCSVReader {
    static func table(data: Data) throws -> RoutineSpreadsheetTable {
        var decoded: String?
        if data.starts(with: [0xff, 0xfe]) || data.starts(with: [0xfe, 0xff]) {
            decoded = String(data: data, encoding: .utf16)
        } else { decoded = String(data: data, encoding: .utf8) }
        guard var text = decoded else { throw RoutineSpreadsheetImportError.unreadable }
        if text.first == "\u{feff}" { text.removeFirst() }
        guard !text.contains("\0") else { throw RoutineSpreadsheetImportError.unreadable }
        let bytes = Array(text.utf8)
        let separator = delimiter(bytes)
        var rows: [RoutineSpreadsheetRow] = []
        var cells: [String] = []
        var field: [UInt8] = []
        var quoted = false
        var closedQuote = false
        var rowHasContent = false
        var line = 1
        var rowLine = 1
        var index = 0

        func malformed() -> RoutineSpreadsheetImportError {
            .invalid("Row \(line): malformed CSV quoting. Put quotes around values containing commas or newlines, and double any quote inside a quoted value.")
        }
        func finishField() throws {
            guard cells.count < RoutineSpreadsheetImporter.maxColumns,
                  let value = String(bytes: field, encoding: .utf8),
                  value.count <= RoutineSpreadsheetImporter.maxCellCharacters else { throw RoutineSpreadsheetImportError.tooLarge }
            cells.append(value)
            field.removeAll(keepingCapacity: true)
            closedQuote = false
        }
        func finishRow() throws {
            try finishField()
            guard rows.count <= RoutineSpreadsheetImporter.maxRows else { throw RoutineSpreadsheetImportError.tooLarge }
            rows.append(RoutineSpreadsheetRow(number: rowLine, cells: cells))
            cells.removeAll(keepingCapacity: true)
            rowHasContent = false
        }

        while index < bytes.count {
            let byte = bytes[index]
            if quoted {
                if byte == 34 {
                    if index + 1 < bytes.count, bytes[index + 1] == 34 { field.append(34); index += 1 }
                    else { quoted = false; closedQuote = true }
                } else if byte == 10 || byte == 13 {
                    field.append(10)
                    if byte == 13, index + 1 < bytes.count, bytes[index + 1] == 10 { index += 1 }
                    line += 1
                } else { field.append(byte) }
            } else if byte == separator {
                try finishField()
                rowHasContent = true
            } else if byte == 10 || byte == 13 {
                try finishRow()
                if byte == 13, index + 1 < bytes.count, bytes[index + 1] == 10 { index += 1 }
                line += 1
                rowLine = line
            } else if byte == 34 {
                guard field.isEmpty, !closedQuote else { throw malformed() }
                quoted = true
                rowHasContent = true
            } else if closedQuote {
                guard byte == 32 || byte == 9 else { throw malformed() }
            } else {
                field.append(byte)
                rowHasContent = true
            }
            guard field.count <= RoutineSpreadsheetImporter.maxCellCharacters * 4 else { throw RoutineSpreadsheetImportError.tooLarge }
            index += 1
        }
        guard !quoted else { throw malformed() }
        if rowHasContent || !field.isEmpty || !cells.isEmpty { try finishRow() }
        return RoutineSpreadsheetTable(name: nil, rows: rows)
    }

    private static func delimiter(_ bytes: [UInt8]) -> UInt8 {
        var counts: [UInt8: Int] = [44: 0, 59: 0, 9: 0]
        var quoted = false
        var hasContent = false
        for byte in bytes {
            if byte == 34 { quoted.toggle() }
            if !quoted {
                if byte == 10 || byte == 13 {
                    if hasContent { break }
                    continue
                }
                if counts[byte] != nil { counts[byte, default: 0] += 1 }
            }
            if byte != 32 && byte != 10 && byte != 13 { hasContent = true }
        }
        return [UInt8(44), 59, 9].max { counts[$0, default: 0] < counts[$1, default: 0] } ?? 44
    }
}

enum RoutineXLSXReader {
    private static let maxExpandedBytes = 32 * 1_024 * 1_024
    private static let maxPartBytes = 8 * 1_024 * 1_024

    static func tables(data: Data) throws -> [RoutineSpreadsheetTable] {
        let archive: Archive
        do { archive = try Archive(data: data, accessMode: .read) }
        catch { throw RoutineSpreadsheetImportError.unreadable }
        var entries: [String: Entry] = [:]
        var declaredTotal: UInt64 = 0
        for entry in archive {
            guard entries.count < 512, entries[entry.path] == nil else { throw RoutineSpreadsheetImportError.tooLarge }
            guard entry.uncompressedSize <= UInt64(maxExpandedBytes) - declaredTotal else { throw RoutineSpreadsheetImportError.tooLarge }
            declaredTotal += entry.uncompressedSize
            entries[entry.path] = entry
        }
        var expanded = 0
        func part(_ path: String, required: Bool = true) throws -> Data? {
            guard let entry = entries[path] else {
                if required { throw RoutineSpreadsheetImportError.invalid("The Excel workbook is missing \(path). Export a new .xlsx file and try again.") }
                return nil
            }
            guard entry.type == .file else { throw RoutineSpreadsheetImportError.unreadable }
            guard entry.uncompressedSize <= UInt64(maxPartBytes) else { throw RoutineSpreadsheetImportError.tooLarge }
            var output = Data()
            do {
                let checksum = try archive.extract(entry, bufferSize: 32 * 1_024) { chunk in
                    guard chunk.count <= maxPartBytes - output.count,
                          chunk.count <= maxExpandedBytes - expanded else { throw RoutineSpreadsheetImportError.tooLarge }
                    output.append(chunk)
                    expanded += chunk.count
                }
                // ZIPFoundation calculates and returns the CRC; callers must compare it.
                guard checksum == entry.checksum, UInt64(output.count) == entry.uncompressedSize else {
                    throw RoutineSpreadsheetImportError.unreadable
                }
            } catch let error as RoutineSpreadsheetImportError { throw error }
            catch { throw RoutineSpreadsheetImportError.unreadable }
            return output
        }

        let workbook = RoutineWorkbookXML()
        try parseXML(try part("xl/workbook.xml")!, delegate: workbook)
        let relationships = RoutineRelationshipsXML()
        try parseXML(try part("xl/_rels/workbook.xml.rels")!, delegate: relationships)
        let shared = RoutineSharedStringsXML()
        if let data = try part("xl/sharedStrings.xml", required: false) { try parseXML(data, delegate: shared) }
        guard !workbook.sheets.isEmpty else { throw RoutineSpreadsheetImportError.empty }
        var tables: [RoutineSpreadsheetTable] = []
        var totalRows = 0
        for sheet in workbook.sheets {
            guard let relation = relationships.entries[sheet.relationship],
                  !relation.external, relation.type.hasSuffix("/worksheet") else {
                throw RoutineSpreadsheetImportError.invalid("The workbook has an unsupported or external worksheet. Export its values as CSV and try again.")
            }
            let path = try worksheetPath(relation.target)
            let reader = RoutineWorksheetXML(sharedStrings: shared.strings)
            try parseXML(try part(path)!, delegate: reader)
            totalRows += reader.rows.count
            guard totalRows <= RoutineSpreadsheetImporter.maxRows + 20 else { throw RoutineSpreadsheetImportError.tooLarge }
            tables.append(RoutineSpreadsheetTable(name: sheet.name, rows: reader.rows))
        }
        return tables
    }

    private static func worksheetPath(_ target: String) throws -> String {
        let parts = target.split(separator: "/", omittingEmptySubsequences: false)
        guard !target.contains("\\"), !target.contains(":"), !parts.contains(".."), !parts.contains(".") else {
            throw RoutineSpreadsheetImportError.unreadable
        }
        let path = target.hasPrefix("/") ? String(target.dropFirst()) : "xl/" + target
        guard path.hasPrefix("xl/worksheets/"), path.hasSuffix(".xml") else { throw RoutineSpreadsheetImportError.unreadable }
        return path
    }

    private static func parseXML(_ data: Data, delegate: RoutineXMLDelegate) throws {
        guard let text = String(data: data, encoding: .utf8) ?? String(data: data, encoding: .utf16),
              !text.localizedCaseInsensitiveContains("<!DOCTYPE"),
              !text.localizedCaseInsensitiveContains("<!ENTITY") else {
            throw RoutineSpreadsheetImportError.invalid("The workbook contains unsupported XML declarations. Export its values as CSV and try again.")
        }
        let parser = XMLParser(data: data)
        parser.shouldResolveExternalEntities = false
        parser.delegate = delegate
        guard parser.parse(), delegate.failure == nil else {
            throw delegate.failure ?? RoutineSpreadsheetImportError.unreadable
        }
    }
}

private class RoutineXMLDelegate: NSObject, XMLParserDelegate {
    var failure: RoutineSpreadsheetImportError?
    private var nodes = 0
    private var depth = 0

    func stop(_ parser: XMLParser, _ error: RoutineSpreadsheetImportError) {
        if failure == nil { failure = error }
        parser.abortParsing()
    }

    func local(_ name: String) -> String { String(name.split(separator: ":").last ?? Substring(name)) }

    func parser(_ parser: XMLParser, didStartElement elementName: String, namespaceURI: String?, qualifiedName qName: String?, attributes attributeDict: [String: String]) {
        nodes += 1
        depth += 1
        if nodes > 200_000 || depth > 64 { stop(parser, .tooLarge) }
    }

    func parser(_ parser: XMLParser, didEndElement elementName: String, namespaceURI: String?, qualifiedName qName: String?) { depth -= 1 }
    // Keep this witness on the superclass so FoundationXML also dynamically dispatches the
    // subclasses' text handling on platforms where XMLParserDelegate is a Swift protocol.
    func parser(_ parser: XMLParser, foundCharacters string: String) { }
}

private final class RoutineWorkbookXML: RoutineXMLDelegate {
    struct Sheet { let name: String; let relationship: String }
    var sheets: [Sheet] = []
    override func parser(_ parser: XMLParser, didStartElement elementName: String, namespaceURI: String?, qualifiedName qName: String?, attributes: [String: String]) {
        super.parser(parser, didStartElement: elementName, namespaceURI: namespaceURI, qualifiedName: qName, attributes: attributes)
        guard failure == nil, local(elementName) == "sheet" else { return }
        guard sheets.count < 20 else { stop(parser, .tooLarge); return }
        // Hidden tabs are not part of what the person sees when reviewing a workbook.
        guard attributes["state"] != "hidden", attributes["state"] != "veryHidden" else { return }
        guard let name = attributes["name"], name.count <= 120,
              let relation = attributes["r:id"] ?? attributes.first(where: { $0.key.hasSuffix(":id") })?.value else {
            stop(parser, .unreadable); return
        }
        sheets.append(Sheet(name: name, relationship: relation))
    }
}

private final class RoutineRelationshipsXML: RoutineXMLDelegate {
    struct Relation { let target: String; let type: String; let external: Bool }
    var entries: [String: Relation] = [:]
    override func parser(_ parser: XMLParser, didStartElement elementName: String, namespaceURI: String?, qualifiedName qName: String?, attributes: [String: String]) {
        super.parser(parser, didStartElement: elementName, namespaceURI: namespaceURI, qualifiedName: qName, attributes: attributes)
        guard failure == nil, local(elementName) == "Relationship" else { return }
        guard entries.count < 512, let id = attributes["Id"], let target = attributes["Target"], let type = attributes["Type"], entries[id] == nil else {
            stop(parser, .unreadable); return
        }
        entries[id] = Relation(target: target, type: type, external: attributes["TargetMode"]?.lowercased() == "external")
    }
}

private final class RoutineSharedStringsXML: RoutineXMLDelegate {
    var strings: [String] = []
    private var value = ""
    private var inString = false
    private var inText = false
    private var inPhonetics = false
    override func parser(_ parser: XMLParser, didStartElement elementName: String, namespaceURI: String?, qualifiedName qName: String?, attributes: [String: String]) {
        super.parser(parser, didStartElement: elementName, namespaceURI: namespaceURI, qualifiedName: qName, attributes: attributes)
        guard failure == nil else { return }
        switch local(elementName) {
        case "si": value = ""; inString = true
        case "rPh": inPhonetics = true
        case "t": inText = inString && !inPhonetics
        default: break
        }
    }
    override func parser(_ parser: XMLParser, foundCharacters string: String) {
        guard inText else { return }
        value += string
        if value.count > RoutineSpreadsheetImporter.maxCellCharacters { stop(parser, .tooLarge) }
    }
    override func parser(_ parser: XMLParser, didEndElement elementName: String, namespaceURI: String?, qualifiedName qName: String?) {
        super.parser(parser, didEndElement: elementName, namespaceURI: namespaceURI, qualifiedName: qName)
        switch local(elementName) {
        case "t": inText = false
        case "rPh": inPhonetics = false
        case "si":
            guard strings.count < 10_000 else { stop(parser, .tooLarge); return }
            strings.append(value); inString = false
        default: break
        }
    }
}

private final class RoutineWorksheetXML: RoutineXMLDelegate {
    let sharedStrings: [String]
    var rows: [RoutineSpreadsheetRow] = []
    private var rowNumber = 0
    private var cells: [String] = []
    private var inRow = false
    private var inCell = false
    private var column = 0
    private var type = ""
    private var value = ""
    private var inText = false
    private var inPhonetics = false
    init(sharedStrings: [String]) { self.sharedStrings = sharedStrings }

    override func parser(_ parser: XMLParser, didStartElement elementName: String, namespaceURI: String?, qualifiedName qName: String?, attributes: [String: String]) {
        super.parser(parser, didStartElement: elementName, namespaceURI: namespaceURI, qualifiedName: qName, attributes: attributes)
        guard failure == nil else { return }
        switch local(elementName) {
        case "row":
            let next: Int
            if let reference = attributes["r"] {
                guard let parsed = Int(reference) else {
                    stop(parser, .invalid("The worksheet contains an invalid row reference.")); return
                }
                next = parsed
            } else { next = rowNumber + 1 }
            guard !inRow, next > rowNumber, next <= 1_048_576, rows.count <= RoutineSpreadsheetImporter.maxRows else {
                stop(parser, .tooLarge); return
            }
            rowNumber = next; inRow = true; cells = []
        case "c":
            guard inRow, !inCell else { stop(parser, .unreadable); return }
            let reference = attributes["r"]
            guard let location = reference.map(cellLocation) ?? (cells.count, rowNumber),
                  location.0 >= cells.count, location.0 < RoutineSpreadsheetImporter.maxColumns, location.1 == rowNumber else {
                stop(parser, .invalid("Row \(rowNumber): invalid or oversized Excel cell reference.")); return
            }
            column = location.0; inCell = true; value = ""; type = attributes["t"] ?? "n"
        case "f":
            stop(parser, .invalid("Row \(rowNumber): formulas cannot be imported. Copy the calculated cells and paste their values before exporting."))
        case "rPh": inPhonetics = true
        case "v": inText = inCell
        case "t": inText = inCell && type == "inlineStr" && !inPhonetics
        default: break
        }
    }

    override func parser(_ parser: XMLParser, foundCharacters string: String) {
        guard inText else { return }
        value += string
        if value.count > RoutineSpreadsheetImporter.maxCellCharacters { stop(parser, .tooLarge) }
    }

    override func parser(_ parser: XMLParser, didEndElement elementName: String, namespaceURI: String?, qualifiedName qName: String?) {
        super.parser(parser, didEndElement: elementName, namespaceURI: namespaceURI, qualifiedName: qName)
        guard failure == nil else { return }
        switch local(elementName) {
        case "v", "t": inText = false
        case "rPh": inPhonetics = false
        case "c":
            let cell: String
            switch type {
            case "s":
                guard let index = Int(value.trimmingCharacters(in: .whitespacesAndNewlines)), sharedStrings.indices.contains(index) else {
                    stop(parser, .invalid("Row \(rowNumber): an Excel shared-string reference is invalid.")); return
                }
                cell = sharedStrings[index]
            case "inlineStr", "str", "n": cell = value
            default:
                guard value.isEmpty else { stop(parser, .invalid("Row \(rowNumber): unsupported Excel cell type. Export plain text or numeric values.")); return }
                cell = ""
            }
            while cells.count < column { cells.append("") }
            cells.append(cell); inCell = false
        case "row":
            rows.append(RoutineSpreadsheetRow(number: rowNumber, cells: cells)); inRow = false
        default: break
        }
    }

    private func cellLocation(_ reference: String) -> (Int, Int)? {
        var column = 0
        var digits = ""
        var startedDigits = false
        for byte in reference.utf8 {
            if (65...90).contains(byte), !startedDigits {
                guard column <= 1_000 else { return nil }
                column = column * 26 + Int(byte - 64)
            } else if (48...57).contains(byte) { startedDigits = true; digits.append(Character(UnicodeScalar(byte))) }
            else { return nil }
        }
        guard column > 0, let row = Int(digits), row > 0 else { return nil }
        return (column - 1, row)
    }
}
