import CoreGraphics
#if canImport(UIKit)
import UIKit
#endif

/// The strip along the leading screen edge where a drag is the swipe back, not a chart's pan. The system's edge
/// recogniser begins only in this strip, so a chart that stands aside for a touch that started here never competes
/// with it, and everywhere else the chart keeps its drag.
enum LeadingEdgeStrip {
    /// A thumb's width: the system recogniser's own edge region is about 20pt.
    static let width: CGFloat = 24

    /// The pure test: `x` in window coordinates, `width` the window's width.
    static func contains(x: CGFloat, in width: CGFloat, leftToRight: Bool) -> Bool {
        leftToRight ? x < Self.width : x > width - Self.width
    }
}

#if canImport(UIKit)
extension LeadingEdgeStrip {
    /// Whether `recognizer`'s touch began inside the strip. A recogniser outside a window has no edge.
    @MainActor
    static func contains(startOf recognizer: UIPanGestureRecognizer) -> Bool {
        guard let view = recognizer.view, let window = view.window else { return false }
        let moved = recognizer.translation(in: view)
        let startX = recognizer.location(in: window).x - moved.x
        return contains(x: startX, in: window.bounds.width,
                        leftToRight: UIView.userInterfaceLayoutDirection(for: view.semanticContentAttribute) == .leftToRight)
    }
}
#endif
