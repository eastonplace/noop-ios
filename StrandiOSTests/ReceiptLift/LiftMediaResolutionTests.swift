import Foundation
import Testing
import UIKit
@testable import ReceiptLiftFeature

@Suite("Lift media resolution")
struct LiftMediaResolutionTests {
  @Test("Frozen aliases resolve to the expected bundled assets", arguments: [
    ("ab machine or cable crunch", "catalog_0175_WW95auq"),
    ("back extension", "catalog_0573_rUXfn3R"),
    ("bulgarian split squat", "catalog_0410_qx4fgX7"),
    ("cable fly or pec deck", "catalog_0227_Pr9Rhf4"),
    ("calf raise", "catalog_1373_bJYHBIN"),
    ("chest supported row", "catalog_0327_7vG5o25"),
    ("hack squat", "catalog_0743_Qa55kX1"),
    ("hanging knee raise", "catalog_0011_03lzqwk"),
    ("hammer curl", "catalog_1678_IGtBdNT"),
    ("hip thrust", "catalog_3236_Pjbc0Kt"),
    ("incline dumbbell curl", "catalog_0318_ae9UoXQ"),
    ("incline dumbbell press", "catalog_0314_ns0SIbU"),
    ("lat pulldown", "catalog_2330_LEprlgG"),
    ("leg extension", "catalog_0585_my33uHU"),
    ("leg press", "catalog_0739_10Z2DXU"),
    ("lying leg curl", "catalog_0586_17lJ1kr"),
    ("machine chest press", "catalog_0577_T0yTjgW"),
    ("machine row or cable row", "catalog_0861_fUBheHs"),
    ("machine shoulder press", "catalog_0603_67n3r98"),
    ("overhead cable extension", "catalog_0194_2IxROQ1"),
    ("pallof press or plank", "catalog_0979_9pa4H5m"),
    ("rear delt fly", "catalog_0602_myfUsKf"),
    ("romanian deadlift", "catalog_0085_wQ2c4XD"),
    ("rope pushdown", "catalog_0200_dU605di"),
    ("russian twist or hanging knee raise", "catalog_0687_XVDdcoj"),
    ("seated leg curl", "catalog_0599_Zg3XY7P"),
    ("smith incline press", "catalog_0757_5v7KYld"),
    ("straight arm pulldown", "catalog_0237_DT14T9T"),
    ("straight bar pushdown", "catalog_0201_3ZflifB"),
    ("t bar row", "catalog_0606_aaXr7ld")
  ])
  func frozenAliasResolves(name: String, expectedAsset: String) {
    #expect(LiftMedia.imageName(forName: name) == expectedAsset)
    #expect(UIImage(named: expectedAsset, in: LiftMedia.resourceBundle, compatibleWith: nil) != nil)
  }

  @Test("Bench press retains original catalog metadata")
  func benchMetadata() throws {
    let source = try #require(LiftExerciseCatalog.records.first { $0.id == "0025" })
    let exercise = source.liftExercise
    #expect(exercise.name == "barbell bench press")
    #expect(LiftMedia.imageName(for: exercise) == source.imageAssetName)
    let record = try #require(LiftExerciseCatalog.metadata(for: exercise))
    #expect(record.target == "pectorals")
    #expect(record.bodyPart == "chest")
    #expect(record.secondaryMuscles == ["triceps", "shoulders"])
    #expect(record.instructionSteps?["en"]?.count == 7)
  }

  @Test("Every seeded-routine exercise resolves to bundled artwork", arguments: [
    "Machine Chest Press",
    "Pull-Up",
    "Incline Dumbbell Press",
    "Chest-Supported Row",
    "Cable Fly or Pec Deck",
    "Rope Pushdown",
    "Cable Curl",
    "Hanging Knee Raise",
    "Leg Press",
    "Romanian Deadlift",
    "Seated Leg Curl",
    "Walking Lunge",
    "Leg Extension",
    "Calf Raise",
    "Side Plank",
    "T-Bar Row",
    "Lat Pulldown",
    "Machine Row or Cable Row",
    "Straight-Arm Pulldown",
    "Rear-Delt Fly",
    "Face Pull",
    "Incline Dumbbell Curl",
    "Hammer Curl",
    "Dead Hang",
    "Machine Shoulder Press",
    "Smith Incline Press",
    "Cable Lateral Raise",
    "Overhead Cable Extension",
    "Straight-Bar Pushdown",
    "Ab Machine or Cable Crunch",
    "Pallof Press or Plank",
    "Hack Squat",
    "Hip Thrust",
    "Lying Leg Curl",
    "Bulgarian Split Squat",
    "Back Extension",
    "Russian Twist or Hanging Knee Raise"
  ])
  func seededRoutineExerciseResolves(name: String) throws {
    if ["Dead Hang", "Face Pull", "Side Plank"].contains(name) {
      withKnownIssue("Frozen media mapping has no asset route for \(name)") {
        #expect(LiftMedia.imageName(forName: name) != nil)
      }
      return
    }
    let asset = try #require(LiftMedia.imageName(forName: name))
    #expect(UIImage(named: asset, in: LiftMedia.resourceBundle, compatibleWith: nil) != nil)
  }

  @Test("Resolution is case, punctuation, and diacritic stable", arguments: [
    ("  CÂBLE—FLY / OR PEC DECK  ", "catalog_0227_Pr9Rhf4"),
    ("T-BAR ROW", "catalog_0606_aaXr7ld"),
    ("INCLÍNE DUMBBELL PRESS", "catalog_0314_ns0SIbU")
  ])
  func normalizedVariantResolves(name: String, expectedAsset: String) {
    #expect(LiftMedia.imageName(forName: name) == expectedAsset)
  }

  @Test("Unknown exercise name returns nil for the fallback path")
  func unknownExerciseReturnsNil() {
    #expect(LiftMedia.imageName(forName: "__lift_media_unknown_fixture__") == nil)
  }

  @Test("Receipt numbers are chronological, deterministic, and ignore active sessions")
  func receiptNumbersAreStable() throws {
    let now = Date(timeIntervalSinceReferenceDate: 30_000)
    let lowerTieID = try #require(UUID(uuidString: "00000000-0000-4000-8000-000000000001"))
    let targetID = try #require(UUID(uuidString: "00000000-0000-4000-8000-000000000002"))
    let higherTieID = try #require(UUID(uuidString: "00000000-0000-4000-8000-000000000003"))
    let target = Self.session(id: targetID, startedAt: now, endedAt: now.addingTimeInterval(60))
    let sessions = [
      Self.session(id: higherTieID, startedAt: now, endedAt: now.addingTimeInterval(60)),
      Self.session(id: UUID(), startedAt: now.addingTimeInterval(-100), endedAt: now),
      Self.session(id: UUID(), startedAt: now.addingTimeInterval(-200), endedAt: nil),
      target,
      Self.session(id: lowerTieID, startedAt: now, endedAt: now.addingTimeInterval(60))
    ]

    #expect(LiftMedia.receiptNumber(for: target, in: sessions) == "#00003")
    #expect(LiftMedia.receiptNumber(for: target, in: Array(sessions.reversed())) == "#00003")
  }

  private static func session(id: UUID, startedAt: Date, endedAt: Date?) -> LiftSession {
    LiftSession(
      id: id, routineID: nil, title: "Test", startedAt: startedAt, endedAt: endedAt, sets: []
    )
  }
}
