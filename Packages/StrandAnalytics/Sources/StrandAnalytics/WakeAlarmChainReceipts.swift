import Foundation

/// Persisted trail of how the strap's single alarm slot was handed from one saved alarm to the next, so a
/// "second alarm did not buzz" report can be settled from the debug export instead of guessed at.
public enum WakeAlarmChainReceipts {
    public static let key = "alarm.chain.receipts.v1"
    public static let limit = 40

    public struct Entry: Codable, Equatable, Sendable {
        public let at: Date
        public let event: String
        public let endpoint: Date?
    }

    public static func record(_ event: String, endpoint: Date?, at: Date = Date(),
                              to defaults: UserDefaults = .standard) {
        var entries = load(from: defaults)
        // Foreground and reconnect reconciles repeat the same arm; keep one so they cannot evict the night.
        if let last = entries.last, last.event == event, last.endpoint == endpoint { return }
        entries.append(Entry(at: at, event: event, endpoint: endpoint))
        guard let data = try? JSONEncoder().encode(entries.suffix(limit)) else { return }
        defaults.set(data, forKey: key)
    }

    public static func load(from defaults: UserDefaults = .standard) -> [Entry] {
        defaults.data(forKey: key).flatMap { try? JSONDecoder().decode([Entry].self, from: $0) } ?? []
    }

    /// One readable line per receipt, oldest first, in the user's local time.
    public static func lines(from defaults: UserDefaults = .standard, calendar: Calendar = .current) -> [String] {
        func clock(_ date: Date, seconds: Bool) -> String {
            let parts = calendar.dateComponents([.hour, .minute, .second], from: date)
            let base = String(format: "%02d:%02d", parts.hour ?? 0, parts.minute ?? 0)
            return seconds ? base + String(format: ":%02d", parts.second ?? 0) : base
        }
        return load(from: defaults).map { entry in
            let target = entry.endpoint.map { " → \(clock($0, seconds: false))" } ?? ""
            return "\(clock(entry.at, seconds: true)) \(entry.event)\(target)"
        }
    }
}
