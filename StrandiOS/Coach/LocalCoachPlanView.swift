#if os(iOS)
import SwiftUI
import StrandDesign

struct LocalCoachPlanView: View {
    @EnvironmentObject private var coach: LocalCoachEngine
    @State private var editing: PlanEdit?
    @State private var confirmSave = false
    @State private var showWorkouts = false
    @State private var summaryExpanded = false
    @Environment(\.dynamicTypeSize) private var typeSize
    @ScaledMetric(relativeTo: .caption) private var stepDiameter: CGFloat = 24
    @ScaledMetric(relativeTo: .title) private var titleSize: CGFloat = 29
    @ScaledMetric(relativeTo: .title3) private var dayTitleSize: CGFloat = 20
    @ScaledMetric(relativeTo: .footnote) private var dayMinutesSize: CGFloat = 14
    @ScaledMetric(relativeTo: .subheadline) private var linkSize: CGFloat = 15
    let onBuild: () -> Void

    /// The exercise being tuned and the day it belongs to, so the edit lands on the right session.
    private struct PlanEdit: Identifiable {
        let dayID: UUID
        let exercise: LocalCoachPlannedExercise
        var id: UUID { exercise.id }
    }

    /// The mockup's page gutter for the plan: 20pt either side.
    private let gutter = NoopMetrics.space5

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                if let plan = coach.plan {
                    planHeader(plan)
                    ForEach(Array(plan.days.enumerated()), id: \.element.id) { index, day in
                        if index > 0 { FlatSectionSeparator.coach.padding(.horizontal, gutter) }
                        daySection(day, in: plan, isFirst: index == 0)
                    }
                    Text("Tap an exercise to adjust sets, reps, rest or notes. Start with a load you can control.")
                        .font(StrandFont.footnote).foregroundStyle(StrandPalette.textTertiary)
                        .padding(.horizontal, gutter)
                        .padding(.top, NoopMetrics.space4)
                    // At accessibility sizes the bar would take much of the screen, so the actions end the page instead.
                    if typeSize.isAccessibilitySize {
                        actionButtons(plan).padding(.horizontal, NoopMetrics.space4).padding(.top, NoopMetrics.space4)
                    }
                } else {
                    emptyPlan.padding(.horizontal, NoopMetrics.space4)
                }
            }
            .padding(.top, coach.plan == nil ? CoachRhythm.pageTop : 6)
            .padding(.bottom, CoachRhythm.pageBottom)
        }
        // The one action rides above the list on a fade, like the mockup's: rows slide away under it instead of
        // stopping at a hard edge.
        .safeAreaInset(edge: .bottom, spacing: 0) {
            if let plan = coach.plan, !typeSize.isAccessibilitySize { actionBar(plan) }
        }
        .sheet(item: $editing) { edit in
            LocalCoachExerciseEditor(exercise: edit.exercise) { edited in
                guard var plan = coach.plan, let dayIndex = plan.days.firstIndex(where: { $0.id == edit.dayID }),
                      let exerciseIndex = plan.days[dayIndex].exercises.firstIndex(where: { $0.id == edited.id }) else { return }
                plan.days[dayIndex].exercises[exerciseIndex] = edited
                coach.updatePlan(plan)
            }
            .noopSheetPresentation(largeFirst: true)
        }
        .sheet(isPresented: $showWorkouts) {
            NavigationStack {
                // A sheet inherits the presenter's header context (Coach is pushed from Explore, a drill-in): reset it so
                // Workouts draws its own header here, and give it the canonical close button. Workouts hides the navigation
                // bar, so a toolbar Done would never show.
                WorkoutsView()
                    .sheetScreenScaffoldEnvironment(onClose: { showWorkouts = false })
                    .background(StrandPalette.appCanvas.ignoresSafeArea())
            }
            .tint(StrandPalette.accent)
            .noopSheetPresentation(largeFirst: true)
        }
        // A workout request (Quick Actions, the Live Activity, a deep link) closes the Workouts sheet, so the workout
        // journey's cover can open at the root.
        .collapsesForWorkoutJourney($showWorkouts)
        .collapsesForWorkoutJourney($editing)
        .confirmationDialog("Save this plan to NOOP?", isPresented: $confirmSave, titleVisibility: .visible) {
            Button("Save reviewed plan") { Task { await coach.savePlan() } }
            Button("Keep reviewing", role: .cancel) { }
        } message: {
            Text("This adds the reviewed sessions to your local workout plan. It does not start or mark a workout as completed.")
        }
        .accessibilityIdentifier("coach.plan")
    }

    // MARK: Header

    /// The plan as one summary: what it is, its title and summary, and three facts. The actions that move it forward
    /// live in the bar at the foot of the page.
    private func planHeader(_ plan: LocalCoachPlan) -> some View {
        let perSession = CoachPlanText.minutesPerSession(plan.days.map(\.minutes))
        let exercises = plan.days.reduce(0) { $0 + $1.exercises.count }
        return VStack(alignment: .leading, spacing: 0) {
            SectionEyebrow(plan.saved ? "Saved to your workouts" : "Built for your review",
                           systemImage: plan.saved ? "checkmark.circle.fill" : "dumbbell", tint: .accent)
            Text(plan.title)
                .font(StrandFont.sized(titleSize, weight: .bold)).tracking(-0.6)
                .foregroundStyle(StrandPalette.textPrimary)
                .lineLimit(4).minimumScaleFactor(0.6)
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityAddTraits(.isHeader)
                .padding(.top, NoopMetrics.space3)
            // A generated summary can run long (assumptions, caveats). Keep the header calm: three lines,
            // with a chip to read the rest when it really runs past them. VoiceOver always reads all of it.
            CoachCollapsibleSummary(text: plan.summary, isExpanded: $summaryExpanded)
                .padding(.top, NoopMetrics.space2)
            Rectangle().fill(StrandPalette.hairline).frame(height: 1).accessibilityHidden(true)
                .padding(.top, NoopMetrics.space4)
            FactStrip(facts: [
                .init("Sessions", value: "\(plan.days.count)"),
                .init("Per session", value: perSession.map(String.init) ?? WidgetMetrics.missingValue,
                      unit: "min"),
                .init("Exercises", value: "\(exercises)")
            ])
            .padding(.top, 11)
        }
        .padding(.horizontal, gutter)
    }

    // MARK: Actions

    /// Save is the one primary action: a solid pill on a fade. Building another plan is a quiet line above it.
    private func actionBar(_ plan: LocalCoachPlan) -> some View {
        actionButtons(plan)
            .padding(.horizontal, NoopMetrics.space4)
            .padding(.bottom, NoopMetrics.space3)
            .background { CoachBottomFade() }
            // Solid down through the home-indicator area, so rows scrolling past never show beneath the pill.
            .background(alignment: .bottom) { StrandPalette.appCanvas.ignoresSafeArea(edges: .bottom) }
    }

    private func actionButtons(_ plan: LocalCoachPlan) -> some View {
        VStack(spacing: 0) {
            Button(action: onBuild) {
                Text("Build a different plan")
                    .font(StrandFont.sized(linkSize, weight: .semibold))
                    .foregroundStyle(StrandPalette.textSecondary)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: .infinity, minHeight: 44)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            Button {
                guard !coach.isPreview else { return }
                if plan.saved { showWorkouts = true } else { confirmSave = true }
            } label: {
                Label(plan.saved ? "Open saved workouts" : "Review & save plan",
                      systemImage: plan.saved ? "checkmark.circle" : "checkmark")
                    .labelStyle(.titleAndIcon)
            }
            .buttonStyle(CoachSolidPillButtonStyle())
            .disabled(coach.isResponding)
            .accessibilityIdentifier("coach.savePlan")
        }
    }

    // MARK: Days

    private func date(of day: LocalCoachPlanDay, in plan: LocalCoachPlan) -> Date {
        Calendar.current.date(byAdding: .day, value: day.dayOffset, to: plan.createdAt) ?? plan.createdAt
    }

    /// One session: the weekday and date as the eyebrow (a Today pill on the day itself), its title with the
    /// duration beside it, then the exercises as plain rows.
    private func daySection(_ day: LocalCoachPlanDay, in plan: LocalCoachPlan, isFirst: Bool) -> some View {
        let when = date(of: day, in: plan)
        let isToday = Calendar.current.isDateInToday(when)
        let weekday = when.formatted(.dateTime.weekday(.abbreviated))
        let monthDay = when.formatted(.dateTime.month(.abbreviated).day())
        let focus = day.focus.trimmingCharacters(in: .whitespacesAndNewlines)
        let showsFocus = !focus.isEmpty && focus.caseInsensitiveCompare(day.title) != .orderedSame
        return VStack(alignment: .leading, spacing: 0) {
            SectionEyebrow(title: "\(weekday) · \(monthDay)", systemImage: "dumbbell", tint: .workout,
                           trailing: isToday ? .pill("Today", tone: .accent) : .none)
                .padding(.horizontal, gutter)
                .padding(.top, isFirst ? 22 : 0)
            dayTitle(day)
                .padding(.horizontal, gutter)
                .padding(.top, 4)
            if showsFocus {
                Text(focus).font(StrandFont.footnote).foregroundStyle(StrandPalette.textSecondary)
                    .lineLimit(2).fixedSize(horizontal: false, vertical: true)
                    .padding(.horizontal, gutter)
                    .padding(.top, 2)
            }
            VStack(spacing: 0) {
                ForEach(Array(day.exercises.enumerated()), id: \.element.id) { index, exercise in
                    if index > 0 {
                        // Hairlines start at the text, not the picture.
                        Rectangle().fill(StrandPalette.hairline).frame(height: 1).accessibilityHidden(true)
                            .padding(.leading, CoachPlanExerciseRow.textInset).padding(.trailing, gutter)
                    }
                    Button { editing = PlanEdit(dayID: day.id, exercise: exercise) } label: {
                        CoachPlanExerciseRow(exercise: exercise)
                            .padding(.horizontal, gutter)
                    }
                    .buttonStyle(CoachRowPressStyle())
                }
            }
            .padding(.top, 4)
        }
    }

    /// "Upper body" with its duration quiet beside it, on one baseline; the duration drops under at large text sizes.
    private func dayTitle(_ day: LocalCoachPlanDay) -> some View {
        ViewThatFits(in: .horizontal) {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                dayTitleText(day)
                dayMinutes(day)
            }
            VStack(alignment: .leading, spacing: 2) {
                dayTitleText(day)
                dayMinutes(day)
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isHeader)
    }

    private func dayTitleText(_ day: LocalCoachPlanDay) -> some View {
        Text(day.title)
            .font(StrandFont.sized(dayTitleSize, weight: .semibold)).tracking(-0.3)
            .foregroundStyle(StrandPalette.textPrimary)
            .lineLimit(3).minimumScaleFactor(0.6)
    }

    private func dayMinutes(_ day: LocalCoachPlanDay) -> some View {
        Text("\(day.minutes) min")
            .font(StrandFont.sized(dayMinutesSize, weight: .medium))
            .foregroundStyle(StrandPalette.textTertiary)
            .lineLimit(1)
    }

    // MARK: Empty

    /// No plan yet: an invitation, the one action, and what happens next.
    private var emptyPlan: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: NoopMetrics.space3) {
                CoachMedallion(systemImage: "figure.strengthtraining.traditional", tint: .workout)
                Text("Make room\nfor progress.").font(StrandFont.title1)
                    .foregroundStyle(StrandPalette.textPrimary)
                Text("Build a training plan around your focus and available time. Review the exercises, adjust the details and save it to your NOOP workouts.")
                    .font(StrandFont.subhead).lineSpacing(3).foregroundStyle(StrandPalette.textSecondary)
                Button(action: onBuild) { Text("Build my plan") }
                    .buttonStyle(PrimaryPillButtonStyle())
                    .accessibilityIdentifier("coach.buildPlan")
            }
            FlatSectionSeparator.coach
            FlatSection("How it works", systemImage: "list.number", tint: .workout) {
                VStack(alignment: .leading, spacing: NoopMetrics.space3) {
                    step(1, "Pick your focus and time")
                    step(2, "Review and adjust the draft")
                    step(3, "Save it to your workouts")
                }
            }
        }
    }

    private func step(_ number: Int, _ title: LocalizedStringKey) -> some View {
        HStack(spacing: NoopMetrics.space3) {
            Text("\(number)").font(StrandFont.captionNumber)
                .foregroundStyle(DomainTint.workout.accent)
                .frame(width: stepDiameter, height: stepDiameter)
                .background(Circle().fill(DomainTint.workout.accent.opacity(0.14)))
                .accessibilityHidden(true)
            Text(title).font(StrandFont.subhead).foregroundStyle(StrandPalette.textSecondary)
        }
        .accessibilityElement(children: .combine)
    }
}


// MARK: - Header and bar chrome

/// The plan page's own header, a drill-in from Coach: back, YOUR PLAN, and the plan's state as a quiet pill. It replaces
/// the Coach header (wordmark, title, availability line) on this page only.
struct LocalCoachPlanHeader: View {
    @EnvironmentObject private var coach: LocalCoachEngine
    let onBack: () -> Void

    var body: some View {
        NoopDetailTitleRow("Your plan", backAction: onBack, backLabel: "Back to chat", backIdentifier: "coach.tab.chat") {
            if let plan = coach.plan {
                StatePill(LocalizedStringKey(plan.saved ? "Saved" : "Draft"),
                          tone: plan.saved ? .positive : .neutral, showsDot: false)
            }
        }
        .padding(.horizontal, NoopMetrics.space4)
        .padding(.vertical, NoopMetrics.space3)
        .background(StrandPalette.appCanvas)
    }
}

/// The canvas fading in from the list: transparent a little above the bar, solid behind its buttons. It reaches
/// above the bar by `reach`, so rows slide away under it instead of stopping at a hard edge.
private struct CoachBottomFade: View {
    private let reach: CGFloat = 54

    var body: some View {
        GeometryReader { proxy in
            LinearGradient(
                stops: [.init(color: StrandPalette.appCanvas.opacity(0), location: 0),
                        .init(color: StrandPalette.appCanvas, location: 0.3)],
                startPoint: .top, endPoint: .bottom)
                .frame(width: proxy.size.width, height: proxy.size.height + reach)
                .offset(y: -reach)
        }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}

/// The page's one primary action: a full-width solid ink pill, 56pt tall, with a soft ink glow. Disabled it takes the
/// standard quiet look rather than a dimmed accent.
private struct CoachSolidPillButtonStyle: ButtonStyle {
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(Font.system(.body, design: .default).weight(.bold))
            .foregroundStyle(isEnabled ? StrandPalette.onInk : StrandPalette.textTertiary)
            .multilineTextAlignment(.center)
            .frame(maxWidth: .infinity, minHeight: 56)
            .padding(.horizontal, NoopMetrics.space4)
            .background(isEnabled ? StrandPalette.ink : StrandPalette.chipFill, in: Capsule(style: .continuous))
            .shadow(color: isEnabled ? StrandPalette.ink.opacity(0.25) : .clear, radius: 15, x: 0, y: 10)
            .contentShape(Capsule(style: .continuous))
            .opacity(isEnabled && configuration.isPressed ? 0.85 : 1)
    }
}

/// A row that dims while pressed; the rows have no surface to show a press on.
private struct CoachRowPressStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label.opacity(configuration.isPressed ? 0.6 : 1)
    }
}

// MARK: - Exercise row

/// One exercise: the figure straight on the canvas (no tile), its name and equipment · rest, and the prescription on
/// the right. At accessibility text sizes the prescription drops under the name.
private struct CoachPlanExerciseRow: View {
    static let figureSize: CGFloat = 78
    /// The figure's box starts this far left of the page gutter, so the scaled picture's edge sits on it.
    static let figureOverhang: CGFloat = 6
    static let gap: CGFloat = 12
    /// Where the text starts, from the screen's left edge: the hairlines between rows start here too.
    static var textInset: CGFloat { NoopMetrics.space5 - figureOverhang + figureSize + gap }

    let exercise: LocalCoachPlannedExercise
    @Environment(\.dynamicTypeSize) private var typeSize
    @ScaledMetric(relativeTo: .body) private var nameSize: CGFloat = 16.5
    @ScaledMetric(relativeTo: .footnote) private var metaSize: CGFloat = 13
    @ScaledMetric(relativeTo: .body) private var prescriptionSize: CGFloat = 18

    var body: some View {
        HStack(spacing: Self.gap) {
            CoachExerciseThumbnail(exercise: exercise, size: Self.figureSize)
                .padding(.leading, -Self.figureOverhang)
            if typeSize.isAccessibilitySize {
                VStack(alignment: .leading, spacing: 4) {
                    details
                    prescription
                }
                Spacer(minLength: 0)
            } else {
                details
                Spacer(minLength: NoopMetrics.space2)
                // The prescription is never cut short; the name beside it wraps instead.
                prescription.fixedSize(horizontal: true, vertical: false)
            }
        }
        .padding(.vertical, 6)
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
    }

    private var details: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(exercise.name.capitalized)
                .font(StrandFont.sized(nameSize, weight: .semibold)).tracking(-0.2)
                .foregroundStyle(StrandPalette.textPrimary)
            Text("\(exercise.equipment.capitalized) · \(exercise.restSeconds)s rest")
                .font(StrandFont.sized(metaSize, weight: .regular))
                .foregroundStyle(StrandPalette.textSecondary)
        }
        .multilineTextAlignment(.leading)
    }

    private var prescription: some View {
        Text("\(exercise.sets) × \(exercise.reps)")
            .font(StrandFont.sized(prescriptionSize, weight: .semibold)).monospacedDigit()
            .foregroundStyle(StrandPalette.textPrimary)
            .accessibilityLabel(Text(verbatim: "\(exercise.sets) × \(exercise.reps) \(String(localized: "sets × reps"))"))
    }
}

/// A paragraph that collapses to three lines behind a More chip only when it really runs past three lines at the
/// current width and text size. Measured with two hidden copies, not guessed from a character count.
private struct CoachCollapsibleSummary: View {
    let text: String
    @Binding var isExpanded: Bool
    @State private var fullHeight: CGFloat = 0
    @State private var clampedHeight: CGFloat = 0
    @ScaledMetric(relativeTo: .subheadline) private var size: CGFloat = 15.5

    private var overflows: Bool { fullHeight > clampedHeight + 1 }

    private func summary(lines: Int?) -> some View {
        Text(text).font(StrandFont.sized(size, weight: .regular)).lineSpacing(3)
            .foregroundStyle(StrandPalette.textSecondary)
            .lineLimit(lines)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: NoopMetrics.space2) {
            summary(lines: isExpanded ? nil : 3)
            if overflows {
                Button { withAnimation(.easeOut(duration: 0.2)) { isExpanded.toggle() } } label: {
                    WidgetChip(appTitle: isExpanded ? "Less" : "More",
                               systemImage: isExpanded ? "chevron.up" : "chevron.down",
                               showsChevron: false, overhangs: false)
                        .chipHitTarget()
                }
                .buttonStyle(.plain)
            }
        }
        .background {
            ZStack {
                summary(lines: nil).fixedSize(horizontal: false, vertical: true)
                    .background(GeometryReader { proxy in
                        Color.clear.preference(key: CoachFullHeightKey.self, value: proxy.size.height)
                    })
                summary(lines: 3).fixedSize(horizontal: false, vertical: true)
                    .background(GeometryReader { proxy in
                        Color.clear.preference(key: CoachClampedHeightKey.self, value: proxy.size.height)
                    })
            }
            .hidden()
            .accessibilityHidden(true)
        }
        .onPreferenceChange(CoachFullHeightKey.self) { fullHeight = $0 }
        .onPreferenceChange(CoachClampedHeightKey.self) { clampedHeight = $0 }
    }
}

private struct CoachFullHeightKey: PreferenceKey {
    static let defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) { value = max(value, nextValue()) }
}

private struct CoachClampedHeightKey: PreferenceKey {
    static let defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) { value = max(value, nextValue()) }
}

/// Exercise pictures from the catalog: found through an index built once, read and scaled off the main thread, and
/// kept by exercise. The plan redraws with every streamed token, so a redraw never goes back to the disk.
@MainActor
private enum CoachExerciseArt {
    private static let cache = NSCache<NSString, UIImage>()
    private static let entriesByID = Dictionary(NoopLiftCatalog.entries.map { ($0.id, $0) },
                                                uniquingKeysWith: { first, _ in first })

    /// What the picture depends on: the catalog entry the plan names, or the exercise's own name when the plan names
    /// one the catalog does not have. Exercises with the same key share a picture.
    static func key(for exercise: LocalCoachPlannedExercise) -> String {
        entriesByID[exercise.catalogID] != nil ? exercise.catalogID : "name:" + exercise.name.lowercased()
    }

    static func cached(for exercise: LocalCoachPlannedExercise) -> UIImage? {
        cache.object(forKey: key(for: exercise) as NSString)
    }

    static func image(for exercise: LocalCoachPlannedExercise, pixelSize: CGSize) async -> UIImage? {
        if let hit = cached(for: exercise) { return hit }
        let entry = entriesByID[exercise.catalogID] ?? NoopLiftCatalog.resolve(name: exercise.name)
        guard let url = entry?.imageURL else { return nil }
        let image = await Task.detached(priority: .utility) {
            UIImage(contentsOfFile: url.path)?.preparingThumbnail(of: pixelSize)
        }.value
        if let image { cache.setObject(image, forKey: key(for: exercise) as NSString) }
        return image
    }
}

/// The exercise's figure straight on the canvas: the catalog's background-removed cutout, scaled so the figure fills
/// its box (the pictures keep a margin) and lifted off the dark by a soft shadow. A quiet dumbbell stands in until
/// the picture has loaded, and for an exercise with no picture.
private struct CoachExerciseThumbnail: View {
    /// How far the cutout is scaled up inside its box so the figure, not its margin, fills it. It may overhang the
    /// box a little: the picture is transparent.
    static let figureScale: CGFloat = 1.32

    let exercise: LocalCoachPlannedExercise
    let size: CGFloat
    @Environment(\.displayScale) private var displayScale
    @State private var image: UIImage?

    init(exercise: LocalCoachPlannedExercise, size: CGFloat) {
        self.exercise = exercise
        self.size = size
        _image = State(initialValue: CoachExerciseArt.cached(for: exercise))
    }

    var body: some View {
        ZStack {
            if let image {
                Image(uiImage: image).resizable().interpolation(.high).scaledToFit()
                    .frame(width: size, height: size)
                    .scaleEffect(Self.figureScale)
                    .shadow(color: .black.opacity(0.5), radius: 6, x: 0, y: 6)
            } else {
                Image(systemName: "dumbbell").font(.system(size: 22, weight: .regular))
                    .foregroundStyle(StrandPalette.textTertiary)
            }
        }
        .frame(width: size, height: size)
        .accessibilityHidden(true)
        .task(id: CoachExerciseArt.key(for: exercise)) {
            image = CoachExerciseArt.cached(for: exercise)
            let side = size * Self.figureScale * displayScale
            image = await CoachExerciseArt.image(for: exercise, pixelSize: CGSize(width: side, height: side))
        }
    }
}

struct LocalCoachPlanBuilder: View {
    @EnvironmentObject private var coach: LocalCoachEngine
    @Environment(\.dismiss) private var dismiss
    @State private var focus = "Full body strength"
    @State private var minutes = 45
    @State private var days = 3
    @State private var building = false
    let onBuilt: () -> Void

    var body: some View {
        NavigationStack {
            NativeSettingsList {
                Section {
                    Text("A plan you can make your own.")
                        .font(StrandFont.title2).padding(.vertical, NoopMetrics.space2)
                    Text("Choose your focus and schedule. NOOP uses its local exercise catalog to create a draft for you to review.")
                        .font(StrandFont.subhead).foregroundStyle(.secondary)
                }
                Section("Your training") {
                    TextField("Focus", text: $focus, axis: .vertical).lineLimit(2...4)
                    Picker("Time per session", selection: $minutes) {
                        ForEach([20, 30, 45, 60, 75, 90], id: \.self) { Text("\($0) minutes").tag($0) }
                    }
                    Stepper("\(days) sessions this week", value: $days, in: 1...7)
                }
                if !coach.preferences.usePersonalData {
                    Section {
                        Toggle("Allow local records for planning", isOn: $coach.preferences.usePersonalData)
                    } footer: { Text("Your plan stays on this iPhone. Review it before adding sessions to your workouts.") }
                }
                Section {
                    Button {
                        building = true
                        let oldID = coach.plan?.id
                        Task {
                            await coach.createPlan(focus: focus, minutes: minutes, days: days)
                            building = false
                            if coach.plan?.id != oldID, coach.plan != nil { onBuilt(); dismiss() }
                        }
                    } label: {
                        HStack { Text(building ? "Building your draft…" : "Create my draft"); Spacer(); if building { ProgressView() } }
                    }.disabled(building || !coach.preferences.usePersonalData || focus.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                        .accessibilityIdentifier("coach.createPlan")
                }
                if let error = coach.errorText { CoachNotice(error: error) }
            }
            .navigationTitle("Build a plan").navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Close") { if building { coach.cancel() }; dismiss() } } }
        }
        .coachSettingsSheetEnvironment()
    }
}

private struct LocalCoachExerciseEditor: View {
    @Environment(\.dismiss) private var dismiss
    @State private var draft: LocalCoachPlannedExercise
    let onSave: (LocalCoachPlannedExercise) -> Void

    init(exercise: LocalCoachPlannedExercise, onSave: @escaping (LocalCoachPlannedExercise) -> Void) {
        _draft = State(initialValue: exercise)
        self.onSave = onSave
    }

    var body: some View {
        NavigationStack {
            NativeSettingsList {
                Section(draft.name.capitalized) {
                    Stepper("\(draft.sets) sets", value: $draft.sets, in: 1...8)
                    Stepper("\(draft.reps) reps", value: $draft.reps, in: 1...30)
                    Stepper("\(draft.restSeconds) seconds rest", value: $draft.restSeconds, in: 15...300, step: 15)
                    TextField("Coaching note", text: $draft.note, axis: .vertical).lineLimit(3...6)
                }
                if let entry = NoopLiftCatalog.entries.first(where: { $0.id == draft.catalogID }) ?? NoopLiftCatalog.resolve(name: draft.name),
                   !entry.instructions.isEmpty {
                    Section("Movement guide") { Text(entry.instructions).font(StrandFont.subhead) }
                }
            }
            .navigationTitle("Tune your workout").navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) { Button("Apply") { onSave(draft); dismiss() } }
            }
        }
        .coachSettingsSheetEnvironment()
    }
}
#endif
