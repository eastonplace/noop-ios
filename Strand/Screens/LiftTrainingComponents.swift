import SwiftUI
import StrandDesign

struct LiftExerciseDetailTarget: Identifiable {
    var id: String { name }
    let name: String
}

struct LiftSetComparisonTable: View {
    struct Row: Identifiable {
        let id: Int
        let previous: String
        let current: String
        let done: Bool
    }
    let rows: [Row]
    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("SET").frame(width: 32, alignment: .leading)
                Text("PREVIOUS").frame(maxWidth: .infinity, alignment: .leading)
                Text("TODAY").frame(maxWidth: .infinity, alignment: .leading)
                Color.clear.frame(width: 18, height: 1)
            }.font(.caption2.weight(.semibold)).foregroundStyle(StrandPalette.textSecondary).padding(.vertical, 10)
            ForEach(rows) { row in
                HStack(spacing: 8) {
                    Text("\(row.id)").frame(width: 24, alignment: .leading)
                    Text(row.previous).foregroundStyle(StrandPalette.textSecondary).frame(maxWidth: .infinity, alignment: .leading)
                    Text(row.current).frame(maxWidth: .infinity, alignment: .leading)
                    Image(systemName: row.done ? "checkmark.circle.fill" : "circle")
                        .foregroundStyle(row.done ? StrandPalette.accent : StrandPalette.textTertiary).frame(width: 18)
                }.font(.caption.monospacedDigit()).padding(.vertical, 10)
                    .padding(.horizontal, 4).background(row.done ? StrandPalette.accent.opacity(0.06) : .clear)
                    .accessibilityElement(children: .combine)
                Divider()
            }
        }
    }
}
