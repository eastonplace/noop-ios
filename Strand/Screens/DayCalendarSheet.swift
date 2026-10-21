import SwiftUI
import StrandDesign

#if os(iOS)
/// Today's day picker: a compact, monochrome month grid on the app's dark surface. Selected day is a filled
/// white circle, today a thin ring, future days dimmed and disabled, and a small dot marks days that have data.
struct DayCalendarSheet: View {
    /// The day currently shown on Today (logical day).
    let selected: Date
    /// Today's logical day: the last selectable day.
    let today: Date
    /// "yyyy-MM-dd" keys of days that have banked data.
    let daysWithData: Set<String>
    let onPick: (Date) -> Void

    @State private var month: Date
    @Environment(\.dismiss) private var dismiss
    private let cal = Calendar.current

    init(selected: Date, today: Date, daysWithData: Set<String>, onPick: @escaping (Date) -> Void) {
        self.selected = selected; self.today = today; self.daysWithData = daysWithData; self.onPick = onPick
        let c = Calendar.current
        _month = State(initialValue: c.date(from: c.dateComponents([.year, .month], from: selected)) ?? selected)
    }

    private static let monthFmt: DateFormatter = {
        let f = DateFormatter(); f.setLocalizedDateFormatFromTemplate("LLLL yyyy"); return f
    }()

    private var canGoForward: Bool {
        guard let next = cal.date(byAdding: .month, value: 1, to: month) else { return false }
        return next <= today
    }

    /// 42 cells starting at the locale's first weekday; nil pads the days outside the month.
    private var cells: [Date?] {
        guard let range = cal.range(of: .day, in: .month, for: month) else { return [] }
        let lead = (cal.component(.weekday, from: month) - cal.firstWeekday + 7) % 7
        var out: [Date?] = Array(repeating: nil, count: lead)
        for d in range { out.append(cal.date(byAdding: .day, value: d - 1, to: month)) }
        while out.count % 7 != 0 { out.append(nil) }
        return out
    }

    private var weekdaySymbols: [String] {
        let s = cal.veryShortStandaloneWeekdaySymbols
        let first = cal.firstWeekday - 1
        return Array(s[first...] + s[..<first])
    }

    var body: some View {
        VStack(spacing: 14) {
            HStack(spacing: 4) {
                Text(verbatim: Self.monthFmt.string(from: month))
                    .font(StrandFont.headline)
                    .foregroundStyle(StrandPalette.textPrimary)
                    .accessibilityAddTraits(.isHeader)
                Spacer()
                Button { step(-1) } label: { arrow("chevron.left") }
                    .accessibilityLabel("Previous month")
                Button { step(1) } label: { arrow("chevron.right") }
                    .disabled(!canGoForward)
                    .opacity(canGoForward ? 1 : 0.3)
                    .accessibilityLabel("Next month")
            }
            .buttonStyle(.plain)

            HStack(spacing: 0) {
                ForEach(Array(weekdaySymbols.enumerated()), id: \.offset) { _, symbol in
                    Text(verbatim: symbol)
                        .font(StrandFont.micro.weight(.medium))
                        .foregroundStyle(StrandPalette.textTertiary)
                        .frame(maxWidth: .infinity)
                }
            }

            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 0), count: 7), spacing: 4) {
                ForEach(Array(cells.enumerated()), id: \.offset) { _, date in
                    if let date { dayCell(date) } else { Color.clear.frame(height: 42) }
                }
            }

            Button {
                onPick(today); dismiss()
            } label: {
                Text("Today")
                    .font(StrandFont.caption.weight(.semibold))
                    .foregroundStyle(StrandPalette.textPrimary)
                    .frame(maxWidth: .infinity, minHeight: 40)
                    .background(Capsule().fill(StrandPalette.surfaceInset))
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier("today.calendar.todayButton")
        }
        .padding(.horizontal, 16)
        .padding(.top, 8)
        .padding(.bottom, 12)
        .background(StrandPalette.surfaceRaised.ignoresSafeArea())
        .presentationDetents([.height(425)])
        .presentationDragIndicator(.visible)
        .presentationBackground(StrandPalette.surfaceRaised)
        .accessibilityIdentifier("today.calendar")
    }

    private func arrow(_ name: String) -> some View {
        Image(systemName: name)
            .font(.system(size: 13, weight: .semibold))
            .foregroundStyle(StrandPalette.textSecondary)
            .frame(width: 36, height: 36)
            .contentShape(Rectangle())
    }

    private func step(_ delta: Int) {
        if let next = cal.date(byAdding: .month, value: delta, to: month) {
            withAnimation(.easeOut(duration: 0.15)) { month = next }
        }
    }

    @ViewBuilder private func dayCell(_ date: Date) -> some View {
        let isFuture = cal.startOfDay(for: date) > cal.startOfDay(for: today)
        let isSelected = cal.isDate(date, inSameDayAs: selected)
        let isToday = cal.isDate(date, inSameDayAs: today)
        let hasData = daysWithData.contains(Repository.localDayKey(date))
        Button {
            onPick(date); dismiss()
        } label: {
            VStack(spacing: 2) {
                Text(verbatim: "\(cal.component(.day, from: date))")
                    .font(StrandFont.body.weight(isSelected ? .semibold : .regular))
                    .monospacedDigit()
                    .foregroundStyle(isSelected ? StrandPalette.canvas : StrandPalette.textPrimary)
                    .frame(width: 34, height: 34)
                    .background(Circle().fill(isSelected ? StrandPalette.textPrimary : .clear))
                    .overlay(Circle().strokeBorder(StrandPalette.textSecondary, lineWidth: 1)
                        .opacity(isToday && !isSelected ? 1 : 0))
                Circle()
                    .fill(StrandPalette.textTertiary)
                    .frame(width: 3, height: 3)
                    .opacity(hasData && !isFuture ? 1 : 0)
            }
            .frame(maxWidth: .infinity, minHeight: 42)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(isFuture)
        .opacity(isFuture ? 0.3 : 1)
        .accessibilityLabel(Text(date.formatted(date: .complete, time: .omitted)))
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }
}
#endif
