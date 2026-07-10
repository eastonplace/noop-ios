import SwiftUI
import StrandDesign

/// Flat Paper gauge for compact metric summaries. Values are normalized to 0...1.
struct PaperGauge: View {
    let value: Double?
    let tint: Color
    var animated: Bool = true

    private var fraction: Double { min(1, max(0, value ?? 0)) }

    var body: some View {
        ZStack {
            Circle()
                .stroke(tint.opacity(0.12), lineWidth: 5)
            Circle()
                .trim(from: 0, to: fraction)
                .stroke(tint, style: StrokeStyle(lineWidth: 5, lineCap: .round))
                .rotationEffect(.degrees(-90))
        }
        .aspectRatio(1, contentMode: .fit)
        .animation(animated ? .easeOut(duration: 0.45) : nil, value: fraction)
        .accessibilityHidden(true)
    }
}

/// Flat Paper progress rail. Values are normalized to 0...1.
struct PaperProgressBar: View {
    let frac: Double
    let tint: Color
    var height: CGFloat = 14
    var animated: Bool = true

    private var fraction: Double { min(1, max(0, frac)) }

    var body: some View {
        GeometryReader { proxy in
            ZStack(alignment: .leading) {
                Capsule().fill(StrandPalette.hairline.opacity(0.7))
                Capsule()
                    .fill(tint)
                    .frame(width: max(height, proxy.size.width * fraction))
            }
        }
        .frame(height: height)
        .animation(animated ? .easeOut(duration: 0.35) : nil, value: fraction)
        .accessibilityHidden(true)
    }
}

/// Crisp, single-stroke Paper sparkline for live samples.
struct PaperSparkline: View {
    let bpm: [Double]
    var tint: Color = Color(.sRGB, red: 1, green: 107 / 255, blue: 129 / 255, opacity: 1)
    var height: CGFloat = 96
    var animated: Bool = true

    var body: some View {
        Canvas { context, size in
            guard bpm.count > 1 else { return }
            let lower = bpm.min() ?? 0
            let upper = bpm.max() ?? lower
            let span = max(10, upper - lower)
            let pad: CGFloat = 8
            let width = max(1, size.width - pad * 2)
            let usableHeight = max(1, size.height - pad * 2)
            var path = Path()
            for index in bpm.indices {
                let x = pad + CGFloat(index) / CGFloat(bpm.count - 1) * width
                let y = size.height - pad - CGFloat((bpm[index] - lower) / span) * usableHeight
                if index == bpm.startIndex { path.move(to: CGPoint(x: x, y: y)) }
                else { path.addLine(to: CGPoint(x: x, y: y)) }
            }
            context.stroke(path, with: .color(tint), style: StrokeStyle(lineWidth: 2, lineCap: .round, lineJoin: .round))
        }
        .frame(height: height)
        .accessibilityHidden(true)
    }
}

struct PaperPressStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.985 : 1)
            .opacity(configuration.isPressed ? 0.9 : 1)
            .animation(.easeOut(duration: 0.14), value: configuration.isPressed)
    }
}

/// A number that animates to its value while retaining monospaced alignment.
struct CountUpNumber: View, Animatable {
    var value: Double
    var font: Font
    var animatableData: Double {
        get { value }
        set { value = newValue }
    }

    var body: some View {
        Text("\(Int(value.rounded()))")
            .font(font)
            .monospacedDigit()
    }
}
