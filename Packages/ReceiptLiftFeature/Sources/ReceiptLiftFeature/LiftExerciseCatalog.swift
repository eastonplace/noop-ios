import Foundation

enum LiftExerciseCatalog {
  struct SourceExercise: Decodable {
    var id: String
    var name: String
    var bodyPart: String
    var equipment: String
    var instructions: [String: String]
    var target: String
    var image: String?
    var secondaryMuscles: [String]?
    var instructionSteps: [String: [String]]?
    var category: String?

    enum CodingKeys: String, CodingKey {
      case id
      case name
      case bodyPart = "body_part"
      case equipment
      case instructions
      case target
      case image
      case secondaryMuscles = "secondary_muscles"
      case instructionSteps = "instruction_steps"
      case category
    }

    var imageAssetName: String? {
      guard let image else { return nil }
      return LiftExerciseCatalog.assetName(forImagePath: image)
    }

    var liftExercise: LiftExercise {
      LiftExercise(
        id: stableID,
        name: name,
        muscleGroup: target.isEmpty ? bodyPart : target,
        equipment: equipment,
        instructions: instructions["en"] ?? ""
      )
    }

    private var stableID: UUID {
      LiftExerciseCatalog.stableID(for: id)
    }
  }

  private static let normalizationLocale = Locale(identifier: "en_US_POSIX")

  static let records: [SourceExercise] = {
    guard let url = Bundle.module.url(forResource: "exercises", withExtension: "json", subdirectory: "ExerciseCatalog/data"),
          let data = try? Data(contentsOf: url),
          let decoded = try? JSONDecoder().decode([SourceExercise].self, from: data)
    else {
      return []
    }
    return decoded
  }()

  private static let cachedExercises = records.map(\.liftExercise)

  static let imageAssetsByNormalizedName: [String: String] = {
    records.reduce(into: [String: String]()) { result, exercise in
      guard let asset = exercise.imageAssetName else { return }
      result[normalizedName(exercise.name)] = asset
    }
  }()

  private static let recordsByID: [UUID: SourceExercise] = Dictionary(
    uniqueKeysWithValues: records.map { ($0.liftExercise.id, $0) }
  )

  private static let recordsByAsset: [String: SourceExercise] = records.reduce(into: [:]) { result, record in
    if let asset = record.imageAssetName { result[asset] = record }
  }

  static func record(forID id: UUID) -> SourceExercise? { recordsByID[id] }

  static func metadata(for exercise: LiftExercise) -> SourceExercise? {
    if let record = record(forID: exercise.id) { return record }
    // Preserve Lift Receipt's existing starter-routine mappings and saved custom exercises.
    guard let asset = LiftMedia.imageName(forName: exercise.name) else { return nil }
    return recordsByAsset[asset]
  }

  static func catalogExercises() -> [LiftExercise] {
    cachedExercises
  }

  static let catalogExerciseIDs: Set<UUID> = Set(cachedExercises.map(\.id))

  private static func stableID(for sourceID: String) -> UUID {
    let value: UInt64
    if let numericID = UInt64(sourceID) {
      value = numericID
    } else {
      var hash: UInt64 = 14_695_981_039_346_656_037
      for byte in sourceID.utf8 {
        hash ^= UInt64(byte)
        hash &*= 1_099_511_628_211
      }
      value = hash
    }
    let suffix = String(format: "%012llx", value & 0x0000_FFFF_FFFF_FFFF)
    return UUID(uuidString: "00000000-0000-4000-8000-\(suffix)")!
  }

  static func assetName(forImagePath imagePath: String) -> String {
    let filename = URL(fileURLWithPath: imagePath).deletingPathExtension().lastPathComponent
    let safeName = filename.unicodeScalars.map { scalar -> Character in
      if CharacterSet.alphanumerics.contains(scalar) {
        Character(scalar)
      } else {
        "_"
      }
    }
    return "catalog_" + String(safeName)
      .split(separator: "_")
      .joined(separator: "_")
  }

  static func normalizedName(_ name: String) -> String {
    let folded = name.folding(
      options: [.caseInsensitive, .diacriticInsensitive],
      locale: normalizationLocale
    )
    var output = ""
    var previousWasSpace = true

    for scalar in folded.unicodeScalars {
      if CharacterSet.alphanumerics.contains(scalar) {
        output.append(Character(scalar).lowercased())
        previousWasSpace = false
      } else if !previousWasSpace {
        output.append(" ")
        previousWasSpace = true
      }
    }

    return output.trimmingCharacters(in: .whitespacesAndNewlines)
  }
}
