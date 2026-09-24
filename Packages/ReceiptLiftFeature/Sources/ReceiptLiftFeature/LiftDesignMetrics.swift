import SwiftUI

/// Design-lab measurements shared by the host surfaces that adopt Spec 008.
enum LiftDesignMetrics {
  enum Composer {
    static let ordinalFontSize: CGFloat = 9
    static let nameFontSize: CGFloat = 22
    static let artworkSize: CGFloat = 72
    static let loadFontSize: CGFloat = 44
    static let multiplierFontSize: CGFloat = 34
    static let lastSetLimit = 3
    static let warmupChipHorizontalPadding: CGFloat = 12
    static let plateLoaderHorizontalPadding: CGFloat = 12
    static let restInlineSpacing: CGFloat = 4
  }

  enum RestBar {
    static let height: CGFloat = 50
    static let cornerRadius: CGFloat = 15
    static let horizontalPadding: CGFloat = 13
    static let inlineHorizontalPadding: CGFloat = 8
    static let eyebrowFontSize: CGFloat = 9
    static let timerFontSize: CGFloat = 21
    static let actionFontSize: CGFloat = 10
  }

  enum Receipt {
    static let lineInsertionOffset: CGFloat = -8
    static let stampDwellSeconds: TimeInterval = 1.6
  }

  enum PlateLoader {
    static let barWeight: Double = 45
    static let minimumTargetSize: CGFloat = 44
  }

  enum ScheduleWeek {
    static let minimumTargetSize: CGFloat = 44
    static let selectionCornerRadius: CGFloat = 4
  }
}
