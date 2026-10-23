import Foundation
import NoopPhase34Core

/// A separate App Group blob keeps prose out of the live metric lane. The active sink token rejects
/// old-source data even if the app exits during a source transition before it can clear this key.
public enum CoachBriefWidgetStore {
    public static let storageKey = "noop.widget.coach-brief.v1"
    public static let generationKey = "noop.widget.coach-brief-generation.v1"

    public static func load(defaults: UserDefaults, now: Date = Date(),
                            calendar: Calendar = .current) -> CoachBriefWidgetPayload? {
        guard let active = ActiveVerifiedSinkEpochStore.activeToken(defaults: defaults),
              let data = defaults.data(forKey: storageKey), data.count <= 8_192,
              let brief = try? JSONDecoder().decode(CoachBriefWidgetPayload.self, from: data),
              brief.isDisplayable(epoch: active.epoch, contextID: active.contextId,
                                  logicalDay: WidgetLogicalDay.key(of: now, calendar: calendar), now: now)
        else { return nil }
        return brief
    }

    @discardableResult
    public static func save(_ brief: CoachBriefWidgetPayload, defaults: UserDefaults) -> Bool {
        guard let data = try? JSONEncoder().encode(brief), data.count <= 8_192 else { return false }
        let result = ActiveVerifiedSinkEpochStore.commitIfCurrent(
            token: .init(epoch: brief.epoch, contextId: brief.contextID), generation: brief.generation,
            defaults: defaults, generationKey: generationKey) { defaults in
                defaults.set(data, forKey: storageKey)
                return defaults.data(forKey: storageKey) == data
            }
        return result == .published || result == .alreadyCurrent
    }

    @discardableResult
    public static func clear(defaults: UserDefaults) -> Bool {
        let hadBrief = defaults.object(forKey: storageKey) != nil
        defaults.removeObject(forKey: storageKey)
        defaults.removeObject(forKey: generationKey)
        return hadBrief
    }
}
