import StrandDesign
import SwiftUI

/// Lift's own settings: the default rest, haptics, how a shared receipt is printed, and the starter routines.
struct SettingsView: View {
  @EnvironmentObject private var store: LiftStore
  @Environment(\.dismiss) private var dismiss
  @Environment(\.liftFormat) private var format

  private let starterNames = ["Upper A", "Lower A", "Pull + Posture", "Push + Delts", "Lower B"]

  var body: some View {
    LiftSheetPage(title: "Lift settings", onClose: { dismiss() }) {
      workoutSection
      FlatSectionSeparator()
      unitSection
      FlatSectionSeparator()
      receiptsSection
      FlatSectionSeparator()
      aboutSection
    }
    .presentationDetents([.large])
    .presentationDragIndicator(.visible)
  }

  // MARK: Workout

  private var workoutSection: some View {
    LiftFlatSection("Workout", systemImage: "timer", contentSpacing: NoopMetrics.space3) {
      VStack(alignment: .leading, spacing: NoopMetrics.space4) {
        LiftBigStepper(
          title: "Default rest",
          value: LiftFormat.duration(store.settings.defaultRestSeconds),
          spokenValue: format.spokenDuration(store.settings.defaultRestSeconds),
          decrement: { store.setDefaultRestSeconds(max(15, store.settings.defaultRestSeconds - 15)) },
          increment: { store.setDefaultRestSeconds(min(600, store.settings.defaultRestSeconds + 15)) }
        )
        Toggle(isOn: hapticsBinding) {
          VStack(alignment: .leading, spacing: 2) {
            Text("Haptics")
              .font(StrandFont.body)
              .foregroundStyle(StrandPalette.textPrimary)
            Text("Feel each logged set and finished rest")
              .font(StrandFont.caption)
              .foregroundStyle(StrandPalette.textSecondary)
              .fixedSize(horizontal: false, vertical: true)
          }
        }
        .noopToggle()
        .frame(minHeight: 44)
      }
    }
  }

  // MARK: Units

  private var unitSection: some View {
    LiftFlatSection("Units", systemImage: "scalemass", contentSpacing: 0) {
      LiftKeyValueRow(
        label: "Weights",
        value: format.unit == .pounds ? String(localized: "Pounds") : String(localized: "Kilograms"))
      LiftNote(text: "Lift follows the unit you chose in NOOP's settings.")
    }
  }

  // MARK: Receipts

  private var receiptsSection: some View {
    LiftFlatSection("Receipts", systemImage: "ticket", contentSpacing: NoopMetrics.space3) {
      VStack(alignment: .leading, spacing: NoopMetrics.space4) {
        VStack(alignment: .leading, spacing: NoopMetrics.space2) {
          Text("Export paper")
            .font(StrandFont.body)
            .foregroundStyle(StrandPalette.textPrimary)
          Text("Used when you share a receipt image")
            .font(StrandFont.caption)
            .foregroundStyle(StrandPalette.textSecondary)
            .fixedSize(horizontal: false, vertical: true)
          SegmentedPillControl([ExportPaperStyle.white, ExportPaperStyle.cream], selection: exportBinding) {
            $0 == .white ? String(localized: "White") : String(localized: "Cream")
          }
        }
        Menu {
          ForEach(starterNames, id: \.self) { name in
            Button(name) { store.restoreStarterRoutine(named: name) }
          }
        } label: {
          LiftListRow(
            title: String(localized: "Restore starter routine"),
            details: [String(localized: "Five starter templates")],
            showsChevron: true
          )
        }
        .buttonStyle(FlatRowPressStyle())
      }
    }
  }

  // MARK: About

  private var aboutSection: some View {
    LiftFlatSection("About", systemImage: "info.circle", contentSpacing: 0) {
      LiftKeyValueRow(label: "Version", value: appVersion)
      LiftNote(text: "Exercise media: Gym Visual · see notice")
    }
  }

  private var hapticsBinding: Binding<Bool> {
    Binding(get: { store.settings.hapticsEnabled }, set: { value in
      var settings = store.settings
      settings.hapticsEnabled = value
      store.updateSettings(settings)
    })
  }

  private var exportBinding: Binding<ExportPaperStyle> {
    Binding(get: { store.settings.exportPaperStyle }, set: { value in
      var settings = store.settings
      settings.exportPaperStyle = value
      store.updateSettings(settings)
    })
  }

  private var appVersion: String {
    Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "1.0"
  }
}
