#if canImport(UIKit)
import SwiftUI
import UIKit
import XCTest
@testable import StrandDesign

/// `HoldToConfirmButton` was generalised (styles, a hint, a VoiceOver action). At every non-accessibility text size the
/// default style must still draw exactly what the destructive gates always drew. The old drawing is kept here, verbatim,
/// and both are rendered and compared pixel for pixel.
@MainActor
final class HoldToConfirmLegacyLookTests: XCTestCase {
    /// The button as it was before the change, at rest.
    private struct LegacyHoldToConfirm: View {
        let title: String
        var body: some View {
            GeometryReader { proxy in
                ZStack(alignment: .leading) {
                    RoundedRectangle(cornerRadius: 13, style: .continuous)
                        .fill(StrandPalette.metricRose.opacity(0.12))
                    RoundedRectangle(cornerRadius: 13, style: .continuous)
                        .fill(StrandPalette.metricRose.opacity(0.82))
                        .frame(width: proxy.size.width * 0)
                    HStack(spacing: 7) {
                        Image(systemName: "trash")
                            .font(.system(size: 12, weight: .bold))
                        Text(title)
                            .font(StrandFont.caption.weight(.semibold))
                    }
                    .foregroundStyle(StrandPalette.metricRose)
                    .frame(maxWidth: .infinity)
                }
            }
            .frame(height: 44)
            .clipShape(RoundedRectangle(cornerRadius: 13, style: .continuous))
        }
    }

    private func pixels<V: View>(_ view: V, size: DynamicTypeSize, scheme: ColorScheme) -> (width: Int, height: Int, data: [UInt8])? {
        let framed = view
            .frame(width: 320)
            .padding(10)
            .background(Color.black)
            .environment(\.dynamicTypeSize, size)
            .environment(\.colorScheme, scheme)
        let renderer = ImageRenderer(content: framed)
        renderer.scale = 2
        guard let cg = renderer.cgImage else { return nil }
        let width = cg.width, height = cg.height
        var data = [UInt8](repeating: 0, count: width * height * 4)
        guard let context = CGContext(
            data: &data, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        context.draw(cg, in: CGRect(x: 0, y: 0, width: width, height: height))
        return (width, height, data)
    }

    func testTheDefaultStyleDrawsWhatTheDestructiveGatesAlwaysDrew() throws {
        let sizes: [DynamicTypeSize] = [.xSmall, .small, .medium, .large, .xLarge, .xxLarge, .xxxLarge]
        for scheme in [ColorScheme.light, .dark] {
            for size in sizes {
                for title in ["Remove", "Remove this device"] {
                    let legacy = try XCTUnwrap(pixels(LegacyHoldToConfirm(title: title), size: size, scheme: scheme))
                    let current = try XCTUnwrap(pixels(HoldToConfirmButton(title: title, action: {}), size: size, scheme: scheme))
                    XCTAssertEqual(legacy.width, current.width, "\(title) \(size) \(scheme)")
                    XCTAssertEqual(legacy.height, current.height, "\(title) \(size) \(scheme)")
                    XCTAssertTrue(legacy.data == current.data, "\(title) at \(size) in \(scheme) draws differently from before")
                }
            }
        }
    }

    func testTheBigEndStyleIsTallerThanTheBarAndGrowsWithItsLabelAtAccessibilitySizes() throws {
        let bar = try XCTUnwrap(pixels(HoldToConfirmButton(title: "Hold to end", style: .glanceEnd, action: {}),
                                       size: .large, scheme: .dark))
        let small = try XCTUnwrap(pixels(HoldToConfirmButton(title: "Hold to end", action: {}), size: .large, scheme: .dark))
        XCTAssertGreaterThan(bar.height, small.height)
        XCTAssertGreaterThanOrEqual(CGFloat(bar.height) / 2, GlanceActionButtonStyle.minimumHeight)

        let long = "Zum Beenden gedrückt halten, bitte nicht loslassen"
        let ax = try XCTUnwrap(pixels(HoldToConfirmButton(title: long, style: .glanceEnd, action: {}),
                                      size: .accessibility5, scheme: .dark))
        XCTAssertGreaterThan(ax.height, bar.height, "the label wraps and the button grows rather than clipping it")
    }
}
#endif
