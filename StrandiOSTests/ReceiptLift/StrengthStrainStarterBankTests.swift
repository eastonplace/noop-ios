import Foundation
import StrandAnalytics
import XCTest
@testable import ReceiptLiftFeature
@testable import NOOP

/// SM-R2-1: every starter exercise, through the production mapping (envelope -> `ReceiptLiftHistory` ->
/// `StrengthStrainIntegration.inputs`), scored at 40 kg for a person of 80 kg.
final class StrengthStrainStarterBankTests: XCTestCase {

    private enum Expected {
        case external(Double, w: Double, f: Double)
        case bodyweight(Double, w: Double, f: Double)
        case isometric
    }

    private static let bodyweight = 80.0
    private static let loadKg = 40.0

    private static let table: [(name: String, expected: Expected)] = [
        ("Machine Chest Press", .external(0, w: 40, f: 0.9307)),
        ("Pull-Up", .bodyweight(0.93, w: 114.4, f: 0.9095)),
        ("Incline Dumbbell Press", .external(0, w: 40, f: 0.9307)),
        ("Chest-Supported Row", .external(0, w: 40, f: 0.9307)),
        ("Cable Fly or Pec Deck", .external(0, w: 40, f: 0.5585)),
        ("Rope Pushdown", .external(0, w: 40, f: 0.2173)),
        ("Cable Curl", .external(0, w: 40, f: 0.2173)),
        ("Hanging Knee Raise", .bodyweight(0.30, w: 64, f: 0.2226)),
        ("Leg Press", .external(0, w: 28.4, f: 1.225)),
        ("Romanian Deadlift", .external(0.77, w: 101.6, f: 1.16)),
        ("Seated Leg Curl", .external(0, w: 40, f: 0.615)),
        ("Walking Lunge", .external(0.77, w: 101.6, f: 1.225)),
        ("Leg Extension", .external(0, w: 40, f: 0.66)),
        ("Calf Raise", .external(0, w: 40, f: 0.1605)),
        ("Side Plank", .isometric),
        ("T-Bar Row", .external(0, w: 40, f: 0.9095)),
        ("Lat Pulldown", .external(0, w: 40, f: 0.9818)),
        ("Machine Row or Cable Row", .external(0, w: 40, f: 0.9095)),
        ("Straight-Arm Pulldown", .external(0, w: 40, f: 0.9095)),
        ("Rear-Delt Fly", .external(0, w: 40, f: 0.4032)),
        ("Face Pull", .external(0, w: 40, f: 0.6)),
        ("Incline Dumbbell Curl", .external(0, w: 40, f: 0.2173)),
        ("Hammer Curl", .external(0, w: 40, f: 0.2173)),
        ("Dead Hang", .isometric),
        ("Machine Shoulder Press", .external(0, w: 40, f: 0.672)),
        ("Smith Incline Press", .external(0, w: 40, f: 0.9307)),
        ("Cable Lateral Raise", .external(0, w: 40, f: 0.3942)),
        ("Overhead Cable Extension", .external(0, w: 40, f: 0.2226)),
        ("Straight-Bar Pushdown", .external(0, w: 40, f: 0.2173)),
        ("Ab Machine or Cable Crunch", .external(0, w: 40, f: 0.3622)),
        ("Pallof Press or Plank", .isometric),
        ("Hack Squat", .external(0.5467, w: 72.136, f: 1.225)),
        ("Hip Thrust", .external(0, w: 40, f: 1.2)),
        ("Lying Leg Curl", .external(0, w: 40, f: 0.615)),
        ("Bulgarian Split Squat", .external(0.77, w: 101.6, f: 1.225)),
        ("Back Extension", .external(0, w: 40, f: 0.432)),
        ("Russian Twist or Hanging Knee Raise", .bodyweight(0.30, w: 64, f: 0.2173)),
    ]

    /// One completed session with one working set per starter exercise, written as the app stores it (pounds).
    private func starterWorkout(loadKg: Double, rpe: Double = 8) throws -> ReceiptLiftWorkout {
        let bank = LiftRoutineBank.make()
        let start = Date(timeIntervalSince1970: 1_800_000_000)
        let sets = bank.exercises.enumerated().map { index, exercise in
            LiftSet(id: UUID(), exerciseID: exercise.id, setNumber: 1, weight: loadKg / 0.45359237, reps: 10,
                    rpe: rpe, isWarmup: false, completedAt: start.addingTimeInterval(Double(index) * 90), notes: "")
        }
        let session = LiftSession(
            id: UUID(), routineID: nil, title: "Starter bank", startedAt: start,
            endedAt: start.addingTimeInterval(7_200), sets: sets)
        let envelope = LiftDataEnvelope(
            schemaVersion: LiftDataEnvelope.currentSchemaVersion,
            starterBankVersion: LiftDataEnvelope.currentStarterBankVersion, userExercises: bank.exercises,
            routines: [], scheduledWorkouts: [], sessions: [session], activeSession: nil, restTimerEndDate: nil,
            workoutRestOverrideSeconds: nil, completedExerciseIDs: [], activeExerciseIDsOverride: nil,
            activePlanOverrides: [:], activeSupersetGroups: [:], settings: LiftSettings())
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let data = try encoder.encode(envelope)
        return try XCTUnwrap(ReceiptLiftHistory.completedWorkouts(fromStateData: data).first)
    }

    func testEveryStarterExerciseScoresAsDocumented() throws {
        let workout = try starterWorkout(loadKg: Self.loadKg)
        let inputs = StrengthStrainIntegration.inputs(for: workout)
        XCTAssertEqual(inputs.count, Self.table.count, "the starter bank changed; the table must follow")

        for (input, row) in zip(inputs, Self.table) {
            XCTAssertEqual(input.exerciseName, row.name)
            let kind = StrengthStrain.classify(exerciseName: input.exerciseName, equipment: input.equipment)
            let result = StrengthStrain.evaluate(input, bodyweightKg: Self.bodyweight)
            switch row.expected {
            case let .external(fraction, w, f):
                guard case let .external(bodyFraction) = kind else { XCTFail("\(row.name): \(kind)"); continue }
                XCTAssertEqual(bodyFraction, fraction, accuracy: 1e-4, "\(row.name) body fraction")
                XCTAssertEqual(result.effectiveWeightKg, w, accuracy: 1e-6, "\(row.name) W_eff")
                XCTAssertEqual(result.massFactor, f, accuracy: 1e-4, "\(row.name) F")
                XCTAssertNil(result.skip, row.name)
            case let .bodyweight(fraction, w, f):
                guard case let .bodyweight(bodyFraction) = kind else { XCTFail("\(row.name): \(kind)"); continue }
                XCTAssertEqual(bodyFraction, fraction, accuracy: 1e-4, "\(row.name) body fraction")
                XCTAssertEqual(result.effectiveWeightKg, w, accuracy: 1e-6, "\(row.name) W_eff")
                XCTAssertEqual(result.massFactor, f, accuracy: 1e-4, "\(row.name) F")
                XCTAssertNil(result.skip, row.name)
            case .isometric:
                XCTAssertEqual(kind, .skip(.isometric), row.name)
                XCTAssertEqual(result.skip, .isometric, row.name)
            }
        }
    }

    func testNoStarterSetSkipsAsNoWeightAtFortyKilograms() throws {
        let workout = try starterWorkout(loadKg: Self.loadKg)
        let session = StrengthStrain.evaluate(sets: StrengthStrainIntegration.inputs(for: workout),
                                              bodyweightKg: Self.bodyweight)
        XCTAssertEqual(session.skipped[.noWeight] ?? 0, 0)
        XCTAssertEqual(session.skipped[.isometric], 3)
    }

    /// A8: a bodyweight-loaded move logged with no weight still counts. Only f == 0 and w <= 0 is noWeight.
    func testEveryBodyweightLoadedStarterIsCountedAtZeroKilograms() throws {
        let workout = try starterWorkout(loadKg: 0)
        let inputs = StrengthStrainIntegration.inputs(for: workout)
        for (input, row) in zip(inputs, Self.table) {
            let result = StrengthStrain.evaluate(input, bodyweightKg: Self.bodyweight)
            switch row.expected {
            case let .external(fraction, _, _):
                if fraction > 0 {
                    XCTAssertNil(result.skip, "\(row.name) has a body-weight share and must count at 0 kg")
                    XCTAssertGreaterThan(result.dose, 0, row.name)
                } else {
                    XCTAssertEqual(result.skip, .noWeight, row.name)
                }
            case .bodyweight:
                XCTAssertNil(result.skip, row.name)
                XCTAssertGreaterThan(result.dose, 0, row.name)
            case .isometric:
                XCTAssertEqual(result.skip, .isometric, row.name)
            }
        }
    }
}
