import StrandDesign
import SwiftUI

// MARK: - Lift's flat pages
//
// Lift is built from the same pieces as Today, Workouts and Coach: a page of flat sections on the canvas, each with an
// eyebrow in the workout colour and one hairline between neighbours, values bright with their units muted, a primary
// pill for the one thing a page is for. This file holds the few compositions Lift needs on top of StrandDesign's
// (`FlatSection`, `FactStrip`, `HeroValue`, `WidgetChipButton`, `NoopSheetTitleRow`, `GlyphDisc`): the page with its
// pinned title row, the list row, the pinned action bar and the big stepper a set is logged with.

enum LiftChromeMetrics {
  /// The page gutter every NOOP page uses.
  static let gutter: CGFloat = NoopMetrics.space4
  /// Readable column cap on iPad, matching `ScreenScaffold`.
  static let maxColumnWidth: CGFloat = 700
}

// MARK: Host chrome

/// Controls the embedding app injects around Lift's root pages. Lift is presented in a sheet the host owns, so close and
/// back live in the page's title row instead of a separate bar stacked above it.
struct LiftHostChrome {
  var onBack: (() -> Void)?
  var onClose: (() -> Void)?
}

extension EnvironmentValues {
  @Entry var liftHostChrome = LiftHostChrome()
}

/// Where a page sits. A root page is the first thing in the sheet (a sheet title and the host's close button); a pushed
/// page is reached from another and wears the compact row with its back chip; a sheet page is the first page of a modal
/// of its own and closes just that modal.
enum LiftScreenRole {
  case root
  case pushed
  case sheet
}

extension EnvironmentValues {
  @Entry var liftScreenRole: LiftScreenRole = .root
}

// MARK: Page

extension LocalizedStringKey {
  /// A title that is somebody's own text (a routine, session or exercise name). It goes through the catalog's "%@" entry,
  /// so it is drawn as typed and never looked up as a key: a seeded routine called "Upper A" must not pick up the
  /// translation of the name-field placeholder.
  init(userText: String) { self.init("\(userText)") }
}

/// A scrolling Lift page: the pinned title row, a 16pt gutter and flat sections on the canvas.
struct LiftPage<Trailing: View, Content: View>: View {
  let title: LocalizedStringKey
  /// Quiet text at the trailing end of a pushed page's title row (a date, say).
  var context: String? = nil
  /// What the back chip of a pushed page does; it pops the page when nil.
  var backAction: (() -> Void)? = nil
  /// What the close chip of a sheet page does; it dismisses the modal when nil.
  var closeAction: (() -> Void)? = nil
  /// Build the content lazily: a long list only draws the rows on screen.
  var lazy = false
  var bottomPadding: CGFloat = NoopMetrics.space4
  @ViewBuilder var trailing: () -> Trailing
  @ViewBuilder var content: () -> Content

  @Environment(\.liftScreenRole) private var role
  @Environment(\.liftHostChrome) private var host
  @Environment(\.dismiss) private var dismiss

  var body: some View {
    ScrollView(.vertical) {
      column
        .padding(.horizontal, LiftChromeMetrics.gutter)
        .padding(.top, NoopMetrics.space2)
        .padding(.bottom, bottomPadding)
        .frame(maxWidth: LiftChromeMetrics.maxColumnWidth, alignment: .leading)
        .frame(maxWidth: .infinity)
    }
    .scrollIndicators(.hidden)
    .scrollDismissesKeyboard(.interactively)
    .background(StrandPalette.appCanvas.ignoresSafeArea())
    .safeAreaInset(edge: .top, spacing: 0) { header }
    .toolbar(.hidden, for: .navigationBar)
  }

  @ViewBuilder private var column: some View {
    if lazy {
      LazyVStack(alignment: .leading, spacing: 0) { content() }
    } else {
      VStack(alignment: .leading, spacing: 0) { content() }
    }
  }

  private var header: some View {
    headerRow
      .padding(.horizontal, LiftChromeMetrics.gutter)
      .padding(.top, NoopMetrics.space3)
      .padding(.bottom, NoopMetrics.space1)
      .frame(maxWidth: LiftChromeMetrics.maxColumnWidth + LiftChromeMetrics.gutter * 2)
      .frame(maxWidth: .infinity)
      .background(StrandPalette.appCanvas)
  }

  @ViewBuilder private var headerRow: some View {
    switch role {
    case .pushed:
      NoopDetailTitleRow(title, context: context, backAction: backAction ?? { dismiss() }) { trailing() }
    case .sheet:
      NoopSheetTitleRow(title) {
        HStack(spacing: 0) {
          trailing()
          HeaderChipButton("xmark", accessibilityLabel: "Close") { (closeAction ?? { dismiss() })() }
        }
      }
    case .root:
      if let onBack = host.onBack {
        NoopDetailTitleRow(title, context: context, backAction: onBack) { trailingWithClose }
      } else {
        NoopSheetTitleRow(title) { trailingWithClose }
      }
    }
  }

  @ViewBuilder private var trailingWithClose: some View {
    HStack(spacing: 0) {
      trailing()
      if let onClose = host.onClose {
        HeaderChipButton("xmark", accessibilityLabel: "Close", action: onClose)
      }
    }
  }
}

extension LiftPage where Trailing == EmptyView {
  init(
    title: LocalizedStringKey,
    context: String? = nil,
    backAction: (() -> Void)? = nil,
    closeAction: (() -> Void)? = nil,
    lazy: Bool = false,
    bottomPadding: CGFloat = NoopMetrics.space4,
    @ViewBuilder content: @escaping () -> Content
  ) {
    self.init(
      title: title, context: context, backAction: backAction, closeAction: closeAction, lazy: lazy,
      bottomPadding: bottomPadding, trailing: { EmptyView() }, content: content)
  }
}

extension View {
  /// The pinned action bar at the foot of a page: the canvas, a hairline above and the shared gutter. Opaque, so the
  /// rows scrolling beneath it never show through the button's surroundings.
  func liftFooterBar() -> some View {
    padding(.horizontal, LiftChromeMetrics.gutter)
      .padding(.vertical, NoopMetrics.space3)
      .frame(maxWidth: .infinity)
      .background(StrandPalette.appCanvas.ignoresSafeArea(edges: .bottom))
      .overlay(alignment: .top) {
        Rectangle().fill(StrandPalette.hairline).frame(height: 1).accessibilityHidden(true)
      }
  }
}

// MARK: Sections

/// A flat section on the canvas in the workout colour. Titles are looked up in the app's string table.
struct LiftFlatSection<Content: View>: View {
  let title: LocalizedStringKey
  var systemImage = "dumbbell.fill"
  var tint: DomainTint = .workout
  var trailing: EyebrowTrailing = .none
  var contentSpacing: CGFloat = WidgetMetrics.contentSpacing
  @ViewBuilder var content: () -> Content

  init(
    _ title: LocalizedStringKey,
    systemImage: String = "dumbbell.fill",
    tint: DomainTint = .workout,
    trailing: EyebrowTrailing = .none,
    contentSpacing: CGFloat = WidgetMetrics.contentSpacing,
    @ViewBuilder content: @escaping () -> Content
  ) {
    self.title = title
    self.systemImage = systemImage
    self.tint = tint
    self.trailing = trailing
    self.contentSpacing = contentSpacing
    self.content = content
  }

  var body: some View {
    FlatSection(title, systemImage: systemImage, tint: tint, trailing: trailing, contentSpacing: contentSpacing) {
      content()
    }
  }
}

/// A flat section whose title is data (a month), shown as written.
struct LiftDataSection<Content: View>: View {
  let title: String
  var systemImage = "calendar"
  var trailing: EyebrowTrailing = .none
  var contentSpacing: CGFloat = 0
  @ViewBuilder var content: () -> Content

  var body: some View {
    FlatSection(
      verbatim: title, systemImage: systemImage, tint: .workout, trailing: trailing, contentSpacing: contentSpacing
    ) { content() }
  }
}

/// A quiet sentence for a section with nothing in it yet ("No routines yet").
struct LiftNote: View {
  let text: LocalizedStringKey

  var body: some View {
    Text(text)
      .font(StrandFont.footnote)
      .foregroundStyle(StrandPalette.textTertiary)
      .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
      .fixedSize(horizontal: false, vertical: true)
  }
}

/// A full-page message for a state with nothing to show or a failure: one heading, one sentence and at most one action.
struct LiftMessage: View {
  var symbol: String? = nil
  var isLoading = false
  let title: LocalizedStringKey
  var message: LocalizedStringKey? = nil
  var actionTitle: LocalizedStringKey? = nil
  var action: (() -> Void)? = nil

  var body: some View {
    VStack(alignment: .leading, spacing: NoopMetrics.space3) {
      if isLoading {
        ProgressView().tint(StrandPalette.textSecondary)
      } else if let symbol {
        GlyphDisc(symbol)
      }
      Text(title)
        .font(StrandFont.title2)
        .foregroundStyle(StrandPalette.textPrimary)
        .fixedSize(horizontal: false, vertical: true)
      if let message {
        Text(message)
          .font(StrandFont.subhead)
          .foregroundStyle(StrandPalette.textSecondary)
          .fixedSize(horizontal: false, vertical: true)
      }
      if let actionTitle, let action {
        Button(action: action) { Text(actionTitle) }
          .buttonStyle(PrimaryPillButtonStyle())
          .padding(.top, NoopMetrics.space1)
      }
    }
    .frame(maxWidth: .infinity, alignment: .leading)
    .padding(.top, NoopMetrics.space4)
    .accessibilityElement(children: .contain)
  }
}

// MARK: Rows

/// One list row: a leading glyph or picture, a title over quiet facts, a bright figure and a chevron. The row is one
/// spoken element. From the largest standard text size up it stacks (picture, title, facts, figure), because side by
/// side it would cut its words.
struct LiftListRow<Leading: View, Accessory: View>: View {
  let title: String
  /// A line in the workout colour under the title: what the row asks of you ("4 sets × 6-8 reps").
  var highlight: String? = nil
  var details: [String] = []
  /// The trailing figure ("1,240 lb"); a missing one reads "—" in the tertiary ink.
  var value: String? = nil
  var showsChevron = false
  @ViewBuilder var leading: () -> Leading
  @ViewBuilder var accessory: () -> Accessory

  @Environment(\.dynamicTypeSize) private var typeSize

  /// True when the row stacks its parts; separators and layout follow the same rule.
  static func stacks(_ size: DynamicTypeSize) -> Bool { size >= .xxxLarge }

  var body: some View {
    Group {
      if Self.stacks(typeSize) { stacked } else { inline }
    }
    .padding(.vertical, NoopMetrics.space3)
    .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
    .contentShape(Rectangle())
  }

  private var inline: some View {
    HStack(alignment: .center, spacing: NoopMetrics.space3) {
      leading()
      texts.layoutPriority(1)
      Spacer(minLength: NoopMetrics.space2)
      accessory()
      figure
      if showsChevron { chevron }
    }
  }

  private var stacked: some View {
    VStack(alignment: .leading, spacing: NoopMetrics.space2) {
      HStack {
        leading()
        Spacer(minLength: 0)
        accessory()
        if showsChevron { chevron }
      }
      texts
      figure
    }
  }

  private var texts: some View {
    VStack(alignment: .leading, spacing: 2) {
      Text(verbatim: title)
        .font(StrandFont.body.weight(.semibold))
        .foregroundStyle(StrandPalette.textPrimary)
        .fixedSize(horizontal: false, vertical: true)
      if let highlight {
        Text(verbatim: highlight)
          .font(StrandFont.subhead.weight(.semibold))
          .foregroundStyle(DomainTint.workout.accent)
          .fixedSize(horizontal: false, vertical: true)
      }
      ForEach(Array(details.enumerated()), id: \.offset) { _, detail in
        Text(verbatim: detail)
          .font(StrandFont.footnote)
          .foregroundStyle(StrandPalette.textSecondary)
          .fixedSize(horizontal: false, vertical: true)
      }
    }
  }

  @ViewBuilder private var figure: some View {
    if let value {
      LiftScaledValue(value: value)
        .fixedSize(horizontal: true, vertical: false)
        .layoutPriority(2)
    }
  }

  private var chevron: some View {
    Image(systemName: "chevron.right")
      .font(.system(size: 11, weight: .semibold))
      .foregroundStyle(StrandPalette.textTertiary)
      .accessibilityHidden(true)
  }
}

extension LiftListRow where Leading == EmptyView, Accessory == EmptyView {
  init(
    title: String, highlight: String? = nil, details: [String] = [], value: String? = nil, showsChevron: Bool = false
  ) {
    self.init(
      title: title, highlight: highlight, details: details, value: value, showsChevron: showsChevron,
      leading: { EmptyView() }, accessory: { EmptyView() })
  }
}

extension LiftListRow where Accessory == EmptyView {
  init(
    title: String,
    highlight: String? = nil,
    details: [String] = [],
    value: String? = nil,
    showsChevron: Bool = false,
    @ViewBuilder leading: @escaping () -> Leading
  ) {
    self.init(
      title: title, highlight: highlight, details: details, value: value, showsChevron: showsChevron,
      leading: leading, accessory: { EmptyView() })
  }
}

/// Rows with the hairline between them, starting under the row's text.
struct LiftRowList<Item: Identifiable, Row: View>: View {
  let items: [Item]
  /// Where the hairline starts: the width of the row's leading picture plus its gap, 0 when it has none.
  var separatorInset: CGFloat = 0
  /// True when every row leads with a `GlyphDisc`. The disc grows with the text, so the hairline starts under the row's
  /// text at the disc's size for the current text size instead of at a fixed width.
  var leadsWithGlyphDisc = false
  @ViewBuilder var row: (Item, Int) -> Row

  @Environment(\.dynamicTypeSize) private var typeSize
  @ScaledMetric(relativeTo: .body) private var glyphDiameter: CGFloat = 38

  private var hairlineInset: CGFloat {
    if typeSize >= .xxxLarge { return 0 }
    return leadsWithGlyphDisc ? GlyphDisc.diameter(scaled: glyphDiameter) + NoopMetrics.space3 : separatorInset
  }

  var body: some View {
    VStack(spacing: 0) {
      ForEach(Array(items.enumerated()), id: \.element.id) { index, item in
        if index > 0 {
          FlatRowSeparator(leadingInset: hairlineInset)
        }
        row(item, index)
      }
    }
  }
}

/// The small tonal badge beside a personal record.
struct LiftTag: View {
  let text: LocalizedStringKey
  var tint: Color = StrandPalette.accent

  var body: some View {
    Text(text)
      .font(StrandFont.micro.weight(.semibold))
      .foregroundStyle(tint)
      .lineLimit(1)
      .padding(.horizontal, 9)
      .frame(height: 24)
      .background(tint.opacity(0.14), in: Capsule(style: .continuous))
      .fixedSize()
  }
}

// MARK: Fields

/// A labelled single-line or multi-line text field on the inset surface the app's other forms use.
struct LiftField: View {
  let title: LocalizedStringKey
  @Binding var text: String
  let placeholder: LocalizedStringKey
  var axis: Axis = .horizontal
  var capitalization: TextInputAutocapitalization = .words
  /// Hides the label above the field when the section already names it; VoiceOver still reads it.
  var hidesTitle = false

  var body: some View {
    VStack(alignment: .leading, spacing: 6) {
      if !hidesTitle {
        Text(title)
          .font(StrandFont.caption)
          .foregroundStyle(StrandPalette.textSecondary)
      }
      TextField(text: $text, axis: axis) { Text(placeholder) }
        .accessibilityLabel(title)
        .font(StrandFont.body)
        .foregroundStyle(StrandPalette.textPrimary)
        .textInputAutocapitalization(capitalization)
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
        .frame(minHeight: 48, alignment: .leading)
        .background(
          StrandPalette.surfaceInset,
          in: RoundedRectangle(cornerRadius: NoopMetrics.radius2, style: .continuous)
        )
        .overlay(
          RoundedRectangle(cornerRadius: NoopMetrics.radius2, style: .continuous)
            .strokeBorder(StrandPalette.hairline, lineWidth: 1)
        )
    }
  }
}

// MARK: Steppers

/// The big round step control a set is logged with. 56pt, a good deal over the 44pt minimum, because it is pressed
/// mid-workout with sweaty hands. With `longPress` a long press takes the larger step.
struct LiftStepButton: View {
  let systemImage: String
  let action: () -> Void
  var longPress: (() -> Void)? = nil

  static let size: CGFloat = 56

  var body: some View {
    glyph
      .gesture(
        LongPressGesture(minimumDuration: 0.45, maximumDistance: 10)
          .exclusively(before: TapGesture())
          .onEnded { value in
            switch value {
            case .first(let didLongPress):
              if didLongPress { (longPress ?? action)() }
            case .second:
              action()
            }
          }
      )
      .accessibilityHidden(true)
  }

  private var glyph: some View {
    Image(systemName: systemImage)
      .font(.system(size: 18, weight: .semibold))
      .foregroundStyle(StrandPalette.textPrimary)
      .frame(width: Self.size, height: Self.size)
      .background(StrandPalette.chipFill, in: Circle())
      .overlay(Circle().strokeBorder(StrandPalette.hairline, lineWidth: 1))
      .contentShape(Circle())
  }
}

/// A figure with a minus and a plus either side: one spoken element that VoiceOver adjusts by swiping up or down, with the
/// larger step offered as a named action. The value shows its unit small and muted. At the accessibility text sizes the
/// buttons sit below the figure, so the figure keeps its whole width.
struct LiftBigStepper: View {
  let title: LocalizedStringKey
  /// The figure as written ("130 lb", "8"); a trailing unit is split off and muted.
  let value: String
  /// The figure read aloud ("130 pounds").
  let spokenValue: String
  let decrement: () -> Void
  let increment: () -> Void
  var decrementLarge: (() -> Void)? = nil
  var incrementLarge: (() -> Void)? = nil
  /// What VoiceOver calls the larger steps ("Increase by 25 pounds"); with these the actions are offered.
  var increaseLargeLabel: String? = nil
  var decreaseLargeLabel: String? = nil

  @Environment(\.dynamicTypeSize) private var typeSize
  @ScaledMetric(relativeTo: .title2) private var valueSize: CGFloat = 28

  var body: some View {
    Group {
      if typeSize.isAccessibilitySize { stacked } else { inline }
    }
    .accessibilityElement(children: .ignore)
    .accessibilityLabel(title)
    .accessibilityValue(Text(verbatim: spokenValue))
    .accessibilityAdjustableAction { direction in
      switch direction {
      case .increment: increment()
      case .decrement: decrement()
      @unknown default: break
      }
    }
    .modifier(LargeStepActions(
      increaseLabel: increaseLargeLabel, decreaseLabel: decreaseLargeLabel,
      decrement: decrementLarge, increment: incrementLarge))
  }

  private var inline: some View {
    HStack(spacing: NoopMetrics.space3) {
      LiftStepButton(systemImage: "minus", action: decrement, longPress: decrementLarge)
      figure.frame(maxWidth: .infinity)
      LiftStepButton(systemImage: "plus", action: increment, longPress: incrementLarge)
    }
  }

  private var stacked: some View {
    VStack(spacing: NoopMetrics.space2) {
      figure
      HStack(spacing: NoopMetrics.space4) {
        LiftStepButton(systemImage: "minus", action: decrement, longPress: decrementLarge)
        LiftStepButton(systemImage: "plus", action: increment, longPress: incrementLarge)
      }
    }
    .frame(maxWidth: .infinity)
  }

  private var figure: some View {
    VStack(spacing: 2) {
      Text(title)
        .font(StrandFont.micro)
        .foregroundStyle(StrandPalette.textTertiary)
        .lineLimit(1)
      UnitValueText(value: value, size: valueSize, weight: .bold)
        .contentTransition(.numericText())
    }
  }

  /// Offers the larger step as a named VoiceOver action when there is one.
  private struct LargeStepActions: ViewModifier {
    let increaseLabel: String?
    let decreaseLabel: String?
    let decrement: (() -> Void)?
    let increment: (() -> Void)?

    @ViewBuilder func body(content: Content) -> some View {
      if let increaseLabel, let decreaseLabel, let decrement, let increment {
        content
          .accessibilityAction(named: Text(verbatim: increaseLabel)) { increment() }
          .accessibilityAction(named: Text(verbatim: decreaseLabel)) { decrement() }
      } else {
        content
      }
    }
  }
}

// MARK: Row menu

/// The "…" at the end of a row: that row's own actions in a menu, in a 44pt target.
struct LiftRowMenu<Items: View>: View {
  let label: LocalizedStringKey
  @ViewBuilder var items: () -> Items

  var body: some View {
    Menu {
      items()
    } label: {
      Image(systemName: "ellipsis")
        .font(.system(size: 15, weight: .semibold))
        .foregroundStyle(StrandPalette.textTertiary)
        .frame(width: 44, height: 44)
        .contentShape(Rectangle())
    }
    .accessibilityLabel(label)
  }
}

// MARK: Sheet page

/// A modal form page: the sheet title with a close chip, a scrolling form of flat sections and the pinned footer the
/// page's one action sits in. At the accessibility text sizes the footer follows the form instead, so the keyboard and
/// a very large button never take the sheet's height.
struct LiftSheetPage<Content: View, Footer: View>: View {
  let title: LocalizedStringKey
  let onClose: () -> Void
  @ViewBuilder var content: () -> Content
  @ViewBuilder var footer: () -> Footer
  /// False for a page with no action of its own (a list of choices that closes on tap).
  var hasFooter = true

  @Environment(\.dynamicTypeSize) private var typeSize

  var body: some View {
    ScrollView(.vertical) {
      VStack(alignment: .leading, spacing: 0) {
        content()
        if hasFooter, typeSize.isAccessibilitySize {
          footer().padding(.top, NoopMetrics.space4)
        }
      }
      .padding(.horizontal, LiftChromeMetrics.gutter)
      .padding(.top, NoopMetrics.space2)
      .padding(.bottom, NoopMetrics.space4)
      .frame(maxWidth: LiftChromeMetrics.maxColumnWidth, alignment: .leading)
      .frame(maxWidth: .infinity)
    }
    .scrollIndicators(.hidden)
    .scrollDismissesKeyboard(.interactively)
    .background(StrandPalette.appCanvas.ignoresSafeArea())
    .safeAreaInset(edge: .top, spacing: 0) {
      NoopSheetTitleRow(title) { HeaderChipButton("xmark", accessibilityLabel: "Close", action: onClose) }
        .padding(.horizontal, LiftChromeMetrics.gutter)
        .padding(.top, NoopMetrics.space3)
        .padding(.bottom, NoopMetrics.space1)
        .frame(maxWidth: LiftChromeMetrics.maxColumnWidth + LiftChromeMetrics.gutter * 2)
        .frame(maxWidth: .infinity)
        .background(StrandPalette.appCanvas)
    }
    .safeAreaInset(edge: .bottom, spacing: 0) {
      if hasFooter, !typeSize.isAccessibilitySize { footer().liftFooterBar() }
    }
    .toolbar(.hidden, for: .navigationBar)
  }
}

extension LiftSheetPage where Footer == EmptyView {
  init(title: LocalizedStringKey, onClose: @escaping () -> Void, @ViewBuilder content: @escaping () -> Content) {
    self.init(title: title, onClose: onClose, content: content, footer: { EmptyView() }, hasFooter: false)
  }
}

/// A selectable row in a list of choices: its title and facts, and a check on the one chosen.
struct LiftChoiceRow: View {
  let title: String
  var detail: String? = nil
  let isSelected: Bool
  let action: () -> Void

  var body: some View {
    Button(action: action) {
      LiftListRow(
        title: title,
        details: detail.map { [$0] } ?? [],
        leading: { GlyphDisc(isSelected ? "checkmark" : "dumbbell.fill", tint: isSelected ? .accent : .workout) },
        accessory: { EmptyView() }
      )
    }
    .buttonStyle(FlatRowPressStyle())
    .accessibilityElement(children: .combine)
    .accessibilityAddTraits(isSelected ? .isSelected : [])
  }
}

extension View {
  /// Stretches a pill button's label across the page, for the one action a pinned footer is for.
  func liftPillLabel() -> some View { frame(maxWidth: .infinity) }
}

/// A 44pt pill for the timer's quick actions (a preset, plus or minus fifteen seconds, skip). Bigger than a chip because
/// it is tapped between sets, often with a chalky thumb. `title` is already in the person's language. `fillsWidth` makes
/// it take the whole column it is placed in, so a grid of presets lines up with the content above and below.
struct LiftTimerPill: View {
  let title: String
  var isSelected = false
  var fillsWidth = false
  let accessibilityLabel: Text
  let action: () -> Void

  var body: some View {
    Button(action: action) {
      Text(verbatim: title)
        .monospacedDigit()
        .lineLimit(1)
        .minimumScaleFactor(0.8)
        .frame(minWidth: 40, maxWidth: fillsWidth ? .infinity : nil, minHeight: 24)
    }
    .buttonStyle(SecondaryPillButtonStyle())
    .overlay {
      if isSelected {
        Capsule(style: .continuous).stroke(DomainTint.workout.accent, lineWidth: 1.5)
      }
    }
    .accessibilityLabel(accessibilityLabel)
    .accessibilityAddTraits(isSelected ? .isSelected : [])
  }
}

/// A figure with its muted unit, the figure scaling with Dynamic Type like the unit beside it (the design system's
/// `UnitValueText` takes a fixed point size, so on its own the unit would outgrow the number at the largest sizes).
struct LiftScaledValue: View {
  let value: String
  @ScaledMetric(relativeTo: .body) private var size: CGFloat = 17

  var body: some View { UnitValueText(value: value, size: size) }
}

// MARK: Key-value row

/// A quiet label with its bright value on the same line, stacking at the largest text sizes so neither is cut.
struct LiftKeyValueRow: View {
  let label: LocalizedStringKey
  let value: String

  @Environment(\.dynamicTypeSize) private var typeSize

  var body: some View {
    Group {
      if LiftListRow<EmptyView, EmptyView>.stacks(typeSize) {
        VStack(alignment: .leading, spacing: 2) { labelText; valueText }
      } else {
        HStack(alignment: .firstTextBaseline, spacing: NoopMetrics.space3) {
          labelText
          Spacer(minLength: NoopMetrics.space2)
          valueText.multilineTextAlignment(.trailing)
        }
      }
    }
    .padding(.vertical, NoopMetrics.space3)
    .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
    .accessibilityElement(children: .combine)
  }

  private var labelText: some View {
    Text(label).font(StrandFont.subhead).foregroundStyle(StrandPalette.textSecondary)
  }

  private var valueText: some View {
    Text(verbatim: value)
      .font(StrandFont.subhead)
      .foregroundStyle(StrandPalette.textPrimary)
      .fixedSize(horizontal: false, vertical: true)
  }
}
