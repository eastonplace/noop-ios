import SwiftUI
import UIKit

enum LiftMotion {
  enum Parameters {
    static let printLineResponse = 0.35
    static let printLineDamping = 0.80
    static let surfaceResponse = 0.40
    static let surfaceDamping = 0.75
    static let composeDuration = 0.30
    static let reducedCrossfadeDuration = 0.16
    static let continuityResponse = 0.50
    static let continuityDamping = 0.85
    static let receiptPrintDuration = 0.80
  }

  static let printLine = Animation.spring(
    response: Parameters.printLineResponse,
    dampingFraction: Parameters.printLineDamping
  )
  static let surface = Animation.spring(
    response: Parameters.surfaceResponse,
    dampingFraction: Parameters.surfaceDamping
  )
  static let compose = Animation.snappy(duration: Parameters.composeDuration)
  static let reducedCrossfade = Animation.linear(duration: Parameters.reducedCrossfadeDuration)
  static let continuity = Animation.spring(
    response: Parameters.continuityResponse,
    dampingFraction: Parameters.continuityDamping
  )
  static let receiptPrint = Animation.easeOut(duration: Parameters.receiptPrintDuration)

  static func resolved(_ base: Animation, reduceMotion: Bool) -> Animation? {
    reduceMotion ? nil : base
  }
}

func liftAnimation(_ base: Animation, reduceMotion: Bool) -> Animation? {
  LiftMotion.resolved(base, reduceMotion: reduceMotion)
}

@MainActor
func liftAnimation(_ base: Animation) -> Animation? {
  liftAnimation(base, reduceMotion: UIAccessibility.isReduceMotionEnabled)
}

enum LiftHaptics {
  enum Event: Equatable, Sendable {
    case selection
    case setLogged
    case exerciseCompleted
    case personalRecord
    case workoutFinished
  }

  enum Feedback: Equatable, Sendable {
    case selection
    case lightImpact
    case rigidImpact
    case success
  }

  static func shouldPlay(enabled: Bool) -> Bool {
    enabled
  }

  static func feedback(for event: Event) -> Feedback {
    switch event {
    case .selection:
      .selection
    case .setLogged:
      .lightImpact
    case .exerciseCompleted:
      .rigidImpact
    case .personalRecord, .workoutFinished:
      .success
    }
  }

  @MainActor
  static func play(_ event: Event, enabled: Bool) {
    guard shouldPlay(enabled: enabled) else { return }
    switch feedback(for: event) {
    case .selection:
      UISelectionFeedbackGenerator().selectionChanged()
    case .lightImpact:
      UIImpactFeedbackGenerator(style: .light).impactOccurred()
    case .rigidImpact:
      UIImpactFeedbackGenerator(style: .rigid).impactOccurred()
    case .success:
      UINotificationFeedbackGenerator().notificationOccurred(.success)
    }
  }

  @MainActor
  static func setLogged(enabled: Bool) {
    play(.setLogged, enabled: enabled)
  }

  @MainActor
  static func exerciseCompleted(enabled: Bool) {
    play(.exerciseCompleted, enabled: enabled)
  }

  @MainActor
  static func workoutFinished(enabled: Bool) {
    play(.workoutFinished, enabled: enabled)
  }
}
