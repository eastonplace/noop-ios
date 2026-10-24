import XCTest
import UIKit

/// A tab return must paint the retained Trends chart without a scroll gesture.
@MainActor
final class TrendsReturnUITests: XCTestCase {
    func testScrolledTabReturnsKeepWeeklyReadoutWithoutScrolling() throws {
        #if !targetEnvironment(simulator)
        throw XCTSkip("The isolated Trends demo runs only on Simulator")
        #else
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = [
            "--noop-coach-shell-qa", "--demo-seed", "--noop-lift-demo", "fresh",
            "--demo-tab", "trends", "-AppleLanguages", "(en)", "-AppleLocale", "en_US",
            "-AppleInterfaceStyle", "Dark",
        ]
        app.launch()
        defer { app.terminate() }
        waitFor("completed demo seed") { app.buttons["app.battery"].label == "Strap battery 68 percent" }
        let previousWeek = app.buttons["Previous week"]
        for _ in 0..<12 {
            let viewport = contentViewport(app)
            if previousWeek.exists, viewport.contains(previousWeek.frame) { break }
            let down = previousWeek.exists && previousWeek.frame.maxY < viewport.minY
            let origin = app.coordinate(withNormalizedOffset: CGVector(dx: 0.02, dy: down ? 0.4 : 0.75))
            origin.press(forDuration: 0.05, thenDragTo: app.coordinate(
                withNormalizedOffset: CGVector(dx: 0.02, dy: down ? 0.75 : 0.4)))
        }
        XCTAssertTrue(previousWeek.exists && contentViewport(app).contains(previousWeek.frame),
            "Reach the real weekly readout below the header and above the tab bar")
        let firstFrame = previousWeek.frame
        capture(app, "trends-weekly-before-return")
        for visit in 1...4 {
            app.buttons["app.tab.0"].tap()
            waitFor("departed Trends") { !app.buttons["app.deviceStatus"].label.contains("Trends") }
            app.buttons["app.tab.1"].tap()
            waitFor("returned Trends") { app.buttons["app.deviceStatus"].label.contains("Trends") }
            capture(app, "trends-weekly-return-\(visit)-no-scroll")
            XCTAssertTrue(previousWeek.exists && contentViewport(app).contains(previousWeek.frame),
                "A return must paint the retained weekly readout without scrolling")
            XCTAssertEqual(previousWeek.frame.minY, firstFrame.minY, accuracy: 3,
                "Revalidating an unchanged range must keep its scroll position")
        }
        #endif
    }

    private func contentViewport(_ app: XCUIApplication) -> CGRect {
        let header = max(app.buttons["app.deviceStatus"].frame.maxY, app.buttons["app.battery"].frame.maxY)
        let tabTop = app.buttons["app.tab.1"].frame.minY
        return CGRect(x: app.frame.minX, y: header + 12, width: app.frame.width,
            height: max(0, tabTop - header - 24))
    }

    func testRepeatedTabReturnsPaintChartWithoutScrolling() throws {
        #if !targetEnvironment(simulator)
        throw XCTSkip("The isolated Trends demo runs only on Simulator")
        #else
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = [
            "--noop-coach-shell-qa", "--demo-seed", "--noop-lift-demo", "fresh",
            "--demo-tab", "today", "-AppleLanguages", "(en)", "-AppleLocale", "en_US",
            "-AppleInterfaceStyle", "Dark",
        ]
        app.launch()
        defer { app.terminate() }
        waitFor("completed demo seed") { app.buttons["app.battery"].label == "Strap battery 68 percent" }
        app.buttons["app.tab.1"].tap()
        let chart = app.descendants(matching: .any).matching(
            NSPredicate(format: "label BEGINSWITH %@", "Recovery trend, latest ")
        ).firstMatch
        waitFor("first Trends chart") { chart.exists && chart.frame.height > 100 }
        let firstInk = try chartInk(app.screenshot(), frame: chart.frame)
        XCTAssertGreaterThan(firstInk, 100, "The initial chart must contain a visible colored data line")
        capture(app, "trends-first-visit")

        for (visit, otherTab) in ["0", "2", "4", "0", "2", "4", "0", "2"].enumerated() {
            app.buttons["app.tab.\(otherTab)"].tap()
            waitFor("departed Trends") { !app.buttons["app.deviceStatus"].label.contains("Trends") }
            app.buttons["app.tab.1"].tap()
            waitFor("returned Trends chart") {
                app.buttons["app.deviceStatus"].label.contains("Trends") && chart.exists && chart.frame.height > 100
            }
            let ink = try chartInk(app.screenshot(), frame: chart.frame)
            capture(app, "trends-return-\(visit + 1)-no-scroll")
            XCTAssertGreaterThanOrEqual(ink, Int(Double(firstInk) * 0.8),
                "Return \(visit + 1) must paint the data line before any scrolling")
            XCTAssertFalse(app.staticTexts["Preparing trends…"].exists)
        }
        #endif
    }

    /// Count saturated pixels in the real plot, independent of its accessibility tree.
    /// A hidden reveal can leave all chart labels accessible while its line has zero ink.
    private func chartInk(_ screenshot: XCUIScreenshot, frame: CGRect) throws -> Int {
        let image = screenshot.image
        let source = try XCTUnwrap(image.cgImage)
        let width = source.width
        let height = source.height
        var pixels = [UInt8](repeating: 0, count: width * height * 4)
        let colorSpace = CGColorSpace(name: CGColorSpace.sRGB)!
        let context = try XCTUnwrap(CGContext(data: &pixels, width: width, height: height,
            bitsPerComponent: 8, bytesPerRow: width * 4, space: colorSpace,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.draw(source, in: CGRect(x: 0, y: 0, width: width, height: height))
        let scale = CGFloat(width) / image.size.width
        let bounds = frame.applying(CGAffineTransform(scaleX: scale, y: scale))
            .intersection(CGRect(x: 0, y: 0, width: width, height: height)).integral
        XCTAssertFalse(bounds.isEmpty, "The chart must be in the visible viewport")
        var count = 0
        for y in max(0, Int(bounds.minY))..<min(height, Int(bounds.maxY)) {
            for x in max(0, Int(bounds.minX))..<min(width, Int(bounds.maxX)) {
                let offset = (y * width + x) * 4
                let channels = [pixels[offset], pixels[offset + 1], pixels[offset + 2]]
                if let high = channels.max(), let low = channels.min(), high > 90, high - low > 35 {
                    count += 1
                }
            }
        }
        return count
    }

    private func waitFor(_ description: String, condition: @escaping () -> Bool) {
        let expectation = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in condition() }, object: nil)
        XCTAssertEqual(XCTWaiter.wait(for: [expectation], timeout: 60), .completed, description)
    }

    private func capture(_ app: XCUIApplication, _ name: String) {
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}
