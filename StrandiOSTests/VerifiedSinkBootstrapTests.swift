import XCTest
@testable import NOOP

#if os(iOS)
/// Only a source transition writes the App Group's verified-sink token, so an install that predates it never had one and
/// every Widget and Live Activity write carrying health was superseded. The launch, foreground and protected-data recovery
/// repairs it (`AppModel.bootstrapVerifiedSink`), and must never touch a token a pending transition owns.
@MainActor
final class VerifiedSinkBootstrapTests: XCTestCase {
    private var suite = ""
    private var defaults: UserDefaults!
    private var activations: [(contextId: String, epoch: UInt64)] = []

    override func setUp() async throws {
        suite = "noop.verified-sink-bootstrap.\(UUID().uuidString)"
        defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        activations = []
    }

    override func tearDown() async throws {
        defaults.removePersistentDomain(forName: suite)
    }

    /// `context` is the day's snapshot context; `projection` the verified projection's, when there is one.
    private func bootstrap(
        loaded: Bool = true,
        context: String? = "context-A",
        projection: String? = nil,
        pending: Bool = false,
        sinksActivate: Bool = true
    ) -> AppModel.VerifiedSinkBootstrapOutcome {
        AppModel.bootstrapVerifiedSink(
            repositoryLoaded: loaded,
            projectionContextId: projection,
            snapshotContextId: context,
            hasPendingTransition: pending,
            defaults: defaults,
            activateSinks: { contextId, epoch in
                self.activations.append((contextId, epoch))
                return sinksActivate
            })
    }

    private func install(contextId: String) throws -> VerifiedSinkToken {
        let epoch = try XCTUnwrap(ActiveVerifiedSinkEpochStore.beginTransition(defaults: defaults))
        return try XCTUnwrap(ActiveVerifiedSinkEpochStore.activate(contextId: contextId, epoch: epoch, defaults: defaults))
    }

    private var activeRecord: Data? { defaults.data(forKey: ActiveVerifiedSinkEpochStore.activeKey) }

    func testAMissingTokenIsActivatedForTheRepositoryContext() throws {
        XCTAssertNil(ActiveVerifiedSinkEpochStore.activeToken(defaults: defaults), "an install from before the token")
        XCTAssertEqual(bootstrap(context: "context-A"), .activated)
        let token = try XCTUnwrap(ActiveVerifiedSinkEpochStore.activeToken(defaults: defaults))
        XCTAssertEqual(token.contextId, "context-A")
        XCTAssertEqual(activations.map { $0.contextId }, ["context-A"], "both iOS sinks were activated")
        XCTAssertEqual(activations.map { $0.epoch }, [token.epoch])
    }

    func testATokenForAContextThatMovedIsReplacedUnderAHigherEpoch() throws {
        let old = try install(contextId: "context-A")
        // The Live Activity's generation fence from the old epoch would reject every verified write under the new one.
        _ = ActiveVerifiedSinkEpochStore.commitIfCurrent(
            token: old, generation: 5, defaults: defaults,
            generationKey: ActiveVerifiedSinkEpochStore.liveActivityGenerationKey,
            writeAndReadBackPayload: { _ in true })
        XCTAssertEqual(bootstrap(context: "context-B"), .activated)
        let token = try XCTUnwrap(ActiveVerifiedSinkEpochStore.activeToken(defaults: defaults))
        XCTAssertEqual(token.contextId, "context-B")
        XCTAssertGreaterThan(token.epoch, old.epoch)
        XCTAssertNil(defaults.data(forKey: ActiveVerifiedSinkEpochStore.liveActivityGenerationKey))
    }

    /// The Widget envelope is fenced to its epoch: left behind, it would make every commit under the new epoch superseded
    /// and the Home Screen widget blank for good.
    func testAContextMoveClearsTheOldEpochsWidgetSoTheNextPublishIsReadable() throws {
        let old = try install(contextId: "context-A")
        let oldSnapshot = WidgetSnapshot(recovery: 71, bpm: nil, batteryPct: nil, bonded: false, updated: Date(),
                                         verifiedContextId: "context-A", verifiedProjectionGeneration: 3)
        XCTAssertEqual(VerifiedWidgetEnvelopeStore.commit(
            token: old, generation: 3, snapshot: oldSnapshot, defaults: defaults), .published)
        XCTAssertNotNil(VerifiedWidgetEnvelopeStore.loadForDisplay(defaults: defaults))

        XCTAssertEqual(bootstrap(context: "context-B"), .activated)
        XCTAssertNil(VerifiedWidgetEnvelopeStore.load(defaults: defaults), "the old epoch's envelope is gone")
        XCTAssertNil(defaults.data(forKey: ActiveVerifiedSinkEpochStore.widgetLiveOverlayKey))

        let token = try XCTUnwrap(ActiveVerifiedSinkEpochStore.activeToken(defaults: defaults))
        let snapshot = WidgetSnapshot(recovery: 64, bpm: nil, batteryPct: nil, bonded: false, updated: Date(),
                                      verifiedContextId: "context-B", verifiedProjectionGeneration: 1)
        XCTAssertEqual(VerifiedWidgetEnvelopeStore.commit(
            token: token, generation: 1, snapshot: snapshot, defaults: defaults), .published,
                       "the next publish under the new epoch commits")
        XCTAssertEqual(VerifiedWidgetEnvelopeStore.loadForDisplay(defaults: defaults)?.verifiedContextId, "context-B",
                       "and the widget can read it")
    }

    func testAMatchingTokenIsKept() throws {
        let token = try install(contextId: "context-A")
        let before = activeRecord
        XCTAssertEqual(bootstrap(context: "context-A"), .kept)
        XCTAssertEqual(ActiveVerifiedSinkEpochStore.activeToken(defaults: defaults), token)
        XCTAssertEqual(activeRecord, before, "the epoch did not move")
        XCTAssertTrue(activations.isEmpty)
    }

    func testANonTerminalTransitionRecordLeavesTheTokenUntouched() throws {
        _ = try install(contextId: "context-A")
        let before = activeRecord
        XCTAssertEqual(bootstrap(context: "context-B", pending: true), .waitingForSourceTransition)
        XCTAssertEqual(activeRecord, before)

        defaults.removeObject(forKey: ActiveVerifiedSinkEpochStore.activeKey)
        XCTAssertEqual(bootstrap(context: "context-B", pending: true), .waitingForSourceTransition)
        XCTAssertNil(activeRecord, "a missing token waits for the transition too")
        XCTAssertTrue(activations.isEmpty)
    }

    func testARepositoryNotYetLoadedNeverClearsOrActivates() throws {
        let token = try install(contextId: "context-A")
        let before = activeRecord
        XCTAssertEqual(bootstrap(loaded: false, context: nil), .repositoryNotLoaded)
        XCTAssertEqual(bootstrap(loaded: false, context: "context-B"), .repositoryNotLoaded)
        XCTAssertEqual(activeRecord, before)
        XCTAssertEqual(ActiveVerifiedSinkEpochStore.activeToken(defaults: defaults), token)

        defaults.removeObject(forKey: ActiveVerifiedSinkEpochStore.activeKey)
        XCTAssertEqual(bootstrap(loaded: false, context: "context-A"), .repositoryNotLoaded)
        XCTAssertNil(activeRecord)
        XCTAssertTrue(activations.isEmpty)
    }

    func testALoadedRepositoryWithNoContextLeavesTheTokenAlone() throws {
        let token = try install(contextId: "context-A")
        XCTAssertEqual(bootstrap(context: nil), .closedSourceLeftAlone)
        XCTAssertEqual(ActiveVerifiedSinkEpochStore.activeToken(defaults: defaults), token)
        XCTAssertTrue(activations.isEmpty)
    }

    // MARK: Projection first

    /// The widgets publish, and the Live Activity admits health, only under a token naming the verified projection's
    /// context. A working token for the projection is kept although the day's snapshot moved on, so an upgrade never
    /// rotates it away and blanks the widgets.
    func testATokenMatchingTheProjectionIsKeptWhileTheSnapshotMovedOn() throws {
        let token = try install(contextId: "context-P")
        let snapshot = WidgetSnapshot(recovery: 71, bpm: nil, batteryPct: nil, bonded: false, updated: Date(),
                                      verifiedContextId: "context-P", verifiedProjectionGeneration: 3)
        XCTAssertEqual(VerifiedWidgetEnvelopeStore.commit(
            token: token, generation: 3, snapshot: snapshot, defaults: defaults), .published)
        let envelope = defaults.data(forKey: VerifiedWidgetEnvelopeStore.storageKey)
        let record = activeRecord

        XCTAssertEqual(bootstrap(context: "context-S", projection: "context-P"), .kept)
        XCTAssertEqual(activeRecord, record, "the token and its epoch did not move")
        XCTAssertEqual(defaults.data(forKey: VerifiedWidgetEnvelopeStore.storageKey), envelope,
                       "the widget envelope is untouched")
        XCTAssertEqual(VerifiedWidgetEnvelopeStore.loadForDisplay(defaults: defaults)?.verifiedContextId, "context-P")
        XCTAssertTrue(activations.isEmpty)
    }

    /// After the repair, a drive carrying the projection's surface is under the token: it keeps its health values.
    func testAfterTheBootstrapADriveForTheProjectionSeesAMatchingToken() throws {
        XCTAssertEqual(bootstrap(context: "context-S", projection: "context-P"), .activated)
        let token = try XCTUnwrap(ActiveVerifiedSinkEpochStore.activeToken(defaults: defaults))
        XCTAssertEqual(token.contextId, "context-P", "the projection's context, not the snapshot's")

        let admission = LiveActivityDriveAdmission.decide(
            recovery: 64, effort: 9.2, verifiedContextId: "context-P", verifiedProjectionGeneration: 1,
            activeToken: ActiveVerifiedSinkEpochStore.activeToken(defaults: defaults))
        XCTAssertEqual(admission.tokenState, .match)
        XCTAssertFalse(admission.strippedHealth)
        XCTAssertEqual(admission.recovery, 64)
    }

    func testWithoutAProjectionTheSnapshotsContextIsActivated() throws {
        XCTAssertEqual(bootstrap(context: "context-S", projection: nil), .activated)
        XCTAssertEqual(ActiveVerifiedSinkEpochStore.activeToken(defaults: defaults)?.contextId, "context-S")
    }

    /// A sink that refuses the activation is reported (and logged), never taken as success.
    func testAFailedSinkActivationIsReported() {
        XCTAssertEqual(bootstrap(context: "context-A", sinksActivate: false), .failed)
    }
}
#endif
