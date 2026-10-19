import XCTest
import Foundation
@testable import StrandAnalytics

/// Classifies every record of the shipped exercise catalog (1,324) with its own name and equipment and pins the
/// result, so a change to a token list, a fraction or a mass weight shows up here as a count that moved.
final class StrengthStrainCatalogSnapshotTests: XCTestCase {

    private typealias SS = StrengthStrain
    private typealias Catalog = StrengthStrainCatalog

    private func describe(_ kind: SS.LoadKind) -> String {
        switch kind {
        case .external(let f): return String(format: "external %.4f", f)
        case .bodyweight(let f): return String(format: "bodyweight %.4f", f)
        case .assisted(let f): return String(format: "assisted %.4f", f)
        case .skip(let reason): return "skip \(reason.rawValue)"
        }
    }

    func testCatalogLoads() {
        XCTAssertEqual(Catalog.records.count, 1_324, "exercises.json was not found or changed size")
    }

    func testClassificationCounts() {
        var counts: [String: Int] = [:]
        for record in Catalog.records {
            counts[describe(SS.classify(exerciseName: record.name, equipment: record.equipment)), default: 0] += 1
        }
        let expected: [String: Int] = [
            "external 0.0000": 822,
            "bodyweight 0.3000": 187,
            "external 0.7700": 113,
            "skip stretch": 57,
            "bodyweight 0.9300": 39,
            "bodyweight 0.7700": 35,
            "bodyweight 0.6400": 30,
            "skip isometric": 19,
            "assisted 0.9300": 9,
            "bodyweight 0.5500": 6,
            "bodyweight 0.4900": 2,
            "bodyweight 0.4100": 2,
            "external 0.5467": 2,
            "bodyweight 0.7000": 1,
        ]
        XCTAssertEqual(counts, expected)
        XCTAssertEqual(counts.values.reduce(0, +), 1_324)
    }

    func testCardioSingleJointCountsAndMassFactorDistribution() {
        let cardio = Catalog.records.filter { $0.factor.isCardio }
        XCTAssertEqual(cardio.count, 29)
        XCTAssertEqual(Catalog.records.filter { SS.isSingleJoint($0.name) }.count, 437)

        let factors = Catalog.records.map(\.factor).filter { !$0.isCardio }.map(\.factor).sorted()
        XCTAssertEqual(factors.count, 1_295)
        func percentile(_ p: Double) -> Double {
            let position = Double(factors.count - 1) * p
            let lower = Int(position.rounded(.down))
            let upper = min(lower + 1, factors.count - 1)
            return factors[lower] + (position - Double(lower)) * (factors[upper] - factors[lower])
        }
        XCTAssertEqual(factors.first!, 0.15525, accuracy: 1e-9)
        XCTAssertEqual(percentile(0.10), 0.21735, accuracy: 1e-9)
        XCTAssertEqual(percentile(0.50), 0.5406, accuracy: 1e-9)
        XCTAssertEqual(percentile(0.90), 1.2, accuracy: 1e-9)
        XCTAssertEqual(factors.last!, 1.295, accuracy: 1e-9)
    }

    /// Every target and secondary muscle in the catalog is in the mass table or is a cardio token.
    func testEveryCatalogMuscleTokenIsKnown() {
        var offenders = Set<String>()
        for record in Catalog.records {
            for token in [record.target] + record.secondary {
                let normalized = token.trimmingCharacters(in: .whitespaces).lowercased()
                if SS.muscleMass(normalized) == nil && !SS.cardioPrimaryTokens.contains(normalized) {
                    offenders.insert(normalized)
                }
            }
        }
        if !offenders.isEmpty { print("Unknown catalog muscle tokens: \(offenders.sorted())") }
        XCTAssertTrue(offenders.isEmpty, "unknown muscle tokens: \(offenders.sorted())")
    }

    /// No catalog record may be unmapped: the unknown-primary path is for user-made exercises only.
    func testNoCatalogRecordHasAnUnmappedPrimary() {
        XCTAssertTrue(Catalog.records.filter { $0.factor.unmapped }.isEmpty)
    }
}
