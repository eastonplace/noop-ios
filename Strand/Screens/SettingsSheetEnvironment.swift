import SwiftUI

extension View {
    /// Prepares the environment for Settings shown in a sheet's own `NavigationStack`.
    ///
    /// The Settings tab keeps the native navigation bar and puts `.settingsDetail` on its stack, so every page it
    /// pushes uses the native grouped-list look. A sheet inherits its presenter's environment instead (a pushed
    /// screen's drill-in role, a tab root's pinned app chrome), so Settings opened in a sheet has to say the same
    /// thing itself, on the stack, or its pages fall back to the dashboard scaffold.
    func settingsSheetScreenScaffoldEnvironment() -> some View {
        environment(\.screenScaffoldNavigationRole, .root)
            .environment(\.screenScaffoldPresentation, .settingsDetail)
            .environment(\.appHeaderChromeVisibility, .hidden)
            .environment(\.screenScaffoldCloseAction, nil)
    }
}
