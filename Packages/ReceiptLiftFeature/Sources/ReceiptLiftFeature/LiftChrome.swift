import SwiftUI
import StrandDesign

// MARK: - Lift chrome
//
// Lift's screens compose the same pieces as the rest of NOOP: `NoopScreenHeader` for the page header,
// `SectionHeader` for section labels, flat rows separated by hairlines (spec 010: content has no
// fill, radius, or border), `NoopButton` for actions, and `StrandFont` roles for type. This file holds
// the few small compositions Lift needs that the shared design system does not already provide. The
// receipt artifact (the printed receipt itself) lives in `ReceiptComponents.swift` and keeps its own look.

/// The trailing cluster of a root page header: the page's own actions, then the host's close button.
struct LiftHeaderTrailing<Actions: View>: View {
  @Environment(\.liftHostChrome) private var host
  @ViewBuilder var actions: () -> Actions

  var body: some View {
    HStack(spacing: 8) {
      actions()
      if let onClose = host.onClose {
        NoopIconButton("xmark", accessibilityLabel: "Close", action: onClose)
      }
    }
  }
}

extension LiftHeaderTrailing where Actions == EmptyView {
  init() { self.init(actions: { EmptyView() }) }
}

// MARK: - Screen

/// A scrolling Lift page: canonical header, 16pt gutter, flat content on the canvas.
struct LiftScreen<Trailing: View, Content: View>: View {
  var title: LocalizedStringKey?
  var subtitle: LocalizedStringKey?
  var backAction: (() -> Void)? = nil
  /// Long lists build rows on demand instead of all at once.
  var lazy = false
  var bottomPadding: CGFloat = 24
  @ViewBuilder var trailing: () -> Trailing
  @ViewBuilder var content: () -> Content

  var body: some View {
    ScrollView(.vertical) {
      column
        .padding(.horizontal, LiftChromeMetrics.gutter)
        .padding(.bottom, bottomPadding)
        .frame(maxWidth: LiftChromeMetrics.maxColumnWidth, alignment: .leading)
        .frame(maxWidth: .infinity)
    }
    .scrollIndicators(.hidden)
    .background(LiftTheme.paper.ignoresSafeArea())
    .toolbar(.hidden, for: .navigationBar)
  }

  @ViewBuilder private var column: some View {
    if lazy {
      LazyVStack(alignment: .leading, spacing: LiftChromeMetrics.blockSpacing) {
        header
        content()
      }
    } else {
      VStack(alignment: .leading, spacing: LiftChromeMetrics.blockSpacing) {
        header
        content()
      }
    }
  }

  private var header: some View {
    NoopScreenHeader(
      title: title,
      subtitle: subtitle,
      backAction: backAction,
      style: .expanded,
      trailing: trailing
    )
  }
}

extension LiftScreen where Trailing == EmptyView {
  init(
    title: LocalizedStringKey?,
    subtitle: LocalizedStringKey? = nil,
    backAction: (() -> Void)? = nil,
    lazy: Bool = false,
    bottomPadding: CGFloat = 24,
    @ViewBuilder content: @escaping () -> Content
  ) {
    self.init(
      title: title,
      subtitle: subtitle,
      backAction: backAction,
      lazy: lazy,
      bottomPadding: bottomPadding,
      trailing: { EmptyView() },
      content: content
    )
  }
}

// MARK: - Sections and rows

/// A titled block of flat content.
struct LiftSection<Content: View>: View {
  let title: LocalizedStringKey
  var trailing: String? = nil
  @ViewBuilder var content: () -> Content

  var body: some View {
    VStack(alignment: .leading, spacing: NoopMetrics.space2) {
      SectionHeader(title, trailing: trailing)
      content()
    }
    .frame(maxWidth: .infinity, alignment: .leading)
  }
}

/// A flat list row: optional leading element, title + detail, optional value, optional chevron, and a
/// hairline underneath. Wrap in a `Button`/`NavigationLink` with `.buttonStyle(.plain)` to make it tappable.
struct LiftRow<Leading: View, Trailing: View>: View {
  let title: String
  var detail: String? = nil
  var value: String? = nil
  var showsChevron = false
  var titleColor: Color = StrandPalette.textPrimary
  @ViewBuilder var leading: () -> Leading
  @ViewBuilder var trailing: () -> Trailing

  var body: some View {
    HStack(spacing: 12) {
      leading()
      VStack(alignment: .leading, spacing: 2) {
        Text(title)
          .font(StrandFont.body)
          .foregroundStyle(titleColor)
          .fixedSize(horizontal: false, vertical: true)
        if let detail {
          Text(detail)
            .font(StrandFont.caption)
            .foregroundStyle(StrandPalette.textSecondary)
            .fixedSize(horizontal: false, vertical: true)
        }
      }
      .frame(maxWidth: .infinity, alignment: .leading)
      trailing()
      if let value {
        Text(value)
          .font(StrandFont.number(15))
          .foregroundStyle(StrandPalette.textPrimary)
          .lineLimit(1)
          .fixedSize(horizontal: true, vertical: false)
          .layoutPriority(1)
      }
      if showsChevron {
        Image(systemName: "chevron.right")
          .font(.system(size: 13, weight: .semibold))
          .foregroundStyle(StrandPalette.textTertiary)
          .accessibilityHidden(true)
      }
    }
    .contentRowSurface(boundedPadding: NoopMetrics.space3, flatVerticalPadding: NoopMetrics.space3)
    .contentShape(Rectangle())
  }
}

extension LiftRow where Leading == EmptyView, Trailing == EmptyView {
  init(title: String, detail: String? = nil, value: String? = nil, showsChevron: Bool = false) {
    self.init(
      title: title,
      detail: detail,
      value: value,
      showsChevron: showsChevron,
      leading: { EmptyView() },
      trailing: { EmptyView() }
    )
  }
}

extension LiftRow where Trailing == EmptyView {
  init(
    title: String,
    detail: String? = nil,
    value: String? = nil,
    showsChevron: Bool = false,
    titleColor: Color = StrandPalette.textPrimary,
    @ViewBuilder leading: @escaping () -> Leading
  ) {
    self.init(
      title: title,
      detail: detail,
      value: value,
      showsChevron: showsChevron,
      titleColor: titleColor,
      leading: leading,
      trailing: { EmptyView() }
    )
  }
}

/// A fixed-width list index ("01") used as a row's leading element.
struct LiftRowIndex: View {
  let index: Int

  var body: some View {
    Text(String(format: "%02d", index))
      .font(StrandFont.number(12, weight: .medium))
      .foregroundStyle(StrandPalette.textTertiary)
      .frame(width: 24, alignment: .leading)
      .accessibilityHidden(true)
  }
}

/// A labelled figure: overline label above a number.
struct LiftMetric: View {
  let title: String
  let value: String
  var tint: Color = StrandPalette.textPrimary

  var body: some View {
    VStack(alignment: .leading, spacing: 4) {
      Text(title).strandOverline().lineLimit(1)
      Text(value)
        .font(StrandFont.number(22, weight: .bold))
        .foregroundStyle(tint)
        .lineLimit(1)
        .minimumScaleFactor(0.6)
    }
    .frame(maxWidth: .infinity, alignment: .leading)
    .accessibilityElement(children: .combine)
  }
}

/// A hairline between flat blocks that are not rows.
struct LiftDivider: View {
  var body: some View {
    Rectangle()
      .fill(StrandPalette.hairline)
      .frame(height: 1)
      .accessibilityHidden(true)
  }
}

// MARK: - States

/// Loading, empty, and error states. Centered icon or spinner, a headline, an explanation, and an
/// optional single action.
struct LiftStateMessage: View {
  var symbol: String? = nil
  var isLoading = false
  let title: String
  var message: String? = nil
  var actionTitle: String? = nil
  var action: (() -> Void)? = nil

  var body: some View {
    VStack(spacing: 12) {
      if isLoading {
        ProgressView().tint(StrandPalette.textSecondary)
      } else if let symbol {
        Image(systemName: symbol)
          .font(.system(size: 28, weight: .medium))
          .foregroundStyle(StrandPalette.textTertiary)
          .accessibilityHidden(true)
      }
      Text(title)
        .font(StrandFont.headline)
        .foregroundStyle(StrandPalette.textPrimary)
        .multilineTextAlignment(.center)
      if let message {
        Text(message)
          .font(StrandFont.subhead)
          .foregroundStyle(StrandPalette.textSecondary)
          .multilineTextAlignment(.center)
          .fixedSize(horizontal: false, vertical: true)
      }
      if let actionTitle, let action {
        NoopButton(LocalizedStringKey(actionTitle), kind: .secondary, action: action)
          .padding(.top, 4)
      }
    }
    .frame(maxWidth: .infinity)
    .padding(.vertical, 32)
    .padding(.horizontal, LiftChromeMetrics.gutter)
  }
}

/// A short inline note for an empty block inside a screen ("No receipts yet").
struct LiftEmptyNote: View {
  let text: String

  var body: some View {
    Text(text)
      .font(StrandFont.subhead)
      .foregroundStyle(StrandPalette.textSecondary)
      .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
      .fixedSize(horizontal: false, vertical: true)
  }
}

// MARK: - Controls

/// A labelled single-line or multi-line text field with the shared bounded-control treatment.
struct LiftTextField: View {
  let title: String
  @Binding var text: String
  let placeholder: String
  var axis: Axis = .horizontal
  var capitalization: TextInputAutocapitalization = .words

  var body: some View {
    VStack(alignment: .leading, spacing: 6) {
      Text(title)
        .font(StrandFont.caption)
        .foregroundStyle(StrandPalette.textSecondary)
      TextField(placeholder, text: $text, axis: axis)
        .font(StrandFont.body)
        .foregroundStyle(StrandPalette.textPrimary)
        .textInputAutocapitalization(capitalization)
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
        .frame(minHeight: NoopMetrics.controlHeight, alignment: .leading)
        .background(
          StrandPalette.surfaceInset,
          in: RoundedRectangle(cornerRadius: NoopMetrics.radius3, style: .continuous)
        )
        .overlay(
          RoundedRectangle(cornerRadius: NoopMetrics.radius3, style: .continuous)
            .strokeBorder(StrandPalette.hairline, lineWidth: 1)
        )
    }
  }
}

/// The small tonal badge shown beside a personal record.
struct LiftBadge: View {
  let text: String
  var tint: Color = StrandPalette.accent

  var body: some View {
    Text(text)
      .font(StrandFont.micro.weight(.semibold))
      .foregroundStyle(tint)
      .lineLimit(1)
      .padding(.horizontal, 9)
      .frame(height: 24)
      .background(tint.opacity(0.14), in: Capsule(style: .continuous))
  }
}

// MARK: - Steppers

/// The square +/- control used by the set composer.
private struct LiftStepSurface: View {
  let systemImage: String
  var isPressed = false

  var body: some View {
    Image(systemName: systemImage)
      .font(.system(size: 16, weight: .semibold))
      .foregroundStyle(StrandPalette.textPrimary)
      .frame(width: 48, height: 48)
      .background(
        StrandPalette.surfaceInset,
        in: RoundedRectangle(cornerRadius: NoopMetrics.radius2, style: .continuous)
      )
      .overlay(
        RoundedRectangle(cornerRadius: NoopMetrics.radius2, style: .continuous)
          .strokeBorder(StrandPalette.hairline, lineWidth: 1)
      )
      .opacity(isPressed ? NoopButtonMetrics.pressedOpacity : 1)
      .contentShape(Rectangle())
  }
}

private struct LiftStepButtonStyle: ButtonStyle {
  let systemImage: String

  func makeBody(configuration: Configuration) -> some View {
    LiftStepSurface(systemImage: systemImage, isPressed: configuration.isPressed)
  }
}

/// Plus/minus with an optional long-press for the larger step (weight changes by 5, long-press by 25).
private struct LiftStepControl: View {
  let systemImage: String
  let accessibilityLabel: String
  let action: () -> Void
  var longPressAction: (() -> Void)? = nil

  var body: some View {
    if let longPressAction {
      LiftStepSurface(systemImage: systemImage)
        .gesture(
          LongPressGesture(minimumDuration: 0.45, maximumDistance: 10)
            .exclusively(before: TapGesture())
            .onEnded { value in
              switch value {
              case .first(let didLongPress):
                if didLongPress { longPressAction() }
              case .second:
                action()
              }
            }
        )
        .accessibilityElement()
        .accessibilityAddTraits(.isButton)
        .accessibilityLabel(accessibilityLabel)
        .accessibilityAction { action() }
        .accessibilityAction(named: "Change by 25") { longPressAction() }
    } else {
      Button(action: action) {
        EmptyView()
      }
      .buttonStyle(LiftStepButtonStyle(systemImage: systemImage))
      .accessibilityLabel(accessibilityLabel)
    }
  }
}

struct LiftStepper: View {
  let title: String
  let value: String
  let decrement: () -> Void
  let increment: () -> Void
  var decrementLarge: (() -> Void)? = nil
  var incrementLarge: (() -> Void)? = nil

  var body: some View {
    HStack(spacing: 12) {
      LiftStepControl(
        systemImage: "minus",
        accessibilityLabel: "Decrease \(title)",
        action: decrement,
        longPressAction: decrementLarge
      )
      VStack(spacing: 2) {
        Text(title).strandOverline()
        Text(value)
          .font(StrandFont.number(24, weight: .bold))
          .foregroundStyle(StrandPalette.textPrimary)
          .lineLimit(1)
          .minimumScaleFactor(0.7)
      }
      .frame(maxWidth: .infinity)
      LiftStepControl(
        systemImage: "plus",
        accessibilityLabel: "Increase \(title)",
        action: increment,
        longPressAction: incrementLarge
      )
    }
  }
}

// MARK: - Display names

extension String {
  /// The bundled exercise catalog stores lowercase names ("barbell bench press"). Chrome shows them with
  /// each lowercase word capitalised, leaving words that already carry capitals ("DB", "EZ") alone.
  var liftDisplayName: String {
    split(separator: " ", omittingEmptySubsequences: false)
      .map { word in
        guard let first = word.first, first.isLowercase else { return String(word) }
        return first.uppercased() + word.dropFirst()
      }
      .joined(separator: " ")
  }
}
