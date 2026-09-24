import Foundation
import Testing
@testable import ReceiptLiftFeature

@Suite("Lift persistence generations")
@MainActor
struct LiftPersistenceGenerationTests {
  @Test func rapidMutationsCoalesceIntoOneTrailingWrite() async throws {
    let fixture = try makeFixture()
    defer { try? FileManager.default.removeItem(at: fixture.directory) }
    let store = LiftStore(dataURL: fixture.dataURL, saveDebounceInterval: 0.05)
    await store.loadAndWait()
    let baselineWrites = store.persistenceWriteCount

    store.startRestTimer(seconds: 30)
    store.startRestTimer(seconds: 60)
    store.startRestTimer(seconds: 90)
    await store.waitForPendingSave()

    #expect(store.persistenceWriteCount == baselineWrites + 1)
    #expect(try decodeEnvelope(from: fixture.dataURL).restTimerEndDate != nil)
  }

  @Test func staleGenerationCannotOverwriteFlush() async throws {
    let fixture = try makeFixture()
    defer { try? FileManager.default.removeItem(at: fixture.directory) }
    let store = LiftStore(dataURL: fixture.dataURL, saveDebounceInterval: 0.05)
    await store.loadAndWait()
    let baselineWrites = store.persistenceWriteCount

    store.setDefaultRestSeconds(120)
    store.setDefaultRestSeconds(180)
    store.flushPendingSave()
    await store.waitForScheduledWrites()

    #expect(store.persistenceWriteCount == baselineWrites + 1)
    #expect(try decodeEnvelope(from: fixture.dataURL).settings.defaultRestSeconds == 180)
  }

  @Test func encodingAndDecodingRunOffMainThread() async throws {
    let fixture = try makeFixture()
    defer { try? FileManager.default.removeItem(at: fixture.directory) }
    let store = LiftStore(dataURL: fixture.dataURL, saveDebounceInterval: 0.01)
    await store.loadAndWait()
    #expect(store.persistenceCodingRanOnMainThread == false)

    store.setDefaultRestSeconds(135)
    await store.waitForPendingSave()
    #expect(store.persistenceCodingRanOnMainThread == false)
  }

  @Test func backgroundFlushPersistsNewestSnapshot() async throws {
    let fixture = try makeFixture()
    defer { try? FileManager.default.removeItem(at: fixture.directory) }
    let store = LiftStore(dataURL: fixture.dataURL, saveDebounceInterval: 10)
    await store.loadAndWait()

    store.setDefaultRestSeconds(165)
    store.applicationDidEnterBackground()

    #expect(try decodeEnvelope(from: fixture.dataURL).settings.defaultRestSeconds == 165)
  }

  @Test func backgroundBeforeLoadCannotOverwriteExistingData() async throws {
    let fixture = try makeFixture()
    defer { try? FileManager.default.removeItem(at: fixture.directory) }

    let loadedStore = LiftStore(dataURL: fixture.dataURL, saveDebounceInterval: 10)
    await loadedStore.loadAndWait()
    loadedStore.setDefaultRestSeconds(165)
    loadedStore.flushPendingSave()
    let persistedBeforePreview = try Data(contentsOf: fixture.dataURL)

    let unloadedPreviewStore = LiftStore(dataURL: fixture.dataURL, saveDebounceInterval: 10)
    unloadedPreviewStore.applicationDidEnterBackground()

    #expect(try Data(contentsOf: fixture.dataURL) == persistedBeforePreview)
    #expect(try decodeEnvelope(from: fixture.dataURL).settings.defaultRestSeconds == 165)
  }

  @Test func finishFlushesBeforeReturning() async throws {
    let fixture = try makeFixture()
    defer { try? FileManager.default.removeItem(at: fixture.directory) }
    let store = LiftStore(dataURL: fixture.dataURL, saveDebounceInterval: 10)
    await store.loadAndWait()
    store.startRoutine(nil)

    let finished = store.finishActiveSession()
    let persisted = try decodeEnvelope(from: fixture.dataURL)

    #expect(finished != nil)
    #expect(persisted.activeSession == nil)
    #expect(persisted.sessions.first?.id == finished?.id)
  }

  @Test func logSetMutationReturnsUnder100Milliseconds() async throws {
    let fixture = try makeFixture()
    defer { try? FileManager.default.removeItem(at: fixture.directory) }
    let store = LiftStore(dataURL: fixture.dataURL, saveDebounceInterval: 10)
    await store.loadAndWait()
    let exercise = try #require(store.exercises.first)
    store.startRoutine(nil)

    let elapsed = ContinuousClock().measure {
      store.logSet(exercise: exercise, weight: 100, reps: 8, rpe: 8, isWarmup: false)
    }
    store.flushPendingSave()

    #expect(elapsed < .milliseconds(100))
  }

  private func makeFixture() throws -> GenerationFixture {
    let directory = FileManager.default.temporaryDirectory
      .appendingPathComponent("LiftPersistenceGenerationTests-" + UUID().uuidString, isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    return GenerationFixture(
      directory: directory,
      dataURL: directory.appendingPathComponent("lift-data.json")
    )
  }

  private func decodeEnvelope(from url: URL) throws -> LiftDataEnvelope {
    let decoder = JSONDecoder()
    decoder.dateDecodingStrategy = .iso8601
    return try decoder.decode(LiftDataEnvelope.self, from: Data(contentsOf: url))
  }
}

private struct GenerationFixture {
  var directory: URL
  var dataURL: URL
}
