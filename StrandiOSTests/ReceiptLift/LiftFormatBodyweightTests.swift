import Foundation
import Testing
@testable import ReceiptLiftFeature

@Suite("Bodyweight load detection")
struct LiftFormatBodyweightTests {
  private func exercise(_ name: String, equipment: String) -> LiftExercise {
    LiftExercise(id: UUID(), name: name, muscleGroup: "chest", equipment: equipment, instructions: "")
  }

  @Test func bothSpellingsOfBodyweightCount() {
    #expect(liftUsesBodyweightLoad(exercise("Sit-up", equipment: "bodyweight")))
    #expect(liftUsesBodyweightLoad(exercise("push-up", equipment: "body weight")))
    #expect(liftUsesBodyweightLoad(exercise("push-up", equipment: "Body Weight")))
  }

  @Test func loadedMovesDoNot() {
    #expect(!liftUsesBodyweightLoad(exercise("Bench press", equipment: "barbell")))
  }

  @Test func bodyweightReadsBWAtZero() {
    let format = LiftFormat(unit: .pounds, locale: Locale(identifier: "en_US"))
    let pushUp = exercise("push-up", equipment: "body weight")
    #expect(format.load(pounds: 0, for: pushUp) == LiftFormat.bodyweight)
    #expect(format.load(pounds: 25, for: pushUp).hasPrefix("+"))
  }
}
