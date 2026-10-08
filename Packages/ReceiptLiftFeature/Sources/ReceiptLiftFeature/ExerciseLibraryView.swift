import StrandDesign
import SwiftUI

struct ExerciseLibraryView: View {
  @Environment(\.dynamicTypeSize) private var dynamicTypeSize
  @Environment(\.accessibilityReduceMotion) private var reduceMotion
  @Environment(\.dismiss) private var dismiss
  @EnvironmentObject private var store: LiftStore
  private let onSelect: ((LiftExercise) -> Void)?
  @State private var selectedExerciseID: UUID?
  @State private var showingAddExercise = false
  @State private var query = ""
  @State private var sourceSnapshot: [LiftExercise] = []
  @State private var sourceRevision = 0
  @State private var results: [LiftExercise] = []
  @State private var isSearching = false

  init(onSelect: ((LiftExercise) -> Void)? = nil) {
    self.onSelect = onSelect
  }

  var body: some View {
    LiftScreen(
      title: "Exercise library",
      subtitle: onSelect == nil
        ? "\(sourceSnapshot.count) local exercises · program moves first"
        : "Select a move to apply it to your workout",
      lazy: true,
      bottomPadding: 78,
      trailing: {
        HStack(spacing: 8) {
          if onSelect == nil {
            NoopIconButton("plus", accessibilityLabel: "Add exercise") { showingAddExercise = true }
          }
          NoopIconButton("xmark", accessibilityLabel: "Close") { dismiss() }
        }
      }
    ) {
      if onSelect == nil, let selectedExercise {
        ExerciseDetailPanel(exercise: selectedExercise)
          .transition(reduceMotion ? .opacity : .move(edge: .top).combined(with: .opacity))
      }

      PaperSearchField(
        "Search name, muscle, or equipment",
        text: $query,
        inputConfiguration: .searchQuery
      )
      libraryList
    }
    .sheet(isPresented: $showingAddExercise) {
      AddExerciseSheet()
    }
    .onAppear {
      refreshSource()
      if onSelect == nil {
        selectedExerciseID = selectedExerciseID ?? store.preferredExerciseID
      }
    }
    .onChange(of: store.exercises) {
      refreshSource()
    }
    .onChange(of: store.routines) {
      refreshSource()
    }
    .task(id: SearchRequest(query: query, sourceRevision: sourceRevision)) {
      let captured = sourceSnapshot
      isSearching = true
      do {
        let filtered = try await LiftExerciseSearch.debouncedFilter(
          exercises: captured,
          query: query
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

  private var selectedExercise: LiftExercise? {
    guard let selectedExerciseID else {
      guard let preferredExerciseID = store.preferredExerciseID else { return sourceSnapshot.first }
      return sourceSnapshot.first { $0.id == preferredExerciseID }
    }
    return sourceSnapshot.first { $0.id == selectedExerciseID }
  }

  private var libraryList: some View {
    LiftSection(title: isSearching ? "Searching" : "\(results.count) exercises") {
      if !isSearching && results.isEmpty {
        LiftStateMessage(
          symbol: "magnifyingglass",
          title: "No matches",
          message: "Try a muscle or equipment name."
        )
      }
      LazyVStack(spacing: 0) {
        ForEach(results) { exercise in
          exerciseRow(exercise)
        }
      }
    }
  }

  private func exerciseRow(_ exercise: LiftExercise) -> some View {
    let isSelected = onSelect == nil && selectedExerciseID == exercise.id
    return Button {
      if let onSelect {
        onSelect(exercise)
      } else {
        withAnimation(reduceMotion ? LiftMotion.reducedCrossfade : LiftMotion.surface) {
          selectedExerciseID = exercise.id
        }
      }
    } label: {
      LiftRow(
        title: exercise.name.liftDisplayName,
        detail: "\(exercise.muscleGroup) · \(exercise.equipment)".liftDisplayName,
        titleColor: isSelected ? LiftTheme.accent : StrandPalette.textPrimary,
        leading: {
          LiftExerciseThumb(exercise: exercise, size: dynamicTypeSize.isAccessibilitySize ? 64 : 52)
        },
        trailing: {
          Image(systemName: onSelect == nil ? "chevron.right" : "plus")
            .font(.system(size: 13, weight: .semibold))
            .foregroundStyle(isSelected ? LiftTheme.accent : StrandPalette.textTertiary)
            .accessibilityHidden(true)
        }
      )
    }
    .buttonStyle(.plain)
    .accessibilityLabel(onSelect == nil ? exercise.name : "Add \(exercise.name)")
    .accessibilityValue("\(exercise.muscleGroup), \(exercise.equipment)")
    .accessibilityHint(onSelect == nil ? "Shows exercise details" : "Adds this exercise once")
    .accessibilityAddTraits(isSelected ? .isSelected : [])
  }

  private func refreshSource() {
    let snapshot = store.displayExercises
    guard snapshot != sourceSnapshot else { return }
    sourceSnapshot = snapshot
    sourceRevision &+= 1
  }

  private struct SearchRequest: Equatable {
    let query: String
    let sourceRevision: Int
  }
}

private struct ExerciseDetailPanel: View {
  @EnvironmentObject private var store: LiftStore
  let exercise: LiftExercise

  private var sets: [LiftSet] {
    store.sets(for: exercise.id, includeActive: true)
  }

  var body: some View {
    VStack(alignment: .leading, spacing: 16) {
      HStack(alignment: .top, spacing: 14) {
        LiftExerciseThumb(exercise: exercise, size: 96)
        VStack(alignment: .leading, spacing: 6) {
          Text(exercise.name.liftDisplayName)
            .font(StrandFont.title2)
            .foregroundStyle(StrandPalette.textPrimary)
            .lineLimit(3)
            .minimumScaleFactor(0.8)
          Text("\(exercise.muscleGroup) · \(exercise.equipment)".liftDisplayName)
            .font(StrandFont.caption)
            .foregroundStyle(StrandPalette.textSecondary)
          if LiftMedia.imageName(for: exercise) != nil {
            LiftBadge(text: "Databank", tint: StrandPalette.textSecondary)
          }
        }
      }

      HStack(alignment: .top, spacing: 12) {
        LiftMetric(title: "Sets", value: "\(sets.count)")
        LiftMetric(title: "Volume", value: liftVolume(sets.reduce(0) { $0 + $1.volume }))
        LiftMetric(title: "Best", value: liftMeasuredWeight(sets.map(\.estimatedOneRepMax).max() ?? 0))
      }

      ExerciseInformationView(exercise: exercise)

      NavigationLink {
        ExerciseProgressView(exerciseID: exercise.id)
      } label: {
        Label("View progress charts", systemImage: "chart.xyaxis.line")
      }
      .buttonStyle(NoopButtonStyle(.secondary, fullWidth: true))

      LiftDivider()
    }
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
    LiftScreen(
      title: "New exercise",
      subtitle: "Add a move to your local library",
      trailing: {
        NoopIconButton("xmark", accessibilityLabel: "Close") { dismiss() }
      }
    ) {
      LiftTextField(title: "Name", text: $name, placeholder: "Bench press")
      LiftTextField(title: "Muscle", text: $muscleGroup, placeholder: "Chest")
      LiftTextField(title: "Equipment", text: $equipment, placeholder: "Barbell")
      LiftTextField(
        title: "Cues",
        text: $instructions,
        placeholder: "Brace, control, press.",
        axis: .vertical,
        capitalization: .sentences
      )
    }
    .safeAreaInset(edge: .bottom, spacing: 0) {
      NoopButton("Save exercise", systemImage: "checkmark", kind: .primary, fullWidth: true) {
        store.addExercise(name: name, muscleGroup: muscleGroup, equipment: equipment, instructions: instructions)
        dismiss()
      }
      .disabled(!canSave)
      .liftFooterBar()
    }
    .presentationDetents([.medium, .large])
  }
}
