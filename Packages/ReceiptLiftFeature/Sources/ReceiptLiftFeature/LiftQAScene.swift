import os
import SwiftUI

/// DEBUG screenshot harness: `--noop-lift-scene <name>` opens a deeper Lift screen straight from launch, so every
/// screen and state can be captured without UI automation. Pair it with `--noop-lift-demo <variant>` (see
/// `ReceiptLiftDemo`). Release builds compile every hook below to nothing.
///
/// Scenes: `routine-preview`, `routine-editor`, `routine-edit`, `schedule-editor`, `library`, `library-detail`,
/// `exercise`, `exercise-info`, `settings`, `receipt`, `receipt-settled`, `live-rest-options`, `live-receipt`,
/// `live-plates`, `live-warmup`, `live-pr`, `live-library`, `live-superset`, `live-exercise`.
enum LiftQAScene {
  #if DEBUG
  static let requested: String? = {
    let arguments = ProcessInfo.processInfo.arguments
    guard let index = arguments.firstIndex(of: "--noop-lift-scene"), arguments.indices.contains(index + 1) else {
      return nil
    }
    return arguments[index + 1].lowercased()
  }()

  /// Keeps the "logged" stamp on screen so the PR moment can be captured.
  static let holdsStamp = ProcessInfo.processInfo.arguments.contains("--noop-lift-hold-stamp")
  #endif

  /// The scene this launch asked for; always nil in release.
  static var current: String? {
    #if DEBUG
    requested
    #else
    nil
    #endif
  }

  static func isRequested(_ names: [String]) -> Bool {
    guard let current else { return false }
    return names.contains(current)
  }

  #if DEBUG
  private static let claimed = OSAllocatedUnfairLock(initialState: Set<String>())
  #endif

  /// True for the first caller at each `site` only: a scene opens its screen once per launch, however often a view
  /// comes back.
  static func claim(_ names: [String], site: String) -> Bool {
    #if DEBUG
    guard isRequested(names) else { return false }
    return claimed.withLock { $0.insert(site).inserted }
    #else
    return false
    #endif
  }
}

private struct LiftQASceneModifier: ViewModifier {
  let names: [String]
  let delay: Duration
  let site: String
  let perform: @MainActor () -> Void

  func body(content: Content) -> some View {
    content.task {
      guard LiftQAScene.isRequested(names) else { return }
      try? await Task.sleep(for: delay)
      guard !Task.isCancelled, LiftQAScene.claim(names, site: site) else { return }
      perform()
    }
  }
}

extension View {
  /// Runs `perform` once this view has appeared, when a QA launch asked for one of `scenes`. A no-op in release.
  @ViewBuilder
  func liftQAScene(
    _ scenes: String...,
    after delay: Duration = .milliseconds(900),
    fileID: String = #fileID,
    line: Int = #line,
    perform: @escaping @MainActor () -> Void
  ) -> some View {
    #if DEBUG
    modifier(LiftQASceneModifier(names: scenes, delay: delay, site: "\(fileID):\(line)", perform: perform))
    #else
    self
    #endif
  }
}
