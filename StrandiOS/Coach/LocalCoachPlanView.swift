#if os(iOS)
import SwiftUI
import StrandDesign

struct LocalCoachPlanView: View {
    @EnvironmentObject private var coach: LocalCoachEngine
    @State private var editing: PlanEdit?
    @State private var confirmSave = false
    @State private var showWorkouts = false
    @State private var summaryExpanded = false
    let onBuild: () -> Void

    /// The exercise being tuned and the day it belongs to, so the edit lands on the right session.
    private struct PlanEdit: Identifiable {
        let dayID: UUID
        let exercise: LocalCoachPlannedExercise
        var id: UUID { exercise.id }
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                if coach.isPreview { LocalCoachFixtureLabel().padding(.bottom, NoopMetrics.space3) }
                if let plan = coach.plan {
                    planHeader(plan)
                    ForEach(plan.days) { day in
                        CoachSectionSeparator()
                        daySection(day, in: plan)
                    }
                    Text("Tap an exercise to adjust sets, reps, rest or notes. Start with a load you can control.")
                        .font(StrandFont.footnote).foregroundStyle(StrandPalette.textTertiary)
                        .padding(.top, NoopMetrics.space4)
                } else {
                    emptyPlan
                }
            }
            .padding(.horizontal, NoopMetrics.space4)
            .padding(.top, CoachRhythm.pageTop)
            .padding(.bottom, CoachRhythm.pageBottom)
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
                WorkoutsView()
                    .background(StrandPalette.appCanvas.ignoresSafeArea())
                    .toolbarBackground(.hidden, for: .navigationBar)
                    .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { showWorkouts = false } } }
            }
            .tint(StrandPalette.accent)
            .noopSheetPresentation(largeFirst: true)
        }
        .confirmationDialog("Save this plan to NOOP?", isPresented: $confirmSave, titleVisibility: .visible) {
            Button("Save reviewed plan") { Task { await coach.savePlan() } }
            Button("Keep reviewing", role: .cancel) { }
        } message: {
            Text("This adds the reviewed sessions to your local workout plan. It does not start or mark a workout as completed.")
        }
        .accessibilityIdentifier("coach.plan")
    }

    /// Summaries longer than this collapse to three lines behind a More chip.
    private static let summaryCollapseLength = 170

    // MARK: Header

    /// The plan as one summary: its state, title and summary, three facts and the actions that move it forward.
    private func planHeader(_ plan: LocalCoachPlan) -> some View {
        let perSession = CoachPlanText.minutesPerSession(plan.days.map(\.minutes))
        let exercises = plan.days.reduce(0) { $0 + $1.exercises.count }
        return CoachSection(plan.saved ? "Saved to your workouts" : "Built for your review",
                            systemImage: plan.saved ? "checkmark.circle.fill" : "calendar.badge.plus",
                            tint: .workout,
                            trailing: .pill(plan.saved ? "Saved" : "Draft", tone: plan.saved ? .positive : .neutral)) {
            VStack(alignment: .leading, spacing: NoopMetrics.space2) {
                Text(plan.title).font(StrandFont.title1).foregroundStyle(StrandPalette.textPrimary)
                    .fixedSize(horizontal: false, vertical: true)
                // A generated summary can run long (assumptions, caveats). Keep the header calm: three lines,
                // with a chip to read the rest. VoiceOver always reads all of it.
                let isLong = plan.summary.count > Self.summaryCollapseLength
                Text(plan.summary).font(StrandFont.subhead).lineSpacing(3)
                    .foregroundStyle(StrandPalette.textSecondary)
                    .lineLimit(isLong && !summaryExpanded ? 3 : nil)
                if isLong {
                    Button { withAnimation(.easeOut(duration: 0.2)) { summaryExpanded.toggle() } } label: {
                        WidgetChip(appTitle: summaryExpanded ? "Less" : "More",
                                   systemImage: summaryExpanded ? "chevron.up" : "chevron.down",
                                   showsChevron: false, overhangs: false)
                            .chipHitTarget()
                    }
                    .buttonStyle(.plain)
                }
            }
            CoachFactStrip(facts: [
                CoachFact(label: "Workouts", value: "\(plan.days.count)"),
                CoachFact(label: "Per workout", value: perSession.map(String.init) ?? WidgetMetrics.missingValue,
                          unit: "min"),
                CoachFact(label: "Exercises", value: "\(exercises)")
            ])
            actions(plan)
        }
    }

    /// Save is the one primary action; rebuilding is a chip beside it (below it at large text sizes).
    private func actions(_ plan: LocalCoachPlan) -> some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: NoopMetrics.space3) {
                saveButton(plan)
                rebuildChip
                Spacer(minLength: 0)
            }
            VStack(alignment: .leading, spacing: NoopMetrics.space3) {
                saveButton(plan)
                rebuildChip
            }
        }
    }

    private func saveButton(_ plan: LocalCoachPlan) -> some View {
        Button {
            if plan.saved { showWorkouts = true } else { confirmSave = true }
        } label: {
            Label(plan.saved ? "Open saved workouts" : "Review & save plan",
                  systemImage: plan.saved ? "checkmark.circle" : "plus.circle")
                .labelStyle(.titleAndIcon)
        }
        .buttonStyle(CoachPrimaryPillStyle())
        .disabled(coach.isResponding || coach.isPreview)
        .accessibilityIdentifier("coach.savePlan")
    }

    private var rebuildChip: some View {
        Button(action: onBuild) {
            WidgetChip(appTitle: "Build a different plan", systemImage: "arrow.triangle.2.circlepath",
                       showsChevron: false, overhangs: false)
                .chipHitTarget()
        }
        .buttonStyle(.plain)
    }

    // MARK: Days

    private func date(of day: LocalCoachPlanDay, in plan: LocalCoachPlan) -> Date {
        Calendar.current.date(byAdding: .day, value: day.dayOffset, to: plan.createdAt) ?? plan.createdAt
    }

    /// One session: the weekday as the eyebrow (a Today pill on the day itself), its title and focus, then the
    /// exercises as plain rows.
    private func daySection(_ day: LocalCoachPlanDay, in plan: LocalCoachPlan) -> some View {
        let when = date(of: day, in: plan)
        let isToday = Calendar.current.isDateInToday(when)
        let heading = when.formatted(.dateTime.weekday(.wide).month(.abbreviated).day())
        return CoachSection(verbatim: heading, systemImage: "figure.strengthtraining.traditional", tint: .workout,
                            trailing: isToday ? .pill("Today", tone: .accent) : .none) {
            VStack(alignment: .leading, spacing: 2) {
                Text(day.title).font(StrandFont.headline).foregroundStyle(StrandPalette.textPrimary)
                HStack(alignment: .firstTextBaseline, spacing: 4) {
                    Text(day.focus).font(StrandFont.footnote).foregroundStyle(StrandPalette.textSecondary)
                    Text("·").font(StrandFont.footnote).foregroundStyle(StrandPalette.textTertiary)
                    Text("\(day.minutes)").font(StrandFont.captionNumber).foregroundStyle(StrandPalette.textPrimary)
                    Text("min").font(StrandFont.micro).foregroundStyle(StrandPalette.textTertiary)
                }
                .accessibilityElement(children: .combine)
            }
            VStack(spacing: 0) {
                ForEach(Array(day.exercises.enumerated()), id: \.element.id) { index, exercise in
                    if index > 0 {
                        Rectangle().fill(StrandPalette.hairline).frame(height: 1).accessibilityHidden(true)
                    }
                    Button { editing = PlanEdit(dayID: day.id, exercise: exercise) } label: { exerciseRow(exercise) }
                        .buttonStyle(.plain)
                }
            }
            // The rows carry their own air; pull them in so the gaps under the heading and above the next
            // section's hairline match the rest of the page.
            .padding(.top, -NoopMetrics.space1)
            .padding(.bottom, -NoopMetrics.space2)
        }
    }

    private func exerciseRow(_ exercise: LocalCoachPlannedExercise) -> some View {
        let catalog = NoopLiftCatalog.entries.first { $0.id == exercise.catalogID } ?? NoopLiftCatalog.resolve(name: exercise.name)
        return HStack(spacing: NoopMetrics.space3) {
            Group {
                if let url = catalog?.imageURL, let image = UIImage(contentsOfFile: url.path) {
                    Image(uiImage: image).resizable().scaledToFit()
                        .background(Color.white)
                } else {
                    Image(systemName: "dumbbell").font(.system(size: 18, weight: .regular))
                        .foregroundStyle(DomainTint.workout.accent)
                }
            }
            .frame(width: 48, height: 54).background(DomainTint.workout.accent.opacity(0.12))
            .clipShape(.rect(cornerRadius: NoopMetrics.radius1)).accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 3) {
                Text(exercise.name.capitalized).font(StrandFont.subhead.weight(.semibold))
                    .foregroundStyle(StrandPalette.textPrimary)
                Text("\(exercise.equipment.capitalized) · \(exercise.restSeconds)s rest")
                    .font(StrandFont.micro).foregroundStyle(StrandPalette.textTertiary)
            }
            .multilineTextAlignment(.leading)
            Spacer(minLength: NoopMetrics.space2)
            VStack(alignment: .trailing, spacing: 0) {
                Text("\(exercise.sets) × \(exercise.reps)").font(StrandFont.bodyNumber)
                    .foregroundStyle(StrandPalette.textPrimary).lineLimit(1)
                Text("sets × reps").font(StrandFont.micro).foregroundStyle(StrandPalette.textTertiary)
            }
            Image(systemName: "chevron.right").font(.system(size: 10, weight: .semibold))
                .foregroundStyle(StrandPalette.textTertiary).accessibilityHidden(true)
        }
        .padding(.vertical, NoopMetrics.space2)
        .frame(minHeight: 44)
        .contentShape(Rectangle())
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
                    .buttonStyle(CoachPrimaryPillStyle())
                    .accessibilityIdentifier("coach.buildPlan")
            }
            CoachSectionSeparator()
            CoachSection("How it works", systemImage: "list.number", tint: .workout) {
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
                .frame(width: 24, height: 24)
                .background(Circle().fill(DomainTint.workout.accent.opacity(0.14)))
                .accessibilityHidden(true)
            Text(title).font(StrandFont.subhead).foregroundStyle(StrandPalette.textSecondary)
        }
        .accessibilityElement(children: .combine)
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
