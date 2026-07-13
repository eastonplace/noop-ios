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

public struct CoachingStack: Equatable, Sendable, Identifiable {
    public let id: String
    public let name: String
    public let description: String?
    public let scheduleLabel: String?
    public let isActive: Bool
    public let notes: String?
    public let sortIndex: Int

    public init(id: String, name: String, description: String?, scheduleLabel: String?,
                isActive: Bool, notes: String?, sortIndex: Int) {
        self.id = id
        self.name = name
        self.description = description
        self.scheduleLabel = scheduleLabel
        self.isActive = isActive
        self.notes = notes
        self.sortIndex = sortIndex
    }
}

public struct CoachingStackItem: Equatable, Sendable, Identifiable {
    public let stackId: String
    public let canonicalQuestion: String
    public let dose: Double?
    public let unit: String?
    public let sortIndex: Int

    public var id: String { stackId + "\u{1F}" + canonicalQuestion }

    public init(stackId: String, canonicalQuestion: String, dose: Double?, unit: String?, sortIndex: Int) {
        self.stackId = stackId
        self.canonicalQuestion = canonicalQuestion
        self.dose = dose
        self.unit = unit
        self.sortIndex = sortIndex
    }
}

public struct CoachingStackUse: Equatable, Sendable, Identifiable {
    public let id: String
    public let stackId: String
    public let day: String
    public let loggedAt: Int
    public let notes: String?
    public let skipped: Bool

    public init(id: String, stackId: String, day: String, loggedAt: Int,
                notes: String?, skipped: Bool) {
        self.id = id
        self.stackId = stackId
        self.day = day
        self.loggedAt = loggedAt
        self.notes = notes
        self.skipped = skipped
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

    /// Installs the built-in preset once. INSERT OR IGNORE preserves every later user edit.
    public func ensureDefaultCoachingStack(_ stack: CoachingStack,
                                           items: [CoachingStackItem]) async throws -> CoachingStack {
        try syncWrite { db in
            try db.execute(sql: """
                INSERT OR IGNORE INTO coachingStack
                    (id, name, description, scheduleLabel, isActive, notes, sortIndex)
                VALUES (?, ?, ?, ?, ?, ?, ?)
                """, arguments: [stack.id, stack.name, stack.description, stack.scheduleLabel,
                                 stack.isActive ? 1 : 0, stack.notes, stack.sortIndex])
            for item in items {
                try db.execute(sql: """
                    INSERT OR IGNORE INTO coachingStackItem
                        (stackId, canonicalQuestion, dose, unit, sortIndex)
                    VALUES (?, ?, ?, ?, ?)
                    """, arguments: [stack.id, item.canonicalQuestion, item.dose, item.unit, item.sortIndex])
            }
            let row = try Row.fetchOne(db, sql: """
                SELECT id, name, description, scheduleLabel, isActive, notes, sortIndex
                FROM coachingStack WHERE id = ?
                """, arguments: [stack.id])!
            return CoachingStack(id: row["id"], name: row["name"], description: row["description"],
                                 scheduleLabel: row["scheduleLabel"],
                                 isActive: (row["isActive"] as Int) != 0,
                                 notes: row["notes"], sortIndex: row["sortIndex"])
        }
    }

    public func coachingStacks() async throws -> [CoachingStack] {
        try syncRead { db in
            try Row.fetchAll(db, sql: """
                SELECT id, name, description, scheduleLabel, isActive, notes, sortIndex
                FROM coachingStack ORDER BY sortIndex ASC, name ASC
                """).map {
                    CoachingStack(id: $0["id"], name: $0["name"], description: $0["description"],
                                  scheduleLabel: $0["scheduleLabel"],
                                  isActive: ($0["isActive"] as Int) != 0,
                                  notes: $0["notes"], sortIndex: $0["sortIndex"])
                }
        }
    }

    public func coachingStackItems(stackId: String) async throws -> [CoachingStackItem] {
        try syncRead { db in
            try Row.fetchAll(db, sql: """
                SELECT stackId, canonicalQuestion, dose, unit, sortIndex
                FROM coachingStackItem WHERE stackId = ?
                ORDER BY sortIndex ASC, canonicalQuestion ASC
                """, arguments: [stackId]).map {
                    CoachingStackItem(stackId: $0["stackId"], canonicalQuestion: $0["canonicalQuestion"],
                                      dose: $0["dose"], unit: $0["unit"], sortIndex: $0["sortIndex"])
                }
        }
    }

    public func updateCoachingStack(id: String, isActive: Bool, notes: String?) async throws {
        try syncWrite { db in
            try db.execute(sql: "UPDATE coachingStack SET isActive = ?, notes = ? WHERE id = ?",
                           arguments: [isActive ? 1 : 0, notes, id])
        }
    }

    @discardableResult
    public func logCoachingStackUse(stackId: String, day: String, notes: String?,
                                    skipped: Bool, id: String = UUID().uuidString,
                                    loggedAt: Int = Int(Date().timeIntervalSince1970)) async throws -> CoachingStackUse {
        let use = CoachingStackUse(id: id, stackId: stackId, day: day, loggedAt: loggedAt,
                                   notes: notes, skipped: skipped)
        try syncWrite { db in
            try db.execute(sql: """
                INSERT INTO coachingStackUse (id, stackId, day, loggedAt, notes, skipped)
                VALUES (?, ?, ?, ?, ?, ?)
                """, arguments: [use.id, use.stackId, use.day, use.loggedAt, use.notes,
                                 use.skipped ? 1 : 0])
        }
        return use
    }

    public func coachingStackUses(stackId: String) async throws -> [CoachingStackUse] {
        try syncRead { db in
            try Row.fetchAll(db, sql: """
                SELECT id, stackId, day, loggedAt, notes, skipped
                FROM coachingStackUse WHERE stackId = ? ORDER BY loggedAt DESC
                """, arguments: [stackId]).map {
                    CoachingStackUse(id: $0["id"], stackId: $0["stackId"], day: $0["day"],
                                     loggedAt: $0["loggedAt"], notes: $0["notes"],
                                     skipped: ($0["skipped"] as Int) != 0)
                }
        }
    }
}
