#if os(iOS)
import XCTest
@testable import NOOP

@MainActor
final class CoachPersistenceIOTests: XCTestCase {
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
}
#endif
