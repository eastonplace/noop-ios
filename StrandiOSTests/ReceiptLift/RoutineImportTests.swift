import Foundation
import Testing
@testable import ReceiptLiftFeature
@testable import NOOP

@Suite("Reviewed routine spreadsheet import")
@MainActor
struct RoutineImportTests {
    @Test func realHostAdapterMapsTheSpreadsheetIntoExistingRoutineFields() throws {
        let csv = "routine,routine_note,training_mode,exercise,sets,reps,rest,rpe,weight_lb,notes\nPush,Heavy day,strength,Fixture Bench,3,5-8,2 min,8.5,135,Pause\n"
        let draft = try NoopReceiptLiftRoutineImportAdapter.parse(Data(csv.utf8))
        let routine = try #require(draft.routines.first)
        let line = try #require(routine.exercises.first)
        #expect(routine.name == "Push")
        #expect(routine.notes == "Heavy day")
        #expect(routine.trainingMode == "strength")
        #expect(line.sets == "3")
        #expect(line.reps == "5-8")
        #expect(line.rest == "120 s")
        #expect(line.targetEffort == "8.5 RPE")
        #expect(line.notes == "Pause\nPlanned load: 135 lb")
        #expect(draft.warnings.contains { $0.contains("Planned loads") })
    }

    @Test func previewIsReadOnlyMatchesExistingIDsAndDisclosesNewExerciseAndNameCollision() async throws {
        let (coordinator, harness, original) = try await setup()
        let preview = try coordinator.store.prepareRoutineImport(draft())
        #expect(preview.routines[0].name == "Push (imported)")
        #expect(preview.routines[0].id != original.routines[0].id)
        #expect(preview.routines[0].exerciseIDs[0] == original.userExercises[0].id)
        #expect(preview.newExercises.map(\.name) == ["Custom cable arc"])
        #expect(preview.warnings.contains { $0.contains("Push (imported)") })
        #expect(await harness.attempts == 0)
        #expect(coordinator.store.routines == original.routines)
        let persisted = await harness.data
        #expect(try persisted == encode(original))
    }

    @Test func newExercisesRequireExplicitConsentAndAnInvalidFileNeverWrites() async throws {
        let (coordinator, harness, original) = try await setup()
        let preview = try coordinator.store.prepareRoutineImport(draft())
        await #expect(throws: (any Error).self) {
            try await coordinator.store.importReviewedRoutines(preview, allowNewExercises: false)
        }
        #expect(throws: (any Error).self) {
            try NoopReceiptLiftRoutineImportAdapter.parse(Data("exercise,sets\nBench,3.5".utf8))
        }
        #expect(await harness.attempts == 0)
        let persisted = await harness.data
        #expect(try persisted == encode(original))
        #expect(coordinator.store.routines == original.routines)
    }

    @Test func confirmationWritesOneCompleteEnvelopeAndPreservesHistoryScheduleAndExistingRoutineIDs() async throws {
        let (coordinator, harness, original) = try await setup()
        let preview = try coordinator.store.prepareRoutineImport(draft())
        try await coordinator.store.importReviewedRoutines(preview, allowNewExercises: true)
        let saved = try decode(await harness.data)
        #expect(await harness.attempts == 1)
        #expect(await harness.changedWorkouts.isEmpty)
        #expect(Array(saved.routines.prefix(original.routines.count)) == original.routines)
        #expect(saved.routines.last?.exercisePlans?.first?.sets == "3")
        #expect(saved.routines.last?.exercisePlans?.first?.notes == "Planned load: 60 kg")
        #expect(saved.userExercises.count == original.userExercises.count + 1)
        #expect(saved.sessions == original.sessions)
        #expect(saved.scheduledWorkouts == original.scheduledWorkouts)
        #expect(saved.settings == original.settings)
        #expect(saved.schemaVersion == original.schemaVersion)
        #expect(saved.starterBankVersion == original.starterBankVersion)

        coordinator.store.flushPendingSave()
        await coordinator.store.waitForPendingSave()
        let reloaded = ReceiptLiftCoordinator(load: { await harness.data }, save: { data, workouts in
            try await harness.save(data, workouts)
        })
        await reloaded.load()
        #expect(reloaded.store.routines == saved.routines)
        #expect(reloaded.store.exercises.contains { $0.id == preview.newExercises[0].id })
    }

    @Test func failedCommitLeavesMemoryAndDiskUnchangedAndTheSamePreviewCanRetry() async throws {
        let (coordinator, harness, original) = try await setup()
        let preview = try coordinator.store.prepareRoutineImport(draft())
        await harness.failNextSave()
        await #expect(throws: (any Error).self) {
            try await coordinator.store.importReviewedRoutines(preview, allowNewExercises: true)
        }
        let persisted = await harness.data
        #expect(try persisted == encode(original))
        #expect(coordinator.store.routines == original.routines)
        #expect(!coordinator.store.exercises.contains { $0.id == preview.newExercises[0].id })
        try await coordinator.store.importReviewedRoutines(preview, allowNewExercises: true)
        let retried = try decode(await harness.data)
        #expect(retried.routines.count == original.routines.count + 1)
    }

    @Test func reusingAConfirmedPreviewCannotDuplicateAndASecondImportHasANewReviewedName() async throws {
        let (coordinator, harness, original) = try await setup()
        let preview = try coordinator.store.prepareRoutineImport(draft())
        try await coordinator.store.importReviewedRoutines(preview, allowNewExercises: true)
        await #expect(throws: (any Error).self) {
            try await coordinator.store.importReviewedRoutines(preview, allowNewExercises: true)
        }
        #expect(await harness.attempts == 1)
        let second = try coordinator.store.prepareRoutineImport(draft())
        #expect(second.routines[0].name == "Push (imported 2)")
        #expect(second.routines[0].id != preview.routines[0].id)
        #expect(second.newExercises.isEmpty)
        try await coordinator.store.importReviewedRoutines(second, allowNewExercises: false)
        let saved = try decode(await harness.data)
        #expect(saved.routines.count == original.routines.count + 2)
    }

    @Test func sourceChangeAndActiveSessionPreventImportBeforeAnyImportWrite() async throws {
        let (coordinator, harness, original) = try await setup()
        let preview = try coordinator.store.prepareRoutineImport(draft())
        coordinator.configureRoutineImport(parse: NoopReceiptLiftRoutineImportAdapter.parse) {
            throw ImportHarnessError.sourceChanged
        }
        await #expect(throws: (any Error).self) {
            try await coordinator.store.importReviewedRoutines(preview, allowNewExercises: true)
        }
        #expect(await harness.attempts == 0)
        coordinator.configureRoutineImport(parse: NoopReceiptLiftRoutineImportAdapter.parse, validate: {})
        coordinator.store.startRoutine(nil)
        coordinator.store.flushPendingSave()
        await coordinator.store.waitForPendingSave()
        let before = await harness.attempts
        await #expect(throws: (any Error).self) {
            try await coordinator.store.importReviewedRoutines(preview, allowNewExercises: true)
        }
        #expect(await harness.attempts == before)
        #expect(coordinator.store.routines == original.routines)
    }

    @Test func aBackgroundFlushDuringCommitCannotOverwriteTheImportedRoutines() async throws {
        let (coordinator, harness, original) = try await setup()
        let preview = try coordinator.store.prepareRoutineImport(draft())
        await harness.holdNextSave()
        let importing = Task { try await coordinator.store.importReviewedRoutines(preview, allowNewExercises: true) }
        await harness.waitForHeldSave()
        #expect(coordinator.store.routines == original.routines, "The preview is not published as saved before commit")
        coordinator.store.setDefaultRestSeconds(135)
        coordinator.store.applicationDidEnterBackground()
        coordinator.store.startRoutine(nil)
        #expect(coordinator.store.activeSession == nil)
        await harness.releaseHeldSave()
        try await importing.value
        await coordinator.store.waitForPendingSave()
        let saved = try decode(await harness.data)
        #expect(saved.routines.count == original.routines.count + 1)
        #expect(saved.routines.last?.id == preview.routines[0].id)
        #expect(saved.settings.defaultRestSeconds == 135)
        #expect(saved.activeSession == nil)
        #expect(await harness.attempts == 2, "The deferred edit is coalesced into one snapshot after import")
    }

    @Test func selectedFileReadRejectsUnsupportedAndOversizedFilesBeforeParsing() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let csv = folder.appendingPathComponent("routine.csv")
        let expected = Data("exercise,sets\nBench,3".utf8)
        try expected.write(to: csv)
        #expect(try LiftRoutineImportFile.read(csv) == expected)
        let unsupported = folder.appendingPathComponent("routine.numbers")
        try expected.write(to: unsupported)
        #expect(throws: (any Error).self) { try LiftRoutineImportFile.read(unsupported) }
        try Data(repeating: 32, count: LiftRoutineImportFile.maxBytes + 1).write(to: csv)
        #expect(throws: (any Error).self) { try LiftRoutineImportFile.read(csv) }
    }

    @Test func anExerciseCannotSilentlyCollapseTwoPlansOrGuessAnUnknownExercise() throws {
        let original = fixture()
        let repeated = ReceiptLiftRoutineImportDraft(routines: [
            .init(name: "Other", exercises: [.init(name: "Fixture Bench"), .init(name: "fixture-bench")])
        ])
        #expect(throws: (any Error).self) {
            try LiftRoutineImportBuilder.prepare(repeated, routines: original.routines, exercises: original.userExercises)
        }
        let misspelled = ReceiptLiftRoutineImportDraft(routines: [
            .init(name: "Other", exercises: [.init(name: "Fixture Benchh")])
        ])
        let preview = try LiftRoutineImportBuilder.prepare(misspelled, routines: original.routines, exercises: original.userExercises)
        #expect(preview.newExercises.map(\.name) == ["Fixture Benchh"])
        #expect(preview.routines[0].exerciseIDs[0] != original.userExercises[0].id)
    }

    @Test func spreadsheetNamesFindTheOneLibraryExerciseTheyMean() {
        let library = Self.library("Barbell Bench Press", "Dumbbell Bench Press", "Cable Bench Press", "Band Bench Press",
                                   "Barbell Incline Bench Press", "Pull-Up", "Dumbbell Curl", "Cable Curl",
                                   "Barbell Seated Overhead Press", "Dumbbell Standing Overhead Press", "Barbell Bent Over Row")
        let matcher = LiftExerciseMatcher(library)
        func match(_ name: String) -> String? { matcher.match(name)?.name }
        // Case, punctuation, spacing and equipment shorthand.
        #expect(match("barbell bench press") == "Barbell Bench Press")
        #expect(match("BB Bench-Press") == "Barbell Bench Press")
        #expect(match("DB bench press") == "Dumbbell Bench Press")
        #expect(match("Bench Press (barbell)") == "Barbell Bench Press")
        // An unqualified lift means the barbell one when only one barbell version exists.
        #expect(match("Bench Press") == "Barbell Bench Press")
        #expect(match("Incline Bench Press") == "Barbell Incline Bench Press")
        // Singular, plural and run-together spellings.
        #expect(match("Pull Up") == "Pull-Up")
        #expect(match("pull-ups") == "Pull-Up")
        #expect(match("Pullup") == "Pull-Up")
        #expect(match("Dumbbell Curls") == "Dumbbell Curl")
    }

    @Test func aSheetNameWhoseWordsAreInOneLibraryNameMatchesIt() {
        let library = Self.library("Barbell Bent Over Row", "Barbell Seated Overhead Press", "Dumbbell Standing Overhead Press",
                                   "Barbell Bench Press", "Dumbbell Curl", "Cable Curl")
        let matcher = LiftExerciseMatcher(library)
        func match(_ name: String) -> String? { matcher.match(name)?.name }
        #expect(match("Barbell Row") == "Barbell Bent Over Row")
        #expect(match("barbell rows") == "Barbell Bent Over Row")
        #expect(match("Seated Overhead Press") == "Barbell Seated Overhead Press", "Every word is in exactly one name")
        #expect(match("Standing Press") == "Dumbbell Standing Overhead Press")
        #expect(match("Dumbbell Row") == nil, "The named equipment is not in the only row")
    }

    @Test func aSheetNameWhoseWordsAreInSeveralLibraryNamesStaysCustom() {
        let library = Self.library("Barbell Seated Overhead Press", "Dumbbell Standing Overhead Press",
                                   "Barbell Bent Over Row", "Barbell Upright Row", "Barbell Pendlay Row")
        let matcher = LiftExerciseMatcher(library)
        #expect(matcher.match("Overhead Press") == nil, "Seated barbell and standing dumbbell both fit")
        #expect(matcher.match("Pendlay Row")?.name == "Barbell Pendlay Row")
        #expect(matcher.match("Upright Row")?.name == "Barbell Upright Row")
        #expect(matcher.match("Press") == nil, "One word is never enough on its own")
    }

    @Test func ambiguousOrContradictoryNamesStayCustom() {
        let library = Self.library("Barbell Bench Press", "Dumbbell Bench Press", "Dumbbell Curl", "Cable Curl",
                                   "Barbell Seated Overhead Press", "Dumbbell Standing Overhead Press", "Barbell Bent Over Row")
        let matcher = LiftExerciseMatcher(library)
        #expect(matcher.match("Curl") == nil, "Two non-barbell candidates")
        #expect(matcher.match("Overhead Press") == nil, "The words differ from every library name")
        #expect(matcher.match("Machine Bench Press") == nil, "Machine contradicts both library versions")
        #expect(matcher.match("Cable Bench Press") == nil)
        #expect(matcher.match("Benchh Press") == nil)
        let barbell = library[0]
        #expect(matcher.match("Bench Press", excluding: [barbell.id]) == nil, "Never reuse an exercise already in the routine")
    }

    @Test func reviewShowsTheLibraryNameForANearMatchAndSavesNoCustomExercise() throws {
        let original = fixture()
        let library = Self.library("Barbell Bench Press", "Dumbbell Bench Press") + original.userExercises
        let draft = ReceiptLiftRoutineImportDraft(routines: [
            .init(name: "Other", exercises: [.init(name: "Bench Press", sets: "3"), .init(name: "Fixture Bench"), .init(name: "Cable Arc")])
        ])
        let preview = try LiftRoutineImportBuilder.prepare(draft, routines: original.routines, exercises: library)
        let plans = try #require(preview.routines[0].exercisePlans)
        #expect(preview.exercise(plans[0].exerciseID)?.name == "Barbell Bench Press")
        #expect(preview.importedNames[plans[0].id] == "Bench Press")
        #expect(preview.importedNames[plans[1].id] == nil, "An exact match needs no mapping")
        #expect(preview.newExercises.map(\.name) == ["Cable Arc"])
        #expect(preview.matchedExercises.count == 2)
        // A sheet that names different equipment is not matched to the barbell lift.
        let dumbbell = ReceiptLiftRoutineImportDraft(routines: [
            .init(name: "Other", exercises: [.init(name: "Bench Press", equipment: "machine")])
        ])
        let custom = try LiftRoutineImportBuilder.prepare(dumbbell, routines: original.routines, exercises: library)
        #expect(custom.newExercises.map(\.name) == ["Bench Press"])
    }

    @Test func barbellRowImportsAsTheLibraryRowAndAnAmbiguousNameStaysCustom() throws {
        let original = fixture()
        let library = Self.library("Barbell Bent Over Row", "Barbell Seated Overhead Press", "Dumbbell Standing Overhead Press")
        let draft = ReceiptLiftRoutineImportDraft(routines: [
            .init(name: "Pull", exercises: [.init(name: "Barbell Row", sets: "4"), .init(name: "Overhead Press")])
        ])
        let preview = try LiftRoutineImportBuilder.prepare(draft, routines: original.routines, exercises: library)
        let plans = try #require(preview.routines[0].exercisePlans)
        #expect(preview.exercise(plans[0].exerciseID)?.name == "Barbell Bent Over Row")
        #expect(preview.importedNames[plans[0].id] == "Barbell Row")
        #expect(preview.newExercises.map(\.name) == ["Overhead Press"], "Two library candidates: stays custom")
        #expect(preview.importedNames[plans[1].id] == nil)
    }

    private func setup() async throws -> (ReceiptLiftCoordinator, RoutineImportHarness, LiftDataEnvelope) {
        let original = fixture()
        let harness = RoutineImportHarness(data: try encode(original))
        let coordinator = ReceiptLiftCoordinator(load: { await harness.data }, save: { data, workouts in
            try await harness.save(data, workouts)
        })
        coordinator.configureRoutineImport(parse: NoopReceiptLiftRoutineImportAdapter.parse, validate: {})
        await coordinator.load()
        await coordinator.store.waitForPendingSave()
        return (coordinator, harness, original)
    }

    private func draft() -> ReceiptLiftRoutineImportDraft {
        .init(routines: [.init(name: "Push", notes: "Imported plan", trainingMode: "strength", exercises: [
            .init(name: "Fixture Bench", sets: "3", reps: "5-8", rest: "120 s", targetEffort: "8 RPE", notes: "Planned load: 60 kg"),
            .init(name: "Custom cable arc", muscleGroup: "chest", equipment: "cable", sets: "2", reps: "12")
        ])])
    }

    private static func library(_ names: String...) -> [LiftExercise] {
        names.map { name in
            let equipment = ["barbell", "dumbbell", "cable", "band", "machine"].first { name.lowercased().contains($0) } ?? "body weight"
            return LiftExercise(id: UUID(), name: name, muscleGroup: "pectorals", equipment: equipment, instructions: "")
        }
    }

    private func fixture() -> LiftDataEnvelope {
        let exercise = LiftExercise(id: UUID(), name: "Fixture Bench", muscleGroup: "pectorals", equipment: "barbell", instructions: "Press")
        let plan = LiftRoutineExercisePlan(id: UUID(), exerciseID: exercise.id, sets: "4", reps: "8", rest: "90 s", targetEffort: "2 RIR", notes: "Original")
        let routine = LiftRoutine(id: UUID(), name: "Push", notes: "Keep this", trainingMode: .hypertrophy, exerciseIDs: [exercise.id], exercisePlans: [plan])
        let session = LiftSession(id: UUID(), routineID: routine.id, title: "Push", startedAt: Date(timeIntervalSince1970: 1_780_000_000), endedAt: Date(timeIntervalSince1970: 1_780_001_000), sets: [
            LiftSet(id: UUID(), exerciseID: exercise.id, setNumber: 1, weight: 100, reps: 8, rpe: 8, isWarmup: false, completedAt: Date(timeIntervalSince1970: 1_780_000_500), notes: "Keep set")
        ])
        let scheduled = ScheduledWorkout(id: UUID(), routineID: routine.id, plannedAt: Date(timeIntervalSince1970: 1_800_000_000), note: "Keep schedule", completedSessionID: nil)
        return LiftDataEnvelope(schemaVersion: 2, starterBankVersion: 1, userExercises: [exercise], routines: [routine], scheduledWorkouts: [scheduled], sessions: [session], activeSession: nil, restTimerEndDate: nil, workoutRestOverrideSeconds: nil, completedExerciseIDs: [], activeExerciseIDsOverride: nil, activePlanOverrides: [:], activeSupersetGroups: [:], settings: LiftSettings())
    }

    private func encode(_ value: LiftDataEnvelope) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        return try encoder.encode(value)
    }

    private func decode(_ data: Data) throws -> LiftDataEnvelope {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode(LiftDataEnvelope.self, from: data)
    }
}

private enum ImportHarnessError: Error { case failedSave, sourceChanged }

private actor RoutineImportHarness {
    private(set) var data: Data
    private(set) var attempts = 0
    private(set) var changedWorkouts: [ReceiptLiftWorkout] = []
    private var failsNext = false
    private var holdsNext = false
    private var heldSave: CheckedContinuation<Void, Never>?
    private var holdWaiters: [CheckedContinuation<Void, Never>] = []

    init(data: Data) { self.data = data }
    func failNextSave() { failsNext = true }
    func holdNextSave() { holdsNext = true }
    func waitForHeldSave() async {
        if heldSave != nil { return }
        await withCheckedContinuation { holdWaiters.append($0) }
    }
    func releaseHeldSave() { heldSave?.resume(); heldSave = nil }
    func save(_ data: Data, _ workouts: [ReceiptLiftWorkout]) async throws {
        attempts += 1
        if holdsNext {
            holdsNext = false
            await withCheckedContinuation { continuation in
                heldSave = continuation
                for waiter in holdWaiters { waiter.resume() }
                holdWaiters = []
            }
        }
        if failsNext { failsNext = false; throw ImportHarnessError.failedSave }
        self.data = data
        changedWorkouts += workouts
    }
}
