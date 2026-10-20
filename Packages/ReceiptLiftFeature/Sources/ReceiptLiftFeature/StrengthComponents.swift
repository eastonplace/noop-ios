import StrandDesign
import SwiftUI

// MARK: - Strength design pieces
//
// The shared parts of Strength home, live logging and the summary (the approved mockup): the muscular-purple eyebrow,
// the label-over-value strip with hairline dividers, the exercise tile and the split bar. Every pill, chip, button and
// tag on those screens is the L4 pill system (`ValuePill`, `ChoiceChipButton`, the main buttons, `LiftTag`).

extension DomainTint {
  /// The muscular colour: Strength's eyebrow icons, set bars and "your sets" share of Strain.
  static var muscular: DomainTint { .custom(StrandPalette.muscularAccent) }
}

/// Fixed measures of the approved Strength design.
enum StrengthMetrics {
  /// The side gutter of Strength home, live logging and the summary (the design's 20pt, at every text size).
  static let gutter: CGFloat = NoopMetrics.space5
  /// What a 44pt icon button keeps empty around its glyph; the header's last icon sits this far past the gutter so the
  /// glyph, not its tap area, lines up with the page edge.
  static let iconInset: CGFloat = 11
  /// The sheet grabber: 36 x 5, `StrandPalette.grabber` (#3A4246).
  static let grabberSize = CGSize(width: 36, height: 5)
  static let grabberColor = StrandPalette.grabber
}

/// The grabber the design draws at the top of the Strength sheet, 10pt above the header row.
struct StrengthGrabber: View {
  var body: some View {
    Capsule(style: .continuous)
      .fill(StrengthMetrics.grabberColor)
      .frame(width: StrengthMetrics.grabberSize.width, height: StrengthMetrics.grabberSize.height)
      .padding(.bottom, 10)
      .frame(maxWidth: .infinity)
      .accessibilityHidden(true)
  }
}

/// The page header of the Strength screens: a letter-spaced caps title and the screen's own icon buttons.
struct StrengthHeader<Trailing: View>: View {
  let title: LocalizedStringKey
  var onBack: (() -> Void)?
  @ViewBuilder var trailing: () -> Trailing

  @ScaledMetric(relativeTo: .footnote) private var titleSize: CGFloat = 13

  var body: some View {
    HStack(spacing: NoopMetrics.space2) {
      if let onBack {
        HeaderChipButton("chevron.left", accessibilityLabel: "Back", action: onBack)
      }
      Text(title)
        .textCase(.uppercase)
        .font(StrandFont.sized(titleSize, weight: .bold))
        .tracking(2.6)
        .foregroundStyle(StrandPalette.textPrimary)
        .lineLimit(2)
        .minimumScaleFactor(0.7)
        .accessibilityAddTraits(.isHeader)
      Spacer(minLength: NoopMetrics.space2)
      trailing()
    }
    .frame(minHeight: 44)
  }
}

/// A plain icon button for a Strength header: the glyph in the secondary ink, a 44pt target.
struct StrengthIconButton: View {
  let systemImage: String
  let accessibilityLabel: LocalizedStringKey
  let action: () -> Void

  var body: some View {
    Button(action: action) { StrengthIconGlyph(systemImage: systemImage) }
      .buttonStyle(.plain)
      .accessibilityLabel(accessibilityLabel)
  }
}

struct StrengthIconGlyph: View {
  let systemImage: String
  @ScaledMetric(relativeTo: .body) private var size: CGFloat = 18

  var body: some View {
    Image(systemName: systemImage)
      .font(StrandFont.sized(size, weight: .regular))
      .foregroundStyle(StrandPalette.textTertiary)
      .frame(width: max(44, size + 22), height: max(44, size + 22))
      .contentShape(Rectangle())
  }
}

/// Label over value over a quiet caption, in columns split by hairlines; stacks as labelled rows at the accessibility
/// text sizes so nothing is clipped.
struct StrengthStatStrip: View {
  struct Item: Identifiable {
    let id: String
    let label: LocalizedStringKey
    let value: String
    var unit: String? = nil
    var caption: String? = nil
    var valueTint: Color = StrandPalette.textPrimary
    var captionTint: Color = StrandPalette.textSecondary
    var spoken: String? = nil
  }

  let items: [Item]
  var eyebrowLabels = false

  @Environment(\.dynamicTypeSize) private var typeSize
  @ScaledMetric(relativeTo: .title3) private var valueSize: CGFloat = 21
  @ScaledMetric(relativeTo: .caption) private var labelSize: CGFloat = 12

  var body: some View {
    Group {
      if typeSize.isAccessibilitySize {
        VStack(alignment: .leading, spacing: NoopMetrics.space3) {
          ForEach(items) { item in column(item) }
        }
      } else {
        HStack(alignment: .top, spacing: 0) {
          ForEach(Array(items.enumerated()), id: \.element.id) { index, item in
            if index > 0 {
              Rectangle().fill(StrandPalette.hairline).frame(width: 1).padding(.trailing, 12).accessibilityHidden(true)
            }
            column(item).frame(maxWidth: .infinity, alignment: .leading)
          }
        }
        .fixedSize(horizontal: false, vertical: true)
      }
    }
  }

  private func column(_ item: Item) -> some View {
    VStack(alignment: .leading, spacing: 3) {
      Text(item.label)
        .textCase(eyebrowLabels ? .uppercase : nil)
        .tracking(eyebrowLabels ? 1.2 : 0)
        .font(StrandFont.sized(labelSize, weight: eyebrowLabels ? .bold : .regular))
        .foregroundStyle(StrandPalette.textTertiary)
        .lineLimit(typeSize.isAccessibilitySize ? 2 : 1)
        .minimumScaleFactor(0.7)
      HStack(alignment: .firstTextBaseline, spacing: 4) {
        Text(verbatim: item.value)
          .font(StrandFont.sized(valueSize, weight: .semibold))
          .monospacedDigit()
          .foregroundStyle(item.valueTint)
          .lineLimit(1)
          .minimumScaleFactor(0.6)
        if let unit = item.unit {
          Text(verbatim: unit).font(StrandFont.caption).foregroundStyle(StrandPalette.textSecondary)
        }
      }
      if let caption = item.caption {
        Text(verbatim: caption)
          .font(StrandFont.sized(labelSize, weight: .semibold))
          .foregroundStyle(item.captionTint)
          .lineLimit(typeSize.isAccessibilitySize ? 3 : 1)
          .minimumScaleFactor(0.7)
      }
    }
    .accessibilityElement(children: .ignore)
    .accessibilityLabel(item.label)
    .accessibilityValue(Text(verbatim: item.spoken ?? [item.value, item.unit, item.caption].compactMap { $0 }.joined(separator: " ")))
  }
}

/// An exercise picture in a quiet rounded tile, the way the mockup lays thumbnails out. With no `size` the tile is a square
/// that fills the space it is given (inside a `StrengthTileRow`).
struct StrengthExerciseTile: View {
  let exercise: LiftExercise?
  var size: CGFloat? = 58
  var cornerRadius: CGFloat = 14

  var body: some View {
    Group {
      if let size {
        tile(side: size).frame(width: size, height: size)
      } else {
        GeometryReader { proxy in tile(side: min(proxy.size.width, proxy.size.height)) }
      }
    }
    .accessibilityHidden(true)
  }

  private func tile(side: CGFloat) -> some View {
    LiftExerciseThumb(exercise: exercise, size: max(side - 6, 0), style: .paper)
      .frame(width: side, height: side)
      .background(StrandPalette.card, in: RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
      .overlay(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous).strokeBorder(StrandPalette.hairline, lineWidth: 1))
  }
}

/// A row of equal square tiles, at most `maxSide` each. When the row would not fit its width the tiles shrink together
/// (the design's flex row) instead of overflowing, which would widen the page and eat into its gutters.
struct StrengthTileRow: Layout {
  var maxSide: CGFloat = 58
  var spacing: CGFloat = 8

  private func side(width: CGFloat?, count: Int) -> CGFloat {
    guard count > 0 else { return 0 }
    guard let width, width.isFinite else { return maxSide }
    return max(min(maxSide, (width - spacing * CGFloat(count - 1)) / CGFloat(count)), 0)
  }

  func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
    let side = side(width: proposal.width, count: subviews.count)
    let count = CGFloat(subviews.count)
    return CGSize(width: side * count + spacing * max(count - 1, 0), height: side)
  }

  func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
    let side = side(width: bounds.width, count: subviews.count)
    var x = bounds.minX
    for subview in subviews {
      subview.place(at: CGPoint(x: x, y: bounds.minY), anchor: .topLeading, proposal: ProposedViewSize(width: side, height: side))
      x += side + spacing
    }
  }
}

/// A bar of coloured shares on a quiet track: heart rate, then your sets, then what is left of 0-21.
struct StrengthSplitBar: View {
  struct Segment: Identifiable {
    let id = UUID()
    let weight: Double
    let color: Color
  }

  let segments: [Segment]
  var height: CGFloat = 8
  var gap: CGFloat = 2

  var body: some View {
    GeometryReader { proxy in
      let total = max(segments.reduce(0) { $0 + max($1.weight, 0) }, 0.0001)
      let usable = max(proxy.size.width - gap * CGFloat(max(segments.count - 1, 0)), 0)
      HStack(spacing: gap) {
        ForEach(segments) { segment in
          Capsule(style: .continuous)
            .fill(segment.color)
            .frame(width: usable * CGFloat(max(segment.weight, 0) / total))
        }
      }
    }
    .frame(height: height)
    .accessibilityHidden(true)
  }
}

/// "▲ 6 vs last wk" in words.
enum LiftWeekDeltaText {
  static func make(_ delta: Int) -> String {
    if delta > 0 { return String(localized: "▲ \(delta) vs last wk") }
    if delta < 0 { return String(localized: "▼ \(-delta) vs last wk") }
    return String(localized: "Same as last wk")
  }

  static func spoken(_ delta: Int) -> String {
    if delta > 0 { return String(localized: "\(delta) more sets than last week") }
    if delta < 0 { return String(localized: "\(-delta) fewer sets than last week") }
    return String(localized: "Same sets as last week")
  }
}

extension LiftFormat {
  /// Total volume for a strip: "31.2k" past ten thousand, whole numbers below it, with the unit apart.
  func compactVolumeParts(pounds: Double) -> (number: String, unit: String) {
    let value = unit.fromPounds(max(pounds, 0))
    if value >= 10_000 {
      let thousands = (value / 1_000).formatted(.number.precision(.fractionLength(0...1)).locale(locale))
      return (thousands + "k", unitSymbol)
    }
    return (value.formatted(.number.precision(.fractionLength(0)).locale(locale)), unitSymbol)
  }
}
