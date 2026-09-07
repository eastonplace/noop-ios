import SwiftUI

/// A continuous position within the same five 50...100 percent max-HR bands used by workout analytics.
public struct NOOPHeartRateZoneRail: View {
    public let bpm: Int?
    public let maxHR: Double
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    public init(bpm: Int?, maxHR: Double) {
        self.bpm = bpm
        self.maxHR = maxHR
    }

    private var fraction: Double? {
        guard let bpm, bpm > 0, maxHR.isFinite, maxHR > 0 else { return nil }
        return min(1, max(0, (Double(bpm) / maxHR - 0.5) / 0.5))
    }
    private var zone: Int? {
        guard let bpm, fraction != nil else { return nil }
        if Double(bpm) < maxHR * 0.5 { return 0 }
        return min(5, Int(((Double(bpm) / maxHR - 0.5) * 10 + 0.0000001).rounded(.down)) + 1)
    }
    private var status: String {
        guard let zone else { return "Waiting for heart rate" }
        return zone == 0 ? "Below Zone 1" : "Zone \(zone)"
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                HStack(spacing: 8) {
                    Text(status).font(.caption.weight(.semibold))
                    if let zone, zone > 0 {
                        let lower = Int(ceil(maxHR * (0.4 + Double(zone) * 0.1)))
                        let upper = Int(ceil(maxHR * (0.5 + Double(zone) * 0.1))) - 1
                        Text(zone == 5 ? "\(lower)+" : "\(lower)–\(upper)")
                            .font(.caption2.monospacedDigit()).foregroundStyle(.secondary)
                    }
                }
                Spacer()
                if let bpm { Text("\(bpm) bpm").font(.caption.monospacedDigit()) }
            }
            GeometryReader { geometry in
                let gap: CGFloat = 4
                let width = max(0, (geometry.size.width - gap * 4) / 5)
                ZStack(alignment: .leading) {
                    HStack(spacing: gap) {
                        ForEach(1...5, id: \.self) { value in
                            Capsule().fill(StrandPalette.hrZoneColor(value).opacity(0.8))
                                .frame(width: width, height: 8)
                        }
                    }
                    if let fraction {
                        let scaled = fraction * 5
                        let index = min(4, Int(scaled))
                        let within = scaled - Double(index)
                        let position = CGFloat(index) * (width + gap) + CGFloat(within) * width
                        Circle().fill(.white)
                            .frame(width: 14, height: 14)
                            .overlay(Circle().strokeBorder(.black.opacity(0.4), lineWidth: 2))
                            .offset(x: min(max(0, position - 7), max(0, geometry.size.width - 14)))
                            .animation(reduceMotion ? nil : .linear(duration: 0.25), value: fraction)
                    }
                }
                .frame(height: 16)
            }
            .frame(height: 16)
            HStack {
                ForEach(1...5, id: \.self) { value in
                    Text("Z\(value)").font(.caption2.weight(zone == value ? .bold : .medium))
                        .foregroundStyle(zone == value ? StrandPalette.hrZoneColor(value) : .secondary)
                        .frame(maxWidth: .infinity)
                }
            }

        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Heart rate zones. \(status). \(bpm.map { "\($0) beats per minute" } ?? "No reading")")
    }
}
