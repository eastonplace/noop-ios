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

    /// The red of the label and the stop glyph, found in a rendered button: the leftmost and rightmost columns that hold any.
    private func inkBounds(_ view: some View, width: CGFloat, size: DynamicTypeSize) throws -> (left: CGFloat, right: CGFloat, frameWidth: CGFloat) {
        let framed = view
            .frame(width: width)
            .padding(10)
            .background(Color.black)
            .environment(\.dynamicTypeSize, size)
            .environment(\.colorScheme, .dark)
        let renderer = ImageRenderer(content: framed)
        renderer.scale = 2
        let cg = try XCTUnwrap(renderer.cgImage)
        let w = cg.width, h = cg.height
        var data = [UInt8](repeating: 0, count: w * h * 4)
        let context = try XCTUnwrap(CGContext(
            data: &data, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.draw(cg, in: CGRect(x: 0, y: 0, width: w, height: h))
        var left = w, right = -1
        for y in 0..<h {
            for x in 0..<w {
                let i = (y * w + x) * 4
                // The live red at full strength: the background fill is the same red at 12 percent, far darker.
                if data[i] > 170, data[i + 1] < 90, data[i + 2] < 90 { left = min(left, x); right = max(right, x) }
            }
        }
        return (CGFloat(left) / 2 - 10, CGFloat(right + 1) / 2 - 10, width)
    }

    /// German, Italian and Russian at the width of one of two side-by-side buttons, and German at AX5 stacked: the label
    /// (and the stop glyph) stay clear of the capsule's curved ends.
    func testTheBigEndLabelKeepsAnInsetFromTheCapsuleEnds() throws {
        let cases: [(String, CGFloat, DynamicTypeSize)] = [
            ("Zum Beenden halten", 165, .large),
            ("Tieni premuto per terminare", 165, .large),
            ("Удерживайте, чтобы завершить", 165, .large),
            ("Zum Beenden halten", 343, .accessibility5),
        ]
        for (title, width, size) in cases {
            let bounds = try inkBounds(HoldToConfirmButton(title: title, style: .glanceEnd, action: {}), width: width, size: size)
            XCTAssertGreaterThanOrEqual(bounds.left, NoopMetrics.space5 - 1, "\(title) at \(size): the glyph starts at the curve")
            XCTAssertLessThanOrEqual(bounds.right, width - NoopMetrics.space5 + 1, "\(title) at \(size): the label runs into the curve")
        }
    }

    func testTheBigEndStyleIsTallerThanTheBarAndNeverShrinksAtAccessibilitySizes() throws {
        let bar = try XCTUnwrap(pixels(HoldToConfirmButton(title: "Hold to end", style: .glanceEnd, action: {}),
                                       size: .large, scheme: .dark))
        let small = try XCTUnwrap(pixels(HoldToConfirmButton(title: "Hold to end", action: {}), size: .large, scheme: .dark))
        XCTAssertGreaterThan(bar.height, small.height)
        XCTAssertGreaterThanOrEqual(CGFloat(bar.height) / 2, GlanceActionButtonStyle.minimumHeight)

        let long = "Zum Beenden gedrückt halten, bitte nicht loslassen"
        let ax = try XCTUnwrap(pixels(HoldToConfirmButton(title: long, style: .glanceEnd, action: {}),
                                      size: .accessibility5, scheme: .dark))
        // At accessibility sizes the label wraps to two lines and then scales, so a long translation fits inside the button
        // instead of being cut off with an ellipsis; the button never gets shorter than the style's height.
        XCTAssertGreaterThanOrEqual(ax.height, bar.height, "the label wraps and scales; the button keeps its height")
    }
}
#endif
