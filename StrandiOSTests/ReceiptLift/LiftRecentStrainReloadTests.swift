import Foundation
import Testing
@testable import ReceiptLiftFeature

/// Strength home reads the stored Strain of its Recent rows again whenever the host announces a change, so a lift that
/// has just finished (its Strain is written after its session appears in the list) does not stay a dash.
@Suite("Strength home recent Strain reload")
@MainActor
struct LiftRecentStrainReloadTests {
  /// A provider whose stored values the test changes, and whose updates the test fires.
  private final class ScriptedProvider: LiftStrainProviding, @unchecked Sendable {
    private let lock = NSLock()
    private var stored: [String: Double] = [:]
    private var continuation: AsyncStream<Void>.Continuation?

    func setStored(_ values: [String: Double]) {
      lock.withLock { stored = values }
    }

    func fireUpdate() {
      let continuation = lock.withLock { self.continuation }
      continuation?.yield()
    }

    func updates() -> AsyncStream<Void> {
      AsyncStream { continuation in
        lock.withLock { self.continuation = continuation }
      }
    }

    func recentStrains(sessionIDs: [String]) async -> [String: Double] {
      lock.withLock { stored.filter { sessionIDs.contains($0.key) } }
    }

    func summary(sessionID: String) async -> LiftStrainSnapshot? { nil }
    func liveVitals(start: Date, sets: [ReceiptLiftSet]) async -> LiftLiveVitals? { nil }
    func beginLiveHeartRate() async {}
    func endLiveHeartRate() async {}
  }

  /// The values `observe` handed out, in order, with a way to wait for the next one.
  private final class Recorder: @unchecked Sendable {
    private let lock = NSLock()
    private var values: [[String: Double]] = []
    var all: [[String: Double]] { lock.withLock { values } }
    func append(_ value: [String: Double]) { lock.withLock { values.append(value) } }
  }

  private func waitUntil(_ condition: () -> Bool) async {
    for _ in 0..<400 where !condition() { try? await Task.sleep(for: .milliseconds(10)) }
  }

  @Test func readsOnceThenAgainOnEveryUpdate() async {
    let provider = ScriptedProvider()
    let recorder = Recorder()
    let task = Task { @MainActor in
      await LiftRecentStrain.observe(provider: provider, sessionIDs: ["a", "b"]) { recorder.append($0) }
    }
    await waitUntil { recorder.all.count == 1 }
    #expect(recorder.all == [[:]])

    // The finished lift's Strain is stored after its session is listed: nothing to show yet, then an update.
    provider.setStored(["a": 11.6])
    provider.fireUpdate()
    await waitUntil { recorder.all.count == 2 }
    #expect(recorder.all.last == ["a": 11.6])

    provider.setStored(["a": 11.8, "b": 9.2, "other": 4])
    provider.fireUpdate()
    await waitUntil { recorder.all.count == 3 }
    #expect(recorder.all.last == ["a": 11.8, "b": 9.2])

    task.cancel()
    await task.value
  }

  @Test func stopsWhenTheTaskIsCancelled() async {
    let provider = ScriptedProvider()
    let recorder = Recorder()
    let task = Task { @MainActor in
      await LiftRecentStrain.observe(provider: provider, sessionIDs: ["a"]) { recorder.append($0) }
    }
    await waitUntil { recorder.all.count == 1 }
    task.cancel()
    await task.value
    provider.setStored(["a": 5])
    provider.fireUpdate()
    try? await Task.sleep(for: .milliseconds(50))
    #expect(recorder.all.count == 1)
  }
}
