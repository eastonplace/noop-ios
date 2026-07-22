import Foundation
import StrandAnalytics

extension LiveState {
    public var batteryEstimate: BatteryEstimator.Estimate? {
        BatteryEstimator.estimate(samples: batterySamples, ratedHours: batteryRatedHours)
    }

    public var batteryEstimateTraceLines: [String] {
        BatteryEstimator.estimateTrace(samples: batterySamples, ratedHours: batteryRatedHours).trace
    }

    public func emitBatteryTrace() {
        guard TestCentre.active(.battery) else { return }
        for line in batteryEstimateTraceLines { append(log: line, domain: .battery) }
    }

    public func batteryReadout(_ id: String) -> String {
        guard let estimate = batteryEstimate else { return "--" }
        switch id {
        case "currentSoc": return "\(Int(estimate.currentSoc.rounded()))%"
        case "estimateDaysLeft": return BatteryEstimator.label(hours: estimate.remainingHours)
        case "slopeSource": return estimate.source.rawValue
        default: return "--"
        }
    }

    public func setBattery(_ pct: Double) {
        batteryPct = pct
        bankBatterySample(pct)
        onBatteryUpdate?(pct)
    }

    func bankBatterySample(_ pct: Double, now: Int = Int(Date().timeIntervalSince1970)) {
        if let last = batterySamples.last, last.soc == pct, now - last.ts < 600 { return }
        batterySamples.append((ts: now, soc: pct))
        if batterySamples.count > Self.maxBatterySamples {
            batterySamples.removeFirst(batterySamples.count - Self.maxBatterySamples)
        }
        if TestCentre.active(.battery) {
            append(log: "bank soc=\(String(format: "%.1f", pct)) t=\(now)s", domain: .battery)
            emitBatteryTrace()
        }
    }

    public func seedBatterySamples(_ seed: [(ts: Int, soc: Double)]) {
        guard !seed.isEmpty else { return }
        let existing = Set(batterySamples.map { $0.ts })
        let fresh = seed.filter { !existing.contains($0.ts) }
        guard !fresh.isEmpty else { return }
        batterySamples.append(contentsOf: fresh)
        batterySamples.sort { $0.ts < $1.ts }
        if batterySamples.count > Self.maxBatterySamples {
            batterySamples.removeFirst(batterySamples.count - Self.maxBatterySamples)
        }
    }

    public func clearBatterySamples() {
        batterySamples.removeAll(keepingCapacity: true)
    }
}
