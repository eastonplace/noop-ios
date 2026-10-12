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

/// What sits under the pages. The page dots are the one adjustable "Pages" element VoiceOver and Switch Control change pages
/// with, so they are there in every state; once the workout is paused (or End was tried) the preview of what the save would hold
/// sits above them.
enum LiveWorkoutPagerFooter {
    static func showsPageDots(isPaused: Bool, isEnding: Bool) -> Bool { true }
    static func showsSavePreview(isPaused: Bool, isEnding: Bool) -> Bool { isPaused || isEnding }
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
            // Under the figures: the page dots, and, once paused, what the save would hold above them (the preview is what the
            // hold below is about). The dots stay: they are the adjustable "Pages" element VoiceOver and Switch Control change
            // pages with, in every state.
            if LiveWorkoutPagerFooter.showsSavePreview(isPaused: workout.isPaused, isEnding: workout.isEnding) {
                LiveSavePreview(model: model, workout: workout, recorder: recorder)
            }
            if LiveWorkoutPagerFooter.showsPageDots(isPaused: workout.isPaused, isEnding: workout.isEnding) {
                PageDots(titles: pages.map(\.title), selection: dotSelection)
            }
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
            LiveFocusPage(workout: workout, recorder: recorder, profile: model.profile, live: model.live, isVisible: isVisible)
        case .heart:
            LiveHeartPage(workout: workout, recorder: recorder, profile: model.profile, live: model.live,
                          isVisible: isVisible, onManageDevices: onManageDevices)
        case .route:
            LiveRoutePage(workout: workout, recorder: recorder, live: model.live, isVisible: isVisible,
                          isNear: current == .route || current == .heart)
        }
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

// MARK: - Save preview

/// What End would save, in the dots' place while the workout is paused: "Saves 34:11 · 5.49 km · strain 7.4", the figures in
/// white and the words in grey. The same gate `endWorkout()` applies, so the hold is never a leap of faith.
struct LiveSavePreview: View {
    @ObservedObject var model: AppModel
    @ObservedObject var workout: AppModel.ActiveWorkout
    @ObservedObject var recorder: GpsWorkoutRecorder
    @AppStorage(UnitPrefs.systemKey) private var unitSystemRaw = UnitSystem.metric.rawValue

    /// One segment of the line: some words, or a figure.
    struct Segment: Equatable {
        let text: String
        let isFigure: Bool
    }

    var body: some View {
        Group {
            if model.finishNeedsMoreEvidence {
                // The dock's own panel says there is nothing to save; this line would say it a second time.
                Color.clear.frame(height: 0)
            } else if model.workoutWouldSave {
                let segments = Self.segments(elapsed: workout.activeElapsed(), distance: distanceText, strain: strainText)
                Self.oneLineOrStacked(joined: Self.line(for: segments), lines: Self.facts(of: segments).map(Self.line(for:)))
            } else {
                let message = String(localized: "Nothing to save yet · no heart rate or route")
                let parts = message.components(separatedBy: " · ").map { Text(verbatim: $0) }
                Self.oneLineOrStacked(joined: Text(verbatim: message), lines: parts)
                    .foregroundStyle(LivePalette.amber)
            }
        }
        .liveText(14, weight: .medium, maxSize: 19, lines: 3)
        .multilineTextAlignment(.center)
        .frame(maxWidth: .infinity, minHeight: 28)
        .screenPadding()
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text(verbatim: spoken))
        // With nothing to save the dock's own panel says so; this line is not there to say it a second time.
        .accessibilityHidden(model.finishNeedsMoreEvidence)
    }

    private var imperial: Bool { unitSystemRaw == UnitSystem.imperial.rawValue }

    /// The distance with its unit, only for a route that is being recorded and has gone somewhere.
    private var distanceText: (figure: String, unit: String)? {
        guard model.activeWorkoutIsGps, recorder.hasDrawableRoute, recorder.distanceM > 0 else { return nil }
        return (LiveWorkoutTiles.distanceText(meters: recorder.distanceM, imperial: imperial),
                LiveWorkoutGlance.Units.distance(imperial: imperial))
    }

    private var strainText: String? {
        if case .scored(let stored) = workout.liveStrainState { return StrainScale.formatted(stored) }
        return nil
    }

    /// The segments of "Saves 34:11 · 5.49 km · strain 7.4". The words are the String Catalog's, so a language puts its figure
    /// where it wants it: each template is localized with a marker where the figure goes, and split at the marker.
    static func segments(elapsed: TimeInterval, distance: (figure: String, unit: String)?, strain: String?) -> [Segment] {
        let marker = "\u{1}"
        var result: [Segment] = []
        func add(template: String, figure: String) {
            let parts = template.components(separatedBy: marker)
            if let first = parts.first, !first.isEmpty { result.append(Segment(text: first, isFigure: false)) }
            result.append(Segment(text: figure, isFigure: true))
            if parts.count > 1, !parts[1].isEmpty { result.append(Segment(text: parts[1], isFigure: false)) }
        }
        add(template: String(localized: "Saves \(marker)"), figure: LiveWorkoutTiles.elapsedText(elapsed))
        if let distance {
            result.append(Segment(text: " · ", isFigure: false))
            result.append(Segment(text: distance.figure, isFigure: true))
            result.append(Segment(text: " \(distance.unit)", isFigure: false))
        }
        if let strain {
            result.append(Segment(text: " · ", isFigure: false))
            add(template: String(localized: "strain \(marker)"), figure: strain)
        } else {
            result.append(Segment(text: " · ", isFigure: false))
            result.append(Segment(text: String(localized: "strain not scored yet"), isFigure: false))
        }
        return result
    }

    /// The line split at its " · " separators: "Saves 34:11", "5.49 km", "strain 7.4".
    static func facts(of segments: [Segment]) -> [[Segment]] {
        var facts: [[Segment]] = [[]]
        for segment in segments {
            if segment.text == " · " { facts.append([]) } else { facts[facts.count - 1].append(segment) }
        }
        return facts.filter { !$0.isEmpty }
    }

    /// One line when it fits; when it does not (a long translation, a large type size) one fact per line, never a wrap that
    /// strands a "·" at the end of a line.
    private static func oneLineOrStacked(joined: Text, lines: [Text]) -> some View {
        ViewThatFits(in: .horizontal) {
            joined.lineLimit(1).fixedSize(horizontal: true, vertical: false)
            VStack(spacing: 2) {
                ForEach(Array(lines.enumerated()), id: \.offset) { _, line in line }
            }
        }
    }

    private static func line(for segments: [Segment]) -> Text {
        segments.reduce(Text(verbatim: "")) { text, segment in
            text + Text(verbatim: segment.text)
                .foregroundStyle(segment.isFigure ? StrandPalette.textPrimary : LivePalette.secondaryText)
        }
    }

    /// The same line for VoiceOver, with the units as words ("5.49 kilometers"), not letters.
    private var spoken: String {
        if !model.workoutWouldSave { return String(localized: "Nothing to save yet · no heart rate or route") }
        var parts = [String(localized: "Saves \(LiveWorkoutTiles.spokenElapsed(workout.activeElapsed()))")]
        if let distance = distanceText { parts.append(LiveWorkoutTiles.spokenDistance(distance.figure, imperial: imperial)) }
        if let strain = strainText { parts.append(String(localized: "strain \(strain)")) } else { parts.append(String(localized: "strain not scored yet")) }
        return parts.joined(separator: ", ")
    }
}
#endif
