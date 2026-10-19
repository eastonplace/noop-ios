import Testing
@testable import ReceiptLiftFeature

@Suite("Lift auto-resume policy")
struct LiftAutoResumePolicyTests {
  @Test func resumesAnActiveSessionOnTheStartScreen() {
    #expect(LiftAutoResumePolicy.shouldResume(
      destination: .start, hasActiveSession: true, alreadyAutoResumed: false))
  }

  @Test func neverRepeatsWithinOnePresentation() {
    // The user dismissed the resumed workout on purpose; the picker underneath must stay put.
    #expect(!LiftAutoResumePolicy.shouldResume(
      destination: .start, hasActiveSession: true, alreadyAutoResumed: true))
  }

  @Test func doesNothingWithoutAnActiveSession() {
    #expect(!LiftAutoResumePolicy.shouldResume(
      destination: .start, hasActiveSession: false, alreadyAutoResumed: false))
  }

  @Test func theLaunchFlagIsOffByDefault() {
    #expect(!LiftAutoResumePolicy.suppressedByLaunchFlag)
  }

  @Test func leavesEveryOtherDestinationAlone() {
    for destination in [LiftDestination.history, .progress, .routines] {
      #expect(!LiftAutoResumePolicy.shouldResume(
        destination: destination, hasActiveSession: true, alreadyAutoResumed: false))
    }
  }
}

@Suite("Lift root navigation")
struct LiftRootNavigationTests {
  @Test func showingCompletedHistoryClearsWhateverTheChipsPushed() {
    // Schedule pushed from the start screen's chip, a workout started and finished from it.
    var navigation = LiftRootNavigation(path: [.routines], showsCompletedHistory: false)
    navigation.showCompletedHistory()
    #expect(navigation.path.isEmpty)
    #expect(navigation.showsCompletedHistory)
  }

  @Test func showingCompletedHistoryIsStableWhenNothingWasPushed() {
    var navigation = LiftRootNavigation()
    navigation.showCompletedHistory()
    #expect(navigation == LiftRootNavigation(path: [], showsCompletedHistory: true))
  }
}
