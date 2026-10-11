import Foundation

private final class LiftExerciseSearchTextCache: @unchecked Sendable {
  let values: NSCache<NSString, NSString>

  init(countLimit: Int) {
    values = NSCache<NSString, NSString>()
    values.countLimit = countLimit
  }
}

enum LiftExerciseSearch {
  private static let searchableTextCache = LiftExerciseSearchTextCache(countLimit: 4_096)

  /// The exercises that match `query` (name, muscle or equipment), narrowed to one muscle group and one kind of
  /// equipment when given, in the order they were passed in.
  nonisolated static func filter(
    exercises: [LiftExercise],
    query: String,
    muscle: String? = nil,
    equipment: String? = nil,
    limit: Int = 60
  ) -> [LiftExercise] {
    guard limit > 0 else { return [] }
    let needle = LiftExerciseCatalog.normalizedName(query)
    let muscleKey = muscle.map(LiftExerciseCatalog.normalizedName)
    let equipmentKey = equipment.map(LiftExerciseCatalog.normalizedName)
    if needle.isEmpty, muscleKey == nil, equipmentKey == nil {
      return Array(exercises.prefix(limit))
    }
    return Array(
      exercises.lazy.filter { exercise in
        if let muscleKey, LiftExerciseCatalog.normalizedName(exercise.muscleGroup) != muscleKey { return false }
        if let equipmentKey, LiftExerciseCatalog.normalizedName(exercise.equipment) != equipmentKey { return false }
        return needle.isEmpty || searchableText(for: exercise).contains(needle)
      }
      .prefix(limit)
    )
  }

  nonisolated static func debouncedFilter(
    exercises: [LiftExercise],
    query: String,
    muscle: String? = nil,
    equipment: String? = nil,
    limit: Int = 60,
    delay: Duration = .milliseconds(150)
  ) async throws -> [LiftExercise] {
    try await Task.sleep(for: delay)
    try Task.checkCancellation()
    let result = filter(exercises: exercises, query: query, muscle: muscle, equipment: equipment, limit: limit)
    try Task.checkCancellation()
    return result
  }

  /// The muscle groups and kinds of equipment the exercises use, most used first (ties by name), each spelled as its
  /// first exercise spells it. Blank values are left out.
  nonisolated static func facets(for exercises: [LiftExercise]) -> (muscles: [String], equipment: [String]) {
    func ranked(_ values: [String]) -> [String] {
      var counts: [String: Int] = [:]
      var spelling: [String: String] = [:]
      for value in values {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { continue }
        let key = LiftExerciseCatalog.normalizedName(trimmed)
        counts[key, default: 0] += 1
        if spelling[key] == nil { spelling[key] = trimmed }
      }
      return counts.keys
        .sorted { left, right in
          let (a, b) = (counts[left] ?? 0, counts[right] ?? 0)
          return a != b ? a > b : left < right
        }
        .compactMap { spelling[$0] }
    }
    return (ranked(exercises.map(\.muscleGroup)), ranked(exercises.map(\.equipment)))
  }

  private nonisolated static func searchableText(for exercise: LiftExercise) -> String {
    let cacheKey = [
      exercise.id.uuidString,
      exercise.name,
      exercise.muscleGroup,
      exercise.equipment
    ].joined(separator: "|") as NSString

    if let cached = searchableTextCache.values.object(forKey: cacheKey) {
      return cached as String
    }

    let normalized = LiftExerciseCatalog.normalizedName(
      "\(exercise.name) \(exercise.muscleGroup) \(exercise.equipment)"
    )
    searchableTextCache.values.setObject(normalized as NSString, forKey: cacheKey)
    return normalized
  }
}
