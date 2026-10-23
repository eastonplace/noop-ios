import Foundation

/// Finds the library exercise a spreadsheet name means, so "Bench Press" lands on "Barbell Bench Press" instead of becoming
/// a custom exercise. It only answers when there is one clear candidate; anything else stays custom.
///
/// Tiers, most exact first:
/// 1. The same words ignoring case, punctuation and spacing, with a singular or plural last word
///    ("pull up", "Pull-Ups", "pullup").
/// 2. The same words once equipment qualifiers (barbell, dumbbell, machine, cable) are set aside. A qualifier the sheet
///    names must not contradict the exercise's; an unqualified name means the barbell lift when that is the only one.
/// 3. Every meaningful word of the sheet's name (two or more) appears in exactly one library exercise
///    ("Seated Overhead Press" is only "Barbell Seated Overhead Press"). Two or more candidates stay custom.
///    A bare "row" is first read as the common "bent over row", so "Barbell Row" finds "Barbell Bent Over Row".
///
/// The exercise model has no aliases, so there is nothing else to consult.
struct LiftExerciseMatcher {
  private struct Entry {
    let exercise: LiftExercise
    let qualifiers: Set<String>
  }

  private static let qualifiers: Set<String> = ["barbell", "dumbbell", "machine", "cable"]
  private static let abbreviations: [String: String] = ["bb": "barbell", "db": "dumbbell", "dumbbells": "dumbbell"]

  private static let fillerWords: Set<String> = ["a", "an", "the", "of", "with", "and", "or"]
  /// A generic core name people shorten, and the library words it usually means.
  private static let shorthand: [[String]: [String]] = [["row"]: ["bent", "over", "row"]]

  private let bySpelling: [String: [Entry]]
  private let byCore: [String: [Entry]]
  private let tokenSets: [(entry: Entry, tokens: Set<String>)]

  init(_ exercises: [LiftExercise]) {
    var spelling: [String: [Entry]] = [:]
    var core: [String: [Entry]] = [:]
    for exercise in exercises {
      let words = Self.words(exercise.name)
      let entry = Entry(exercise: exercise, qualifiers: Set(words.filter(Self.qualifiers.contains)))
      let spellingKey = Self.key(words)
      if !spellingKey.isEmpty { spelling[spellingKey, default: []].append(entry) }
      let coreKey = Self.key(words.filter { !Self.qualifiers.contains($0) })
      if !coreKey.isEmpty { core[coreKey, default: []].append(entry) }
    }
    bySpelling = spelling
    byCore = core
    tokenSets = exercises.map { exercise in
      let words = Self.words(exercise.name)
      return (Entry(exercise: exercise, qualifiers: Set(words.filter(Self.qualifiers.contains))), Self.tokens(words))
    }
  }

  /// The one library exercise `name` means, or nil when nothing fits or several do. `excluding` holds exercises the caller
  /// already used in the same routine; a match that is one of them is dropped rather than collapsing two rows into one.
  func match(_ name: String, excluding used: Set<UUID> = []) -> LiftExercise? {
    let words = Self.words(name)
    guard let found = resolveWithShorthand(words) ?? resolveBySubset(words), !used.contains(found.id) else { return nil }
    return found
  }

  private func resolveWithShorthand(_ words: [String]) -> LiftExercise? {
    if let found = resolve(words) { return found }
    let core = words.filter { !Self.qualifiers.contains($0) }.map(Self.singular)
    guard let expanded = Self.shorthand[core] else { return nil }
    return resolve(words.filter(Self.qualifiers.contains) + expanded)
  }

  /// The only library exercise that contains every meaningful word of the name, or nil for none or several.
  private func resolveBySubset(_ words: [String]) -> LiftExercise? {
    let wanted = Self.tokens(words)
    guard wanted.count >= 2 else { return nil }
    let candidates = tokenSets.filter { wanted.isSubset(of: $0.tokens) }
    return candidates.count == 1 ? candidates[0].entry.exercise : nil
  }

  private static func tokens(_ words: [String]) -> Set<String> {
    Set(words.filter { !fillerWords.contains($0) }.map(singular))
  }

  private func resolve(_ words: [String]) -> LiftExercise? {
    let spellingKey = Self.key(words)
    guard !spellingKey.isEmpty else { return nil }
    if let same = bySpelling[spellingKey] { return same.count == 1 ? same[0].exercise : nil }

    let asked = Set(words.filter(Self.qualifiers.contains))
    guard var pool = byCore[Self.key(words.filter { !Self.qualifiers.contains($0) })] else { return nil }
    if !asked.isEmpty {
      // A named qualifier rules out another equipment ("Dumbbell Row" is never "Cable Row"); a generic entry still fits.
      pool = pool.filter { $0.qualifiers == asked || $0.qualifiers.isEmpty }
      let exact = pool.filter { $0.qualifiers == asked }
      if exact.count == 1 { return exact[0].exercise }
      if !exact.isEmpty { return nil }
    }
    if pool.count == 1 { return pool[0].exercise }
    if asked.isEmpty {
      let barbell = pool.filter { $0.qualifiers == ["barbell"] }
      if barbell.count == 1 { return barbell[0].exercise }
    }
    return nil
  }

  private static func words(_ name: String) -> [String] {
    LiftExerciseCatalog.normalizedName(name)
      .split(separator: " ")
      .map { abbreviations[String($0)] ?? String($0) }
  }

  /// The words run together with the last one made singular, so spacing and plurals stop mattering.
  private static func key(_ words: [String]) -> String {
    guard let last = words.last else { return "" }
    return (words.dropLast() + [singular(last)]).joined()
  }

  private static func singular(_ word: String) -> String {
    guard word.count > 2 else { return word }
    if word.hasSuffix("ies") { return String(word.dropLast(3)) + "y" }
    for ending in ["ches", "shes", "sses", "xes"] where word.hasSuffix(ending) { return String(word.dropLast(2)) }
    if word.hasSuffix("s"), !word.hasSuffix("ss"), !word.hasSuffix("us"), !word.hasSuffix("is") { return String(word.dropLast()) }
    return word
  }
}
