import SwiftUI

struct ExerciseLibraryView: View {
  @Environment(\.dynamicTypeSize) private var dynamicTypeSize
  @Environment(\.accessibilityReduceMotion) private var reduceMotion
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
    ScrollView {
      LazyVStack(alignment: .leading, spacing: 16) {
        header

        if onSelect == nil, let selectedExercise {
          ExerciseDetailReceipt(exercise: selectedExercise)
            .transition(reduceMotion ? .opacity : .move(edge: .top).combined(with: .opacity))
        }

        if onSelect != nil {
          Text("SELECT MOVE / APPLY TO WORKOUT")
            .font(.receipt(10, weight: .black))
            .tracking(0.7)
            .foregroundStyle(LiftTheme.paper)
            .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
            .padding(.horizontal, 12)
            .background(LiftTheme.ink)
            .accessibilityLabel("Select a move to apply to the workout")
        }

        searchField
        libraryList
      }
      .padding(.horizontal, 18)
      .padding(.top, 18)
      .padding(.bottom, 78)
    }
    .scrollIndicators(.hidden)
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

  private var header: some View {
    VStack(alignment: .leading, spacing: 10) {
      HStack(alignment: .top) {
        VStack(alignment: .leading, spacing: 0) {
          Text("MOVE")
            .font(.receiptCondensed(48, weight: .black))
          Text("BANK")
            .font(.receiptCondensed(48, weight: .black))
            .offset(y: -6)
        }
        Spacer()
        if onSelect == nil {
          ReceiptSecondaryButton(title: "Add", systemImage: "plus", tint: LiftTheme.ink) {
            showingAddExercise = true
          }
        }
      }
      ReceiptDashedRule()
      Text("\(sourceSnapshot.count) LOCAL EXERCISES / PROGRAM MOVES PRINT FIRST")
        .font(.receipt(10, weight: .black))
        .foregroundStyle(LiftTheme.inkSecondary)
    }
  }

  private var searchField: some View {
    HStack(spacing: 10) {
      Image(systemName: "magnifyingglass")
        .accessibilityHidden(true)
      TextField("Search name, muscle, or equipment", text: $query)
        .textInputAutocapitalization(.never)
        .autocorrectionDisabled()
        .font(.receipt(12, weight: .bold))
      if !query.isEmpty {
        Button {
          query = ""
        } label: {
          Image(systemName: "xmark.circle.fill")
            .frame(width: 44, height: 44)
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Clear Search")
      }
    }
    .padding(.leading, 12)
    .frame(minHeight: 48)
    .overlay(
      RoundedRectangle(cornerRadius: 5)
        .stroke(LiftTheme.ink.opacity(0.2), lineWidth: 1)
    )
  }

  private var libraryList: some View {
    VStack(alignment: .leading, spacing: 10) {
      HStack(spacing: 8) {
        Text(isSearching ? "SEARCHING" : "\(results.count) EXERCISES")
          .font(.receipt(11, weight: .black))
          .foregroundStyle(LiftTheme.ink)
          .fixedSize(horizontal: true, vertical: false)
        Rectangle()
          .fill(LiftTheme.ink.opacity(0.16))
          .frame(height: 1)
      }
      if !isSearching && results.isEmpty {
        Text("NO MATCHES / TRY A MUSCLE OR EQUIPMENT")
          .font(.receipt(10, weight: .bold))
          .foregroundStyle(LiftTheme.inkSecondary)
          .frame(maxWidth: .infinity, minHeight: 88, alignment: .leading)
      }
      LazyVStack(spacing: 0) {
        ForEach(Array(results.enumerated()), id: \.element.id) { index, exercise in
          exerciseRow(exercise, index: index)
          if exercise.id != results.last?.id { ReceiptDashedRule() }
        }
      }
    }
  }

  private func exerciseRow(_ exercise: LiftExercise, index: Int) -> some View {
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
      HStack(spacing: 12) {
        Text(String(format: "%02d", index + 1))
          .font(.receipt(10, weight: .bold))
          .foregroundStyle(isSelected ? LiftTheme.paper.opacity(0.72) : LiftTheme.inkSecondary)
          .frame(width: 24, alignment: .leading)
        LiftExerciseThumb(exercise: exercise, size: dynamicTypeSize.isAccessibilitySize ? 64 : 52)
        VStack(alignment: .leading, spacing: 3) {
          Text(exercise.name.uppercased())
            .font(.receipt(12, weight: .black))
            .foregroundStyle(isSelected ? LiftTheme.paper : LiftTheme.ink)
            .fixedSize(horizontal: false, vertical: true)
          Text("\(exercise.muscleGroup) / \(exercise.equipment)".uppercased())
            .font(.receipt(9, weight: .bold))
            .foregroundStyle(isSelected ? LiftTheme.paper.opacity(0.72) : LiftTheme.inkSecondary)
            .fixedSize(horizontal: false, vertical: true)
        }
        Spacer(minLength: 8)
        Image(systemName: onSelect == nil ? "chevron.right" : "plus")
          .foregroundStyle(isSelected ? LiftTheme.paper : LiftTheme.ink)
          .accessibilityHidden(true)
      }
      .frame(maxWidth: .infinity, minHeight: 60, alignment: .leading)
      .padding(.horizontal, 8)
      .background(isSelected ? LiftTheme.ink : LiftTheme.paper)
      .contentShape(Rectangle())
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

private struct ExerciseDetailReceipt: View {
  @EnvironmentObject private var store: LiftStore
  let exercise: LiftExercise

  private var sets: [LiftSet] {
    store.sets(for: exercise.id, includeActive: true)
  }

  var body: some View {
    VStack(alignment: .leading, spacing: 13) {
      HStack(alignment: .top, spacing: 13) {
        LiftExerciseThumb(exercise: exercise, size: 96)
        VStack(alignment: .leading, spacing: 5) {
          Text(exercise.name.uppercased())
            .font(.receiptCondensed(34, weight: .black))
            .foregroundStyle(LiftTheme.ink)
            .lineLimit(3)
            .minimumScaleFactor(0.68)
          Text("\(exercise.muscleGroup) / \(exercise.equipment)".uppercased())
            .font(.receipt(10, weight: .black))
            .foregroundStyle(LiftTheme.ink)
          if LiftMedia.imageName(for: exercise) != nil {
            Text("DATABANK")
              .font(.receipt(9, weight: .black))
              .tracking(1)
              .padding(.horizontal, 7)
              .padding(.vertical, 4)
              .overlay(Rectangle().stroke(LiftTheme.ink, lineWidth: 1))
              .padding(.top, 2)
          }
        }
      }

      ReceiptDashedRule()

      HStack {
        ReceiptMetric(title: "Sets", value: "\(sets.count)", tint: LiftTheme.ink)
        ReceiptMetric(title: "Volume", value: liftVolume(sets.reduce(0) { $0 + $1.volume }), tint: LiftTheme.ink)
        ReceiptMetric(title: "Best", value: liftMeasuredWeight(sets.map(\.estimatedOneRepMax).max() ?? 0), tint: LiftTheme.ink)
      }

      ExerciseInformationView(exercise: exercise)
      NavigationLink("View progress charts") {
        ExerciseProgressView(exerciseID: exercise.id)
      }
      .frame(minHeight: 44)

    }
    .padding(.vertical, 4)
  }
}

private struct AddExerciseSheet: View {
  @Environment(\.dismiss) private var dismiss
  @EnvironmentObject private var store: LiftStore
  @State private var name = ""
  @State private var muscleGroup = ""
  @State private var equipment = ""
  @State private var instructions = ""

  var body: some View {
    VStack(alignment: .leading, spacing: 14) {
      HStack(alignment: .top) {
        VStack(alignment: .leading, spacing: 0) {
          Text("NEW")
            .font(.receiptCondensed(44, weight: .black))
          Text("MOVE")
            .font(.receiptCondensed(44, weight: .black))
            .offset(y: -6)
        }
        Spacer()
        Button {
          dismiss()
        } label: {
          Image(systemName: "xmark")
            .frame(width: 34, height: 34)
        }
        .buttonStyle(ReceiptIconButtonStyle())
        .padding(.top, 8)
        .padding(.trailing, 8)
      }

      ReceiptDashedRule()

      ReceiptField(title: "Name", text: $name, placeholder: "Bench Press")
      ReceiptField(title: "Muscle", text: $muscleGroup, placeholder: "Chest")
      ReceiptField(title: "Equipment", text: $equipment, placeholder: "Barbell")
      ReceiptField(title: "Cues", text: $instructions, placeholder: "Brace, control, press.", axis: .vertical)

      Spacer(minLength: 0)

      ReceiptPrimaryButton(title: "Save Exercise", systemImage: "checkmark", tint: LiftTheme.ink) {
        store.addExercise(name: name, muscleGroup: muscleGroup, equipment: equipment, instructions: instructions)
        dismiss()
      }
      .opacity(name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? 0.42 : 1)
      .disabled(name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
    }
    .padding(18)
    .presentationDetents([.medium, .large])
    .liftScreenBackground()
  }
}

private struct ReceiptField: View {
  let title: String
  @Binding var text: String
  let placeholder: String
  var axis: Axis = .horizontal

  var body: some View {
    VStack(alignment: .leading, spacing: 5) {
      Text(title.uppercased())
        .font(.receipt(9, weight: .black))
        .foregroundStyle(LiftTheme.inkSecondary)
      TextField(placeholder.uppercased(), text: $text, axis: axis)
        .font(.receipt(13, weight: .bold))
        .textInputAutocapitalization(.words)
        .padding(12)
        .background(LiftTheme.paper, in: RoundedRectangle(cornerRadius: 5))
        .overlay(
          RoundedRectangle(cornerRadius: 5)
            .stroke(LiftTheme.ink.opacity(0.16), lineWidth: 1)
        )
    }
  }
}
