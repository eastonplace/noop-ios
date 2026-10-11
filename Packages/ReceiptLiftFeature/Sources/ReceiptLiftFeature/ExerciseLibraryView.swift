import StrandDesign
import SwiftUI

/// Every exercise Lift knows, searchable and filterable by muscle and equipment. Browsing opens an exercise's own page;
/// with `onSelect` it is a picker (the live workout's swap and add, the routine editor's add) and a tap hands the
/// exercise back.
struct ExerciseLibraryView: View {
  @Environment(\.dynamicTypeSize) private var dynamicTypeSize
  @EnvironmentObject private var store: LiftStore
  private let onSelect: ((LiftExercise) -> Void)?
  @State private var showingAddExercise = false
  @State private var query = ""
  @State private var muscle: String?
  @State private var equipment: String?
  @State private var sourceSnapshot: [LiftExercise] = []
  @State private var facets: (muscles: [String], equipment: [String]) = ([], [])
  @State private var sourceRevision = 0
  @State private var results: [LiftExercise] = []
  @State private var isSearching = false

  /// How many matches the list draws; the rest are one narrower search away.
  private static let resultLimit = 60

  init(onSelect: ((LiftExercise) -> Void)? = nil) {
    self.onSelect = onSelect
  }

  var body: some View {
    LiftPage(
      title: "Exercise library",
      lazy: true,
      trailing: {
        if onSelect == nil {
          HeaderChipButton("plus", accessibilityLabel: "Add exercise") { showingAddExercise = true }
        }
      }
    ) {
      VStack(alignment: .leading, spacing: 0) {
        if onSelect != nil {
          LiftNote(text: "Select a move to apply it to your workout")
        }
        PaperSearchField(
          "Search name, muscle, or equipment",
          text: $query,
          inputConfiguration: .searchQuery
        )
        filterRow
      }
      libraryList
    }
    .environment(\.liftScreenRole, .sheet)
    .sheet(isPresented: $showingAddExercise) {
      AddExerciseSheet()
    }
    .onAppear(perform: refreshSource)
    .onChange(of: store.exercises) { refreshSource() }
    .onChange(of: store.routines) { refreshSource() }
    .task(id: SearchRequest(query: query, muscle: muscle, equipment: equipment, sourceRevision: sourceRevision)) {
      let captured = sourceSnapshot
      isSearching = true
      do {
        let filtered = try await LiftExerciseSearch.debouncedFilter(
          exercises: captured,
          query: query,
          muscle: muscle,
          equipment: equipment,
          limit: Self.resultLimit
        )
        try Task.checkCancellation()
        results = filtered
      } catch is CancellationError {
        return
      } catch {
        results = []
      }
      isSearching = false
    }
  }

  // MARK: Filters

  private var filterRow: some View {
    ChipRow {
      filterMenu(
        title: String(localized: "Muscle"), systemImage: "figure.strengthtraining.traditional",
        selection: $muscle, options: facets.muscles)
      filterMenu(
        title: String(localized: "Equipment"), systemImage: "dumbbell.fill",
        selection: $equipment, options: facets.equipment)
      if muscle != nil || equipment != nil {
        ChoiceChipButton(verbatimTitle: String(localized: "Clear filters"), systemImage: "xmark") {
          muscle = nil
          equipment = nil
        }
      }
    }
    .padding(.vertical, NoopMetrics.space2)
  }

  private func filterMenu(
    title: String, systemImage: String, selection: Binding<String?>, options: [String]
  ) -> some View {
    ChipMenu(
      verbatimTitle: selection.wrappedValue?.liftDisplayName ?? title,
      systemImage: systemImage,
      isSelected: selection.wrappedValue != nil,
      accessibilityLabel: LocalizedStringKey(title),
      accessibilityValue: selection.wrappedValue?.liftDisplayName ?? String(localized: "All")
    ) {
      Button { selection.wrappedValue = nil } label: {
        if selection.wrappedValue == nil {
          Label("All", systemImage: "checkmark")
        } else {
          Text("All")
        }
      }
      ForEach(options, id: \.self) { option in
        Button { selection.wrappedValue = option } label: {
          if selection.wrappedValue == option {
            Label(option.liftDisplayName, systemImage: "checkmark")
          } else {
            Text(verbatim: option.liftDisplayName)
          }
        }
      }
    }
  }

  // MARK: List

  private var libraryList: some View {
    let capped = results.count >= Self.resultLimit
    return LiftFlatSection(
      "Exercises",
      trailing: isSearching
        ? .text(String(localized: "Searching"))
        : .text(capped ? String(localized: "First \(Self.resultLimit) matches") : LiftFormat.exerciseCount(results.count)),
      contentSpacing: 0
    ) {
      if !isSearching && results.isEmpty {
        LiftMessage(
          symbol: "magnifyingglass",
          title: "No matches",
          message: "Try a muscle or equipment name."
        )
      }
      LazyVStack(spacing: 0) {
        ForEach(Array(results.enumerated()), id: \.element.id) { index, exercise in
          if index > 0 { FlatRowSeparator(leadingInset: thumbSize + NoopMetrics.space3) }
          exerciseRow(exercise)
        }
      }
    }
  }

  private var thumbSize: CGFloat { dynamicTypeSize.isAccessibilitySize ? 64 : 52 }

  @ViewBuilder
  private func exerciseRow(_ exercise: LiftExercise) -> some View {
    let details = LiftFormat.facts([exercise.muscleGroup, exercise.equipment]).liftDisplayName
    if let onSelect {
      Button { onSelect(exercise) } label: {
        LiftListRow(
          title: exercise.name.liftDisplayName,
          details: [details],
          leading: { LiftExerciseThumb(exercise: exercise, size: thumbSize) },
          accessory: {
            Image(systemName: "plus")
              .font(.system(size: 13, weight: .semibold))
              .foregroundStyle(StrandPalette.textTertiary)
              .accessibilityHidden(true)
          }
        )
      }
      .buttonStyle(FlatRowPressStyle())
      .accessibilityElement(children: .ignore)
      .accessibilityLabel("Add \(exercise.name)")
      .accessibilityValue("\(exercise.muscleGroup), \(exercise.equipment)")
      .accessibilityHint("Adds this exercise once")
    } else {
      NavigationLink {
        ExerciseProgressView(exerciseID: exercise.id)
      } label: {
        LiftListRow(
          title: exercise.name.liftDisplayName,
          details: [details],
          showsChevron: true,
          leading: { LiftExerciseThumb(exercise: exercise, size: thumbSize) }
        )
      }
      .buttonStyle(FlatRowPressStyle())
      .accessibilityElement(children: .ignore)
      .accessibilityLabel(exercise.name.liftDisplayName)
      .accessibilityValue("\(exercise.muscleGroup), \(exercise.equipment)")
      .accessibilityHint("Shows exercise details")
    }
  }

  private func refreshSource() {
    let snapshot = store.displayExercises
    guard snapshot != sourceSnapshot else { return }
    sourceSnapshot = snapshot
    facets = LiftExerciseSearch.facets(for: snapshot)
    sourceRevision &+= 1
  }

  private struct SearchRequest: Equatable {
    let query: String
    let muscle: String?
    let equipment: String?
    let sourceRevision: Int
  }
}

private struct AddExerciseSheet: View {
  @Environment(\.dismiss) private var dismiss
  @EnvironmentObject private var store: LiftStore
  @State private var name = ""
  @State private var muscleGroup = ""
  @State private var equipment = ""
  @State private var instructions = ""

  private var canSave: Bool {
    !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
  }

  var body: some View {
    LiftSheetPage(
      title: "New exercise",
      onClose: { dismiss() },
      content: {
        LiftFlatSection("Exercise", systemImage: "dumbbell.fill") {
          VStack(alignment: .leading, spacing: NoopMetrics.space4) {
            LiftField(title: "Name", text: $name, placeholder: "Bench press")
            LiftField(title: "Muscle", text: $muscleGroup, placeholder: "Chest")
            LiftField(title: "Equipment", text: $equipment, placeholder: "Barbell")
            LiftField(
              title: "Cues", text: $instructions, placeholder: "Brace, control, press.", axis: .vertical,
              capitalization: .sentences)
          }
        }
      },
      footer: {
        Button {
          store.addExercise(name: name, muscleGroup: muscleGroup, equipment: equipment, instructions: instructions)
          dismiss()
        } label: {
          Label("Save exercise", systemImage: "checkmark").liftPillLabel()
        }
        .buttonStyle(PrimaryPillButtonStyle())
        .disabled(!canSave)
      }
    )
    .presentationDetents([.large])
    .presentationDragIndicator(.visible)
  }
}
