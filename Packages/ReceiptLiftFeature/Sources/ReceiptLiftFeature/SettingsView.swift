import StrandDesign
import SwiftUI

struct SettingsView: View {
  @EnvironmentObject private var store: LiftStore
  @Environment(\.dismiss) private var dismiss

  private let starterNames = ["Upper A", "Lower A", "Pull + Posture", "Push + Delts", "Lower B"]

  var body: some View {
    LiftScreen(
      title: "Lift settings",
      subtitle: "Rest, feedback and workout exports",
      trailing: {
        NoopIconButton("xmark", accessibilityLabel: "Close") { dismiss() }
      }
    ) {
      LiftSection(title: "Workout") {
        Stepper(value: restBinding, in: 15...600, step: 15) {
          settingLabel("Default rest", value: "\(Int(store.settings.defaultRestSeconds)) sec")
        }
        .contentRowSurface(boundedPadding: NoopMetrics.space3, flatVerticalPadding: NoopMetrics.space3)

        Toggle(isOn: hapticsBinding) {
          settingLabel("Haptics", value: store.settings.hapticsEnabled ? "On" : "Off")
        }
        .noopToggle()
        .contentRowSurface(boundedPadding: NoopMetrics.space3, flatVerticalPadding: NoopMetrics.space3)
      }

      LiftSection(title: "Receipts") {
        VStack(alignment: .leading, spacing: 10) {
          settingLabel("Export paper", value: "Used when you share a receipt image")
          SegmentedPillControl(
            [ExportPaperStyle.white, ExportPaperStyle.cream],
            selection: exportBinding
          ) { $0 == .white ? "White" : "Cream" }
        }
        .contentRowSurface(boundedPadding: NoopMetrics.space3, flatVerticalPadding: NoopMetrics.space3)

        Menu {
          ForEach(starterNames, id: \.self) { name in
            Button(name) { store.restoreStarterRoutine(named: name) }
          }
        } label: {
          LiftRow(
            title: "Restore starter routine",
            detail: "Five starter templates",
            showsChevron: true
          )
        }
        .buttonStyle(.plain)
      }

      LiftSection(title: "About") {
        LiftRow(title: "Version", value: appVersion)
        Text("Exercise media: Gym Visual · see notice")
          .font(StrandFont.caption)
          .foregroundStyle(StrandPalette.textTertiary)
      }
    }
  }

  private func settingLabel(_ title: String, value: String) -> some View {
    VStack(alignment: .leading, spacing: 2) {
      Text(title)
        .font(StrandFont.body)
        .foregroundStyle(StrandPalette.textPrimary)
      Text(value)
        .font(StrandFont.caption)
        .foregroundStyle(StrandPalette.textSecondary)
    }
  }

  private var restBinding: Binding<Double> {
    Binding(get: { store.settings.defaultRestSeconds }, set: { store.setDefaultRestSeconds($0) })
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
