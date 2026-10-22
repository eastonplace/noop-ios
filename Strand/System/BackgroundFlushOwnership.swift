import Foundation

/// MainActor owners reserve before requesting an OS background assertion. Expiration can release a
/// reservation while its IO continues; a late completion must not end a newer assertion's lifetime.
struct BackgroundFlushOwnership<Identifier> {
    private var token: UUID?
    private var identifier: Identifier?

    mutating func reserve() -> UUID? {
        guard token == nil else { return nil }
        let value = UUID()
        token = value
        return value
    }

    mutating func assign(_ identifier: Identifier, to token: UUID) {
        guard self.token == token else { return }
        self.identifier = identifier
    }

    mutating func finish(_ token: UUID) -> Identifier? {
        guard self.token == token else { return nil }
        let value = identifier
        self.token = nil
        identifier = nil
        return value
    }
}
