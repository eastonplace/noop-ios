import XCTest
import Foundation
@testable import StrandAnalytics

/// The exercise catalog the app ships, read straight from its JSON by path relative to this file, so the
/// StrengthStrain tests classify real records with their own name, target, secondaries and equipment.
enum StrengthStrainCatalog {

    struct Record {
        let name: String
        let equipment: String
        let target: String
        let secondary: [String]

        /// One set of this record, the way production maps a catalog exercise to a ``StrengthStrain/SetInput``.
        func set(reps: Int, kg: Double?, rpe: Double? = 8, warmup: Bool = false) -> StrengthStrain.SetInput {
            StrengthStrain.SetInput(exerciseName: name, equipment: equipment,
                                    primaryMuscle: target, secondaryMuscles: secondary,
                                    reps: reps, weightKg: kg, rpe: rpe, isWarmup: warmup)
        }

        var factor: (factor: Double, isCardio: Bool, unmapped: Bool) {
            StrengthStrain.massFactor(exerciseName: name, primary: target, secondary: secondary)
        }
    }

    /// `Packages/ReceiptLiftFeature/.../ExerciseCatalog/data/exercises.json`, found from this file's path.
    static func catalogURL(from file: StaticString = #filePath) -> URL {
        URL(fileURLWithPath: "\(file)")
            .deletingLastPathComponent()
            .appendingPathComponent("../../../ReceiptLiftFeature/Sources/ReceiptLiftFeature/Resources/ExerciseCatalog/data/exercises.json")
            .standardizedFileURL
    }

    static let records: [Record] = {
        guard let data = try? Data(contentsOf: catalogURL()),
              let json = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] else { return [] }
        return json.map { row in
            Record(name: row["name"] as? String ?? "",
                   equipment: row["equipment"] as? String ?? "",
                   target: row["target"] as? String ?? "",
                   secondary: row["secondary_muscles"] as? [String] ?? [])
        }
    }()

    /// The first record with this exact name (six names repeat in the catalog; they classify the same).
    static func record(_ name: String, file: StaticString = #filePath, line: UInt = #line) -> Record {
        guard let found = records.first(where: { $0.name == name }) else {
            XCTFail("catalog has no record named \(name)", file: file, line: line)
            return Record(name: name, equipment: "", target: "", secondary: [])
        }
        return found
    }

    /// One set of the named catalog record.
    static func set(_ name: String, reps: Int, kg: Double?, rpe: Double? = 8, warmup: Bool = false,
                    file: StaticString = #filePath, line: UInt = #line) -> StrengthStrain.SetInput {
        record(name, file: file, line: line).set(reps: reps, kg: kg, rpe: rpe, warmup: warmup)
    }

    /// `count` identical sets of the named catalog record.
    static func sets(_ name: String, count: Int, reps: Int, kg: Double?, rpe: Double? = 8, warmup: Bool = false,
                     file: StaticString = #filePath, line: UInt = #line) -> [StrengthStrain.SetInput] {
        Array(repeating: set(name, reps: reps, kg: kg, rpe: rpe, warmup: warmup, file: file, line: line),
              count: count)
    }
}

/// SplitMix64: a tiny seeded generator, so every property test draws the same cases on every run.
struct SplitMix64 {
    private var state: UInt64
    init(seed: UInt64) { state = seed }

    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }

    /// A double in [0, 1).
    mutating func unit() -> Double { Double(next() >> 11) / 9_007_199_254_740_992.0 }

    mutating func double(in range: ClosedRange<Double>) -> Double {
        range.lowerBound + unit() * (range.upperBound - range.lowerBound)
    }

    mutating func int(in range: ClosedRange<Int>) -> Int {
        range.lowerBound + Int(next() % UInt64(range.upperBound - range.lowerBound + 1))
    }

    mutating func bool(_ probability: Double = 0.5) -> Bool { unit() < probability }

    mutating func pick<T>(_ items: [T]) -> T { items[int(in: 0...(items.count - 1))] }
}
