#if os(iOS)
import Foundation
import WidgetKit

/// UIP-10 / CORE-07: the one place the publication lanes ask WidgetKit to reload. Each lane names only the
/// kinds its change can reach, and a verified commit WidgetKit was already asked to read isn't requested
/// again, so a busy day doesn't spend the background reload budget on identical timelines.
@MainActor
enum WidgetTimelineReloads {
    /// Seam for tests, which swap in a recorder.
    static var reload: ([String]) -> Void = { kinds in
        for kind in kinds { WidgetCenter.shared.reloadTimelines(ofKind: kind) }
    }

    /// The last verified generation this process asked WidgetKit to read.
    private static var lastRequestedCommit: WidgetEnrichmentKey?

    /// Core and enrichment commits change the verified core or its enrichment, which every kind renders,
    /// stress included. `.alreadyCurrent` asks again only for a generation this process hasn't requested
    /// yet: after a relaunch WidgetKit can still hold an older timeline for a snapshot that is current.
    static func afterVerifiedCommit(_ result: VerifiedProjectionGenerationWriteResult, key: WidgetEnrichmentKey) {
        switch result {
        case .published:
            break
        case .alreadyCurrent:
            guard lastRequestedCommit != key else { return }
        case .superseded, .failed:
            return
        }
        lastRequestedCommit = key
        reload(WidgetKinds.all)
    }

    /// The live lane writes heart rate, battery, connection and the workout sparkline, which only
    /// `NOOPWidget` shows. The Strain circle reloads only when the Strain it shows moved.
    static func liveKinds(previous: WidgetSnapshot?, next: WidgetSnapshot) -> [String] {
        previous?.strain == next.strain
            ? [WidgetKinds.main]
            : [WidgetKinds.main, WidgetKinds.strainAccessory]
    }

    static func afterLivePublish(previous: WidgetSnapshot?, next: WidgetSnapshot) {
        reload(liveKinds(previous: previous, next: next))
    }

    static func afterCoachBriefChange() { reload([WidgetKinds.coachBrief]) }

    #if DEBUG
    static func resetForTesting() { lastRequestedCommit = nil }
    #endif
}
#endif
