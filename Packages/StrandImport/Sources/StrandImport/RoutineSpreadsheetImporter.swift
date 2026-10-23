import Foundation

/// A reviewed plan, never a completed workout. The host maps this into its existing routine model.
public struct RoutineSpreadsheetDocument: Equatable, Sendable {
    public let routines: [RoutineSpreadsheetRoutine]
    public let warnings: [String]
}

public struct RoutineSpreadsheetRoutine: Equatable, Sendable {
    public let name: String
    public var notes: String
    public var trainingMode: String
    public var exercises: [RoutineSpreadsheetExercise]
}

public struct RoutineSpreadsheetExercise: Equatable, Sendable {
    public let sourceRow: Int
    public let name: String
    public let muscleGroup: String
    public let equipment: String
    public let sets: Int?
    public let reps: String?
    public let restSeconds: Int?
    public let rpe: Double?
    public let load: RoutineSpreadsheetLoad?
    public let notes: String
}

public struct RoutineSpreadsheetLoad: Equatable, Sendable {
    public enum Unit: String, Equatable, Sendable { case kilograms = "kg", pounds = "lb" }
    public let value: Double
    public let unit: Unit
}

public enum RoutineSpreadsheetImportError: Error, Equatable, LocalizedError, Sendable {
    case unreadable
    case tooLarge
    case empty
    case missingExerciseColumn
    case invalid(String)

    public var errorDescription: String? {
        switch self {
        case .unreadable: return "This file could not be read. Export it as CSV or Excel (.xlsx), then try again."
        case .tooLarge: return "This spreadsheet is too large. Use a file under 8 MB with at most 50 routines, 200 exercises per routine, and 5,000 rows."
        case .empty: return "This spreadsheet has no exercises. Add one exercise per row below the header."
        case .missingExerciseColumn: return "Add an exercise column to the first nonempty row of the spreadsheet."
        case .invalid(let message): return message
        }
    }
}

/// Strict, bounded CSV/XLSX parsing. Any invalid prescription rejects the whole preview: a typo must
/// not silently remove a load or turn a fractional set count into a different training plan.
public enum RoutineSpreadsheetImporter {
    public static let maxFileBytes = 8 * 1_024 * 1_024
    static let maxRows = 5_000
    static let maxColumns = 64
    static let maxCellCharacters = 4_000
    private static let maxRoutines = 50
    private static let maxExercises = 200

    public static func parse(data: Data) throws -> RoutineSpreadsheetDocument {
        guard data.count <= maxFileBytes else { throw RoutineSpreadsheetImportError.tooLarge }
        guard !data.isEmpty else { throw RoutineSpreadsheetImportError.empty }
        let tables: [RoutineSpreadsheetTable]
        if data.starts(with: [0x50, 0x4b]) {
            tables = try RoutineXLSXReader.tables(data: data)
        } else {
            tables = [try RoutineCSVReader.table(data: data)]
        }
        var routines: [RoutineSpreadsheetRoutine] = []
        var routineIndices: [String: Int] = [:]
        var exerciseNames: [String: Set<String>] = [:]
        var modes: [String: String] = [:]
        var warnings: [String] = []
        var matchedTable = false
        var totalRows = 0

        for table in tables {
            guard let headerIndex = table.rows.firstIndex(where: { $0.cells.contains { !$0.trimmed.isEmpty } }) else { continue }
            let header = table.rows[headerIndex]
            let keys = header.cells.map { columnKey($0) }
            guard keys.contains("exercise") else { continue }
            matchedTable = true
            let nonemptyKeys = keys.filter { !$0.isEmpty }
            guard Set(nonemptyKeys).count == nonemptyKeys.count else {
                throw invalid(table.name, row: header.number, "two columns describe the same field. Keep one column for each value.")
            }
            let loadColumns = Set(keys).intersection(["load_kg", "load_lb", "load"])
            guard loadColumns.count <= 1 else {
                throw invalid(table.name, row: header.number, "use one load column: weight_kg, weight_lb, or weight with a unit column.")
            }
            let unknown = zip(header.cells, keys).compactMap { title, key in
                !key.isEmpty && !knownColumns.contains(key) ? title.trimmed : nil
            }
            if !unknown.isEmpty {
                warnings.append("\(table.name.map { "\($0): " } ?? "")Unused columns: \(unknown.joined(separator: ", ")).")
            }

            for row in table.rows.dropFirst(headerIndex + 1) {
                totalRows += 1
                guard totalRows <= maxRows else { throw RoutineSpreadsheetImportError.tooLarge }
                guard row.cells.contains(where: { !$0.trimmed.isEmpty }) else { continue }
                guard row.cells.count <= keys.count || row.cells.dropFirst(keys.count).allSatisfy({ $0.trimmed.isEmpty }) else {
                    throw invalid(table.name, row: row.number, "there are more values than column headers. Check commas and quoting.")
                }
                var values: [String: String] = [:]
                for (index, cell) in row.cells.enumerated() where index < keys.count {
                    guard cell.count <= maxCellCharacters else { throw RoutineSpreadsheetImportError.tooLarge }
                    if keys[index].isEmpty {
                        guard cell.trimmed.isEmpty else {
                            throw invalid(table.name, row: row.number, "a value has no column header.")
                        }
                    } else { values[keys[index]] = cell.trimmed }
                }
                func value(_ key: String) -> String { values[key] ?? "" }
                func bounded(_ key: String, limit: Int) throws -> String {
                    let text = value(key)
                    guard text.count <= limit else {
                        throw invalid(table.name, row: row.number, "\(key.replacingOccurrences(of: "_", with: " ")) is longer than \(limit) characters.")
                    }
                    return text
                }
                let name = try bounded("exercise", limit: 120)
                guard !name.isEmpty, !normalized(name).isEmpty else {
                    throw invalid(table.name, row: row.number, "an exercise name is required.")
                }
                let routineValue = try bounded("routine", limit: 120)
                let routineName = routineValue.isEmpty ? (table.name ?? "Imported routine") : routineValue
                let routineKey = normalized(routineName)
                guard !routineKey.isEmpty else {
                    throw invalid(table.name, row: row.number, "a routine name must contain letters or numbers.")
                }
                let routineNotes = try bounded("routine_note", limit: 2_000)
                let mode = value("training_mode").lowercased()
                guard mode.isEmpty || ["strength", "hypertrophy", "endurance"].contains(mode) else {
                    throw invalid(table.name, row: row.number, "training_mode must be strength, hypertrophy, or endurance.")
                }
                guard exerciseNames[routineKey, default: []].insert(normalized(name)).inserted else {
                    throw invalid(table.name, row: row.number, "\(name) appears twice in \(routineName). Use one row per exercise and put the set count in sets.")
                }
                let line: RoutineSpreadsheetExercise
                do {
                    line = RoutineSpreadsheetExercise(
                        sourceRow: row.number, name: name,
                        muscleGroup: try bounded("muscle", limit: 80),
                        equipment: try bounded("equipment", limit: 80),
                        sets: try integer(value("sets"), field: "sets", range: 1...100),
                        reps: try repetitions(value("reps")),
                        restSeconds: try rest(value("rest")),
                        rpe: try number(value("rpe"), field: "RPE", range: 1...10),
                        load: try load(values), notes: try bounded("notes", limit: 2_000))
                } catch let RoutineSpreadsheetImportError.invalid(reason) {
                    throw invalid(table.name, row: row.number, reason)
                }
                if let index = routineIndices[routineKey] {
                    guard routines[index].exercises.count < maxExercises else { throw RoutineSpreadsheetImportError.tooLarge }
                    if !routineNotes.isEmpty, !routines[index].notes.isEmpty, routines[index].notes != routineNotes {
                        throw invalid(table.name, row: row.number, "\(routineName) has conflicting routine notes. Keep the same note or leave later cells empty.")
                    }
                    if !mode.isEmpty, let previous = modes[routineKey], previous != mode {
                        throw invalid(table.name, row: row.number, "\(routineName) has conflicting training modes.")
                    }
                    if !routineNotes.isEmpty { routines[index].notes = routineNotes }
                    if !mode.isEmpty { modes[routineKey] = mode; routines[index].trainingMode = mode }
                    routines[index].exercises.append(line)
                } else {
                    guard routines.count < maxRoutines else { throw RoutineSpreadsheetImportError.tooLarge }
                    routineIndices[routineKey] = routines.count
                    if !mode.isEmpty { modes[routineKey] = mode }
                    routines.append(RoutineSpreadsheetRoutine(name: routineName, notes: routineNotes,
                        trainingMode: mode.isEmpty ? "hypertrophy" : mode, exercises: [line]))
                }
            }
        }
        guard matchedTable else { throw RoutineSpreadsheetImportError.missingExerciseColumn }
        guard !routines.isEmpty else { throw RoutineSpreadsheetImportError.empty }
        return RoutineSpreadsheetDocument(routines: routines, warnings: warnings)
    }

    private static let knownColumns: Set<String> = [
        "exercise", "routine", "routine_note", "training_mode", "muscle", "equipment",
        "sets", "reps", "rest", "rpe", "load", "load_kg", "load_lb", "unit", "notes"
    ]

    private static func columnKey(_ raw: String) -> String {
        let key = normalized(raw).replacingOccurrences(of: " ", with: "_")
        switch key {
        case "exercise", "movement", "lift", "exercise_name": return "exercise"
        case "routine", "program", "programme", "workout", "day": return "routine"
        case "routine_note", "routine_notes", "program_note", "programme_note", "workout_note": return "routine_note"
        case "mode", "training_mode": return "training_mode"
        case "primary_muscle", "primary", "muscle", "muscle_group": return "muscle"
        case "equipment": return "equipment"
        case "sets", "working_sets", "target_sets": return "sets"
        case "reps", "rep", "target_reps", "repetitions": return "reps"
        case "rest", "rest_sec", "rest_s", "rest_seconds": return "rest"
        case "rpe", "max_rpe", "target_rpe", "target_max_rpe", "rpe_max": return "rpe"
        case "weight_kg", "load_kg", "target_weight_kg", "kg": return "load_kg"
        case "weight_lb", "weight_lbs", "load_lb", "load_lbs", "target_weight_lb", "lb", "lbs": return "load_lb"
        case "weight", "load", "target_weight": return "load"
        case "unit", "weight_unit", "load_unit": return "unit"
        case "note", "notes", "technique_note", "cue": return "notes"
        default: return key
        }
    }

    static func normalized(_ value: String) -> String {
        value.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: Locale(identifier: "en_US_POSIX"))
            .lowercased().components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { !$0.isEmpty }.joined(separator: " ")
    }

    private static func invalid(_ sheet: String?, row: Int, _ reason: String) -> RoutineSpreadsheetImportError {
        .invalid("\(sheet.map { "\($0), " } ?? "")Row \(row): \(reason)")
    }

    private static func numeric(_ value: String) -> Double? {
        let text = value.trimmed.replacingOccurrences(of: ",", with: ".")
        guard text.range(of: #"^[+-]?[0-9]+(?:\.[0-9]+)?(?:[eE][+-]?[0-9]+)?$"#, options: .regularExpression) != nil,
              let number = Double(text), number.isFinite else { return nil }
        return number
    }

    private static func number(_ raw: String, field: String, range: ClosedRange<Double>) throws -> Double? {
        guard !raw.isEmpty else { return nil }
        guard let value = numeric(raw), range.contains(value) else {
            throw RoutineSpreadsheetImportError.invalid("\(field) must be a number from \(format(range.lowerBound)) to \(format(range.upperBound)).")
        }
        return value
    }

    private static func integer(_ raw: String, field: String, range: ClosedRange<Int>) throws -> Int? {
        guard !raw.isEmpty else { return nil }
        guard let value = numeric(raw), value.rounded(.towardZero) == value,
              (Double(range.lowerBound)...Double(range.upperBound)).contains(value) else {
            throw RoutineSpreadsheetImportError.invalid("\(field) must be a whole number from \(range.lowerBound) to \(range.upperBound).")
        }
        return Int(value)
    }

    private static func repetitions(_ raw: String) throws -> String? {
        guard !raw.isEmpty else { return nil }
        let text = raw.replacingOccurrences(of: "–", with: "-").replacingOccurrences(of: "—", with: "-")
        if let value = try? integer(text, field: "reps", range: 1...1_000) { return String(value) }
        let parts = text.split(separator: "-", omittingEmptySubsequences: false)
        guard parts.count == 2,
              let low = try integer(String(parts[0]).trimmed, field: "reps", range: 1...1_000),
              let high = try integer(String(parts[1]).trimmed, field: "reps", range: 1...1_000), low <= high else {
            throw RoutineSpreadsheetImportError.invalid("reps must be a whole number or an increasing range, such as 8-12.")
        }
        return low == high ? String(low) : "\(low)-\(high)"
    }

    private static func rest(_ raw: String) throws -> Int? {
        guard !raw.isEmpty else { return nil }
        var text = raw.lowercased().trimmed
        var multiplier = 1.0
        for suffix in ["minutes", "minute", "mins", "min", "seconds", "second", "secs", "sec", "s"] {
            if text.hasSuffix(suffix) {
                multiplier = suffix.hasPrefix("min") ? 60 : 1
                text = String(text.dropLast(suffix.count)).trimmed
                break
            }
        }
        guard let value = numeric(text) else { throw RoutineSpreadsheetImportError.invalid("rest must be seconds or minutes, such as 90 or 1.5 min.") }
        let seconds = value * multiplier
        guard seconds.isFinite, (0...3_600).contains(seconds), seconds.rounded(.towardZero) == seconds else {
            throw RoutineSpreadsheetImportError.invalid("rest must resolve to a whole number of seconds from 0 to 3600.")
        }
        return Int(seconds)
    }

    private static func load(_ values: [String: String]) throws -> RoutineSpreadsheetLoad? {
        let column = ["load_kg", "load_lb", "load"].first { !(values[$0] ?? "").isEmpty }
        let unitText = (values["unit"] ?? "").lowercased()
        let units: [String: RoutineSpreadsheetLoad.Unit] = ["kg": .kilograms, "kgs": .kilograms, "kilogram": .kilograms, "kilograms": .kilograms,
            "lb": .pounds, "lbs": .pounds, "pound": .pounds, "pounds": .pounds]
        guard unitText.isEmpty || units[unitText] != nil else { throw RoutineSpreadsheetImportError.invalid("load unit must be kg or lb.") }
        guard let column, var raw = values[column]?.lowercased() else { return nil }
        let columnUnit: RoutineSpreadsheetLoad.Unit? = column == "load_kg" ? .kilograms : column == "load_lb" ? .pounds : nil
        var suffixUnit: RoutineSpreadsheetLoad.Unit?
        for suffix in units.keys.sorted(by: { $0.count > $1.count }) where raw.hasSuffix(suffix) {
            suffixUnit = units[suffix]
            raw = String(raw.dropLast(suffix.count)).trimmed
            break
        }
        let explicitUnits = [columnUnit, units[unitText], suffixUnit].compactMap { $0 }
        guard Set(explicitUnits.map(\.rawValue)).count <= 1 else {
            throw RoutineSpreadsheetImportError.invalid("the load's unit conflicts with its column or unit cell.")
        }
        let unit = explicitUnits.first ?? .kilograms
        let maximum = unit == .kilograms ? 2_000.0 : 2_000 / 0.45359237
        guard let value = try number(raw, field: "load", range: 0...maximum) else {
            throw RoutineSpreadsheetImportError.invalid("load must include a number.")
        }
        return RoutineSpreadsheetLoad(value: value, unit: unit)
    }

    private static func format(_ number: Double) -> String {
        number == number.rounded() ? String(Int(number)) : String(format: "%.2f", locale: Locale(identifier: "en_US_POSIX"), number)
    }
}

struct RoutineSpreadsheetTable {
    let name: String?
    let rows: [RoutineSpreadsheetRow]
}

struct RoutineSpreadsheetRow {
    let number: Int
    let cells: [String]
}

private extension String {
    var trimmed: String { trimmingCharacters(in: .whitespacesAndNewlines) }
}
