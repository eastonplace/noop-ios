#if os(iOS)
import SwiftUI
import StrandDesign

struct LocalCoachPlanView: View {
    @EnvironmentObject private var coach: LocalCoachEngine
    @State private var selectedDayID: UUID?
    @State private var editingExercise: LocalCoachPlannedExercise?
    @State private var confirmSave = false
    @State private var showWorkouts = false
    let onBuild: () -> Void

    private var selectedDay: LocalCoachPlanDay? {
        coach.plan?.days.first(where: { $0.id == selectedDayID }) ?? coach.plan?.days.first
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                if coach.isPreview { LocalCoachFixtureLabel() }
                if let plan = coach.plan {
                    planHeader(plan)
                    days(plan)
                    if let day = selectedDay {
                        HStack {
                            LocalCoachSectionHeading(title: day.title, eyebrow: day.focus.uppercased())
                            Spacer()
                            Label("\(day.minutes) min", systemImage: "clock").font(.caption).foregroundStyle(StrandPalette.textTertiary)
                        }
                        VStack(spacing: 10) {
                            ForEach(day.exercises) { exercise in
                                Button { editingExercise = exercise } label: { exerciseRow(exercise) }
                                    .buttonStyle(.plain)
                            }
                        }
                        Text("Tap an exercise to adjust sets, reps, rest or notes. Start with a load you can control.")
                            .font(.footnote).foregroundStyle(StrandPalette.textTertiary)
                    }
                    Button {
                        if plan.saved { showWorkouts = true } else { confirmSave = true }
                    } label: {
                        Label(plan.saved ? "Open saved workouts" : "Review & save plan", systemImage: plan.saved ? "checkmark.circle" : "plus.circle")
                    }
                    .buttonStyle(LocalCoachPrimaryButtonStyle())
                    .disabled(coach.isResponding || coach.isPreview)
                    .accessibilityIdentifier("coach.savePlan")
                    Button("Build a different plan", action: onBuild)
                        .font(.footnote).frame(maxWidth: .infinity).foregroundStyle(StrandPalette.textSecondary)
                } else {
                    VStack(alignment: .leading, spacing: 20) {
                        Image(systemName: "figure.strengthtraining.traditional")
                            .font(.system(size: 48, weight: .ultraLight)).foregroundStyle(StrandPalette.accent)
                        Text("Make room\nfor progress.").font(.system(size: 34, weight: .medium, design: .rounded))
                        Text("Build a training plan around your focus and available time. Review the exercises, adjust the details and save it to your NOOP workouts.")
                            .foregroundStyle(StrandPalette.textSecondary).lineSpacing(4)
                        Button("Build my plan", action: onBuild).buttonStyle(LocalCoachPrimaryButtonStyle())
                    }.padding(.vertical, 20)
                }
            }.padding(22)
        }
        .sheet(item: $editingExercise) { exercise in
            LocalCoachExerciseEditor(exercise: exercise) { edited in
                guard var plan = coach.plan, let dayIndex = plan.days.firstIndex(where: { $0.id == selectedDay?.id }),
                      let exerciseIndex = plan.days[dayIndex].exercises.firstIndex(where: { $0.id == edited.id }) else { return }
                plan.days[dayIndex].exercises[exerciseIndex] = edited
                coach.updatePlan(plan)
            }
        }
        .sheet(isPresented: $showWorkouts) {
            NavigationStack {
                WorkoutsView()
                    .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { showWorkouts = false } } }
            }
        }
        .confirmationDialog("Save this plan to NOOP?", isPresented: $confirmSave, titleVisibility: .visible) {
            Button("Save reviewed plan") { Task { await coach.savePlan() } }
            Button("Keep reviewing", role: .cancel) { }
        } message: {
            Text("This adds the reviewed sessions to your local workout plan. It does not start or mark a workout as completed.")
        }
        .accessibilityIdentifier("coach.plan")
    }

    private func planHeader(_ plan: LocalCoachPlan) -> some View {
        VStack(alignment: .leading, spacing: 15) {
            HStack {
                Text(plan.saved ? "SAVED TO YOUR WORKOUTS" : "BUILT FOR YOUR REVIEW")
                    .font(.system(size: 9, weight: .medium, design: .monospaced)).tracking(1.2)
                Spacer()
                Image(systemName: plan.saved ? "checkmark.circle" : "calendar.badge.plus")
            }.foregroundStyle(StrandPalette.accent)
            Text(plan.title).font(.system(size: 28, weight: .medium, design: .rounded)).fixedSize(horizontal: false, vertical: true)
            Text(plan.summary).font(.subheadline).foregroundStyle(StrandPalette.textSecondary).lineSpacing(3)
            HStack(spacing: 16) {
                Label("\(plan.days.count) sessions", systemImage: "calendar")
                Label("Editable", systemImage: "slider.horizontal.3")
            }.font(.caption).foregroundStyle(StrandPalette.textTertiary)
        }.modifier(LocalCoachPanel())
    }

    private func days(_ plan: LocalCoachPlan) -> some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 10) {
                ForEach(plan.days) { day in
                    let selected = selectedDay?.id == day.id
                    Button { selectedDayID = day.id } label: {
                        VStack(alignment: .leading, spacing: 9) {
                            Text(Calendar.current.date(byAdding: .day, value: day.dayOffset, to: plan.createdAt) ?? plan.createdAt,
                                 format: .dateTime.weekday(.abbreviated))
                                .textCase(.uppercase).font(.system(size: 10, weight: .semibold, design: .monospaced))
                            Text(day.focus).font(.system(size: 14, weight: .medium)).lineLimit(2)
                            Text("\(day.exercises.count) exercises").font(.system(size: 10))
                        }
                        .foregroundStyle(selected ? StrandPalette.onInk : StrandPalette.textSecondary)
                        .frame(width: 115, alignment: .leading).padding(14)
                        .background(selected ? StrandPalette.accent : StrandPalette.inset, in: .rect(cornerRadius: 16))
                    }.buttonStyle(.plain).accessibilityAddTraits(selected ? .isSelected : [])
                }
            }
        }
    }

    private func exerciseRow(_ exercise: LocalCoachPlannedExercise) -> some View {
        let catalog = NoopLiftCatalog.entries.first { $0.id == exercise.catalogID } ?? NoopLiftCatalog.resolve(name: exercise.name)
        return HStack(spacing: 14) {
            Group {
                if let url = catalog?.imageURL, let image = UIImage(contentsOfFile: url.path) {
                    Image(uiImage: image).resizable().scaledToFit()
                        .background(Color.white)
                } else {
                    Image(systemName: "dumbbell").font(.system(size: 22, weight: .light)).foregroundStyle(StrandPalette.accent)
                }
            }
            .frame(width: 60, height: 68).background(StrandPalette.inset)
            .clipShape(.rect(cornerRadius: 12)).accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 7) {
                Text(exercise.name.capitalized).font(.system(size: 14, weight: .semibold)).foregroundStyle(StrandPalette.textPrimary)
                Text("\(exercise.sets) sets × \(exercise.reps) reps")
                    .font(.system(size: 12, weight: .medium)).foregroundStyle(StrandPalette.accent)
                Text("\(exercise.equipment.capitalized) · \(exercise.restSeconds)s rest")
                    .font(.system(size: 10)).foregroundStyle(StrandPalette.textTertiary)
            }
            Spacer(minLength: 0)
            Image(systemName: "slider.horizontal.3").font(.footnote).foregroundStyle(StrandPalette.textTertiary)
        }.padding(12).background(StrandPalette.card, in: .rect(cornerRadius: 17))
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
            Form {
                Section {
                    Text("A plan you can make your own.")
                        .font(.system(size: 28, weight: .medium, design: .rounded)).padding(.vertical, 10)
                    Text("Choose your focus and schedule. NOOP uses its local exercise catalog to create a draft for you to review.")
                        .font(.subheadline).foregroundStyle(.secondary)
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
                if let error = coach.errorText { Text(error).foregroundStyle(StrandPalette.warning).font(.footnote) }
            }
            .navigationTitle("Build a plan").navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Close") { if building { coach.cancel() }; dismiss() } } }
        }.tint(StrandPalette.accent).preferredColorScheme(.dark)
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
            Form {
                Section(draft.name.capitalized) {
                    Stepper("\(draft.sets) sets", value: $draft.sets, in: 1...8)
                    Stepper("\(draft.reps) reps", value: $draft.reps, in: 1...30)
                    Stepper("\(draft.restSeconds) seconds rest", value: $draft.restSeconds, in: 15...300, step: 15)
                    TextField("Coaching note", text: $draft.note, axis: .vertical).lineLimit(3...6)
                }
                if let entry = NoopLiftCatalog.entries.first(where: { $0.id == draft.catalogID }) ?? NoopLiftCatalog.resolve(name: draft.name),
                   !entry.instructions.isEmpty {
                    Section("Movement guide") { Text(entry.instructions).font(.subheadline) }
                }
            }
            .navigationTitle("Tune your workout").navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) { Button("Apply") { onSave(draft); dismiss() } }
            }
        }.tint(StrandPalette.accent).preferredColorScheme(.dark)
    }
}
#endif
