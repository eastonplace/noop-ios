import Foundation
import WhoopProtocol

extension LiveState {
    public func recordSleepLiveHr(ts: Int, bpm: Int) {
        recentHrSamples.append(HRSample(ts: ts, bpm: bpm))
        if recentHrSamples.count > Self.maxSleepReadoutSamples {
            recentHrSamples.removeFirst(recentHrSamples.count - Self.maxSleepReadoutSamples)
        }
    }

    public func recordSleepLiveGravity(_ samples: [GravitySample]) {
        guard !samples.isEmpty else { return }
        recentGravitySamples.append(contentsOf: samples)
        if recentGravitySamples.count > Self.maxSleepReadoutSamples {
            recentGravitySamples.removeFirst(recentGravitySamples.count - Self.maxSleepReadoutSamples)
        }
    }

    public func setStrapRange(newestUnix: Int, oldestUnix: Int?) {
        let firmware = strapRange?.firmwareLayout
        let oldest = oldestUnix ?? strapRange?.oldestUnix
        strapRange = StrapRange(newestUnix: newestUnix, oldestUnix: oldest, firmwareLayout: firmware)
        UserDefaults.standard.set(newestUnix, forKey: "strap.newestRecordTs")
    }

    public func setStrapFirmwareLayout(_ version: Int) {
        if let range = strapRange {
            strapRange = StrapRange(
                newestUnix: range.newestUnix,
                oldestUnix: range.oldestUnix,
                firmwareLayout: version
            )
        } else {
            strapRange = StrapRange(newestUnix: 0, oldestUnix: nil, firmwareLayout: version)
        }
    }

    public func clearStrapRange() { strapRange = nil }

    public func noteFrameRouted(now: Int = Int(Date().timeIntervalSince1970)) {
        lastFrameAtUnix = now
    }

    public func clearSensorMetrics() {
        sensorSpeedKmh = nil
        sensorCadence = nil
        sensorPowerWatts = nil
    }

    public var hasSensorMetrics: Bool {
        sensorSpeedKmh != nil || sensorCadence != nil || sensorPowerWatts != nil
    }

    nonisolated static func formatSpeedKmh(_ kmh: Double?) -> String? {
        guard let kmh, kmh.isFinite, kmh >= 0 else { return nil }
        return String(format: "%.1f", kmh)
    }

    nonisolated static func formatCadence(_ perMin: Double?) -> String? {
        guard let perMin, perMin.isFinite, perMin >= 0 else { return nil }
        return String(Int(perMin.rounded()))
    }

    nonisolated static func formatPowerWatts(_ watts: Int?) -> String? {
        guard let watts, watts >= 0 else { return nil }
        return String(watts)
    }

    public func setRRIntervals(_ intervals: [Int], recentLimit: Int = 60) {
        rr = intervals
        let valid = intervals.filter { $0 > 0 }
        guard !valid.isEmpty else { return }
        rrRecent.append(contentsOf: valid)
        if rrRecent.count > recentLimit {
            rrRecent.removeFirst(rrRecent.count - recentLimit)
        }
    }

    public func clearBiometrics() {
        heartRate = nil
        streamingLiveHR = false
        standardHRMode = nil
        rr.removeAll(keepingCapacity: true)
        rrRecent.removeAll(keepingCapacity: true)
        clearBatterySamples()
        recentHrSamples.removeAll(keepingCapacity: true)
        recentGravitySamples.removeAll(keepingCapacity: true)
        clearStrapRange()
        lastFrameAtUnix = nil
        Task { await flushLogPersistence() }
    }
}
