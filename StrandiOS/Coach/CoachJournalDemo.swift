#if DEBUG && os(iOS)
import Foundation

/// `--demo-coach-journal` (simulator and Debug only): lets the Coach journal widget and association cards render on a
/// simulator that has no Apple Intelligence model. Pair it with `--demo-seed`, which lays down the journal answers.
///
/// It grants the personal-record consent those two surfaces read (in memory only; nothing is saved to Coach settings)
/// and stands a stand-in model in for the missing one. The stand-in only writes one fixed sentence; the journal read
/// before it, and so every card, is the real analysis over the seeded records. Compiled out of Release builds.
enum CoachJournalDemo {
    static var requested: Bool {
        #if targetEnvironment(simulator)
        CommandLine.arguments.contains("--demo-coach-journal")
        #else
        false
        #endif
    }
}

@MainActor
struct CoachJournalDemoModelDriver: LocalCoachModelDriver {
    var availability: LocalCoachAvailability { .available }
    var contextCapacity: Int? { 4_096 }

    func stream(_ request: LocalCoachRequest, tools: [LocalCoachToolDescriptor],
                read: @escaping LocalCoachRead, receive: @escaping LocalCoachReceive) async throws {
        receive("Demo reply, no model: these are the journal comparisons from your records. They show associations, not causes.")
    }
}
#endif
