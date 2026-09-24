import SwiftUI

struct SettingsView: View {
  @EnvironmentObject private var store: LiftStore
  @Environment(\.dismiss) private var dismiss

  private let starterNames = ["Upper A", "Lower A", "Pull + Posture", "Push + Delts", "Lower B"]

  var body: some View {
    NavigationStack {
      ScrollView {
        ReceiptSheet {
          HStack(alignment: .top) {
            ReceiptHeader(title: "Settings", subtitle: "Lift Receipt")
            Spacer()
            Button("DONE") { dismiss() }
              .font(.receipt(10, weight: .black))
          }
          ReceiptDashedRule()

          Stepper(value: restBinding, in: 15...600, step: 15) {
            settingLabel("Default Rest", value: "\(Int(store.settings.defaultRestSeconds)) sec")
          }
          ReceiptRule()
          Toggle(isOn: hapticsBinding) { settingLabel("Haptics", value: store.settings.hapticsEnabled ? "On" : "Off") }
            .tint(LiftTheme.ink)
          ReceiptRule()
          Picker("Export Paper", selection: exportBinding) {
            Text("WHITE").tag(ExportPaperStyle.white)
            Text("CREAM").tag(ExportPaperStyle.cream)
          }
          .pickerStyle(.segmented)

          ReceiptDashedRule()
          Menu {
            ForEach(starterNames, id: \.self) { name in
              Button(name) { store.restoreStarterRoutine(named: name) }
            }
          } label: {
            ReceiptLine(
              title: "Restore Starter Routine",
              detail: "Five starter templates",
              value: "OPEN →"
            )
          }
          .buttonStyle(.plain)

          ReceiptDashedRule()
          ReceiptSectionLabel(title: "About")
          ReceiptLine(title: "Version", value: appVersion)
          Text("EXERCISE MEDIA: GYM VISUAL · SEE NOTICE")
            .font(.receipt(9, weight: .bold))
            .foregroundStyle(LiftTheme.inkSecondary)
        }
      }
      .scrollIndicators(.hidden)
      .toolbar(.hidden, for: .navigationBar)
    }
  }

  private func settingLabel(_ title: String, value: String) -> some View {
    VStack(alignment: .leading, spacing: 2) {
      Text(title.uppercased()).font(.receipt(11, weight: .black))
      Text(value.uppercased()).font(.receipt(9, weight: .bold)).foregroundStyle(LiftTheme.inkSecondary)
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
