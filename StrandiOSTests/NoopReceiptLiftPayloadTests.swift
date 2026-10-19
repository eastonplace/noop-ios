import Foundation
import Testing
import ReceiptLiftFeature
import WhoopStore
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
