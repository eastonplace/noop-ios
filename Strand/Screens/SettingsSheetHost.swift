import SwiftUI
import StrandDesign

#if os(iOS)
/// Settings as a sheet over whatever the person was looking at. The shell (`RootTabView`) presents it when the top bar's
/// profile button, or any other caller, asks `NavRouter.openSettings`.
///
/// The host owns the navigation stack, so a deep link is just a route pushed onto `path` as the sheet appears and the
/// pages Settings pushes sit above the root in one stack. Swiping the sheet down dismisses it from anywhere in that stack.
///
/// Pages that serve both Settings and the rest of the app read `.settingsDetail` from the stack itself (not from the
/// root view) and draw their native list instead of the scaffold: SwiftUI hosts a pushed page, and every page that page
/// pushes, outside the view that created the link, so the stack is the one place the value reaches all of them.
struct SettingsSheetHost: View {
    let request: SettingsSheetRequest
    let onClose: () -> Void
    @State private var path: [SettingsRouteID]

    init(request: SettingsSheetRequest, onClose: @escaping () -> Void) {
        self.request = request
        self.onClose = onClose
        _path = State(initialValue: Self.initialPath(for: request))
    }

    /// The pages already pushed when the sheet appears: none for the root, the one page for a deep link.
    static func initialPath(for request: SettingsSheetRequest) -> [SettingsRouteID] {
        request.route.map { [$0] } ?? []
    }

    var body: some View {
        NavigationStack(path: $path) {
            SettingsView()
                .background(Color(.systemGroupedBackground).ignoresSafeArea())
                .toolbar {
                    if #available(iOS 26, *) {
                        ToolbarItem(placement: .topBarTrailing) {
                            doneButton
                        }
                        .sharedBackgroundVisibility(.hidden)
                    } else {
                        ToolbarItem(placement: .topBarTrailing) {
                            doneButton
                        }
                    }
                }
        }
        .environment(\.screenScaffoldPresentation, .settingsDetail)
        .environment(\.appHeaderChromeVisibility, .hidden)
        .environment(\.screenScaffoldCloseAction, nil)
    }

    private var doneButton: some View {
        Button(action: onClose) {
            Text("Done")
                .foregroundStyle(.white)
                .frame(minWidth: 44, minHeight: 44)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("settings.done")
    }
}
#endif
