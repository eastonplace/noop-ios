import Foundation
import Testing
import ReceiptLiftFeature
import WhoopStore
import WhoopProtocol
@testable import NOOP

@Suite("Receipt Lift host integration")
struct NoopReceiptLiftPayloadTests {
    @Test("Catalog muscle labels retain precise classifications")
    func catalogMuscles() {
        #expect(NoopReceiptLiftPayload.muscle("pectorals") == .chest)
        #expect(NoopReceiptLiftPayload.muscle("quadriceps") == .quads)
        #expect(NoopReceiptLiftPayload.muscle("triceps") == .triceps)
        #expect(NoopReceiptLiftPayload.muscle("shoulders") == nil)
        #expect(NoopReceiptLiftPayload.muscle("legs") == nil)
    }

    @Test("Completed sets retain catalog metadata and owning source")
    func completedWorkout() throws {
        let json = #"{"id":"workout","title":"Push","startedAt":100,"endedAt":200,"sets":[{"id":"set","exercise":"barbell bench press","muscleGroup":"pectorals","secondaryMuscles":["triceps","shoulders"],"setIndex":1,"weightKg":60,"reps":8,"isWarmup":false,"completedAt":150}]}"#
        let workout = try JSONDecoder().decode(ReceiptLiftWorkout.self, from: Data(json.utf8))
        let rows = NoopReceiptLiftPayload.make(owner: "original-source", workouts: [workout])
        let set = try #require(rows.sets.first)
        #expect(set.deviceId == "original-source")
        #expect(set.primaryMuscle == .chest)
        #expect(set.secondaryMuscles == [.triceps])
        #expect(set.weightKg == 60)
        #expect(set.reps == 8)
        #expect(rows.workouts.first?.durationS == 100)
    }
    @Test("Strength Strain leaves the saved rows and the muscle mapping untouched")
    func strengthStrainDoesNotChangeTheSavedRows() throws {
        let json = #"{"id":"workout","title":"Pull","startedAt":100,"endedAt":200,"sets":[{"id":"set","exercise":"pull-up","muscleGroup":"upper back","secondaryMuscles":["biceps","levator scapulae","legs"],"setIndex":1,"weightKg":0,"reps":8,"isWarmup":false,"completedAt":150,"equipment":"Bodyweight"}]}"#
        let workout = try JSONDecoder().decode(ReceiptLiftWorkout.self, from: Data(json.utf8))
        let rows = NoopReceiptLiftPayload.make(owner: "owner", workouts: [workout])
        let set = try #require(rows.sets.first)
        #expect(set.primaryMuscle == .upperBack)
        #expect(set.secondaryMuscles == [.biceps, .neck])
        // The written workout row has no Strain: Strength Strain adds it later, through the settle only.
        let written = try #require(rows.workouts.first)
        #expect(written.strain == nil)
        #expect(written.strainVersion == nil)
        #expect(written.source == "manual")
        #expect(written.sport == StrengthStrainIntegration.sport)
        #expect(rows.sessions.first?.sport == StrengthStrainIntegration.sport)
    }
}

#if targetEnvironment(simulator)
@Suite("Receipt Lift source ownership")
@MainActor
struct NoopReceiptLiftSourceOwnershipTests {
    @Test("An active provider retains its owner and rejects another source's live values")
    func providerRetainsItsSourceAcrossSelectionChanges() async throws {
        ActiveWorkoutPersistence.clear()
        defer {
            ActiveWorkoutPersistence.flushPendingWrites()
            ActiveWorkoutPersistence.clear()
        }
        let model = AppModel(startRuntimeTasks: false)
        let store = try await WhoopStore.inMemory()
        let originalSource = model.repo.deviceId
        let provider = try #require(NoopReceiptLiftIntegration.strainProvider(model: model, store: store)
            as? AppLiftStrainProvider)
        defer { provider.stopHR() }
        model.bpm = 111
        #expect(provider.deviceId() == originalSource)
        #expect(provider.bpm() == 111)
        provider.startHR()
        #expect(model.live.liveFeedActive)

        #expect(model.repo.adoptActiveDeviceId("second-lift-source"))
        model.bpm = 177

        #expect(provider.deviceId() == originalSource)
        #expect(provider.bpm() == nil)
        #expect(await provider.hrSamples(0, 10).isEmpty)
        provider.stopHR()
        #expect(!model.live.liveFeedActive, "the original provider can still release its owned token")
        provider.startHR()
        #expect(!model.live.liveFeedActive, "the old session cannot start the new source's feed")
    }

    @Test("A source change during the composite read rejects every live value")
    func compositeVitalsRejectSourceChangeDuringSampleRead() async throws {
        for hasSamples in [false, true] {
            let source = LiftSourceValidityFixture()
            let gate = LiftSourceSampleReadGate()
            let store = try await WhoopStore.inMemory()
            let provider = AppLiftStrainProvider(
                store: store, deviceId: { "source-A" }, bpm: { source.valid ? 111 : nil },
                startHR: {}, stopHR: {}, maxHR: { 190 }, restingHR: { 60 },
                hrSamples: { _, _ in await gate.read() }, liveSourceIsCurrent: { source.valid })
            let now = Int(Date().timeIntervalSince1970)
            let task = Task { await provider.liveVitals(start: Date(timeIntervalSince1970: Double(now - 1_000)), sets: []) }
            await gate.waitUntilStarted()
            source.valid = false
            let samples = hasSamples ? (1..<1_000).map { HRSample(ts: now - 1_000 + $0, bpm: 140) } : []
            await gate.finish(samples)
            #expect(await task.value == nil)
        }
    }

    @Test("Frozen HR reads retain original read IDs when selection changes away and back")
    func frozenRepositoryReadRetainsOriginalSources() async throws {
        let store = try await WhoopStore.inMemory()
        _ = try await store.insert(Streams(hr: [HRSample(ts: 100, bpm: 111)]), deviceId: "source-A")
        _ = try await store.insert(Streams(hr: [HRSample(ts: 101, bpm: 112)]), deviceId: "my-whoop")
        _ = try await store.insert(Streams(hr: [HRSample(ts: 100, bpm: 177)]), deviceId: "source-B")
        let repo = Repository(deviceId: "source-A")
        #expect(repo.adoptActiveDeviceId("source-A"))
        let readIds = repo.importedReadIds
        #expect(repo.adoptActiveDeviceId("source-B"))
        let task = Task { await Repository.hrSamples(store: store, sourceIds: readIds, from: 100, to: 101) }
        #expect(repo.adoptActiveDeviceId("source-A"))
        #expect(await task.value == [HRSample(ts: 100, bpm: 111), HRSample(ts: 101, bpm: 112)])
    }
}

@MainActor
private final class LiftSourceValidityFixture { var valid = true }

private actor LiftSourceSampleReadGate {
    private var readContinuation: CheckedContinuation<[HRSample], Never>?
    private var startContinuation: CheckedContinuation<Void, Never>?
    func read() async -> [HRSample] {
        await withCheckedContinuation { continuation in
            readContinuation = continuation
            startContinuation?.resume()
            startContinuation = nil
        }
    }
    func waitUntilStarted() async {
        guard readContinuation == nil else { return }
        await withCheckedContinuation { startContinuation = $0 }
    }
    func finish(_ samples: [HRSample]) {
        readContinuation?.resume(returning: samples)
        readContinuation = nil
    }
}
#endif
