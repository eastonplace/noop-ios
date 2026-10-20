import SwiftUI
import StrandDesign

enum ScreenScaffoldNavigationRole: Sendable {
    case root
    case detail
}

enum ScreenScaffoldPresentation: Sendable {
    case standard
    case settingsDetail
}

/// Boxes the sheet-dismiss closure so it can live in the environment (`@Entry` rejects bare closures).
struct ScreenScaffoldCloseAction {
    let perform: () -> Void
}

extension EnvironmentValues {
    @Entry var screenScaffoldNavigationRole: ScreenScaffoldNavigationRole = .root
    @Entry var screenScaffoldPresentation: ScreenScaffoldPresentation = .standard
    /// Dismisses the modal sheet whose root screen is the current scaffold. When set (by
    /// `sheetScreenScaffoldEnvironment(onClose:)`), the root scaffold's header shows one canonical close
    /// button in its trailing slot, so a sheet never needs a system navigation bar "Done".
    @Entry var screenScaffoldCloseAction: ScreenScaffoldCloseAction? = nil
}

/// Captures the process-wide `AppModel` as a plain reference for a heavy screen root.
///
/// `@EnvironmentObject` subscribes a view to every `AppModel` publication. Screens that only need the
/// model to issue commands must not own that subscription: live workout samples otherwise re-evaluate their
/// entire dashboard or history log. This zero-layout leaf owns the subscription and hands the stable object
/// identity to its parent once. The parent stores it in `@State` (which does not observe the object's
/// publications); narrow leaves remain responsible for observing live values they actually render.
struct AppModelReferenceCapture: View {
    @EnvironmentObject private var model: AppModel
    @Binding var reference: AppModel?

    var body: some View {
        Color.clear
            .frame(width: 0, height: 0)
            .accessibilityHidden(true)
            .onAppear { capture() }
    }

    private func capture() {
        guard reference !== model else { return }
        reference = model
    }
}

/// The LiveState twin of `AppModelReferenceCapture`. Heavy routes retain the stable object identity in
/// `@State`; only their purpose-built live leaves subscribe to streaming HR, R-R, log, and sync updates.
struct LiveStateReferenceCapture: View {
    @EnvironmentObject private var live: LiveState
    @Binding var reference: LiveState?

    var body: some View {
        Color.clear
            .frame(width: 0, height: 0)
            .accessibilityHidden(true)
            .onAppear { capture() }
    }

    private func capture() {
        guard reference !== live else { return }
        reference = live
    }
}

/// Keeps the one-time DeviceRegistry publication out of the Devices route. Device changes themselves are
/// observed by `DevicesContent` through the registry, not by the global AppModel broadcaster.
struct DeviceRegistryReferenceCapture: View {
    @EnvironmentObject private var model: AppModel
    @Binding var reference: DeviceRegistry?

    var body: some View {
        Color.clear
            .frame(width: 0, height: 0)
            .accessibilityHidden(true)
            .onAppear { reference = model.deviceRegistry }
            .onReceive(model.$deviceRegistry) { registry in
                guard reference !== registry else { return }
                reference = registry
            }
    }
}

/// Standard scrollable screen container: title + dark surface + content column.
struct ScreenScaffold<Content: View, Trailing: View>: View {
    /// Optional — when nil (and no subtitle) the header is omitted entirely, so a screen can supply its
    /// own custom header in `content` (iOS Today's compact top bar).
    let title: LocalizedStringKey?
    var subtitle: LocalizedStringKey? = nil
    /// Optional pull-to-refresh hook. When set, the scroll view becomes `.refreshable`
    /// (the standard iPhone gesture for a data dashboard). Defaults to nil so callers that
    /// don't opt in are unaffected — and on macOS `.refreshable` surfaces no affordance.
    var onRefresh: (() async -> Void)? = nil
    /// Lazily materialise the content column. When `true` the inner stack is a `LazyVStack`,
    /// so a screen whose content ends in a long `ForEach` only builds the cards on screen
    /// rather than all of them up-front — the fix for Intelligence "ALL" freezing on an
    /// 800+ day imported history (#345). Defaults to `false` so every existing caller keeps
    /// the eager `VStack` and its identical layout/scroll behaviour.
    var lazy: Bool = false
    /// Optional full-bleed view drawn behind the scroll content at the TOP of the screen (e.g. Today's
    /// day-cycle scene). Defaults to nil so other screens stay on the flat canvas; nil renders nothing.
    var topBackground: AnyView? = nil
    /// Some screens have an interactive inline date navigator immediately below their page title.
    /// Keep that date out of the expanded header, while still exposing it in the compact replacement.
    var showsSubtitleInExpandedHeader: Bool = true
    /// Optional inline back action for pushed/sheet screens. When present, the shared Paper header
    /// owns the chevron so navigation never consumes a separate row above the wordmark.
    var backAction: (() -> Void)? = nil
    /// Tertiary context shown at the trailing end of a pushed screen's compact title row (the date being viewed,
    /// say). Pushed screens drop `subtitle` from their header, so anything the subtitle said that matters belongs
    /// here or in the screen's content. Ignored everywhere else.
    var headerContext: String? = nil
    /// Opt-in compact title for modal utility roots. Other presentations keep their existing chrome.
    var usesCompactUtilityHeader: Bool = false
    /// Optional element pinned to the header's trailing edge (e.g. the strap-battery badge on Today).
    /// Defaults to `EmptyView` via the convenience init below, so other screens are unaffected.
    @ViewBuilder var trailing: () -> Trailing
    @ViewBuilder var content: () -> Content

    // iPad runs the shared screens full-screen, where an uncapped column gives 120+ character lines
    // in landscape. On iOS regular width (iPad) the readable column is capped + centred; compact
    // (iPhone) and macOS are unchanged. macOS also reports a horizontalSizeClass, so the cap is gated
    // by `#if os(iOS)` — a runtime size-class check alone would also narrow the Mac detail pane.
    #if os(iOS)
    @Environment(\.horizontalSizeClass) private var hSizeClass
    @Environment(\.screenScaffoldNavigationRole) private var navigationRole
    @Environment(\.screenScaffoldPresentation) private var presentation
    @Environment(\.dismiss) private var dismiss
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.appHeaderChromeVisibility) private var appHeaderChromeVisibility
    @Environment(\.screenScaffoldCloseAction) private var sheetCloseAction
    @State private var showsCompactHeader = false
    /// The actual visible scroll viewport. The content column is assigned this exact width (including
    /// its 16pt side insets) so no child with a long intrinsic label can enlarge UIScrollView's content
    /// width and make the entire page draggable left/right.
    @State private var viewportWidth: CGFloat = 0
    #endif

    var body: some View {
        scaffoldLayout
        // The flat canvas, plus an optional full-bleed TOP backdrop (Today's day-cycle scene) drawn behind
        // the scroll content — edge-to-edge under the status bar. The scene is CONFINED to the header+hero
        // band (see SceneScreenBackground.height) so it fades out ABOVE the dashboard cards, which then sit
        // on the opaque canvas and stay fully legible (2026-06-23: cards were "losing the data").
        .background(alignment: .top) {
            ZStack(alignment: .top) {
                #if os(iOS)
                StrandPalette.appCanvas
                #else
                StrandPalette.surfaceBase
                #endif
                topBackground
            }
            .ignoresSafeArea()
        }
        .modifier(ScreenScaffoldSettingsNavigation(title: title, presentation: presentation))
        #if os(iOS)
        .modifier(ScreenScaffoldPushedNavigationBar(
            hidden: presentation == .standard && navigationRole == .detail, backAction: detailBackAction))
        #endif
        #if os(macOS)
        // The mac window toolbar's default vibrant material washed the top of the liquid day-of-sky WHITE
        // (the scroll-under-titlebar blend). Hide it so the sky reads edge-to-edge and dark, like iOS.
        .toolbarBackground(.hidden, for: .windowToolbar)
        #endif
    }

    /// A tab root gives the header its own layout and hit-test region. Clipping the scroll viewport
    /// keeps scrolling content and its gestures below that sibling instead of under an inset overlay.
    @ViewBuilder private var scaffoldLayout: some View {
        #if os(iOS)
        if showsAppHeaderChrome {
            VStack(spacing: 0) {
                AppHeaderChrome(title: title ?? "Today")
                    .fixedSize(horizontal: false, vertical: true)
                    .zIndex(1)
                scrollViewport
                    .clipped()
                    .contentShape(Rectangle())
            }
        } else {
            scrollViewport
        }
        #else
        scrollViewport
        #endif
    }

    private var scrollViewport: some View {
        ScrollView(.vertical) {
            column
            #if os(iOS)
            // Anything navigated to from inside this screen's content is a drill-in: it owns a back
            // chevron, never the pinned app chrome, a system bar or the presenting sheet's close button.
            .modifier(ScreenScaffoldDrillInEnvironment(active: presentation == .standard))
            // Unified side margins matching the liquid home (16pt) so every page's cards + header line up
            // to the same edges (2026-07-02); macOS keeps the classic 28 in the #else branch.
            .padding(.horizontal, 16)
            // Flat pages begin immediately below the compact header; the old card canvas needed
            // extra breathing room here, but on a continuous surface it read as an accidental gap.
            .padding(.top, 0)
            // The tab bar floats over the scroll content, so the last card sat hidden behind it.
            // Reserve extra bottom scroll room so every screen's final card clears the floating bar.
            .padding(.bottom, NoopMetrics.tabBarClearance)
            // iPad: cap the readable column, then centre it in the full-width scroll viewport.
            // iPhone (.compact): the inner frame is .infinity/.leading, identical to before.
            .frame(width: constrainedColumnWidth,
                   alignment: hSizeClass == .regular ? .center : .leading)
            .clipped()
            .frame(maxWidth: .infinity, alignment: .center)
            #else
            .padding(28)
            .frame(maxWidth: .infinity, alignment: .leading)
            #endif
        }
        #if os(iOS)
        .onGeometryChange(for: CGFloat.self) { proxy in
            proxy.size.width
        } action: { width in
            if abs(viewportWidth - width) > 0.5 { viewportWidth = width }
        }
        .coordinateSpace(.named("screen-scaffold-scroll"))
        .overlay(alignment: .top) {
            // Tab roots keep their page header outside this scroll viewport.
            if showsCompactHeader, !showsAppHeaderChrome, !showsUtilityHeader, title != nil || subtitle != nil {
                compactHeader
                .padding(.horizontal, 16)
                .padding(.vertical, 6)
                .background(StrandPalette.appCanvas)
                .transition(reduceMotion ? .identity : .opacity)
                .accessibilityHidden(false)
            }
        }
        .animation(reduceMotion ? nil : .easeOut(duration: 0.16), value: showsCompactHeader)
        .safeAreaInset(edge: .top, spacing: 0) {
            if showsUtilityHeader {
                utilityHeader
                    .padding(.horizontal, 16)
                    .padding(.vertical, 4)
                    .background(StrandPalette.appCanvas)
            }
        }
        // This is a vertical screen contract. Because the exact-width column cannot overflow, size-based
        // horizontal bounce resolves to disabled and the page cannot expose an off-canvas edge.
        .scrollBounceBehavior(.basedOnSize, axes: .horizontal)
        #endif
        .modifier(RefreshableIfNeeded(onRefresh: onRefresh))
    }

    #if os(iOS)
    private var constrainedColumnWidth: CGFloat? {
        guard viewportWidth > 0 else { return nil }
        return hSizeClass == .regular ? min(700, viewportWidth) : viewportWidth
    }
    #endif

    /// The header + content column. `lazy` swaps the eager `VStack` for a `LazyVStack` so a long
    /// trailing `ForEach` (Intelligence "ALL") builds cards on demand instead of all at once. The
    /// alignment/spacing/header are identical in both branches, so the non-lazy path is byte-for-byte
    /// the previous layout. `@ViewBuilder` lets the two stack types resolve to one opaque return.
    @ViewBuilder private var column: some View {
        if lazy {
            LazyVStack(alignment: .leading, spacing: 16) {
                headerForColumn
                content()
            }
        } else {
            VStack(alignment: .leading, spacing: 16) {
                headerForColumn
                content()
            }
        }
    }

    @ViewBuilder private var headerForColumn: some View {
        #if os(iOS)
        if showsAppHeaderChrome {
            // The pinned H2 header owns the page title. Keep every screen-specific action in the
            // scrolling content row: suppressing a duplicate title must not remove Coach or Trends tools.
            if Trailing.self != EmptyView.self || resolvedCloseAction != nil {
                HStack(spacing: 8) {
                    Spacer(minLength: 0)
                    headerTrailing
                }
                .frame(minHeight: 44)
            }
        } else if let title, let back = detailBackAction {
            // A pushed screen gets one compact row of its own: back chip, caps title, optional context. No
            // wordmark (the tab it came from owns that) and no subtitle line. The bare `trailing()` goes in (a
            // pushed screen has no sheet close button), so an empty one adds no gap after the context.
            NoopDetailTitleRow(title, context: headerContext, backAction: back) { trailing() }
                .accessibilityHidden(showsCompactHeader)
                .onGeometryChange(for: Bool.self) { proxy in
                    proxy.frame(in: .named("screen-scaffold-scroll")).maxY <= 0
                } action: { isPastTop in
                    if showsCompactHeader != isPastTop {
                        showsCompactHeader = isPastTop
                    }
                }
        } else if presentation == .standard, !showsUtilityHeader, title != nil || subtitle != nil {
            expandedHeader
                .accessibilityHidden(showsCompactHeader)
                .onGeometryChange(for: Bool.self) { proxy in
                    proxy.frame(in: .named("screen-scaffold-scroll")).maxY <= 0
                } action: { isPastTop in
                    if showsCompactHeader != isPastTop {
                        showsCompactHeader = isPastTop
                    }
                }
        }
        #else
        legacyHeader
        #endif
    }

    #if os(iOS)
    /// The pinned app chrome (strap, sync, updates, profile) belongs to tab roots only. A drill-in owns a
    /// back chevron instead, and a modal sheet owns a close button, so neither stacks a second header.
    private var showsAppHeaderChrome: Bool {
        presentation == .standard && appHeaderChromeVisibility == .visible && navigationRole == .root
    }

    private var showsUtilityHeader: Bool {
        usesCompactUtilityHeader && presentation == .standard && navigationRole == .root
            && !showsAppHeaderChrome && title != nil
    }

    /// The title stays above the scrolling controls and grows vertically at accessibility sizes.
    private var utilityHeader: some View {
        HStack(spacing: 8) {
            Group {
                if let close = resolvedCloseAction {
                    Button(action: close) {
                        Image(systemName: "xmark")
                            .font(.system(size: 14, weight: .semibold))
                            .foregroundStyle(StrandPalette.textPrimary)
                            .frame(width: 44, height: 44)
                            .background {
                                Circle().fill(StrandPalette.surfaceRaised).frame(width: 32, height: 32)
                            }
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Close")
                } else {
                    Color.clear.frame(width: 44, height: 44).accessibilityHidden(true)
                }
            }

            if let title {
                Text(title)
                    .font(StrandFont.screenOverline)
                    .tracking(StrandFont.screenOverlineTracking)
                    .textCase(.uppercase)
                    .foregroundStyle(StrandPalette.textPrimary)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity)
                    .accessibilityAddTraits(.isHeader)
            }

            HStack(spacing: 0) { trailing() }
                .frame(minWidth: 44, minHeight: 44)
        }
    }

    /// The back action of a pushed screen that wears the compact title row, nil for every other screen: a tab
    /// root (pinned chrome), a modal sheet's root (a close button, or a wizard's own back step, keeps its header),
    /// Settings' native detail pages, and a scaffold that draws over a sky backdrop or has no title of its own.
    private var detailBackAction: (() -> Void)? {
        guard presentation == .standard, navigationRole == .detail, topBackground == nil, title != nil else { return nil }
        return resolvedBackAction
    }

    private var resolvedBackAction: (() -> Void)? {
        if let backAction { return backAction }
        guard navigationRole == .detail else { return nil }
        return { dismiss() }
    }

    /// The sheet's single close affordance, only on the screen that roots a modal sheet.
    private var resolvedCloseAction: (() -> Void)? {
        guard presentation == .standard, navigationRole == .root else { return nil }
        return sheetCloseAction?.perform
    }

    /// The screen's own trailing content followed by the sheet's close button, when it has one.
    private var headerTrailing: some View {
        HStack(spacing: 8) {
            trailing()
            if let close = resolvedCloseAction {
                NoopIconButton("xmark", accessibilityLabel: "Close", action: close)
            }
        }
    }

    private var expandedHeader: some View {
        let overSky = topBackground != nil
        return NoopScreenHeader(
            title: title,
            subtitle: showsSubtitleInExpandedHeader ? subtitle : nil,
            backAction: resolvedBackAction,
            onDark: overSky,
            style: .expanded,
            trailing: { headerTrailing }
        )
    }

    @ViewBuilder private var compactHeader: some View {
        if let title, let back = detailBackAction {
            NoopDetailTitleRow(title, context: headerContext, backAction: back) { trailing() }
        } else {
            NoopScreenHeader(
                title: title,
                subtitle: subtitle,
                backAction: resolvedBackAction,
                onDark: false,
                style: .compact,
                trailing: { headerTrailing }
            )
        }
    }
    #endif

    private var legacyHeader: some View {
        // When a `topBackground` (the day-cycle liquid sky) sits behind the header, that band is dark in
        // BOTH themes — so the title/subtitle must use the scheme-invariant on-dark tokens. The regular
        // text tokens flip to dark ink in Light mode and went dark-on-dark over the sky, exactly the #1013
        // pattern the Liquid Today hero hit (osifaind's Trends-tab sibling report). Flat-canvas screens
        // (no topBackground) keep the theme tokens so the header reads on the light/dark surfaceBase.
        let overSky = topBackground != nil
        return PaperHeaderBar(title: title, subtitle: subtitle, backAction: backAction,
                              onDark: overSky, trailing: trailing)
    }
}

#if os(iOS)
/// Marks everything inside a standard scaffold's content column as a drill-in destination.
private struct ScreenScaffoldDrillInEnvironment: ViewModifier {
    let active: Bool

    @ViewBuilder
    func body(content: Content) -> some View {
        if active {
            content
                .environment(\.screenScaffoldNavigationRole, .detail)
                .environment(\.screenScaffoldCloseAction, nil)
        } else {
            content
        }
    }
}

/// A pushed screen draws its own back chevron in the scaffold header, so the system navigation bar the
/// host `NavigationStack` would otherwise show above it (a second, empty back button) is hidden. With the bar
/// hidden UIKit stops the edge swipe from popping, so the screen also asks for it back (`EdgeSwipeBack`): the stack
/// pops, or, for a screen that roots a modal stack, the screen's own back action runs.
private struct ScreenScaffoldPushedNavigationBar: ViewModifier {
    let hidden: Bool
    let backAction: (() -> Void)?

    @ViewBuilder
    func body(content: Content) -> some View {
        if hidden {
            content
                .toolbar(.hidden, for: .navigationBar)
                .background { EdgeSwipeBack(rootBackAction: backAction).frame(width: 0, height: 0) }
        } else {
            content
        }
    }
}

private struct ScreenScaffoldSettingsNavigation: ViewModifier {
    let title: LocalizedStringKey?
    let presentation: ScreenScaffoldPresentation

    @ViewBuilder
    func body(content: Content) -> some View {
        if presentation == .settingsDetail, let title {
            content
                .navigationTitle(title)
                .navigationBarTitleDisplayMode(.inline)
        } else {
            content
        }
    }
}
#else
private struct ScreenScaffoldSettingsNavigation: ViewModifier {
    let title: LocalizedStringKey?
    let presentation: ScreenScaffoldPresentation

    func body(content: Content) -> some View { content }
}
#endif

extension ScreenScaffold where Trailing == EmptyView {
    /// Convenience init for the common case with no header trailing element — keeps every existing
    /// call site (which never passed `trailing`) source-compatible.
    init(title: LocalizedStringKey?, subtitle: LocalizedStringKey? = nil,
         onRefresh: (() async -> Void)? = nil, lazy: Bool = false, topBackground: AnyView? = nil,
         showsSubtitleInExpandedHeader: Bool = true,
         backAction: (() -> Void)? = nil,
         headerContext: String? = nil,
         usesCompactUtilityHeader: Bool = false,
         @ViewBuilder content: @escaping () -> Content) {
        self.init(title: title, subtitle: subtitle, onRefresh: onRefresh, lazy: lazy,
                  topBackground: topBackground,
                  showsSubtitleInExpandedHeader: showsSubtitleInExpandedHeader,
                  backAction: backAction,
                  headerContext: headerContext,
                  usesCompactUtilityHeader: usesCompactUtilityHeader,
                  trailing: { EmptyView() }, content: content)
    }
}

extension View {
    /// Prepares the environment for a `ScreenScaffold` that is the root of a modal sheet.
    ///
    /// Sheets inherit their presenter's environment, so without this a sheet opened from a pushed
    /// screen would show a stray back chevron, one opened from Settings would drop the scaffold header
    /// (`.settingsDetail` hides it), and the pinned app chrome would sit above the sheet's own header.
    ///
    /// Pass `onClose` when the sheet's root screen has no close control of its own: the scaffold then
    /// shows the canonical xmark `NoopIconButton` in its header. Omitting it also clears any close action
    /// inherited from a presenting sheet, so a nested sheet never dismisses the wrong layer.
    func sheetScreenScaffoldEnvironment(onClose: (() -> Void)? = nil) -> some View {
        environment(\.appHeaderChromeVisibility, .hidden)
            .environment(\.screenScaffoldNavigationRole, .root)
            .environment(\.screenScaffoldPresentation, .standard)
            .environment(\.screenScaffoldCloseAction, onClose.map(ScreenScaffoldCloseAction.init))
    }

    /// Apply to the `NavigationStack` that hosts a tab or a modal sheet. Screens pushed onto the stack
    /// resolve their environment from the stack itself, not from the root view's modifiers, so this is
    /// what makes every drill-in a `.detail`: a back chevron, no pinned app chrome, no inherited close
    /// button. The stack's own root screen opts back in (`.root` for a tab, `sheetScreenScaffoldEnvironment`
    /// for a sheet), because it inherits this too.
    func drillInDestinationEnvironment() -> some View {
        environment(\.screenScaffoldNavigationRole, .detail)
            .environment(\.screenScaffoldCloseAction, nil)
    }
}

extension View {
    /// The pinned action bar at the foot of a modal sheet: the canvas, a hairline above, and the shared
    /// 16pt gutter. Attach with `.safeAreaInset(edge: .bottom, spacing: 0) { actions.sheetFooterBar() }`.
    func sheetFooterBar() -> some View {
        padding(.horizontal, 16)
            .padding(.vertical, NoopMetrics.space3)
            .frame(maxWidth: .infinity)
            .background(StrandPalette.appCanvas)
            .overlay(alignment: .top) {
                Rectangle().fill(StrandPalette.hairline).frame(height: 1).accessibilityHidden(true)
            }
    }
}

/// Applies `.refreshable` only when a refresh hook is provided. A ViewModifier (rather than an
/// inline `if`) keeps the two branches the same opaque type, and means nil callers — every macOS
/// screen — never attach the modifier at all.
private struct RefreshableIfNeeded: ViewModifier {
    let onRefresh: (() async -> Void)?
    func body(content: Content) -> some View {
        if let onRefresh {
            content.refreshable { await onRefresh() }
        } else {
            content
        }
    }
}

/// Empty / pending-data placeholder for screens still gathering history. Mirrors `DataPendingNote`'s
/// icon-anchored card so an empty screen reads as an intentional state rather than a stray text box.
struct ComingSoon: View {
    let what: LocalizedStringKey
    var symbol: String = "sparkles"
    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: symbol)
                .font(StrandFont.headline)
                .foregroundStyle(StrandPalette.accent)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 8) {
                Text("Coming together")
                    .font(StrandFont.headline).foregroundStyle(StrandPalette.textPrimary)
                Text(what)
                    .font(StrandFont.body).foregroundStyle(StrandPalette.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .contentRowSurface(boundedPadding: 20)
    }
}

/// A reusable "what shows now vs what needs an import" note. Bold title line plus a
/// body line, with an info/sparkles SF Symbol. Used for empty/pending data states so
/// every screen explains the live-now path and the import path with timing.
/// Pulsing "history sync in progress" line (#77). Shown above a screen's empty state while the
/// strap's historical offload runs, so a half-loaded screen ("No nights here yet") reads as
/// in-progress rather than final. Shows the honest live signal — chunks pulled so far — never a
/// percent (total pending is unknowable from the protocol, so a determinate bar would lie).
struct SyncingHistoryNote: View {
    let chunks: Int

    var body: some View {
        HStack(spacing: 10) {
            StatePill("Syncing strap history…", tone: .neutral, pulsing: true)
            if chunks > 0 {
                Text("\(chunks) chunks pulled")
                    .font(StrandFont.footnote)
                    .foregroundStyle(StrandPalette.textSecondary)
            }
        }
    }
}

/// Coarse relative-time label for the "History synced N ago" sync-status line. Pure — `now` is
/// injectable so the bucket edges are unit-testable (RelativeAgoTests) — and deliberately the same
/// buckets as the Android `relativeAgo` (LiveScreen.kt, ed6a31d) so the two apps read identically.
/// Clamps future timestamps (strap-clock skew) to "just now", never negative.
func relativeAgo(_ epochSeconds: TimeInterval,
                 now: TimeInterval = Date().timeIntervalSince1970) -> String {
    let d = max(0, Int(now - epochSeconds))
    let elapsedDaySeconds = 24 * 60 * 60
    switch d {
    case ..<60:     return String(localized: "just now")
    case ..<3600:   return String(localized: "\(d / 60) min ago")
    case ..<elapsedDaySeconds: return String(localized: "\(d / 3600) h ago")
    default:        return String(localized: "\(d / elapsedDaySeconds) d ago")
    }
}

struct DataPendingNote: View {
    let title: LocalizedStringKey
    let message: LocalizedStringKey
    var symbol: String = "sparkles"

    var body: some View {
        StrandCard(padding: 20) {
            HStack(alignment: .top, spacing: 12) {
                Image(systemName: symbol)
                    .font(StrandFont.headline)
                    .foregroundStyle(StrandPalette.accent)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 6) {
                    Text(title)
                        .font(StrandFont.headline)
                        .foregroundStyle(StrandPalette.textPrimary)
                        .fixedSize(horizontal: false, vertical: true)
                    Text(message)
                        .font(StrandFont.subhead)
                        .foregroundStyle(StrandPalette.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }
}
