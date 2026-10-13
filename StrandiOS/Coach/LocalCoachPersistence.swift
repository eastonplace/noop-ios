#if os(iOS)
import Foundation
import CryptoKit

/// App-private, backup-excluded files. There is no iCloud container, network client, or shared BYOK store.
struct LocalCoachPersistence {
    struct State: Codable {
        var version = 1
        var sourceID: String
        var conversations: [LocalCoachConversation] = []
        var memories: [LocalCoachMemory] = []
        var plan: LocalCoachPlan?
        var selectedConversationID: UUID?
        var historyFloor = Date.distantPast
    }

    private struct Settings: Codable {
        var version = 1
        var preferences: LocalCoachPreferences
    }
    private struct Header: Decodable { var version: Int }

    enum StoreError: LocalizedError {
        case unsupportedVersion(Int), wrongSource, tooLarge, invalidDirectory
        var errorDescription: String? {
            switch self {
            case .unsupportedVersion(let version): return "Coach storage version \(version) is not supported. The original file was kept."
            case .wrongSource: return "Coach storage belongs to a different data source. The original file was kept."
            case .tooLarge: return "Coach storage is too large to load or save safely. Export and remove older conversations."
            case .invalidDirectory: return "Coach storage could not find the app's local Application Support directory."
            }
        }
    }

    let directory: URL
    private static let maximumFileBytes = 8 * 1_024 * 1_024

    init(directory: URL) { self.directory = directory }

    static func appLocal() throws -> Self {
        guard let root = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first else {
            throw StoreError.invalidDirectory
        }
        return Self(directory: root.appendingPathComponent("LocalCoach", isDirectory: true))
    }

    func fileURL(sourceID: String) -> URL {
        let hash = SHA256.hash(data: Data(sourceID.utf8)).map { String(format: "%02x", $0) }.joined()
        return directory.appendingPathComponent("source-\(hash).json")
    }

    func load(sourceID: String) throws -> State {
        guard let bytes = try read(fileURL(sourceID: sourceID)) else { return State(sourceID: sourceID) }
        let value = try JSONDecoder().decode(State.self, from: bytes)
        guard value.sourceID == sourceID else { throw StoreError.wrongSource }
        return value
    }

    func save(_ state: State) throws {
        guard state.version == 1 else { throw StoreError.unsupportedVersion(state.version) }
        try write(state, to: fileURL(sourceID: state.sourceID))
    }

    /// Settings are global so master off also applies after the user changes the selected source.
    func loadPreferences() throws -> LocalCoachPreferences {
        let url = directory.appendingPathComponent("settings.json")
        guard let bytes = try read(url) else { return .init() }
        let preferences = try JSONDecoder().decode(Settings.self, from: bytes).preferences
        // CORE-04: settings written by an earlier build carry `.complete`; move them to the readable-after-
        // first-unlock class so a later locked background launch can read them.
        if (try? FileManager.default.attributesOfItem(atPath: url.path)[.protectionKey] as? FileProtectionType)
            == .complete {
            try? FileManager.default.setAttributes([.protectionKey: Self.settingsProtection], ofItemAtPath: url.path)
        }
        return preferences
    }

    func savePreferences(_ preferences: LocalCoachPreferences) throws {
        try write(Settings(preferences: preferences), to: directory.appendingPathComponent("settings.json"),
                  protection: .completeFileProtectionUntilFirstUserAuthentication)
    }

    /// CORE-04: settings hold switches and a style string, nothing personal. They must stay readable in a
    /// locked background launch after first unlock (BLE restoration overnight), like the app's other state
    /// (StorePaths). Conversations and memories keep `.complete`.
    static let settingsProtection = FileProtectionType.completeUntilFirstUserAuthentication

    private func read(_ url: URL) throws -> Data? {
        let attributes: [FileAttributeKey: Any]
        do { attributes = try FileManager.default.attributesOfItem(atPath: url.path) }
        catch let error as CocoaError where error.code == .fileReadNoSuchFile || error.code == .fileNoSuchFile {
            return nil
        }
        guard (attributes[.size] as? NSNumber)?.intValue ?? Int.max <= Self.maximumFileBytes else {
            throw StoreError.tooLarge
        }
        let bytes = try Data(contentsOf: url)
        guard bytes.count <= Self.maximumFileBytes else { throw StoreError.tooLarge }
        let header = try JSONDecoder().decode(Header.self, from: bytes)
        guard header.version == 1 else { throw StoreError.unsupportedVersion(header.version) }
        return bytes
    }

    private func write<T: Encodable>(_ value: T, to url: URL,
                                     protection: Data.WritingOptions = .completeFileProtection) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let bytes = try encoder.encode(value)
        guard bytes.count <= Self.maximumFileBytes else { throw StoreError.tooLarge }
        var directory = directory
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        var flags = URLResourceValues()
        flags.isExcludedFromBackup = true
        try directory.setResourceValues(flags)
        #if os(iOS)
        try FileManager.default.setAttributes([.protectionKey: FileProtectionType.complete], ofItemAtPath: directory.path)
        try bytes.write(to: url, options: [.atomic, protection])
        #else
        try bytes.write(to: url, options: .atomic)
        #endif
        var savedURL = url
        try savedURL.setResourceValues(flags)
    }
}
#endif
