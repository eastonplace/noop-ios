import Foundation

public enum ActiveSinkEpochRecovery {
    public static func nextEpoch(
        defaults: UserDefaults,
        activeKey: String = ActiveVerifiedSinkEpochStore.activeKey,
        widgetGenerationKey: String = ActiveVerifiedSinkEpochStore.widgetGenerationKey,
        liveActivityGenerationKey: String = ActiveVerifiedSinkEpochStore.liveActivityGenerationKey,
        overlayKey: String = ActiveVerifiedSinkEpochStore.widgetLiveOverlayKey
    ) -> UInt64? {
        let decoder = JSONDecoder()
        var epochs: [UInt64] = []

        if let data = defaults.data(forKey: activeKey),
           let active = try? decoder.decode(ActiveVerifiedSinkEpochRecord.self, from: data) {
            epochs.append(active.epoch)
        }
        for key in [widgetGenerationKey, liveActivityGenerationKey] {
            if let data = defaults.data(forKey: key),
               let record = try? decoder.decode(VerifiedSinkGenerationRecord.self, from: data) {
                epochs.append(record.epoch)
            }
        }
        if let data = defaults.data(forKey: overlayKey),
           let overlay = try? decoder.decode(WidgetLiveOverlay.self, from: data) {
            epochs.append(overlay.epoch)
        }

        let maximum = epochs.max() ?? 0
        let (next, overflow) = maximum.addingReportingOverflow(1)
        return overflow ? nil : max(1, next)
    }

    /// Replacement for beginTransition. A missing/corrupt active record does not
    /// reset ordering below surviving Widget/Live records.
    public static func beginTransitionRecovering(
        defaults: UserDefaults
    ) -> UInt64? {
        guard let epoch = nextEpoch(defaults: defaults) else { return nil }
        let record = ActiveVerifiedSinkEpochRecord(epoch: epoch, contextId: nil)
        guard writeAndReadBack(record, defaults: defaults) else { return nil }
        defaults.removeObject(forKey: ActiveVerifiedSinkEpochStore.widgetLiveOverlayKey)
        return epoch
    }

    /// Destructive/no-active boundary. Ordinary A→B selection may keep the old
    /// core until the replacement is committed; privacy delete and final archive
    /// must not.
    public static func clearVerifiedWidgetState(defaults: UserDefaults) {
        VerifiedWidgetEnvelopeStore.clear(defaults: defaults)
        defaults.removeObject(forKey: WidgetSnapshot.storageKey)
        defaults.removeObject(forKey: ActiveVerifiedSinkEpochStore.widgetLiveOverlayKey)
        defaults.removeObject(forKey: ActiveVerifiedSinkEpochStore.widgetGenerationKey)
    }

    public static func clearLiveActivityGeneration(defaults: UserDefaults) {
        defaults.removeObject(forKey: ActiveVerifiedSinkEpochStore.liveActivityGenerationKey)
    }

    private static func writeAndReadBack(
        _ record: ActiveVerifiedSinkEpochRecord,
        defaults: UserDefaults
    ) -> Bool {
        guard let data = try? JSONEncoder().encode(record) else { return false }
        defaults.set(data, forKey: ActiveVerifiedSinkEpochStore.activeKey)
        guard let stored = defaults.data(forKey: ActiveVerifiedSinkEpochStore.activeKey),
              let decoded = try? JSONDecoder().decode(
                ActiveVerifiedSinkEpochRecord.self,
                from: stored
              ) else { return false }
        return decoded == record
    }
}

/*
Source-transition integration:

- Replace `ActiveVerifiedSinkEpochStore.beginTransition` with
  `ActiveSinkEpochRecovery.beginTransitionRecovering`.
- For archive-final-source/privacy-delete:
    1. close epoch;
    2. call clearVerifiedWidgetState;
    3. enqueue and await an ActivityKit end barrier;
    4. reload WidgetCenter timelines.
- Add a regression where activeKey is removed while generation records are at
  epoch 41; the next transition must use 42.
*/
