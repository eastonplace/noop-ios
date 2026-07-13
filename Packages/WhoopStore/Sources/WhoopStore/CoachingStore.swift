import Foundation
import GRDB

public struct CoachingBehaviorSet: Equatable, Sendable {
    public let id: String
    public let name: String
    public let isActive: Bool
    public let createdAt: Int
    public let updatedAt: Int

    public init(id: String, name: String, isActive: Bool, createdAt: Int, updatedAt: Int) {
        self.id = id
        self.name = name
        self.isActive = isActive
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }
}

public struct CoachingBehaviorMembership: Equatable, Sendable, Identifiable {
    public let setId: String
    public let canonicalQuestion: String
    public let coachingGroup: String
    public let sortIndex: Int
    public let isActive: Bool
    public let isQuickAdd: Bool

    public var id: String { setId + "\u{1F}" + canonicalQuestion }

    public init(setId: String, canonicalQuestion: String, coachingGroup: String,
                sortIndex: Int, isActive: Bool, isQuickAdd: Bool) {
        self.setId = setId
        self.canonicalQuestion = canonicalQuestion
        self.coachingGroup = coachingGroup
        self.sortIndex = sortIndex
        self.isActive = isActive
        self.isQuickAdd = isQuickAdd
    }
}

extension WhoopStore {
    /// Creates the initial set once and materializes only missing membership rows. Existing choices
    /// always win, so catalog growth is additive and a launch can never reset Active/Quick Add/order.
    public func ensureDefaultCoachingSet(name: String,
                                         memberships: [CoachingBehaviorMembership]) async throws -> CoachingBehaviorSet {
        try syncWrite { db in
            let now = Int(Date().timeIntervalSince1970)
            let activeRow = try Row.fetchOne(db, sql: """
                SELECT id, name, isActive, createdAt, updatedAt
                FROM coachingBehaviorSet WHERE isActive = 1
                ORDER BY updatedAt DESC LIMIT 1
                """)
            let set: CoachingBehaviorSet
            if let activeRow {
                set = CoachingBehaviorSet(id: activeRow["id"], name: activeRow["name"],
                                          isActive: true, createdAt: activeRow["createdAt"],
                                          updatedAt: activeRow["updatedAt"])
            } else {
                set = CoachingBehaviorSet(id: "daily-fundamentals", name: name, isActive: true,
                                          createdAt: now, updatedAt: now)
                try db.execute(sql: """
                    INSERT INTO coachingBehaviorSet (id, name, isActive, createdAt, updatedAt)
                    VALUES (?, ?, 1, ?, ?)
                    """, arguments: [set.id, set.name, now, now])
            }
            for membership in memberships {
                try db.execute(sql: """
                    INSERT OR IGNORE INTO coachingBehaviorMembership
                        (setId, canonicalQuestion, coachingGroup, sortIndex, isActive, isQuickAdd)
                    VALUES (?, ?, ?, ?, ?, ?)
                    """, arguments: [set.id, membership.canonicalQuestion, membership.coachingGroup,
                                     membership.sortIndex, membership.isActive ? 1 : 0,
                                     membership.isQuickAdd ? 1 : 0])
            }
            return set
        }
    }

    public func coachingBehaviorSets() async throws -> [CoachingBehaviorSet] {
        try syncRead { db in
            try Row.fetchAll(db, sql: """
                SELECT id, name, isActive, createdAt, updatedAt
                FROM coachingBehaviorSet ORDER BY isActive DESC, updatedAt DESC
                """).map {
                    CoachingBehaviorSet(id: $0["id"], name: $0["name"],
                                        isActive: ($0["isActive"] as Int) != 0,
                                        createdAt: $0["createdAt"], updatedAt: $0["updatedAt"])
                }
        }
    }

    public func coachingMemberships(setId: String) async throws -> [CoachingBehaviorMembership] {
        try syncRead { db in
            try Row.fetchAll(db, sql: """
                SELECT setId, canonicalQuestion, coachingGroup, sortIndex, isActive, isQuickAdd
                FROM coachingBehaviorMembership WHERE setId = ?
                ORDER BY sortIndex ASC, canonicalQuestion ASC
                """, arguments: [setId]).map {
                    CoachingBehaviorMembership(setId: $0["setId"], canonicalQuestion: $0["canonicalQuestion"],
                                               coachingGroup: $0["coachingGroup"], sortIndex: $0["sortIndex"],
                                               isActive: ($0["isActive"] as Int) != 0,
                                               isQuickAdd: ($0["isQuickAdd"] as Int) != 0)
                }
        }
    }

    public func upsertCoachingMemberships(_ memberships: [CoachingBehaviorMembership]) async throws {
        try syncWrite { db in
            for membership in memberships {
                try db.execute(sql: """
                    INSERT INTO coachingBehaviorMembership
                        (setId, canonicalQuestion, coachingGroup, sortIndex, isActive, isQuickAdd)
                    VALUES (?, ?, ?, ?, ?, ?)
                    ON CONFLICT(setId, canonicalQuestion) DO UPDATE SET
                        coachingGroup = excluded.coachingGroup,
                        sortIndex = excluded.sortIndex,
                        isActive = excluded.isActive,
                        isQuickAdd = excluded.isQuickAdd
                    """, arguments: [membership.setId, membership.canonicalQuestion,
                                     membership.coachingGroup, membership.sortIndex,
                                     membership.isActive ? 1 : 0, membership.isQuickAdd ? 1 : 0])
            }
        }
    }
}
