import Foundation
import Testing
@testable import ReceiptLiftFeature

@Suite("RPE value cell")
struct LiftEffortValueTests {
  private let enUS = Locale(identifier: "en_US")

  @Test func steppingFromUnratedStartsAtEight() {
    let up = LiftEffortValue.stepped(rpe: 8, rated: false, up: true)
    let down = LiftEffortValue.stepped(rpe: 8, rated: false, up: false)
    #expect(up.rpe == 8.5 && up.rated)
    #expect(down.rpe == 7.5 && down.rated)
  }

  @Test func steppingClampsAtSixAndTen() {
    #expect(LiftEffortValue.stepped(rpe: 10, rated: true, up: true).rpe == 10)
    #expect(LiftEffortValue.stepped(rpe: 6, rated: true, up: false).rpe == 6)
    #expect(LiftEffortValue.stepped(rpe: 9.5, rated: true, up: true).rpe == 10)
  }

  @Test func togglingRatesAtEightThenClears() {
    let rated = LiftEffortValue.toggled(rpe: 8, rated: false)
    #expect(rated.rpe == 8 && rated.rated)
    let cleared = LiftEffortValue.toggled(rpe: 9, rated: true)
    #expect(cleared.rpe == 8 && !cleared.rated)
  }

  @Test func textIsADashUntilRated() {
    #expect(LiftEffortValue.text(rpe: 8, rated: false, locale: enUS) == "–")
    #expect(LiftEffortValue.text(rpe: 8, rated: true, locale: enUS) == "8")
    #expect(LiftEffortValue.text(rpe: 8.5, rated: true, locale: enUS) == "8.5")
  }

  @Test func theButtonsDisableAtTheEnds() {
    #expect(!LiftEffortValue.canStep(rpe: 10, rated: true, up: true))
    #expect(!LiftEffortValue.canStep(rpe: 6, rated: true, up: false))
    #expect(LiftEffortValue.canStep(rpe: 10, rated: false, up: true))
  }
}
