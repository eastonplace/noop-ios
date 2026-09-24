import SwiftUI

struct ReceiptSheet<Content: View>: View {
  @ViewBuilder let content: Content

  init(@ViewBuilder content: () -> Content) {
    self.content = content()
  }

  var body: some View {
    VStack(alignment: .leading, spacing: 12) {
      content
    }
    .padding(.horizontal, 16)
    .padding(.vertical, 12)
    .frame(maxWidth: .infinity, alignment: .leading)
    .background(LiftTheme.paper)
  }
}

struct ReceiptHeader: View {
  let title: String
  var subtitle: String? = nil
  var trailing: String? = nil

  var body: some View {
    VStack(alignment: .leading, spacing: 5) {
      HStack(alignment: .firstTextBaseline, spacing: 12) {
        Text(title)
          .font(.system(.title2, design: .default).weight(.bold))
          .foregroundStyle(LiftTheme.ink)
          .fixedSize(horizontal: false, vertical: true)
        Spacer(minLength: 8)
        if let trailing {
          Text(trailing.uppercased())
            .font(.subheadline)
            .foregroundStyle(LiftTheme.inkSecondary)
            .multilineTextAlignment(.trailing)
        }
      }
      if let subtitle {
        Text(subtitle)
          .font(.subheadline)
          .foregroundStyle(LiftTheme.inkSecondary)
      }
    }
  }
}

struct ReceiptColumns: View {
  let columns: [(String, Alignment)]

  init(_ columns: [(String, Alignment)]) {
    self.columns = columns
  }

  var body: some View {
    HStack(spacing: 8) {
      ForEach(Array(columns.enumerated()), id: \.offset) { _, column in
        Text(column.0.uppercased())
          .font(.receipt(9, weight: .bold))
          .tracking(0.5)
          .foregroundStyle(LiftTheme.inkSecondary)
          .frame(maxWidth: .infinity, alignment: column.1)
      }
    }
  }
}

struct ReceiptLine: View {
  var index: Int?
  let title: String
  var detail: String? = nil
  var value: String? = nil
  var thumb: LiftExercise? = nil

  var body: some View {
    HStack(alignment: .top, spacing: 9) {
      if let index {
        Text(String(format: "%02d", index))
          .font(.receipt(11, weight: .bold))
          .foregroundStyle(LiftTheme.inkSecondary)
          .lineLimit(1)
          .minimumScaleFactor(0.5)
          .allowsTightening(true)
          .frame(width: 24, alignment: .leading)
      }
      if let thumb {
        LiftExerciseThumb(exercise: thumb, size: 40, showsBorder: false)
      }
      VStack(alignment: .leading, spacing: 3) {
        Text(title.uppercased())
          .font(.receipt(12, weight: .black))
          .foregroundStyle(LiftTheme.ink)
          .fixedSize(horizontal: false, vertical: true)
        if let detail {
          Text(detail.uppercased())
            .font(.receipt(9, weight: .medium))
            .foregroundStyle(LiftTheme.inkSecondary)
            .fixedSize(horizontal: false, vertical: true)
        }
      }
      .frame(maxWidth: .infinity, alignment: .leading)
      if let value {
        Text(value.uppercased())
          .font(.receipt(11, weight: .black))
          .monospacedDigit()
          .foregroundStyle(LiftTheme.ink)
          .fixedSize(horizontal: true, vertical: false)
          .layoutPriority(1)
      }
    }
  }
}

struct ReceiptRule: View {
  var body: some View {
    Rectangle()
      .fill(LiftTheme.rule)
      .frame(height: 1)
  }
}

struct ReceiptDashedRule: View {
  var body: some View {
    Rectangle()
      .fill(.clear)
      .frame(height: 1)
      .overlay {
        GeometryReader { proxy in
          Path { path in
            path.move(to: .zero)
            path.addLine(to: CGPoint(x: proxy.size.width, y: 0))
          }
          .stroke(style: StrokeStyle(lineWidth: 1, dash: [2.5, 3.5]))
          .foregroundStyle(LiftTheme.rule)
        }
      }
  }
}

struct ReceiptTotals: View {
  let rows: [(String, String)]

  var body: some View {
    VStack(spacing: 7) {
      ReceiptRule()
      ForEach(Array(rows.enumerated()), id: \.offset) { _, row in
        HStack(alignment: .firstTextBaseline, spacing: 12) {
          Text(row.0.uppercased())
            .font(.receipt(10, weight: .bold))
            .foregroundStyle(LiftTheme.inkSecondary)
          Spacer(minLength: 8)
          Text(row.1.uppercased())
            .font(.receipt(13, weight: .black))
            .monospacedDigit()
            .fixedSize(horizontal: true, vertical: false)
        }
      }
    }
  }
}

struct ReceiptEdge: View {
  nonisolated static func toothCount(for width: CGFloat) -> Int {
    max(Int(ceil(width / 8)), 1)
  }

  var body: some View {
    Canvas { context, size in
      let count = Self.toothCount(for: size.width)
      let width = size.width / CGFloat(count)
      var path = Path()
      path.move(to: .zero)
      for index in 0...count {
        let x = min(CGFloat(index) * width, size.width)
        let y: CGFloat = index.isMultiple(of: 2) ? 0 : 8
        path.addLine(to: CGPoint(x: x, y: y))
      }
      path.addLine(to: CGPoint(x: size.width, y: 8))
      path.addLine(to: CGPoint(x: 0, y: 8))
      path.closeSubpath()
      context.fill(path, with: .color(LiftTheme.paper))
    }
    .frame(height: 8)
    .drawingGroup()
  }
}

struct BarcodeView: View {
  let seed: String

  nonisolated static func pattern(seed: String) -> [Int] {
    var result = [2, 1, 2, 1]
    let bytes = seed.isEmpty ? [UInt8(0)] : Array(seed.utf8)
    for byte in bytes {
      result.append(Int(byte & 0b11) + 1)
      result.append(Int((byte >> 2) & 0b11) + 1)
    }
    result.append(contentsOf: [3, 1, 1, 2])
    return result
  }

  var body: some View {
    Canvas { context, size in
      let pattern = Self.pattern(seed: seed)
      let units = max(pattern.reduce(0, +), 1)
      let unitWidth = size.width / CGFloat(units)
      var x: CGFloat = 0
      for (index, width) in pattern.enumerated() {
        let barWidth = CGFloat(width) * unitWidth
        if index.isMultiple(of: 2) {
          context.fill(
            Path(CGRect(x: x, y: 0, width: max(barWidth, 1), height: size.height)),
            with: .color(LiftTheme.ink)
          )
        }
        x += barWidth
      }
    }
    .frame(height: 42)
    .drawingGroup()
    .accessibilityHidden(true)
  }
}

struct PrintedSetLine: View {
  let index: Int?
  let title: String
  var detail: String? = nil
  var value: String? = nil
  var thumb: LiftExercise? = nil

  @Environment(\.accessibilityReduceMotion) private var reduceMotion

  var body: some View {
    ReceiptLine(index: index, title: title, detail: detail, value: value, thumb: thumb)
      .transition(
        reduceMotion
          ? .opacity
          : .asymmetric(
            insertion: .offset(y: -8).combined(with: .opacity),
            removal: .opacity
          )
      )
  }
}

struct ReceiptMetric: View {
  let title: String
  let value: String
  var tint: Color = LiftTheme.accent

  var body: some View {
    VStack(alignment: .leading, spacing: 4) {
      Text(title.uppercased())
        .font(.receipt(9, weight: .bold))
        .foregroundStyle(LiftTheme.inkSecondary)
      Text(value)
        .font(.receipt(15, weight: .black))
        .foregroundStyle(tint)
        .lineLimit(1)
        .minimumScaleFactor(0.62)
    }
    .frame(maxWidth: .infinity, alignment: .leading)
  }
}

struct ReceiptSectionLabel: View {
  let title: String

  var body: some View {
    HStack(spacing: 8) {
      Text(title.uppercased())
        .font(.receipt(11, weight: .black))
        .foregroundStyle(LiftTheme.ink)
      Rectangle()
        .fill(LiftTheme.ink.opacity(0.16))
        .frame(height: 1)
    }
  }
}

struct ReceiptPrimaryButton: View {
  let title: String
  var systemImage: String? = nil
  var tint: Color = LiftTheme.accent
  let action: () -> Void

  @State private var pressed = false

  var body: some View {
    Button {
      withAnimation(LiftMotion.surface) {
        pressed = true
      }
      action()
      DispatchQueue.main.asyncAfter(deadline: .now() + 0.14) {
        withAnimation(LiftMotion.surface) {
          pressed = false
        }
      }
    } label: {
      HStack(spacing: 10) {
        if let systemImage {
          Image(systemName: systemImage)
            .font(.receipt(14, weight: .black))
        }
        Text(title)
          .font(.headline)
          .lineLimit(1)
          .minimumScaleFactor(0.68)
          .allowsTightening(true)
      }
      .foregroundStyle(LiftTheme.onAccent)
      .frame(maxWidth: .infinity, minHeight: 50)
      .padding(.horizontal, 10)
      .background(tint, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
      .scaleEffect(pressed ? 0.965 : 1)
      .offset(y: pressed ? 2 : 0)
    }
    .buttonStyle(.plain)
  }
}

struct ReceiptSecondaryButton: View {
  let title: String
  var systemImage: String? = nil
  var tint: Color = LiftTheme.accent
  var fillsWidth = false
  let action: () -> Void

  var body: some View {
    Button(action: action) {
      HStack(spacing: 7) {
        if let systemImage {
          Image(systemName: systemImage)
        }
        Text(title)
          .lineLimit(1)
          .minimumScaleFactor(0.62)
          .allowsTightening(true)
      }
      .font(.subheadline.weight(.semibold))
      .foregroundStyle(tint)
      .frame(maxWidth: fillsWidth ? .infinity : nil, minHeight: 44)
      .padding(.horizontal, fillsWidth ? 8 : 10)
      .overlay(
        RoundedRectangle(cornerRadius: 12, style: .continuous)
          .stroke(tint.opacity(0.42), lineWidth: 1)
      )
    }
    .buttonStyle(.plain)
    .accessibilityLabel(title)
  }
}

struct LiftExerciseThumb: View {
  let exercise: LiftExercise?
  var size: CGFloat = 66
  var showsBorder = true

  init(exercise: LiftExercise?, size: CGFloat = 66, showsBorder: Bool = true) {
    self.exercise = exercise
    self.size = size
    self.showsBorder = showsBorder
  }

  init(name: String, size: CGFloat = 66, showsBorder: Bool = true) {
    self.exercise = LiftExercise(id: UUID(), name: name, muscleGroup: "", equipment: "", instructions: "")
    self.size = size
    self.showsBorder = showsBorder
  }

  var body: some View {
    Group {
      if let exercise, let asset = LiftMedia.imageName(for: exercise) {
        Image(asset, bundle: .module)
          .resizable()
          .interpolation(.high)
          .scaledToFit()
      } else {
        Image(systemName: "figure.strengthtraining.traditional")
          .font(.system(size: size * 0.42, weight: .bold))
          .foregroundStyle(LiftTheme.ink.opacity(0.72))
      }
    }
    .frame(width: size, height: size)
  }
}

struct ReceiptStepper: View {
  let title: String
  let value: String
  let decrement: () -> Void
  let increment: () -> Void
  var decrementLarge: (() -> Void)? = nil
  var incrementLarge: (() -> Void)? = nil

  var body: some View {
    HStack(spacing: 12) {
      if let decrementLarge {
        ReceiptPressControl(
          systemImage: "minus",
          accessibilityLabel: "Decrease \(title)",
          action: decrement,
          longPressAction: decrementLarge
        )
      } else {
        Button(action: decrement) {
          Image(systemName: "minus")
            .frame(width: 44, height: 44)
        }
        .buttonStyle(ReceiptIconButtonStyle())
        .accessibilityLabel("Decrease \(title)")
      }

      VStack(spacing: 2) {
        Text(title)
          .font(.receipt(9, weight: .bold))
          .foregroundStyle(LiftTheme.inkSecondary)
        Text(value)
          .font(.receipt(19, weight: .black))
          .foregroundStyle(LiftTheme.ink)
          .monospacedDigit()
          .lineLimit(1)
          .minimumScaleFactor(0.7)
      }
      .frame(maxWidth: .infinity)

      if let incrementLarge {
        ReceiptPressControl(
          systemImage: "plus",
          accessibilityLabel: "Increase \(title)",
          action: increment,
          longPressAction: incrementLarge
        )
      } else {
        Button(action: increment) {
          Image(systemName: "plus")
            .frame(width: 44, height: 44)
        }
        .buttonStyle(ReceiptIconButtonStyle())
        .accessibilityLabel("Increase \(title)")
      }
    }
  }
}

private struct ReceiptPressControl: View {
  let systemImage: String
  let accessibilityLabel: String
  let action: () -> Void
  let longPressAction: () -> Void

  var body: some View {
    Image(systemName: systemImage)
      .font(.headline)
      .foregroundStyle(LiftTheme.ink)
      .frame(width: 44, height: 44)
      .background(
        LiftTheme.ink.opacity(0.07),
        in: RoundedRectangle(cornerRadius: 5)
      )
      .contentShape(Rectangle())
      .gesture(
        LongPressGesture(minimumDuration: 0.45, maximumDistance: 10)
          .exclusively(before: TapGesture())
          .onEnded { value in
            switch value {
            case .first(let didLongPress):
              if didLongPress {
                longPressAction()
              }
            case .second:
              action()
            }
          }
      )
      .accessibilityElement()
      .accessibilityAddTraits(.isButton)
      .accessibilityLabel(accessibilityLabel)
      .accessibilityAction {
        action()
      }
      .accessibilityAction(named: "Change by 25") {
        longPressAction()
      }
  }
}

struct ReceiptIconButtonStyle: ButtonStyle {
  func makeBody(configuration: Configuration) -> some View {
    configuration.label
      .font(.receipt(13, weight: .black))
      .foregroundStyle(LiftTheme.ink)
      .background(LiftTheme.ink.opacity(configuration.isPressed ? 0.14 : 0.07), in: RoundedRectangle(cornerRadius: 5))
      .scaleEffect(configuration.isPressed ? 0.90 : 1)
      .animation(LiftMotion.surface, value: configuration.isPressed)
  }
}

struct ReceiptTabBar: View {
  @Binding var selectedTab: LiftTab

  var body: some View {
    HStack(spacing: 5) {
      ForEach(LiftTab.allCases) { tab in
        Button {
          withAnimation(LiftMotion.compose) {
            selectedTab = tab
          }
        } label: {
          VStack(spacing: 2) {
            Image(systemName: tab.systemImage)
              .font(.system(size: 15, weight: .black))
            Text(tab.title)
              .font(.caption2.weight(.semibold))
              .tracking(0.3)
          }
          .foregroundStyle(selectedTab == tab ? LiftTheme.paper : LiftTheme.ink.opacity(0.58))
          .frame(maxWidth: .infinity)
          .padding(.vertical, 7)
          .background(selectedTab == tab ? LiftTheme.ink : .clear, in: RoundedRectangle(cornerRadius: 4))
        }
        .buttonStyle(.plain)
      }
    }
    .padding(.horizontal, 8)
    .padding(.top, 6)
    .padding(.bottom, 2)
    .background(LiftTheme.paper)
    .overlay(alignment: .top) { ReceiptRule() }
  }
}

private struct ReceiptLivePreview: View {
  let title: String

  private let exercise = LiftExercise(
    id: UUID(uuidString: "00000000-0000-4000-8000-000000000321")!,
    name: "Incline Dumbbell Press",
    muscleGroup: "Chest",
    equipment: "Dumbbells",
    instructions: ""
  )

  var body: some View {
    ScrollView {
      ReceiptSheet {
        ReceiptHeader(title: title, subtitle: "Jul 10 · 44:18", trailing: "#000241")
        ReceiptDashedRule()
        ReceiptColumns([("#", .leading), ("Exercise", .leading), ("Volume", .trailing)])
        PrintedSetLine(
          index: 1,
          title: "Incline DB Press",
          detail: "3 sets · 8 reps · effort 8",
          value: "480 lb",
          thumb: exercise
        )
        ReceiptDashedRule()
        ReceiptLine(index: 2, title: "Cable Row", detail: "3 sets · 10 reps", value: "420 lb")
        ReceiptTotals(rows: [("Total volume", "7,840 lb"), ("Duration", "44:18")])
        BarcodeView(seed: "000241")
        Text("THANK YOU FOR SHOWING UP.")
          .font(.receipt(10, weight: .black))
          .tracking(1)
          .frame(maxWidth: .infinity)
        ReceiptEdge()
      }
      .animation(liftAnimation(LiftMotion.printLine), value: title)
    }
    .background(LiftTheme.paper)
  }
}

#if DEBUG
struct ReceiptLabPreviewGallery: View {
  private let exercise = LiftExercise(
    id: UUID(uuidString: "00000000-0000-4000-8000-000000000321")!,
    name: "Incline Dumbbell Press",
    muscleGroup: "Chest",
    equipment: "Dumbbells",
    instructions: ""
  )

  var body: some View {
    ScrollView {
      ReceiptSheet {
        ReceiptHeader(title: "Lift Receipt", subtitle: "Design Lab · monochrome", trailing: "#000241")
        ReceiptDashedRule()
        composerSpecimen
        restSpecimen
        ReceiptSectionLabel(title: "Live receipt")
        ReceiptColumns([("#", .leading), ("Exercise", .leading), ("Volume", .trailing)])
        PrintedSetLine(
          index: 1,
          title: "Incline DB Press",
          detail: "60 lb × 8 · logged",
          value: "480 lb",
          thumb: exercise
        )
        ReceiptDashedRule()
        ReceiptLine(index: 2, title: "Cable Row", detail: "Ready · set 2 of 3", value: "420 lb")
        ReceiptTotals(rows: [("Sets", "5"), ("Total volume", "2,180 lb")])
        BarcodeView(seed: "000241")
        ReceiptEdge()
      }
    }
    .background(LiftTheme.paper)
    .preferredColorScheme(.light)
  }

  private var composerSpecimen: some View {
    VStack(alignment: .leading, spacing: 9) {
      HStack(alignment: .top, spacing: 12) {
        VStack(alignment: .leading, spacing: 4) {
          Text("02 / 08")
            .font(.receipt(9, weight: .bold))
            .foregroundStyle(LiftTheme.inkSecondary)
          Text("INCLINE DB PRESS")
            .font(.receiptCondensed(21, weight: .black))
          Text("LAST  55 × 10   55 × 9   50 × 11")
            .font(.receipt(9, weight: .medium))
            .foregroundStyle(LiftTheme.inkSecondary)
        }
        Spacer(minLength: 8)
        LiftExerciseThumb(exercise: exercise, size: 68, showsBorder: false)
      }
      Text("SET 2 OF 3")
        .font(.receipt(9, weight: .black))
        .tracking(0.8)
      HStack(alignment: .firstTextBaseline, spacing: 8) {
        Text("60")
          .font(.receipt(42, weight: .black))
        Text("LB")
          .font(.receipt(13, weight: .black))
          .foregroundStyle(LiftTheme.inkSecondary)
        Text("×")
          .font(.receipt(22, weight: .black))
        Text("8")
          .font(.receipt(34, weight: .black))
        Text("REPS")
          .font(.receipt(11, weight: .black))
          .foregroundStyle(LiftTheme.inkSecondary)
      }
      .monospacedDigit()
      HStack(spacing: 8) {
        labChip("EFFORT 8  >", filled: false)
        labChip("WARM-UP", filled: false)
        labChip("READY", filled: true)
      }
    }
    .accessibilityElement(children: .combine)
    .accessibilityLabel("Incline dumbbell press, 60 pounds, 8 reps, set 2 of 3, ready")
  }

  private var restSpecimen: some View {
    HStack(spacing: 10) {
      Text("REST")
        .font(.receipt(9, weight: .black))
        .opacity(0.66)
      Text("01:24")
        .font(.receipt(21, weight: .black))
        .monospacedDigit()
      Spacer(minLength: 4)
      Text("−15   SKIP   +15")
        .font(.receipt(10, weight: .black))
    }
    .foregroundStyle(LiftTheme.paper)
    .padding(.horizontal, 13)
    .frame(maxWidth: .infinity, minHeight: 50)
    .background(LiftTheme.ink, in: RoundedRectangle(cornerRadius: 15, style: .continuous))
    .accessibilityElement(children: .ignore)
    .accessibilityLabel("Rest, 1 minute 24 seconds. Decrease 15 seconds, skip, increase 15 seconds")
  }

  private func labChip(_ title: String, filled: Bool) -> some View {
    Text(title)
      .font(.receipt(9, weight: .black))
      .foregroundStyle(filled ? LiftTheme.paper : LiftTheme.ink)
      .padding(.horizontal, 8)
      .frame(minHeight: 30)
      .background(filled ? LiftTheme.ink : .clear, in: Capsule())
      .overlay(Capsule().stroke(LiftTheme.ink, lineWidth: 1))
  }
}
#endif

#Preview("Live Receipt — Default") {
  ReceiptLivePreview(title: "Live Receipt")
}

#Preview("Live Receipt — XL") {
  ReceiptLivePreview(title: "Live Receipt")
    .environment(\.dynamicTypeSize, .xLarge)
}

#Preview("Receipt Header") {
  ReceiptSheet { ReceiptHeader(title: "Upper A", subtitle: "Today", trailing: "#000241") }
}

#Preview("Receipt Columns + Line") {
  ReceiptSheet {
    ReceiptColumns([("#", .leading), ("Exercise", .leading), ("Value", .trailing)])
    ReceiptLine(index: 1, title: "Machine Chest Press", detail: "3 / 3 sets", value: "840 lb")
  }
}

#Preview("Receipt Rules") {
  ReceiptSheet { ReceiptRule(); ReceiptDashedRule() }
}

#Preview("Receipt Totals") {
  ReceiptSheet { ReceiptTotals(rows: [("Total", "7,840 lb"), ("Duration", "44:18")]) }
}

#Preview("Receipt Edge") {
  VStack(spacing: 0) { Color.gray.frame(height: 32); ReceiptEdge() }
}

#Preview("Printed Set Line") {
  ReceiptSheet { PrintedSetLine(index: 1, title: "Set logged", detail: "100 lb × 8", value: "800 lb") }
}

#Preview("Barcode") {
  ReceiptSheet { BarcodeView(seed: "session-000241") }
}
