import Foundation
import Combine
import SwiftUI
import StrandDesign
import StrandAnalytics

// MARK: - Pages

/// The pages of the live screen, in order. Focus is where every workout starts; Heart and Route are a swipe away. A route page
/// exists only for a sport that is recording a route.
enum LiveWorkoutPage: String, CaseIterable, Hashable, Sendable {
    case focus, heart, route

    /// The pages a workout has, in order.
    static func pages(tracksRoute: Bool) -> [LiveWorkoutPage] {
        tracksRoute ? [.focus, .heart, .route] : [.focus, .heart]
    }

    /// The page to show: the remembered or chosen one when the workout still has it, else the first.
    static func resolve(_ page: LiveWorkoutPage?, in pages: [LiveWorkoutPage]) -> LiveWorkoutPage {
        if let page, pages.contains(page) { return page }
        return pages.first ?? .focus
    }

    /// `--demo-live-page focus|heart|route` (QA).
    static func demoPage(arguments: [String]) -> LiveWorkoutPage? {
        guard let flag = arguments.firstIndex(of: "--demo-live-page"), arguments.indices.contains(flag + 1) else { return nil }
        return LiveWorkoutPage(rawValue: arguments[flag + 1])
    }

    var title: String {
        switch self {
        case .focus: String(localized: "Focus")
        case .heart: String(localized: "Heart")
        case .route: String(localized: "Route")
        }
    }
}

/// The page each workout was last on, so a Minimize and a return find the wearer where they were. Owned by `NavRouter`,
/// handed to the live screen by the journey; not observed, since nothing is drawn from it.
@MainActor
final class WorkoutPageMemory {
    private var pages: [UUID: LiveWorkoutPage] = [:]

    subscript(sessionID: UUID) -> LiveWorkoutPage? {
        get { pages[sessionID] }
        set { pages[sessionID] = newValue }
    }
}

#if os(iOS)

// MARK: - Pager

/// The middle of the live screen: the pages, side by side, and the dots that say which one is showing. The page being looked
/// at has the clocks; the others draw once. The wearer's page is remembered for the workout, so minimizing and coming back
/// returns to it.
struct LiveWorkoutPager: View {
    let model: AppModel
    @ObservedObject var workout: AppModel.ActiveWorkout
    let recorder: GpsWorkoutRecorder
    let pageMemory: WorkoutPageMemory?
    let onManageDevices: () -> Void
    @StateObject private var routeAvailability: LiveRouteAvailability
    @State private var selected: LiveWorkoutPage

    init(model: AppModel, workout: AppModel.ActiveWorkout, recorder: GpsWorkoutRecorder, pageMemory: WorkoutPageMemory?,
         onManageDevices: @escaping () -> Void) {
        self.model = model
        self.workout = workout
        self.recorder = recorder
        self.pageMemory = pageMemory
        self.onManageDevices = onManageDevices
        _routeAvailability = StateObject(wrappedValue: LiveRouteAvailability(recorder: recorder))
        var start: LiveWorkoutPage? = pageMemory?[workout.sessionID]
        #if DEBUG
        start = LiveWorkoutPage.demoPage(arguments: ProcessInfo.processInfo.arguments) ?? start
        #endif
        _selected = State(initialValue: start ?? .focus)
    }

    private var pages: [LiveWorkoutPage] { LiveWorkoutPage.pages(tracksRoute: routeAvailability.tracksRoute) }
    private var current: LiveWorkoutPage { LiveWorkoutPage.resolve(selected, in: pages) }

    var body: some View {
        VStack(spacing: 0) {
            TabView(selection: $selected) {
                ForEach(pages, id: \.self) { page in
                    pageView(page)
                        .tag(page)
                }
            }
            .tabViewStyle(.page(indexDisplayMode: .never))
            PageDots(titles: pages.map(\.title), selection: dotSelection)
        }
        .onChange(of: selected) { _, page in pageMemory?[workout.sessionID] = page }
    }

    private var dotSelection: Binding<Int> {
        Binding(get: { pages.firstIndex(of: current) ?? 0 },
                set: { index in
                    guard pages.indices.contains(index) else { return }
                    withAnimation(.easeInOut(duration: 0.2)) { selected = pages[index] }
                })
    }

    @ViewBuilder private func pageView(_ page: LiveWorkoutPage) -> some View {
        let isVisible = page == current
        switch page {
        case .focus:
            LivePageScroll {
                LiveFocusPage(workout: workout, recorder: recorder, profile: model.profile, live: model.live,
                              isVisible: isVisible)
            }
        case .heart:
            LivePageScroll {
                LiveHeartPage(workout: workout, recorder: recorder, profile: model.profile, live: model.live,
                              isVisible: isVisible, onManageDevices: onManageDevices)
            }
        case .route:
            LiveRoutePage(workout: workout, recorder: recorder, isVisible: isVisible,
                          isNear: current == .route || current == .heart)
                .screenPadding()
                .padding(.vertical, NoopMetrics.space2)
        }
    }
}

/// A page's scrolling body: as tall as the room it has (so a flexible part, the focus number, takes the spare height) and
/// scrolling only when its content is taller (accessibility sizes, a small screen).
struct LivePageScroll<Content: View>: View {
    @ViewBuilder let content: () -> Content

    var body: some View {
        GeometryReader { proxy in
            ScrollView {
                AtLeastHeight(minHeight: proxy.size.height) {
                    content()
                        .screenPadding()
                        .padding(.vertical, NoopMetrics.space2)
                }
            }
            .scrollBounceBehavior(.basedOnSize)
        }
    }
}

/// Makes its one child at least `minHeight` tall: the child is offered the whole height when it is shorter, so its flexible
/// parts (the focus number's region) grow into the room, and its own height when it is taller (then the scroll view scrolls).
struct AtLeastHeight: Layout {
    let minHeight: CGFloat

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        guard let child = subviews.first else { return .zero }
        let natural = child.sizeThatFits(ProposedViewSize(width: proposal.width, height: nil))
        return CGSize(width: proposal.width ?? natural.width, height: max(natural.height, minHeight))
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        subviews.first?.place(at: bounds.origin, anchor: .topLeading,
                              proposal: ProposedViewSize(width: bounds.width, height: bounds.height))
    }
}

/// Publishes only whether the workout is recording a route, so the pager is not redrawn for every GPS point to find out.
@MainActor
private final class LiveRouteAvailability: ObservableObject {
    @Published private(set) var tracksRoute: Bool
    private var token: AnyCancellable?

    init(recorder: GpsWorkoutRecorder) {
        tracksRoute = recorder.isRecording && recorder.canRecordRoute
        // `objectWillChange` fires before the value changes: look on the next turn.
        token = recorder.objectWillChange
            .receive(on: DispatchQueue.main)
            .map { [weak recorder] _ in recorder.map { $0.isRecording && $0.canRecordRoute } ?? false }
            .removeDuplicates()
            .sink { [weak self] value in self?.tracksRoute = value }
    }
}

// MARK: - Zone wash

/// The faint wash of the zone's colour behind the whole live screen, from its top edge down: from `ZoneWashModel`, it follows
/// the heart rate once it has been well inside a new zone for a few seconds, and is nothing at all while the workout is paused
/// or ending or the strap has gone quiet. The zone word on the page says the same thing in words.
struct LiveZoneWash: View {
    @ObservedObject var workout: AppModel.ActiveWorkout
    @ObservedObject var profile: ProfileStore
    @State private var wash = ZoneWashModel()

    var body: some View {
        TimelineView(.periodic(from: .now, by: 1)) { context in
            ZoneWashBackground(zone: wash.displayedZone)
                .onChange(of: context.date) { _, now in feed(now) }
        }
        .onAppear { feed(Date()) }
    }

    private func feed(_ now: Date) {
        let stale = LiveWorkoutSignals.heartRateIsStale(
            lastReadingAt: workout.lastReadingAt, workoutStart: workout.start,
            isPaused: workout.isPaused, isEnding: workout.isEnding, now: now)
        let neutral = workout.isPaused || workout.isEnding || stale
        wash.update(bpm: workout.currentBPM,
                    thresholds: ProfileStore.hrZoneThresholds(override: profile.hrMaxOverride, age: profile.age),
                    now: now, isNeutral: neutral)
    }
}
#endif
