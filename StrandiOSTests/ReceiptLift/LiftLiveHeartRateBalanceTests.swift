import Foundation
import Testing
@testable import ReceiptLiftFeature

/// Counts how often the live workout begins and ends the heart-rate session.
private actor CountingProvider: LiftStrainProviding {
  private(set) var begins = 0
  private(set) var ends = 0

  func summary(sessionID: String) async -> LiftStrainSnapshot? { nil }
  nonisolated func updates() -> AsyncStream<Void> { AsyncStream { _ in } }
  func recentStrains(sessionIDs: [String]) async -> [String: Double] { [:] }
  func liveVitals(start: Date, sets: [ReceiptLiftSet]) async -> LiftLiveVitals? { nil }
  func beginLiveHeartRate() async { begins += 1 }
  func endLiveHeartRate() async { ends += 1 }

  var counts: (Int, Int) { (begins, ends) }
}

@Suite("Live heart-rate session balance")
struct LiftLiveHeartRateBalanceTests {
  @Test func beginAndEndAreBalancedWhenTheViewDisappears() async {
    let provider = CountingProvider()
    let task = Task { await LiftLiveHeartRateSession.run(provider) }
    try? await Task.sleep(for: .milliseconds(100))
    task.cancel()
    _ = await task.value
    try? await Task.sleep(for: .milliseconds(100))
    let (begins, ends) = await provider.counts
    #expect(begins == 1)
    #expect(ends == 1)
  }
}
