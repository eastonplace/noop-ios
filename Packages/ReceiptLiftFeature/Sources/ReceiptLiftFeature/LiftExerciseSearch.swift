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

  nonisolated static func filter(
    exercises: [LiftExercise],
    query: String,
    limit: Int = 60
  ) -> [LiftExercise] {
    guard limit > 0 else { return [] }
    let needle = LiftExerciseCatalog.normalizedName(query)
    if needle.isEmpty {
      return Array(exercises.prefix(limit))
    }
    return Array(
      exercises.lazy.filter { exercise in
        searchableText(for: exercise).contains(needle)
      }
      .prefix(limit)
    )
  }

  nonisolated static func debouncedFilter(
    exercises: [LiftExercise],
    query: String,
    limit: Int = 60,
    delay: Duration = .milliseconds(150)
  ) async throws -> [LiftExercise] {
    try await Task.sleep(for: delay)
    try Task.checkCancellation()
    let result = filter(exercises: exercises, query: query, limit: limit)
    try Task.checkCancellation()
    return result
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
