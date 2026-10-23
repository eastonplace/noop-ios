#if os(iOS)
import XCTest
import UIKit
@testable import NOOP

@MainActor
final class CoachPersistenceIOTests: XCTestCase {
    private final class SourceBox {
        var value: LocalCoachSourceScope
        init(_ value: LocalCoachSourceScope) { self.value = value }
    }
    private func directory() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("CoachIO-\(UUID())")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        return url
    }

    private func waitUntil(_ predicate: () -> Bool) async {
        for _ in 0..<500 {
            if predicate() { return }
            try? await Task.sleep(for: .milliseconds(10))
        }
        XCTFail("Persistence did not settle")
    }

    func testInitializationDefersDecodeAndPreservesUnreadableHistory() async throws {
        let store = LocalCoachPersistence(directory: try directory())
        let file = store.fileURL(sourceID: "a")
        let original = Data("broken json".utf8)
        try original.write(to: file)
        let engine = LocalCoachEngine(data: nil, persistence: store, model: nil,
            source: { .init(storageID: "a", dataSourceID: "a", revision: "1") })
        XCTAssertNil(engine.errorText, "initialization must not synchronously read or decode history")
        await waitUntil { engine.errorText != nil }
        engine.newConversation()
        try? await Task.sleep(for: .milliseconds(50))
        XCTAssertEqual(try Data(contentsOf: file), original)
    }

    func testPreferenceEditBeforeHydrationDoesNotReplaceUneditedStoredFields() async throws {
        let store = LocalCoachPersistence(directory: try directory())
        var saved = LocalCoachPreferences()
        saved.enabled = false
        saved.style = "Stored style"
        try store.savePreferences(saved)
        let engine = LocalCoachEngine(data: nil, persistence: store, model: nil,
            source: { .init(storageID: "a", dataSourceID: "a", revision: "1") })
        engine.preferences.speakReplies = true
        await waitUntil { engine.preferences.style == "Stored style" }
        XCTAssertFalse(engine.preferences.enabled)
        XCTAssertTrue(engine.preferences.speakReplies)
    }

    func testDeleteWhileHydratingCannotBeUndoneByLateLoadOrSave() async throws {
        let store = LocalCoachPersistence(directory: try directory())
        let conversation = LocalCoachConversation(title: "Remove me", messages: [.init(role: .user, text: "private")])
        try store.save(.init(sourceID: "a", conversations: [conversation], selectedConversationID: conversation.id))
        let engine = LocalCoachEngine(data: nil, persistence: store, model: nil,
            source: { .init(storageID: "a", dataSourceID: "a", revision: "1") })
        engine.deleteConversation(conversation.id)
        await waitUntil { (try? store.load(sourceID: "a").conversations.isEmpty) == true }
        XCTAssertTrue(engine.conversations.isEmpty)
        XCTAssertTrue(engine.messages.isEmpty)
    }
    func testWidgetBriefWaitsForHydratedConsentAndSurvivesAnAllowedRelaunch() async throws {
        for allowed in [true, false] {
            let store = LocalCoachPersistence(directory: try directory())
            var saved = LocalCoachPreferences()
            saved.enabled = true
            saved.usePersonalData = allowed
            try store.savePreferences(saved)
            var clears = 0
            let engine = LocalCoachEngine(data: nil, persistence: store, model: nil,
                source: { .init(storageID: "a", dataSourceID: "a", revision: "1") },
                clearPublishedBrief: { clears += 1 })
            XCTAssertEqual(clears, 0, "Persisted consent has not been read yet")
            await engine.waitForHydration()
            XCTAssertEqual(clears, allowed ? 0 : 1,
                "An allowed completed brief must survive relaunch; revoked consent must clear it")
        }
    }

    func testDeletingConversationDuringHydrationImmediatelyClearsWidgetBrief() async throws {
        let store = LocalCoachPersistence(directory: try directory())
        var saved = LocalCoachPreferences()
        saved.enabled = true
        saved.usePersonalData = true
        try store.savePreferences(saved)
        let conversation = LocalCoachConversation(title: "Remove brief", messages: [.init(role: .assistant, text: "Private brief")])
        try store.save(.init(sourceID: "a", conversations: [conversation], selectedConversationID: conversation.id))
        var clears = 0
        let engine = LocalCoachEngine(data: nil, persistence: store, model: nil,
            source: { .init(storageID: "a", dataSourceID: "a", revision: "1") },
            clearPublishedBrief: { clears += 1 })
        engine.deleteConversation(conversation.id)
        XCTAssertEqual(clears, 1, "The widget must not retain prose after the person deletes its conversation")
        await engine.waitForHydration()
        XCTAssertTrue(engine.conversations.isEmpty)
    }

    func testEditingMessageDuringAllowedHydrationImmediatelyClearsWidgetBrief() async throws {
        let store = LocalCoachPersistence(directory: try directory())
        var saved = LocalCoachPreferences()
        saved.enabled = true
        saved.usePersonalData = true
        try store.savePreferences(saved)
        let question = LocalCoachMessage(role: .user, text: "Original question")
        let conversation = LocalCoachConversation(title: "Edit brief", messages: [
            question, .init(role: .assistant, text: "Private brief from original question")
        ])
        try store.save(.init(sourceID: "a", conversations: [conversation], selectedConversationID: conversation.id))
        var clears = 0
        let engine = LocalCoachEngine(data: nil, persistence: store, model: nil,
            source: { .init(storageID: "a", dataSourceID: "a", revision: "1") },
            clearPublishedBrief: { clears += 1 })
        XCTAssertTrue(engine.isHydrating)
        XCTAssertEqual(clears, 0)
        engine.editMessage(question.id, text: "Reviewed new question")
        XCTAssertEqual(clears, 1, "The old brief must disappear as soon as its queued message edit is accepted")
        await engine.flushPersistence()
        XCTAssertEqual(clears, 1, "Allowed consent must not hide a missing immediate clear")
        XCTAssertEqual(engine.messages.map(\.text), ["Reviewed new question"])
        XCTAssertEqual(try store.load(sourceID: "a").conversations.first?.messages.map(\.text), ["Reviewed new question"])
    }

    func testDeletingMemoryDuringAllowedHydrationImmediatelyClearsWidgetBrief() async throws {
        let store = LocalCoachPersistence(directory: try directory())
        var saved = LocalCoachPreferences()
        saved.enabled = true
        saved.usePersonalData = true
        saved.memoryEnabled = true
        try store.savePreferences(saved)
        let memory = LocalCoachMemory(category: .goals, text: "Private goal used by the brief")
        try store.save(.init(sourceID: "a", memories: [memory]))
        var clears = 0
        let engine = LocalCoachEngine(data: nil, persistence: store, model: nil,
            source: { .init(storageID: "a", dataSourceID: "a", revision: "1") },
            clearPublishedBrief: { clears += 1 })
        XCTAssertTrue(engine.isHydrating)
        XCTAssertEqual(clears, 0)
        engine.deleteMemory(memory.id)
        XCTAssertEqual(clears, 1, "The widget must not retain a brief derived from the queued memory deletion")
        await engine.flushPersistence()
        XCTAssertEqual(clears, 1, "Allowed consent must not hide a missing immediate clear")
        XCTAssertTrue(engine.memories.isEmpty)
        XCTAssertTrue(try store.load(sourceID: "a").memories.isEmpty)
    }

    func testQueuedSnapshotsFlushLatestDeletionAndPreferencesInOrder() async throws {
        let store = LocalCoachPersistence(directory: try directory())
        let writer = LocalCoachPersistenceWriter(store)
        let conversation = LocalCoachConversation(title: "First")
        var state = LocalCoachPersistence.State(sourceID: "a", conversations: [conversation])
        writer.save(state)
        await writer.flush()
        state.conversations = []
        writer.save(state)
        var preferences = LocalCoachPreferences()
        preferences.enabled = false
        writer.savePreferences(preferences)
        state.memories = [.init(category: .goals, text: "Keep this accepted edit")]
        writer.save(state)
        await writer.flush()
        let reopened = try store.load(sourceID: "a")
        XCTAssertTrue(reopened.conversations.isEmpty)
        XCTAssertEqual(reopened.memories.map(\.text), ["Keep this accepted edit"])
        XCTAssertFalse(try store.loadPreferences().enabled)
    }

    func testSourceSwitchDuringHydrationCommitsOldDeletionBeforeReturningToSource() async throws {
        let store = LocalCoachPersistence(directory: try directory())
        let conversation = LocalCoachConversation(title: "A only")
        try store.save(.init(sourceID: "a", conversations: [conversation], selectedConversationID: conversation.id))
        let scope = SourceBox(.init(storageID: "a", dataSourceID: "a", revision: "1"))
        let engine = LocalCoachEngine(data: nil, persistence: store, model: nil, source: { scope.value })
        engine.deleteConversation(conversation.id)
        scope.value = .init(storageID: "b", dataSourceID: "b", revision: "2")
        engine.newConversation()
        scope.value = .init(storageID: "a", dataSourceID: "a", revision: "3")
        await engine.flushPersistence()
        XCTAssertTrue(engine.conversations.isEmpty)
        XCTAssertTrue(engine.messages.isEmpty)
        XCTAssertTrue(try store.load(sourceID: "a").conversations.isEmpty)
    }

    func testLeavingForegroundFlushesAcceptedPreferenceEdit() async throws {
        let store = LocalCoachPersistence(directory: try directory())
        let center = NotificationCenter()
        let engine = LocalCoachEngine(data: nil, persistence: store, model: nil,
            source: { .init(storageID: "a", dataSourceID: "a", revision: "1") }, notificationCenter: center)
        await engine.waitForHydration()
        engine.preferences.style = "Keep my edit"
        center.post(name: UIApplication.willResignActiveNotification, object: nil)
        await engine.flushPersistence()
        XCTAssertEqual(try store.loadPreferences().style, "Keep my edit")
    }

}
#endif
