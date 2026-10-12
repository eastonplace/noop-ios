#if os(iOS)
import UIKit

/// Whether anything is presented over the app's root view controller right now: a sheet, a cover, an alert or a menu from
/// any screen below it. SwiftUI will not present a second modal from the root while a descendant already presents one (it
/// logs and drops the request), so a shell that must put a full-screen cover on screen asks this first and collapses
/// whatever is up (`ShellModalCollapse`). Also read by the QA harness to know a route's sheet was not dropped.
@MainActor
enum ModalPresentationProbe {
    private static var rootViewControllers: [UIViewController] {
        UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .flatMap(\.windows)
            .compactMap(\.rootViewController)
    }

    static var isAnyModalPresented: Bool {
        rootViewControllers.contains { $0.presentedViewController != nil }
    }

    /// Last resort: closes every presented controller without animation, for a presenter that did not let go on its own.
    static func dismissAll() {
        for root in rootViewControllers where root.presentedViewController != nil {
            root.dismiss(animated: false)
        }
    }
}
#endif
