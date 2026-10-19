import Foundation
import Testing
@testable import ReceiptLiftFeature

@Suite("REST card numbers")
struct LiftRestDisplayTests {
  private let now = Date(timeIntervalSince1970: 1_780_000_000)

  @Test func noRestMeansNoCard() {
    #expect(LiftRestDisplay.make(restTimerEndDate: nil, lastCompletedAt: now, defaultRestSeconds: 90, now: now) == nil)
  }

  @Test func totalIsTheGapFromTheLastSetToTheEnd() {
    let display = LiftRestDisplay.make(
      restTimerEndDate: now.addingTimeInterval(109), lastCompletedAt: now.addingTimeInterval(-11),
      defaultRestSeconds: 90, now: now)
    #expect(display?.totalSeconds == 120)
    #expect(display?.remainingSeconds == 109)
    let fraction = try? #require(display?.fraction)
    #expect(abs((fraction ?? 0) - 11.0 / 120.0) < 0.001)
  }

  @Test func plusThirtyGrowsTheTotal() {
    let display = LiftRestDisplay.make(
      restTimerEndDate: now.addingTimeInterval(139), lastCompletedAt: now.addingTimeInterval(-11),
      defaultRestSeconds: 90, now: now)
    #expect(display?.totalSeconds == 150)
  }

  @Test func withoutALoggedSetTheDefaultIsTheTotal() {
    let display = LiftRestDisplay.make(
      restTimerEndDate: now.addingTimeInterval(60), lastCompletedAt: nil, defaultRestSeconds: 90, now: now)
    #expect(display?.totalSeconds == 90)
  }

  @Test func anImplausibleGapFallsBackToTheDefault() {
    let display = LiftRestDisplay.make(
      restTimerEndDate: now.addingTimeInterval(60), lastCompletedAt: now.addingTimeInterval(-86_400),
      defaultRestSeconds: 75, now: now)
    #expect(display?.totalSeconds == 75)
  }

  @Test func fractionAndRemainingClamp() {
    let display = LiftRestDisplay.make(
      restTimerEndDate: now.addingTimeInterval(-5), lastCompletedAt: now.addingTimeInterval(-60),
      defaultRestSeconds: 90, now: now)
    #expect(display?.remainingSeconds == 0)
    #expect(display?.fraction == 1)
  }
}
