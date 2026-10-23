#if os(iOS)
import Foundation
import NoopPhase34Core

@MainActor
enum CoachBriefWidgetPublication {
    static func publish(kind: LocalCoachBriefKind, text: String, generatedAt: Date, repo: Repository) {
        let widgetKind: CoachBriefWidgetPayload.Kind
        switch kind {
        case .morning: widgetKind = .morning
        case .evening: widgetKind = .evening
        default: return
        }
        guard !repo.verifiedExternalSurfaceFenced,
              let defaults = UserDefaults(suiteName: WidgetSnapshot.suiteName),
              let envelope = VerifiedWidgetEnvelopeStore.rawActiveEnvelope(defaults: defaults),
              envelope.contextId == repo.currentVerifiedSinkContextIdForActivation,
              WidgetLogicalDay.isSameDay(envelope.snapshot.updated, generatedAt),
              let brief = CoachBriefWidgetPayload(
                epoch: envelope.epoch, contextID: envelope.contextId, generation: envelope.generation,
                logicalDay: WidgetLogicalDay.key(of: generatedAt), generatedAt: generatedAt,
                kind: widgetKind, text: text, recovery: envelope.snapshot.recovery,
                strain: envelope.snapshot.strain, sleepMinutes: envelope.snapshot.sleepMinutes)
        else { return }
        if CoachBriefWidgetStore.save(brief, defaults: defaults) { WidgetTimelineReloads.afterCoachBriefChange() }
    }

    static func clear() {
        guard let defaults = UserDefaults(suiteName: WidgetSnapshot.suiteName) else { return }
        if CoachBriefWidgetStore.clear(defaults: defaults) { WidgetTimelineReloads.afterCoachBriefChange() }
    }
}
#endif
