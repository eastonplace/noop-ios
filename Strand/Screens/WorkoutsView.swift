import SwiftUI
import ReceiptLiftFeature
import StrandDesign
import StrandAnalytics
import WhoopStore
import Foundation

// MARK: - Workouts
//
// The activity hub, in the widget design language: flat sections on the canvas, one hairline between them, values
// bright with their units muted.
//
//  • The header: WORKOUTS and the day, with the one solid Start pill (Open while a workout is running).
//  • Workout minutes: the known recorded minutes of the seven days the feed below covers, as the week's bars.
//  • History: sessions grouped by local start day, with Add and Select chips, Recent/Archived, range, sport, source and
//    search filters, multi-select merge/delete and a row context menu.
//  • Behind "Training tools and summaries": this week, Lift, heart rate zones and the latest pace.
//
// The pieces live in WorkoutHistoryChart.swift, WorkoutsHubSections.swift and WorkoutsHubParts.swift; the rules they
// draw from in WorkoutTimelinePolicy.swift (day groups, the seven days) and WorkoutsHubModel.swift (which Strain a row
// shows, how a week adds up). This file owns the data, the filters and the sheets.

struct WorkoutsView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.screenScaffoldNavigationRole) private var navigationRole
    @Environment(\.screenScaffoldCloseAction) private var sheetCloseAction
    @EnvironmentObject var repo: Repository
    /// #459: "Start Workout" used to live ONLY on the Live screen, so a user reaching Workouts (via the
    /// Quick-action FAB or the tab) had no way to begin one from the obvious place. The model is captured
    /// as a plain command reference below rather than observed by this large history root.
    @State private var appModel: AppModel?
    /// Starting or returning to a workout is the shell's job (one full-screen journey), so this screen only asks.
    @EnvironmentObject private var router: NavRouter
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.dynamicTypeSize) private var typeSize
    private var model: AppModel {
        guard let appModel else {
            preconditionFailure("WorkoutsView rendered before AppModelReferenceCapture supplied AppModel")
        }
        return appModel
    }
    @State private var historyScope: WorkoutHistoryScope = .current
    @State private var liftDestination: LiftDestination?
    @State private var showHistoryFilters = false
    @State private var showTrainingTools = false
    @State private var expandingHistory = false
    @State private var loadedSourceIdentity = ""
    @State private var civilRevision = 0

    private var sourceIdentity: String {
        repo.todayHealthSnapshotScopeId + "|" + repo.liveSourceState.lineageComponent
            + "|" + String(repo.externalSurfaceInvalidationEpoch)
    }
    private var loadIdentity: String {
        sourceIdentity + "|" + String(repo.refreshSeq) + "|" + String(civilRevision)
            + (repo.verifiedExternalSurfaceFenced ? "|updating" : "|ready")
    }

    // Imperial/Metric display preference (D#103). Workout distances are stored in metres; the toggle
    // re-labels them to miles/yards. Display-only — nothing on disk changes.
    @AppStorage(UnitPrefs.systemKey) private var unitSystemRaw = UnitSystem.metric.rawValue
    private var unitSystem: UnitSystem { UnitSystem(rawValue: unitSystemRaw) ?? .metric }

    /// All loaded sessions, newest first. Seedable for previews. #797: this holds only the rows inside the
    /// currently-LOADED window (`loadedWindowDays`), not the entire history. A 1700+-workout import made
    /// the eager all-rows read + sort fire on every `refreshSeq` bump (first paint AND every backfill
    /// slice). First paint loads a bounded window; selecting a wider range than is loaded lazily pages in
    /// the rest (`expandWindow`).
    @State private var allRows: [WorkoutRow]
    @State private var loaded: Bool
    @State private var seededInitialRange = false
    @State private var range: Range = .all
    /// #797: how many trailing days of workouts are currently LOADED into `allRows`. First paint loads
    /// `Self.firstPaintWindowDays`; picking "All" (or a range wider than this) pages the full history in on
    /// demand. nil means the full history is loaded (the user expanded to "All"). Preview rows are treated
    /// as fully loaded (nil) so the preview path is unchanged.
    @State private var loadedWindowDays: Int?
    private let usesPreviewRows: Bool

    /// #797: trailing-day window the FIRST workouts read is bounded to, so first paint never sorts a
    /// multi-thousand-workout history. Comfortably covers the default range (the tightest range with ≥2
    /// sessions, almost always ≤90 days); a wider pick pages the rest in via `expandWindow`. 400 days
    /// covers the 1Y range plus headroom.
    static let firstPaintWindowDays = 400

    /// The add/edit sheet target: `.some(nil)` = add a new workout, `.some(row)` = edit `row`,
    /// `nil` = sheet closed. Wrapped in Identifiable so `.sheet(item:)` can drive presentation.
    @State private var sheet: WorkoutSheetTarget?

    /// The read-only detail screen target — a tapped session. Drives a `.sheet(item:)` separate from
    /// the add/edit sheet so a primary tap (detail) and the ••• menu (edit) never collide. (#410)
    @State private var detail: WorkoutDetailTarget?

    /// A transient one-line note shown after a manual save / relabel for a sport that already has a
    /// solid/building ActivityCost entry — "Sessions like this usually …" (#439). Auto-clears.
    @State private var postLogNote: String?
    @State private var postLogGeneration = 0

    /// The most recent finished lift, read from the lifting log. Nil until read, and when there is none.
    @State private var lastLift: WorkoutLastLift?
    /// Heart-rate zone minutes across the sessions the history is showing. Parsed off the main thread when the
    /// window or the filters change, never in `body`. `.pending` until the first parse reports, so a section that
    /// has not looked yet never claims there is no data.
    @State private var zonesPhase: WorkoutZonesSection.Phase = .pending
    @State private var publishedZonesKey: ZonesKey?
    /// Bumped whenever `allRows` is replaced, so everything computed from the rows knows they changed, whatever
    /// their count and newest start say.
    @State private var rowsGeneration = 0
    /// What the hub derives from the rows once per change rather than once per body: the week and the pace row.
    @State private var derived: HubDerived?

    private struct HubDerived {
        let day: Date
        let week: WorkoutWeekSummary
        let paceRow: WorkoutRow?
    }

    // MARK: - Filters + selection (#64)

    /// Filter beyond the time range: a displayed-sport key (nil = all), an origin class (nil = all), and
    /// a free-text search over the displayed sport. Pure `WorkoutFilter` applies them after the window cut.
    @State private var sportFilter: String?
    @State private var sourceFilter: WorkoutOrigin?
    @State private var searchText = ""

    /// Multi-select + merge mode. `selectionMode` toggles the leading checkmarks + the toolbar strip;
    /// `selected` holds the natural keys ("startTs|sport") of the chosen rows. Only MANUAL / DETECTED rows
    /// are selectable (imported history is read-only and can never be merged or bulk-deleted).
    @State private var selectionMode = false
    @State private var selected: Set<String> = []
    /// When every selected row is a bare detected bout, the merge has no sport to keep — this drives a
    /// small confirm sheet asking the user to name the merged session.
    @State private var mergeSportPrompt: MergeSportTarget?

    /// The selection key for a row (its natural key). Stable across a reload so the checkmarks persist.
    private func selectionKey(_ row: WorkoutRow) -> String { "\(row.startTs)|\(row.sport)" }

    /// Wraps the pending merge inputs so a `.sheet(item:)` can present the "name the merged session" prompt
    /// (used only when every selected row is detected, so there's no sport to inherit).
    private struct MergeSportTarget: Identifiable {
        let rows: [WorkoutRow]
        let id = UUID()
    }

    /// Wraps the optional edited row so `.sheet(item:)` can present add (editing == nil) or edit.
    private struct WorkoutSheetTarget: Identifiable {
        let editing: WorkoutRow?
        let id = UUID()
    }

    /// Wraps a tapped row so `.sheet(item:)` can present its detail screen.
    private struct WorkoutDetailTarget: Identifiable {
        let row: WorkoutRow
        let id = UUID()
    }

    init(previewRows: [WorkoutRow]? = nil) {
        _allRows = State(initialValue: previewRows ?? [])
        _loaded = State(initialValue: previewRows != nil)
        // Preview-seeded rows are treated as the full history (nil window) so the preview path never pages.
        _loadedWindowDays = State(initialValue: previewRows != nil ? nil : Self.firstPaintWindowDays)
        usesPreviewRows = previewRows != nil
    }

    var body: some View {
        Group {
            if appModel != nil {
                dashboard
            } else {
                Color.clear
            }
        }
        // The capture leaf is the only broad observer. Workouts retains only object identity, preventing
        // each active-workout publication from rebuilding the filtered history and summary sections.
        .background(AppModelReferenceCapture(reference: $appModel))
        .segmentedPillSelectionStyle(.quiet)
    }

    /// A pushed hub (or one with no close control of its own) draws a back chevron. The hub at the root of a sheet that
    /// supplies its own close action (Coach's plan opens it so) has nothing to go back to: the scaffold draws the
    /// canonical close button there instead.
    private var dashboardBackAction: (() -> Void)? {
        navigationRole == .root && sheetCloseAction != nil ? nil : { dismiss() }
    }

    private var dashboard: some View {
        ScreenScaffold(title: "Workouts",
                       onRefresh: { _ = await repo.refresh(.currentDay) },
                       // PERF: the column ends in the full history log, so the hub below is a LazyVStack that builds
                       // the off-screen sections and rows on demand. The scaffold's own column stays eager: its header
                       // reports when it has scrolled away (which pins the compact header), and a header inside a
                       // second lazy stack can be released before it reports.
                       lazy: false,
                       topBackground: nil,
                       backAction: dashboardBackAction,
                       headerContext: DrillInFormat.headerDate(Date()),
                       trailing: {
                           WorkoutsStartPill(model: model,
                                             onStart: { router.beginWorkout() },
                                             onOpen: { router.openActiveWorkout() })
                       }) {
            LazyVStack(alignment: .leading, spacing: 0) { hub }
        }
        #if os(iOS)
        .toolbar(.hidden, for: .navigationBar)
        // Rows scroll under the status bar on a screen whose header has scrolled away; a solid strip keeps them out of it.
        .modifier(TopSafeAreaScrim())
        #endif
        // Both are posted on whatever thread noticed the change; hop to the main thread before touching view state.
        .onReceive(NotificationCenter.default.publisher(for: .NSCalendarDayChanged)
            .receive(on: DispatchQueue.main)) { _ in civilRevision &+= 1 }
        .onReceive(NotificationCenter.default.publisher(for: .NSSystemTimeZoneDidChange)
            .receive(on: DispatchQueue.main)) { _ in civilRevision &+= 1 }
        .task(id: loadIdentity) {
            guard !usesPreviewRows else { return }
            #if DEBUG
            // QA: hold the hub in its loading state so that state can be captured (`--noop-qa-hold-load`).
            if ProcessInfo.processInfo.arguments.contains("--noop-qa-hold-load") { return }
            #endif
            // #797: read only the currently-loaded window (bounded on first paint), not the whole history.
            let identity = loadIdentity
            let source = sourceIdentity
            guard !repo.verifiedExternalSurfaceFenced else { return }
            let r = await readLoadedWindow()
            guard !Task.isCancelled, identity == loadIdentity, !repo.verifiedExternalSurfaceFenced else { return }
            loadedSourceIdentity = source
            setRows(r)
            let wasLoaded = loaded
            loaded = true
            if !wasLoaded {
                range = defaultRange(for: r)
                seededInitialRange = true
            }
            let lift = await readLastLift()
            guard !Task.isCancelled, identity == loadIdentity else { return }
            lastLift = lift
        }
        .task(id: zonesKey) {
            // Before the rows arrive there is nothing to parse, and parsing nothing would report "No zone data" for a
            // history that has some. The generation bump that comes with the rows starts this task again.
            guard loaded else { return }
            let key = zonesKey
            let rows = WorkoutHistoryScope.filter(sessions(for: effectiveRange), scope: historyScope)
            let summary = await Task.detached(priority: .userInitiated) { WorkoutZones.summary(from: rows) }.value
            // A detached task does not stop with this one. Without the check a parse for rows the person has already
            // filtered away could land after the newer one and replace it.
            guard !Task.isCancelled else { return }
            zonesPhase = .ready(summary)
            publishedZonesKey = key
        }
        .onAppear {
            // Preview-seeded rows skip `.task`; still choose a range that has data.
            if loaded && !seededInitialRange {
                range = defaultRange(for: allRows)
                seededInitialRange = true
            }
        }
        .paperToast(isPresented: postLogToastPresented, autoDismiss: false) {
            PaperToast(
                LocalizedStringKey(postLogNote ?? ""),
                systemImage: "chart.line.uptrend.xyaxis",
                tint: StrandPalette.effortColor,
                announcement: postLogNote
            )
        }
        // #797: when the user picks a range wider than the bounded first-paint window (typically "All"),
        // page the full history in. A pick that fits the loaded window is a no-op. Also covers the
        // auto-widen: if the selected window is sparse and `effectiveRange` falls back to `.all`, the
        // full read is needed to show the older sessions.
        .onChange(of: range) { _, newRange in
            Task { await expandWindowIfNeeded(for: newRange == .all ? .all : effectiveRange) }
        }
        .sheet(item: $liftDestination) { destination in LiftLogView(destination: destination) }
        .onChange(of: historyScope) { _, scope in
            if scope == .archived { range = .all; Task { await expandWindowIfNeeded(for: .all) } }
        }
        .sheet(item: $sheet) { target in
            ManualWorkoutSheet(editing: target.editing) { row, replacing in
                Task {
                    await repo.saveManualWorkout(row, replacing: replacing)
                    // #598: rescore the just-added workout from the strap's HR for its window NOW, so its
                    // average / peak HR, strain and calories appear immediately (from your own strap data)
                    // instead of waiting up to 15 minutes for the next analyze tick. No-ops when the strap
                    // had no HR for that window, and never overrides a value you typed yourself.
                    await model.intelligence.analyzeRecent()
                    await reload()
                    // Post-log note (#439): if this sport now has a solid/building recovery-cost
                    // entry, surface its personal-pattern sentence as a transient caption.
                    await showPostLogNote(forSport: WorkoutSource.displaySport(row.sport))
                }
            }
        }
        .sheet(item: $detail) { target in
            // These shared screens aren't hosted in a per-screen NavigationStack, so the read-only
            // detail rides its own NavigationStack inside the sheet (the Done toolbar item + iOS
            // grabber give the dismiss affordances). Mirrors HealthView presenting MetricDetailView.
            NavigationStack {
                WorkoutDetailView(row: target.row)
                    .environmentObject(repo)
                    // Modal: one close button in the scaffold header, not the back chevron this screen
                    // inherits from being presented over a pushed screen.
                    .sheetScreenScaffoldEnvironment(onClose: { detail = nil })
            }
            #if os(iOS)
            .noopSheetPresentation(largeFirst: true)
            #else
            .frame(width: 620, height: 720)
            #endif
        }
        // #64: name the merged session when every selected row is a bare detected bout (there's no sport
        // to inherit). Reuses the "Start a workout" named-sport picker.
        .sheet(item: $mergeSportPrompt) { target in
            StartWorkoutSheet { name in
                performMerge(target.rows, sport: name)
            }
        }
        // A workout request (Quick Actions, the Live Activity, a deep link) closes what this screen is presenting, so the
        // workout journey's cover can open at the root.
        #if os(iOS)
        .collapsesForWorkoutJourney {
            sheet = nil
            detail = nil
            liftDestination = nil
            mergeSportPrompt = nil
        }
        #endif
    }

    /// Present the read-only detail for a tapped row. The primary affordance; the row's context menu is the
    /// secondary path for edit/relabel/delete.
    private func openDetail(_ row: WorkoutRow) { detail = WorkoutDetailTarget(row: row) }

    /// Re-read every source after a mutation so the screen reflects the new state immediately.
    /// Keeps the user's current range — only the initial load picks a default — and the auto-widen
    /// (`effectiveRange`) still covers a now-empty window.
    private func reload() async {
        let identity = sourceIdentity
        let rows = await readLoadedWindow()
        guard !Task.isCancelled, identity == sourceIdentity, !repo.verifiedExternalSurfaceFenced else { return }
        loadedSourceIdentity = identity
        setRows(rows)
    }

    /// Reads the loaded window. When the window widens while the read is out (the full-history expansion), it reads
    /// again at the new width, so a narrower answer never replaces the wider history. The window only ever widens
    /// once, so this reads at most twice.
    private func readLoadedWindow() async -> [WorkoutRow] {
        var window = loadedWindowDays
        var rows = await repo.workoutRows(days: window ?? 4000)
        while window != loadedWindowDays, !Task.isCancelled {
            window = loadedWindowDays
            rows = await repo.workoutRows(days: window ?? 4000)
        }
        return rows
    }

    /// Replaces the loaded rows and everything derived from them. The one place `allRows` is assigned.
    private func setRows(_ rows: [WorkoutRow]) {
        allRows = rows
        rowsGeneration &+= 1
        derived = Self.derive(from: rows, unitSystem: unitSystem)
    }

    private static func derive(from rows: [WorkoutRow], unitSystem: UnitSystem, now: Date = Date()) -> HubDerived {
        HubDerived(
            day: Calendar.current.startOfDay(for: now),
            week: WorkoutWeekSummary.make(rows: rows, now: now),
            paceRow: rows.first { WorkoutPace.perUnit($0, system: unitSystem) != nil })
    }

    /// The derived values, recomputed (without touching state) only when a new day has begun since they were made or
    /// when a preview seeded rows before the first load.
    private var currentDerived: HubDerived {
        if let derived, derived.day == Calendar.current.startOfDay(for: Date()) { return derived }
        return Self.derive(from: allRows, unitSystem: unitSystem)
    }

    /// #797: page the FULL workout history in when the user selects a range wider than the bounded
    /// first-paint window. Idempotent: once expanded (`loadedWindowDays == nil`) it never re-reads here.
    /// Only a pick of `.all` (or a future range exceeding the loaded window) triggers the one-time full
    /// read, so the common 7D/30D/90D/1Y interactions stay on the already-loaded bounded set.
    private func expandWindowIfNeeded(for picked: Range) async {
        guard !usesPreviewRows, loadedWindowDays != nil, !expandingHistory else { return }
        if let pickedDays = picked.days, pickedDays <= (loadedWindowDays ?? 0) { return }
        // Widen first, so any read that starts (or is still out) from here on covers the full history too.
        let source = sourceIdentity
        let generation = rowsGeneration
        loadedWindowDays = nil
        expandingHistory = true
        defer { expandingHistory = false }
        let rows = await repo.workoutRows(days: 4000)
        // Only a change of source voids this read: a refresh during the slow full read (refreshSeq moves on every
        // backfill slice) must not leave Archived on the first-paint window. A read that replaced the rows meanwhile
        // already covered the full history and is at least as fresh, so it is kept.
        guard !Task.isCancelled, source == sourceIdentity, generation == rowsGeneration,
              !repo.verifiedExternalSurfaceFenced else { return }
        loadedSourceIdentity = source
        setRows(rows)
    }

    /// The finished lift with the latest start, with its working-set count, from the lifting log.
    private func readLastLift() async -> WorkoutLastLift? {
        guard !usesPreviewRows, let store = await repo.storeHandle() else { return nil }
        let owner = repo.deviceId
        let now = Int(Date().timeIntervalSince1970)
        guard let sessions = try? await store.liftSessions(deviceId: owner, fromTs: now - 365 * 86_400, toTs: now + 1),
              let latest = sessions.first(where: { $0.endTs != nil }) else { return nil }
        let sets = (try? await store.liftSets(sessionId: latest.id)) ?? []
        return WorkoutLastLift.make(session: latest, sets: sets)
    }

    // MARK: - Hub

    /// Everything the column holds. The rows are windowed and grouped ONCE per body evaluation and threaded into
    /// every section: SwiftUI re-runs `body` on hover, animation and every state change.
    @ViewBuilder private var hub: some View {
        if !loaded || (!usesPreviewRows && (loadedSourceIdentity != sourceIdentity || repo.verifiedExternalSurfaceFenced)) {
            WorkoutHistorySkeleton()
        } else if allRows.isEmpty {
            emptyHub
        } else {
            populatedHub
        }
    }

    @ViewBuilder private var populatedHub: some View {
        let resolved = effectiveRange
        let rows = WorkoutHistoryScope.filter(sessions(for: resolved), scope: historyScope)
        let derived = currentDerived
        // Nothing in this view (an empty Archived, or filters that match nothing) has nothing to chart: the history
        // below says so, rather than a week of dots that, in Archived, would not even be one of its weeks.
        if !rows.isEmpty {
            WorkoutHistoryChart(rows: rows, anchor: chartAnchor(rows: rows))
            FlatSectionSeparator.beforeChipHeader
        }
        history(rows: rows, effectiveRange: resolved)
        if historyScope == .current {
            chipButton("View older workouts", systemImage: "clock.arrow.circlepath") { historyScope = .archived }
                .padding(.vertical, NoopMetrics.space2)
                .accessibilityIdentifier("workouts.olderHistory")
        }
        if historyScope == .archived, loadedWindowDays != nil, !expandingHistory {
            chipButton("Load older history", systemImage: "arrow.down") {
                Task { await expandWindowIfNeeded(for: .all) }
            }
            .padding(.vertical, NoopMetrics.space2)
        }
        if expandingHistory { olderHistoryLoading }
        FlatSectionSeparator()
        WorkoutsDisclosureRow(title: "Training tools and summaries", isExpanded: $showTrainingTools)
        if showTrainingTools {
            VStack(alignment: .leading, spacing: 0) {
                FlatSectionSeparator()
                WorkoutsWeekSection(week: derived.week) { EmptyView() }
                FlatSectionSeparator()
                WorkoutsLiftSection(lastLift: lastLift) { liftDestination = $0 }
                FlatSectionSeparator()
                WorkoutZonesSection(phase: publishedZonesKey == zonesKey ? zonesPhase : .pending, zoneSet: zoneSet,
                                    windowCaption: resolved.caption)
                if let paceRow = rows.first(where: { WorkoutPace.perUnit($0, system: unitSystem) != nil }),
                   let pace = WorkoutPace.perUnit(paceRow, system: unitSystem) {
                    FlatSectionSeparator()
                    WorkoutPaceSection(row: paceRow, pace: pace, unitSystem: unitSystem)
                }
            }
            .transition(.softCard(reduced: reduceMotion))
        }
    }

    /// No workouts at all: the empty state leads (nothing to chart, so no chart), then the ways to add one, a look
    /// further back when only the first-paint window was read, and the Lift entry points.
    @ViewBuilder private var emptyHub: some View {
        WorkoutEmptyState(
            symbol: "figure.run", title: "No workouts yet",
            message: "They come from your WHOOP and Apple Health history. Import in Data Sources to bring them in, or add one you tracked elsewhere.")
        ChipRow {
            addChip
            if !usesPreviewRows, loadedWindowDays != nil {
                chipButton("Check older history", systemImage: "clock.arrow.circlepath") {
                    historyScope = .archived
                    Task { await expandWindowIfNeeded(for: .all) }
                }
            }
        }
        .frame(maxWidth: .infinity)
        if expandingHistory { olderHistoryLoading.frame(maxWidth: .infinity) }
        FlatSectionSeparator()
        WorkoutsLiftSection(lastLift: lastLift) { liftDestination = $0 }
    }

    /// The quiet line while the full history is read.
    private var olderHistoryLoading: some View {
        HStack(spacing: NoopMetrics.space2) {
            ProgressView().controlSize(.small)
            Text("Loading older workouts…")
                .font(StrandFont.footnote)
                .foregroundStyle(StrandPalette.textSecondary)
        }
        .padding(.vertical, NoopMetrics.space3)
        .accessibilityElement(children: .combine)
    }

    /// The day the minutes section ends on: today in Recent, the newest archived session's day in Archived.
    private func chartAnchor(rows: [WorkoutRow]) -> Date {
        let calendar = Calendar.current
        guard historyScope == .archived, let newest = rows.map(\.startTs).max() else {
            return calendar.startOfDay(for: Date())
        }
        return calendar.startOfDay(for: Date(timeIntervalSince1970: TimeInterval(newest)))
    }

    /// Add a workout tracked elsewhere: a hairline chip. Starting one is the header's solid pill.
    private var addChip: some View {
        Button { sheet = WorkoutSheetTarget(editing: nil) } label: {
            WidgetChip(appTitle: "Add", systemImage: "plus", showsChevron: false, overhangs: false)
                .chipHitTarget()
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Add a workout")
        .accessibilityIdentifier("workouts.add")
    }

    /// A secondary action as a hairline chip.
    private func chipButton(_ title: LocalizedStringKey, systemImage: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            WidgetChip(appTitle: title, systemImage: systemImage, showsChevron: false, overhangs: false)
                .chipHitTarget()
        }
        .buttonStyle(.plain)
    }

    /// The heart-rate zones the hub's zone section describes, from the profile's max heart rate.
    private var zoneSet: HRZoneSet? {
        model.profile.hrMax > 0 ? HRZones.zones(maxHR: Double(model.profile.hrMax), source: "profile") : nil
    }

    /// What the zone section depends on. A change reruns the parse; typing in the search field does not, until the
    /// filtered set actually changes.
    private struct ZonesKey: Equatable {
        let generation: Int
        let range: Range
        let sport: String?
        let source: WorkoutOrigin?
        let search: String
        let scope: WorkoutHistoryScope
    }

    private var zonesKey: ZonesKey {
        ZonesKey(generation: rowsGeneration, range: range,
                 sport: sportFilter, source: sourceFilter, search: searchText, scope: historyScope)
    }

    // MARK: - Post-log activity-cost note (#439)

    /// After a manual save / relabel, look up whether `sport` has a solid/building ActivityCost entry
    /// (n ≥ minSessions) and, if so, show its plain-English sentence as a transient caption that
    /// auto-clears. Copy is "usually"/"personal pattern" framed (the engine's own wording) — never a
    /// law. Computes off the freshly reloaded sessions + the merged daily Charge.
    private func showPostLogNote(forSport sport: String) async {
        let costs = InsightsView.computeActivityCosts(workouts: allRows, days: repo.days)
        guard let match = costs.first(where: { $0.sport == sport }) else {
            await MainActor.run {
                postLogGeneration &+= 1
                postLogNote = nil
            }
            return
        }
        let sentence = match.sentence()
        let generation = await MainActor.run { () -> Int in
            postLogGeneration &+= 1
            withAnimation(.easeOut(duration: 0.2)) { postLogNote = sentence }
            return postLogGeneration
        }
        // Auto-dismiss after a few seconds (transient caption, not a permanent card).
        try? await Task.sleep(nanoseconds: 7_000_000_000)
        await MainActor.run {
            if postLogGeneration == generation {
                withAnimation(.easeOut(duration: 0.2)) { postLogNote = nil }
            }
        }
    }

    /// Presentation is owner-controlled: `showPostLogNote` remains the sole seven-second timer and its
    /// generation check prevents an older task (including one with identical copy) dismissing a newer note.
    private var postLogToastPresented: Binding<Bool> {
        Binding(
            get: { postLogNote != nil },
            set: { presented in
                guard !presented else { return }
                postLogNote = nil
            }
        )
    }

    // MARK: - Row actions (edit · relabel · dismiss · delete)

    private func editWorkout(_ row: WorkoutRow) { sheet = WorkoutSheetTarget(editing: row) }

    private func relabel(_ row: WorkoutRow, to sport: String) {
        Task {
            await repo.relabelDetected(row, sport: sport)
            await reload()
            await showPostLogNote(forSport: WorkoutSource.displaySport(sport))
        }
    }

    private func dismiss(_ row: WorkoutRow) {
        Task { await repo.dismissDetected(row); await reload() }
    }

    private func delete(_ row: WorkoutRow) {
        // #524: also drop any on-device GPS route stored under this session's natural key, so deleting a
        // workout doesn't leave its route orphaned in the RouteStore side-store.
        RouteStore.remove(startTs: row.startTs, sport: row.sport)
        WorkoutPauseStore.remove(startTs: row.startTs, sport: row.sport)
        Task { await repo.deleteWorkout(row); await reload() }
    }

    /// Common sports offered when re-labelling a detected bout (keeps the menu short and honest —
    /// the user can fine-tune via Edit afterwards).
    private static let relabelSports = ["Running", "Walking", "Cycling", "Strength Training",
                                        "Swimming", "Rowing", "Yoga", "HIIT",
                                        "CrossFit", "Hiking", "Tennis"]

    // MARK: - History

    /// The history: a header with its controls, then one lazily-built child per session. The rows are children of
    /// the page's own lazy stack, not a lazy stack of their own: a lazy stack inside a lazy stack mis-measures the
    /// section above its rows, and a long history only builds the rows on screen this way.
    @ViewBuilder
    private func history(rows: [WorkoutRow], effectiveRange: Range) -> some View {
        FlatSection("History", systemImage: "list.bullet.rectangle", tint: .workout,
                    trailing: .custom(AnyView(historyChips(rows: rows)))) {
            VStack(alignment: .leading, spacing: WidgetMetrics.contentSpacing) {
                controls(rows: rows, effectiveRange: effectiveRange)
                if selectionMode { selectionToolbar(rows: rows) }
            }
        }
        if rows.isEmpty {
            Text("No sessions in this view")
                .font(StrandFont.footnote)
                .foregroundStyle(StrandPalette.textTertiary)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.vertical, NoopMetrics.space3)
        } else {
            ForEach(WorkoutHistoryDay.grouped(rows)) { group in
                dayHeader(group)
                ForEach(Array(group.rows.enumerated()), id: \.element.listID) { index, row in
                    VStack(spacing: 0) {
                        if index > 0 { WorkoutFlatRowSeparator(leadingExtra: selectionMode ? Self.selectionColumnWidth : 0) }
                        sessionRow(row)
                    }
                }
            }
        }
    }

    /// The History header's chips: Add, and Select while a row can be selected.
    private func historyChips(rows: [WorkoutRow]) -> some View {
        ChipRow {
            addChip
            selectChip(rows: rows)
        }
    }

    /// A day's header in the feed: the day in the one format rows and sections use ("Today", "Yesterday",
    /// "Mon, Oct 12", the year only for an earlier year) and its session count. One spoken heading.
    private func dayHeader(_ group: WorkoutHistoryDay) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: NoopMetrics.space2) {
            Text(verbatim: WorkoutFormat.day(group.day))
                .font(StrandFont.subhead.weight(.semibold))
                .foregroundStyle(StrandPalette.textPrimary)
            Spacer(minLength: NoopMetrics.space2)
            Text("\(group.rows.count) sessions")
                .font(StrandFont.micro)
                .foregroundStyle(StrandPalette.textTertiary)
        }
        .padding(.top, NoopMetrics.space4)
        .padding(.bottom, NoopMetrics.space1)
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isHeader)
    }

    /// The scope and range pills, the sport and source filters, the search field and the one-line count.
    private func controls(rows: [WorkoutRow], effectiveRange: Range) -> some View {
        // At accessibility sizes the scope control and the Filters chip each take a line, so neither is squeezed.
        let scopeLayout = typeSize.isAccessibilitySize
            ? AnyLayout(VStackLayout(alignment: .leading, spacing: NoopMetrics.space3))
            : AnyLayout(HStackLayout(alignment: .center, spacing: NoopMetrics.space2))
        return VStack(alignment: .leading, spacing: NoopMetrics.space2) {
            scopeLayout {
                SegmentedPillControl(WorkoutHistoryScope.allCases, selection: $historyScope) { scope in
                    scope == .current ? String(localized: "Recent") : String(localized: "Archived")
                }
                if !typeSize.isAccessibilitySize { Spacer(minLength: NoopMetrics.space2) }
                Button {
                    withAnimation(NoopMotion.gated(StrandMotion.interactive, reduced: reduceMotion)) {
                        showHistoryFilters.toggle()
                    }
                } label: {
                    WidgetChip(appTitle: filter.isActive ? "Filters on" : "Filters",
                               systemImage: "line.3.horizontal.decrease", showsChevron: false, overhangs: false)
                        .chipHitTarget()
                }
                .buttonStyle(.plain)
                .accessibilityValue(showHistoryFilters ? Text("Expanded") : Text("Collapsed"))
            }
            Text(verbatim: rangeCaption(count: rows.count, effectiveRange: effectiveRange))
                .font(StrandFont.footnote).foregroundStyle(StrandPalette.textTertiary)
            if showHistoryFilters {
                VStack(alignment: .leading, spacing: NoopMetrics.space2) {
                    Text("Recent contains the last 90 days. Archived sessions stay saved.")
                        .font(StrandFont.footnote).foregroundStyle(StrandPalette.textTertiary)
                        .fixedSize(horizontal: false, vertical: true)
                    SegmentedPillControl(Range.allCases, selection: $range) { $0.label }
                    filterBar
                }
                .transition(.softCard(reduced: reduceMotion))
            }
            if effectiveRange != range {
                Text("Few sessions in that range, so this shows \(effectiveRange.caption).")
                    .font(StrandFont.footnote).foregroundStyle(StrandPalette.statusWarning)
            }
        }
    }

    /// #64: filter controls: a Sport menu, a Source menu, a search field, and a Clear chip that appears only when a
    /// filter is active. The predicate is the pure `WorkoutFilter`; these controls only drive its state.
    private var filterBar: some View {
        VStack(alignment: .leading, spacing: NoopMetrics.space2) {
            ChipRow {
                filterMenu(
                    title: sportFilter ?? String(localized: "All sports"),
                    active: sportFilter != nil,
                    a11y: String(localized: "Filter by sport")
                ) {
                    Button(String(localized: "All sports")) { sportFilter = nil }
                    Divider()
                    ForEach(availableSports, id: \.self) { s in
                        Button(s) { sportFilter = s }
                    }
                }
                filterMenu(
                    title: sourceFilter.map(Self.sourceFilterLabel) ?? String(localized: "All sources"),
                    active: sourceFilter != nil,
                    a11y: String(localized: "Filter by source")
                ) {
                    Button(String(localized: "All sources")) { sourceFilter = nil }
                    Divider()
                    ForEach(Self.sourceFilterOptions, id: \.self) { opt in
                        Button(Self.sourceFilterLabel(opt)) { sourceFilter = opt }
                    }
                }
                if filter.isActive {
                    Button {
                        withAnimation(NoopMotion.gated(.easeOut(duration: 0.15), reduced: reduceMotion)) {
                            sportFilter = nil; sourceFilter = nil; searchText = ""
                        }
                    } label: {
                        WidgetChip(appTitle: "Clear", systemImage: "xmark", showsChevron: false, overhangs: false)
                            .chipHitTarget()
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Clear filters")
                }
            }
            PaperSearchField("Search sport", text: $searchText, height: 44, cornerRadius: 10)
                #if os(iOS)
                .autocorrectionDisabled()
                .textInputAutocapitalization(.never)
                #endif
        }
    }

    /// A chip that opens a menu: the current selection as its label, filled with the brand ink when a filter is
    /// active so the narrowed list is obvious at a glance.
    private func filterMenu<Content: View>(title: String, active: Bool, a11y: String,
                                           @ViewBuilder content: () -> Content) -> some View {
        Menu {
            content()
        } label: {
            WidgetChip(verbatimTitle: title, opensMenu: true, isSelected: active)
                .chipHitTarget()
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
        .accessibilityLabel(a11y)
        .accessibilityValue(title)
    }

    /// The origins offered in the Source filter (imported + on-device), in a stable menu order.
    private static let sourceFilterOptions: [WorkoutOrigin] =
        [.whoop, .apple, .recorded, .detected, .manual, .lifting, .activityFile]

    /// The Source-filter menu label for an origin.
    private static func sourceFilterLabel(_ c: WorkoutOrigin) -> String {
        switch c {
        case .whoop:        return String(localized: "Whoop")
        case .apple:        return String(localized: "Apple")
        case .recorded:     return String(localized: "Recorded")
        case .detected:     return String(localized: "Detected")
        case .manual:       return String(localized: "Manual")
        case .lifting:      return String(localized: "Lifting")
        case .activityFile: return String(localized: "File")
        }
    }

    // MARK: Session rows

    /// One session: tap opens its detail (or toggles it in selection mode). The row actions are a long-press menu, a quiet
    /// ••• on rows that have edit paths (manual and detected: the only visible way to Edit or Re-label), and named
    /// VoiceOver actions on the row itself. In selection mode a leading checkmark (mergeable rows) or a lock (imported,
    /// read-only) marks each row.
    /// Every row sits under its day header, so it shows its time, not the day again.
    private func sessionRow(_ row: WorkoutRow) -> some View {
        let selectable = WorkoutMerge.isMergeable(row)
        let isSelected = selected.contains(selectionKey(row))
        let presentation = WorkoutRowPresentation.make(
            row, unitSystem: unitSystem, when: .time, detail: .full, includesSource: true)
        return HStack(spacing: 0) {
            Button {
                if selectionMode {
                    guard selectable else { return }
                    withAnimation(NoopMotion.gated(.easeOut(duration: 0.12), reduced: reduceMotion)) { toggleSelection(row) }
                } else {
                    openDetail(row)
                }
            } label: {
                // The glyph is part of the button, so tapping the checkmark selects the row like tapping its text.
                HStack(spacing: 0) {
                    if selectionMode {
                        selectionGlyph(selectable: selectable, isSelected: isSelected)
                            .frame(width: Self.selectionColumnWidth)
                    }
                    WorkoutFlatRow(presentation: presentation)
                }
            }
            .buttonStyle(PaperPressStyle())
            .accessibilityValue(selectionMode
                ? (isSelected ? Text("Selected") : Text("Not selected"))
                : Text(verbatim: ""))
            .accessibilityHint(selectionMode
                ? (selectable ? Text("Double-tap to select") : Text("Imported history can't be merged"))
                : Text("Opens workout detail"))
            .accessibilityActions { if !selectionMode { rowAccessibilityActions(row) } }
            if !selectionMode, selectable { rowActionsMenu(row) }
        }
        .contextMenu { if !selectionMode { rowMenu(row) } }
    }

    /// A quiet ••• for the rows whose actions (Edit, Re-label, Dismiss, Delete) have no other visible path. Imported rows
    /// have only Duplicate, which stays a long-press and a VoiceOver action, so they carry no extra control.
    private func rowActionsMenu(_ row: WorkoutRow) -> some View {
        Menu {
            rowMenu(row)
        } label: {
            Image(systemName: "ellipsis")
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(StrandPalette.textTertiary)
                .frame(width: 44, height: 44)
                .contentShape(Rectangle())
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .accessibilityLabel("Workout actions")
    }

    /// The same actions as `rowMenu`, as named VoiceOver actions on the row (a context menu adds none, and a sub-menu
    /// cannot be opened from an action, so each re-label sport is its own action).
    @ViewBuilder
    private func rowAccessibilityActions(_ row: WorkoutRow) -> some View {
        switch WorkoutSource.classify(row.source) {
        case .detected:
            ForEach(Self.relabelSports, id: \.self) { sport in
                Button { relabel(row, to: sport) } label: {
                    Text(verbatim: "\(String(localized: "Re-label as")) \(sport)")
                }
            }
            Button("Edit details…") { editWorkout(row) }
            Button("Dismiss (not a workout)") { dismiss(row) }
        case .manual:
            Button("Edit…") { editWorkout(row) }
            Button("Delete") { delete(row) }
        case .whoop, .apple, .lifting, .activityFile:
            Button("Duplicate as manual…") { editWorkout(asManualCopy(row)) }
        }
    }

    /// The width of the selection glyph's column, which the separators between rows start after.
    private static let selectionColumnWidth: CGFloat = 36

    /// The leading selection glyph: a filled/hollow checkmark for a mergeable row, or a lock for imported
    /// history (which can never be merged or bulk-deleted).
    @ViewBuilder
    private func selectionGlyph(selectable: Bool, isSelected: Bool) -> some View {
        if selectable {
            Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                .font(.system(size: 20, weight: .regular))
                .foregroundStyle(isSelected ? DomainTint.workout.accent : StrandPalette.textTertiary)
                .accessibilityHidden(true)
        } else {
            Image(systemName: "lock.fill")
                .font(.system(size: 14, weight: .regular))
                .foregroundStyle(StrandPalette.textTertiary.opacity(0.6))
                .accessibilityHidden(true)
        }
    }

    /// Toggle one row's selection (mergeable rows only).
    private func toggleSelection(_ row: WorkoutRow) {
        let key = selectionKey(row)
        if selected.contains(key) { selected.remove(key) } else { selected.insert(key) }
    }

    /// Context-menu actions per row. A DETECTED bout can be re-labelled (becomes a real manual session
    /// that survives re-detection) or dismissed (durably hidden). A MANUAL session can be edited or
    /// deleted. Imported WHOOP / Apple rows are read-only (we never rewrite imported history).
    @ViewBuilder
    private func rowMenu(_ row: WorkoutRow) -> some View {
        switch WorkoutSource.classify(row.source) {
        case .detected:
            Menu("Re-label as") {
                ForEach(Self.relabelSports, id: \.self) { sport in
                    Button(sport) { relabel(row, to: sport) }
                }
            }
            Button("Edit details…") { editWorkout(row) }
            Divider()
            Button("Dismiss (not a workout)", role: .destructive) { dismiss(row) }
        case .manual:
            Button("Edit…") { editWorkout(row) }
            Divider()
            Button("Delete", role: .destructive) { delete(row) }
        case .whoop, .apple, .lifting, .activityFile:
            // Imported history is read-only; offer a copy-to-manual edit path that doesn't touch it.
            Button("Duplicate as manual…") { editWorkout(asManualCopy(row)) }
        }
    }

    /// A manual-source copy of an imported row, so "Duplicate as manual" opens the add sheet pre-filled
    /// without ever mutating the imported original (the sheet saves under the strap source).
    private func asManualCopy(_ row: WorkoutRow) -> WorkoutRow {
        row.replacing(sport: WorkoutSource.displaySport(row.sport), source: "manual")
    }

    // MARK: Selection (#64)

    /// The "Select" chip in the History header toggles multi-select mode. Only shown when at least one row is
    /// selectable (manual / detected); a pure-imported list has nothing to merge or bulk-delete.
    @ViewBuilder
    private func selectChip(rows: [WorkoutRow]) -> some View {
        if rows.contains(where: WorkoutMerge.isMergeable) {
            Button {
                withAnimation(NoopMotion.gated(.easeOut(duration: 0.15), reduced: reduceMotion)) {
                    selectionMode.toggle()
                    if !selectionMode { selected.removeAll() }
                }
            } label: {
                Group {
                    if selectionMode {
                        WidgetChip(appTitle: "Done", showsChevron: false, overhangs: false)
                    } else {
                        WidgetChip(appTitle: "Select", showsChevron: false, overhangs: false)
                    }
                }
                .chipHitTarget()
            }
            .buttonStyle(.plain)
            .accessibilityLabel(selectionMode
                ? Text("Finish selecting")
                : Text("Select sessions to merge or delete"))
        }
    }

    /// #64: the Merge / Delete / Cancel strip shown above the list in selection mode. Merge needs 2+
    /// eligible rows; Delete needs 1+. Plain hairline chips: the header's Start is the one solid control on this page.
    private func selectionToolbar(rows: [WorkoutRow]) -> some View {
        let chosen = rows.filter { selected.contains(selectionKey($0)) }
        let canMerge = WorkoutMerge.canMerge(chosen)
        return ChipRow {
            Button {
                beginMerge(chosen)
            } label: {
                WidgetChip(verbatimTitle: String(localized: "Merge (\(chosen.count))"),
                           systemImage: "arrow.triangle.merge", showsChevron: false)
                    .chipHitTarget()
            }
            .buttonStyle(.plain)
            .disabled(!canMerge)
            .opacity(canMerge ? 1 : 0.45)

            Button(role: .destructive) {
                let toDelete = chosen
                selectionMode = false; selected.removeAll()
                Task { await repo.bulkDeleteWorkouts(toDelete); await reload() }
            } label: {
                WidgetChip(verbatimTitle: String(localized: "Delete (\(chosen.count))"),
                           systemImage: "trash", showsChevron: false)
                    .chipHitTarget()
            }
            .buttonStyle(.plain)
            .disabled(chosen.isEmpty)
            .opacity(chosen.isEmpty ? 0.45 : 1)

            Button {
                withAnimation(NoopMotion.gated(.easeOut(duration: 0.15), reduced: reduceMotion)) { selectionMode = false; selected.removeAll() }
            } label: {
                WidgetChip(appTitle: "Cancel", showsChevron: false, overhangs: false)
                    .chipHitTarget()
            }
            .buttonStyle(.plain)
        }
    }

    /// Start a merge: if the chosen rows carry a real sport, merge straight away; if every one is a bare
    /// detected bout, prompt the user to name the merged session first.
    private func beginMerge(_ chosen: [WorkoutRow]) {
        guard WorkoutMerge.canMerge(chosen) else { return }
        if WorkoutMerge.resolvedSport(chosen) == nil {
            mergeSportPrompt = MergeSportTarget(rows: chosen)
        } else {
            performMerge(chosen, sport: nil)
        }
    }

    /// Commit a merge through the repository (manual-row path), then rescore + reload. Leaves selection
    /// mode. Imported rows can never reach here (canMerge gates on manual/detected).
    private func performMerge(_ chosen: [WorkoutRow], sport: String?) {
        guard let merged = WorkoutMerge.merge(chosen, sport: sport) else { return }
        selectionMode = false; selected.removeAll(); mergeSportPrompt = nil
        Task {
            await repo.mergeWorkouts(chosen, into: merged)
            await model.intelligence.analyzeRecent()
            await reload()
        }
    }

    // MARK: - Windowing + filtering

    /// The latest session start (anchors every window — windows are relative to the
    /// most recent session, not "now", so an old log still resolves).
    private var latestTs: Int? { allRows.map(\.startTs).max() }

    private func calendarCutoff(anchor: Int, daysBack: Int) -> Int {
        let anchorDate = Date(timeIntervalSince1970: TimeInterval(anchor))
        let cutoffDate = Repository.dateByAddingCalendarDays(-max(0, daysBack), to: anchorDate)
        return Int(cutoffDate.timeIntervalSince1970)
    }

    /// The active filter (#64), composed once. Sport / source / search all apply AFTER the window cut,
    /// so the zones and the list all read one filtered set.
    private var filter: WorkoutFilter {
        WorkoutFilter(sport: sportFilter, origin: sourceFilter, search: searchText)
    }

    /// Sessions inside a given range, RELATIVE TO THE LATEST session, then passed through the active
    /// filter. `.all` = all. The window anchor (`latestTs`) is the newest of ALL loaded rows so the
    /// window doesn't shift when a filter narrows the set.
    private func sessions(for r: Range) -> [WorkoutRow] {
        let windowed: [WorkoutRow]
        if let days = r.days {
            guard let last = latestTs else { return [] }
            let cutoff = calendarCutoff(anchor: last, daysBack: days)
            windowed = allRows.filter { $0.startTs >= cutoff }
        } else {
            windowed = allRows
        }
        return filter.apply(windowed)
    }

    /// The set of displayed-sport names present across ALL loaded rows, for the sport-filter menu.
    /// Ordered by frequency (desc) so the common sports sit at the top.
    private var availableSports: [String] {
        var counts: [String: Int] = [:]
        for r in allRows { counts[WorkoutSource.displaySport(r.sport), default: 0] += 1 }
        return counts.sorted { ($0.value, $1.key) > ($1.value, $0.key) }.map(\.key)
    }

    /// The range actually shown: the SELECTED range when it holds ≥1 session, else
    /// the smallest LARGER range that does — so switching ranges stays visibly
    /// distinct and only an empty window widens.
    private var effectiveRange: Range {
        guard !allRows.isEmpty else { return range }
        for r in range.widening where !sessions(for: r).isEmpty { return r }
        return .all
    }

    /// "12 sessions · last 30 days". The count is a plural in the string catalog.
    private func rangeCaption(count: Int, effectiveRange: Range) -> String {
        String(localized: "\(count) sessions · \(effectiveRange.caption)")
    }

    /// History starts with the full recent window rather than a range containing only two sessions.
    private func defaultRange(for source: [WorkoutRow]) -> Range { .quarter }

    // MARK: - Range model

    private enum Range: CaseIterable, Hashable {
        case week, month, quarter, year, all
        var label: String {
            switch self {
            case .week:    return String(localized: "7D")
            case .month:   return String(localized: "30D")
            case .quarter: return String(localized: "90D")
            case .year:    return String(localized: "1Y")
            case .all:     return String(localized: "All")
            }
        }
        var caption: String {
            switch self {
            case .week:    return String(localized: "last 7 days")
            case .month:   return String(localized: "last 30 days")
            case .quarter: return String(localized: "last 90 days")
            case .year:    return String(localized: "last year")
            case .all:     return String(localized: "all time")
            }
        }
        /// Trailing-window length in days, or nil for "all".
        var days: Int? {
            switch self {
            case .week:    return 7
            case .month:   return 30
            case .quarter: return 90
            case .year:    return 365
            case .all:     return nil
            }
        }
        /// This range plus every LARGER range, ascending — the auto-expand search
        /// order when the selected window holds zero sessions.
        var widening: [Range] {
            let order: [Range] = [.week, .month, .quarter, .year, .all]
            guard let i = order.firstIndex(of: self) else { return [.all] }
            return Array(order[i...])
        }
    }
}

/// The header's one solid action, Today's Start pill: Start, or Open while a workout is running. It observes
/// active-workout state itself, so only this control rebuilds when that changes.
private struct WorkoutsStartPill: View {
    @ObservedObject var model: AppModel
    let onStart: () -> Void
    let onOpen: () -> Void

    private var hasActiveWorkout: Bool { model.activeWorkout != nil }

    var body: some View {
        Button(action: openWorkout) {
            Group {
                if hasActiveWorkout { Text("Open") } else { Text("Start") }
            }
            .lineLimit(1)
            .fixedSize()
        }
        .buttonStyle(WorkoutStartPillStyle())
        .accessibilityLabel(hasActiveWorkout ? "View the active workout" : "Start a workout")
        .accessibilityIdentifier("workouts.startWorkout")
    }

    private func openWorkout() {
        if hasActiveWorkout {
            onOpen()
        } else {
            onStart()
        }
    }
}

/// Today's Start pill: the brand ink capsule with dark type. The one definition for this screen and the Quick Actions
/// sheet (the Today original is private to StrandDesign). The tap area reaches 44pt without growing the header row.
struct WorkoutStartPillStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .workoutStartPillChrome()
            .contentShape(Rectangle().inset(by: -8))
            .opacity(configuration.isPressed ? 0.78 : 1)
    }
}

extension View {
    /// The Start pill's look: caption-semibold dark type on a brand-ink capsule.
    func workoutStartPillChrome() -> some View {
        self.font(StrandFont.caption.weight(.semibold))
            .foregroundStyle(StrandPalette.appCanvas)
            .padding(.horizontal, 12)
            .padding(.vertical, 7)
            .background(StrandPalette.ink, in: Capsule(style: .continuous))
    }
}

#if os(iOS)
/// A solid canvas strip over the status bar's safe area, so rows that scroll up never show through the clock. Nothing
/// when the screen has no top inset (a sheet).
private struct TopSafeAreaScrim: ViewModifier {
    func body(content: Content) -> some View {
        content.overlay(alignment: .top) {
            // Painted into the top inset with no measuring; zero height, so a sheet (no inset) shows nothing.
            StrandPalette.appCanvas.ignoresSafeArea(edges: .top).frame(height: 0)
                .allowsHitTesting(false)
                .accessibilityHidden(true)
        }
    }
}
#endif

#if DEBUG
@MainActor
private func previewWorkoutRows() -> [WorkoutRow] {
    let now = Int(Date().timeIntervalSince1970)
    let elapsedDaySeconds = 24 * 60 * 60
    return [
        WorkoutRow(startTs: now - elapsedDaySeconds * 0 - 3600, endTs: now - elapsedDaySeconds * 0,
                   sport: "Running", source: "whoop", durationS: 3600, energyKcal: 712,
                   avgHr: 152, maxHr: 178, strain: 14.2, distanceM: 10_400,
                   zonesJSON: #"{"z1":12.5,"z2":28.0,"z3":33.5,"z4":18.0,"z5":6.0}"#, notes: nil),
        WorkoutRow(startTs: now - elapsedDaySeconds * 1 - 2700, endTs: now - elapsedDaySeconds * 1,
                   sport: "Strength Training", source: "whoop", durationS: 2700, energyKcal: 388,
                   avgHr: 118, maxHr: 156, strain: 9.4, distanceM: nil,
                   zonesJSON: nil, notes: nil),
        WorkoutRow(startTs: now - elapsedDaySeconds * 2 - 1800, endTs: now - elapsedDaySeconds * 2,
                   sport: "Cycling", source: "apple_health", durationS: 1800, energyKcal: 240,
                   avgHr: nil, maxHr: nil, strain: nil, distanceM: 12_800,
                   zonesJSON: nil, notes: nil),
        WorkoutRow(startTs: now - elapsedDaySeconds * 3 - 1500, endTs: now - elapsedDaySeconds * 3,
                   sport: "Running", source: "apple_health", durationS: 1500, energyKcal: 310,
                   avgHr: nil, maxHr: nil, strain: nil, distanceM: 5_100,
                   zonesJSON: nil, notes: nil),
        WorkoutRow(startTs: now - elapsedDaySeconds * 4 - 3300, endTs: now - elapsedDaySeconds * 4,
                   sport: "Cycling", source: "whoop", durationS: 3300, energyKcal: 540,
                   avgHr: 134, maxHr: 162, strain: 11.8, distanceM: 24_600,
                   // Android key shape on purpose — exercises the cross-platform parser.
                   zonesJSON: #"{"zone1":20.0,"zone2":35.0,"zone3":30.0,"zone4":10.0}"#, notes: nil),
        WorkoutRow(startTs: now - elapsedDaySeconds * 6 - 2400, endTs: now - elapsedDaySeconds * 6,
                   sport: "Yoga", source: "whoop", durationS: 2400, energyKcal: 165,
                   avgHr: 92, maxHr: 118, strain: 5.1, distanceM: nil,
                   zonesJSON: nil, notes: nil),
    ]
}

#Preview("Workouts") {
    WorkoutsView(previewRows: previewWorkoutRows())
        .environmentObject(Repository(deviceId: "preview"))
        .frame(width: 1040, height: 940)
        .preferredColorScheme(.dark)
}

#Preview("Workouts — empty") {
    WorkoutsView(previewRows: [])
        .environmentObject(Repository(deviceId: "preview"))
        .frame(width: 1040, height: 600)
        .preferredColorScheme(.dark)
}
#endif
