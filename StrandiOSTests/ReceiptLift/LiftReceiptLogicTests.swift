import Foundation
import Testing
@testable import ReceiptLiftFeature

@Suite("Lift receipt logic")
struct LiftReceiptLogicTests {
  @Test("Receipt rows keep log order and truthful warm-up/bodyweight semantics")
  func receiptProjection() throws {
    let fixture = ReceiptFixture()
    let session = fixture.session(
      sets: [
        fixture.set(exerciseID: fixture.loaded.id, number: 1, weight: 45, reps: 10, warmup: true),
        fixture.set(exerciseID: fixture.loaded.id, number: 2, weight: 100, reps: 5),
        fixture.set(exerciseID: fixture.bodyweight.id, number: 1, weight: 0, reps: 8),
      ],
      duration: 180
    )

    let snapshot = LiftReceiptSnapshot.make(
      session: session,
      exercisesByID: [fixture.loaded.id: fixture.loaded, fixture.bodyweight.id: fixture.bodyweight],
      targetSetsByExerciseID: [fixture.loaded.id: 3, fixture.bodyweight.id: 2],
      now: fixture.start.addingTimeInterval(999)
    )

    #expect(snapshot.lines.map(\.id) == session.sets.map(\.id))
    #expect(snapshot.lines[0].statusLabel == "WARM-UP")
    #expect(snapshot.lines[0].loadLabel == "45 LB × 10")
    #expect(snapshot.lines[0].volumeLabel == "450 LB")
    #expect(snapshot.lines[1].statusLabel == "1/3")
    #expect(snapshot.lines[1].detailLabel == "100 LB × 5  /  1/3 SET")
    #expect(snapshot.lines[1].loadLabel == "100 LB × 5")
    #expect(snapshot.lines[1].volumeLabel == "500 LB")
    #expect(snapshot.lines[2].statusLabel == "1/2")
    #expect(snapshot.lines[2].loadLabel == "BW × 8")
    #expect(snapshot.lines[2].volumeLabel == "—")
  }

  @Test("Warm-ups add volume but do not add working-set totals")
  func truthfulTotals() {
    let fixture = ReceiptFixture()
    let session = fixture.session(
      sets: [
        fixture.set(exerciseID: fixture.loaded.id, number: 1, weight: 45, reps: 10, warmup: true),
        fixture.set(exerciseID: fixture.loaded.id, number: 2, weight: 100, reps: 5),
        fixture.set(exerciseID: fixture.bodyweight.id, number: 1, weight: 0, reps: 8),
      ],
      duration: 180
    )

    let snapshot = LiftReceiptSnapshot.make(
      session: session,
      exercisesByID: [fixture.loaded.id: fixture.loaded, fixture.bodyweight.id: fixture.bodyweight],
      targetSetsByExerciseID: [:],
      now: fixture.start.addingTimeInterval(999)
    )

    #expect(snapshot.workingSetCount == 2)
    #expect(snapshot.totalVolume == 950)
    #expect(snapshot.duration == 180)
  }

  @Test("Missing exercises stay explicit instead of borrowing receipt truth")
  func missingExercise() {
    let fixture = ReceiptFixture()
    let missingID = UUID(uuidString: "00000000-0000-0000-0000-000000000099")!
    let session = fixture.session(
      sets: [fixture.set(exerciseID: missingID, number: 1, weight: 75, reps: 6)],
      duration: 60
    )

    let snapshot = LiftReceiptSnapshot.make(
      session: session,
      exercisesByID: [:],
      targetSetsByExerciseID: [:],
      now: fixture.start.addingTimeInterval(999)
    )

    #expect(snapshot.lines.first?.exerciseName == "EXERCISE UNAVAILABLE")
    #expect(snapshot.lines.first?.loadLabel == "75 LB × 6")
  }

  @MainActor
  @Test("Fresh presentation prints once while history presentation stays settled")
  func presentationContract() {
    #expect(LiftReceiptPresentation.freshlyCompleted.animatesPrint)
    #expect(!LiftReceiptPresentation.settled.animatesPrint)

    let fixture = ReceiptFixture()
    _ = CompletedReceiptView(
      session: fixture.session(sets: [], duration: 0),
      presentation: .settled
    )
  }

  @Test(
    "Export validation rejects unreadable renders",
    arguments: [
      (nil, nil, nil, LiftReceiptExportValidation.missingImage),
      (320, 120, 4_096, .tooSmall),
      (1_170, 2_532, 0, .emptyData),
      (1_170, 2_532, 40_000, .readable),
    ]
  )
  func exportValidation(
    pixelWidth: Int?,
    pixelHeight: Int?,
    byteCount: Int?,
    expected: LiftReceiptExportValidation
  ) {
    #expect(
      LiftReceiptExportValidator.validate(
        pixelWidth: pixelWidth,
        pixelHeight: pixelHeight,
        byteCount: byteCount
      ) == expected
    )
  }

  @MainActor
  @Test("White and cream exports render readable, distinct PNGs")
  func renderedExports() throws {
    let fixture = ReceiptFixture()
    let session = fixture.session(
      sets: [fixture.set(exerciseID: fixture.loaded.id, number: 1, weight: 100, reps: 5)],
      duration: 180
    )
    let snapshot = LiftReceiptSnapshot.make(
      session: session,
      exercisesByID: [fixture.loaded.id: fixture.loaded],
      targetSetsByExerciseID: [:],
      now: fixture.start.addingTimeInterval(999)
    )

    let white = try #require(LiftReceiptExportRenderer.render(
      session: session,
      snapshot: snapshot,
      receiptNumber: "#00001",
      paperStyle: .white,
      displayScale: 3
    ))
    let cream = try #require(LiftReceiptExportRenderer.render(
      session: session,
      snapshot: snapshot,
      receiptNumber: "#00001",
      paperStyle: .cream,
      displayScale: 3
    ))
    let whiteData = try #require(white.pngData())
    let creamData = try #require(cream.pngData())

    for (image, data) in [(white, whiteData), (cream, creamData)] {
      #expect(LiftReceiptExportValidator.validate(
        pixelWidth: Int((image.size.width * image.scale).rounded()),
        pixelHeight: Int((image.size.height * image.scale).rounded()),
        byteCount: data.count
      ) == .readable)
    }
    #expect(whiteData != creamData)
  }
}

private struct ReceiptFixture {
  let start = Date(timeIntervalSince1970: 1_720_000_000)
  let loaded = LiftExercise(
    id: UUID(uuidString: "00000000-0000-0000-0000-000000000001")!,
    name: "Back Squat",
    muscleGroup: "Legs",
    equipment: "Barbell",
    instructions: ""
  )
  let bodyweight = LiftExercise(
    id: UUID(uuidString: "00000000-0000-0000-0000-000000000002")!,
    name: "Pull-Up",
    muscleGroup: "Back",
    equipment: "Bodyweight",
    instructions: ""
  )

  func set(
    exerciseID: UUID,
    number: Int,
    weight: Double,
    reps: Int,
    warmup: Bool = false
  ) -> LiftSet {
    LiftSet(
      id: UUID(),
      exerciseID: exerciseID,
      setNumber: number,
      weight: weight,
      reps: reps,
      rpe: 8,
      isWarmup: warmup,
      completedAt: start.addingTimeInterval(Double(number)),
      notes: ""
    )
  }

  func session(sets: [LiftSet], duration: TimeInterval) -> LiftSession {
    LiftSession(
      id: UUID(uuidString: "00000000-0000-0000-0000-000000000010")!,
      routineID: nil,
      title: "Receipt Fixture",
      startedAt: start,
      endedAt: start.addingTimeInterval(duration),
      sets: sets
    )
  }
}
