import SwiftUI
import StrandDesign

enum SettingsRouteID: String, CaseIterable, Hashable, Identifiable, Sendable {
    case personalProfile
    case scoringBaselines
    case whoop
    case syncBattery
    case appleHealth
    case dataSourcesStorage
    case backupExport
    case notificationsAlerts
    case appearanceUnits
    case workoutPreferences
    case sleepAlarm
    case automationsShortcuts
    case diagnosticsExperimental
    case testCentre
    case privacyDeletion
    case about

    var id: String { rawValue }
}

enum SettingsSectionID: String, CaseIterable, Hashable, Identifiable, Sendable {
    case profile
    case deviceSync
    case healthData
    case appPreferences
    case automation
    case advanced
    case about

    var id: String { rawValue }
}

struct SettingsRootRoute: Identifiable, Equatable, Sendable {
    let id: SettingsRouteID
    let title: String
}

struct SettingsRootSection: Identifiable, Equatable, Sendable {
    let id: SettingsSectionID
    let title: String
    let routes: [SettingsRootRoute]
}

struct SettingsSearchItem: Identifiable, Equatable, Sendable {
    let id: String
    let title: String
    let breadcrumb: String
    let route: SettingsRouteID
    let keywords: [String]

    fileprivate var normalizedSearchText: String {
        SettingsRouteCatalog.normalize(
            ([title] + keywords).joined(separator: " ")
        )
    }
}

enum SettingsRouteCatalog {
    static let rootSections: [SettingsRootSection] = [
        .init(
            id: .profile,
            title: "Profile",
            routes: [
                .init(id: .personalProfile, title: "Personal profile"),
                .init(id: .scoringBaselines, title: "Scoring & baselines"),
            ]
        ),
        .init(
            id: .deviceSync,
            title: "Device & Sync",
            routes: [
                .init(id: .whoop, title: "WHOOP"),
                .init(id: .syncBattery, title: "Sync & battery"),
            ]
        ),
        .init(
            id: .healthData,
            title: "Health & Data",
            routes: [
                .init(id: .appleHealth, title: "Apple Health"),
                .init(id: .dataSourcesStorage, title: "Data Sources & Storage"),
                .init(id: .backupExport, title: "Backup & Export"),
            ]
        ),
        .init(
            id: .appPreferences,
            title: "App Preferences",
            routes: [
                .init(id: .notificationsAlerts, title: "Notifications & alerts"),
                .init(id: .appearanceUnits, title: "Appearance & units"),
                .init(id: .workoutPreferences, title: "Workout & feature preferences"),
            ]
        ),
        .init(
            id: .automation,
            title: "Automation",
            routes: [
                .init(id: .sleepAlarm, title: "Sleep & alarm"),
                .init(id: .automationsShortcuts, title: "Automations & Shortcuts"),
            ]
        ),
        .init(
            id: .advanced,
            title: "Advanced",
            routes: [
                .init(id: .diagnosticsExperimental, title: "Diagnostics & Experimental"),
                .init(id: .privacyDeletion, title: "Privacy & data deletion"),
            ]
        ),
        .init(
            id: .about,
            title: "About",
            routes: [
                .init(id: .about, title: "About NOOP"),
            ]
        ),
    ]

    static let searchItems: [SettingsSearchItem] = [
        .init(
            id: "personal-profile",
            title: "Personal profile",
            breadcrumb: "Profile",
            route: .personalProfile,
            keywords: ["date of birth", "age", "sex", "height", "weight", "waist", "max heart rate", "heart rate zones"]
        ),
        .init(
            id: "recovery-baseline",
            title: "Recovery baseline",
            breadcrumb: "Profile › Scoring & baselines",
            route: .scoringBaselines,
            keywords: ["baseline", "calibration", "recalibrate", "HRV", "recovery", "score"]
        ),
        .init(
            id: "step-calibration",
            title: "Step calibration",
            breadcrumb: "Profile › Scoring & baselines",
            route: .scoringBaselines,
            keywords: ["steps", "counter", "estimate", "calibrate"]
        ),
        .init(
            id: "whoop",
            title: "WHOOP",
            breadcrumb: "Device & Sync",
            route: .whoop,
            keywords: ["strap", "device", "pair", "connect", "connection", "rename", "forget", "battery"]
        ),
        .init(
            id: "background-sync",
            title: "Background sync",
            breadcrumb: "Device & Sync › Sync & battery",
            route: .syncBattery,
            keywords: ["sync", "background", "collection", "history", "offload"]
        ),
        .init(
            id: "continuous-hrv",
            title: "Continuous HRV capture",
            breadcrumb: "Device & Sync › Sync & battery",
            route: .syncBattery,
            keywords: ["HRV", "RR", "R-R", "overnight", "battery", "capture"]
        ),
        .init(
            id: "power-saving",
            title: "Power saving",
            breadcrumb: "Device & Sync › Sync & battery",
            route: .syncBattery,
            keywords: ["battery", "low battery", "power", "sync interval", "pause HRV"]
        ),
        .init(
            id: "apple-health",
            title: "Apple Health",
            breadcrumb: "Health & Data",
            route: .appleHealth,
            keywords: ["HealthKit", "permissions", "read", "write", "sync", "watch"]
        ),
        .init(
            id: "data-sources",
            title: "Data Sources",
            breadcrumb: "Health & Data › Data Sources & Storage",
            route: .dataSourcesStorage,
            keywords: ["imports", "source priority", "storage", "cleanup", "fused record", "WHOOP export"]
        ),
        .init(
            id: "fused-record",
            title: "Fused Record",
            breadcrumb: "Health & Data › Data Sources & Storage",
            route: .dataSourcesStorage,
            keywords: ["timeline", "sources", "combined", "chronological"]
        ),
        .init(
            id: "backup",
            title: "Backup & Export",
            breadcrumb: "Health & Data",
            route: .backupExport,
            keywords: ["backup", "restore", "export", "CSV", "file", "folder", "Shortcuts export"]
        ),
        .init(
            id: "notifications",
            title: "Notifications & alerts",
            breadcrumb: "App Preferences",
            route: .notificationsAlerts,
            keywords: ["notification", "reminders", "stress alert", "inactivity", "coaching"]
        ),
        .init(
            id: "appearance",
            title: "Appearance",
            breadcrumb: "App Preferences › Appearance & units",
            route: .appearanceUnits,
            keywords: ["system", "light", "dark", "theme", "app icon", "day cycle", "charts"]
        ),
        .init(
            id: "units",
            title: "Units",
            breadcrumb: "App Preferences › Appearance & units",
            route: .appearanceUnits,
            keywords: ["US", "metric", "imperial", "temperature", "Celsius", "Fahrenheit", "°C", "°F", "Strain scale"]
        ),
        .init(
            id: "workout-detection",
            title: "Workout detection",
            breadcrumb: "App Preferences › Workout & feature preferences",
            route: .workoutPreferences,
            keywords: ["auto detect", "workout", "Live Activity", "hydration", "keep screen on"]
        ),
        .init(
            id: "sleep-alarm",
            title: "Sleep & alarm",
            breadcrumb: "Automation",
            route: .sleepAlarm,
            keywords: ["alarm", "wake", "weekdays", "wind-down", "adaptive wake", "test vibration"]
        ),
        .init(
            id: "automations",
            title: "Automations & Shortcuts",
            breadcrumb: "Automation",
            route: .automationsShortcuts,
            keywords: ["automation", "rules", "triggers", "Siri", "App Shortcuts", "voice", "actions"]
        ),
        .init(
            id: "test-centre",
            title: "Test Centre",
            breadcrumb: "Advanced › Diagnostics & Experimental",
            route: .testCentre,
            keywords: ["test center", "diagnostics", "connection", "sensor", "scoring", "notification", "evidence"]
        ),
        .init(
            id: "experimental",
            title: "Experimental",
            breadcrumb: "Advanced › Diagnostics & Experimental",
            route: .diagnosticsExperimental,
            keywords: ["WHOOP 5", "MG", "R22", "raw capture", "protocol", "probe", "puffin"]
        ),
        .init(
            id: "privacy",
            title: "Privacy & data deletion",
            breadcrumb: "Advanced",
            route: .privacyDeletion,
            keywords: ["local", "delete", "remove data", "privacy", "storage", "forget"]
        ),
        .init(
            id: "about",
            title: "About NOOP",
            breadcrumb: "About",
            route: .about,
            keywords: ["version", "build", "what's new", "update", "legal", "how NOOP works"]
        ),
    ]

    static func search(_ query: String) -> [SettingsSearchItem] {
        let terms = query
            .split(whereSeparator: { $0.isWhitespace || $0 == "," })
            .flatMap { rawTerm -> [String] in
                let parts = rawTerm.split(separator: "-", omittingEmptySubsequences: true)
                if parts.count > 1, parts.allSatisfy({ $0.count == 1 }) {
                    return [parts.joined()]
                }
                return normalize(String(rawTerm))
                    .split(whereSeparator: { $0.isWhitespace })
                    .map(String.init)
            }
            .filter { !$0.isEmpty }
        guard !terms.isEmpty else { return [] }

        return searchItems.filter { item in
            terms.allSatisfy { item.normalizedSearchText.contains($0) }
        }
    }

    static func normalize(_ value: String) -> String {
        value
            .folding(options: [.diacriticInsensitive, .caseInsensitive], locale: .current)
            .replacingOccurrences(of: "-", with: " ")
            .replacingOccurrences(of: "_", with: " ")
            .lowercased()
    }
}

struct SettingsRootStatus: Equatable, Sendable {
    private var values: [SettingsRouteID: String]

    init(values: [SettingsRouteID: String] = [:]) {
        self.values = values
    }

    subscript(route: SettingsRouteID) -> String? {
        values[route]
    }
}

struct NativeSettingsList<Content: View>: View {
    private let content: Content

    init(@ViewBuilder content: () -> Content) {
        self.content = content()
    }

    var body: some View {
        #if os(iOS)
        List { content }
            .listStyle(.insetGrouped)
            .environment(\.defaultMinListRowHeight, 44)
            .listSectionSpacing(.compact)
        #else
        List { content }
        #endif
    }
}

struct SettingsRootView: View {
    let status: SettingsRootStatus
    @State private var query = ""

    private var results: [SettingsSearchItem] {
        SettingsRouteCatalog.search(query)
    }

    var body: some View {
        NativeSettingsList {
            if query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                ForEach(SettingsRouteCatalog.rootSections) { section in
                    Section {
                        ForEach(section.routes) { route in
                            SettingsRouteLink(
                                route: route.id,
                                title: route.title,
                                value: status[route.id]
                            )
                        }
                    } header: {
                        Text(section.title)
                    }
                }
                Section {
                    Color.clear
                        .frame(height: NoopMetrics.tabBarClearance)
                        .listRowInsets(EdgeInsets())
                        .listRowBackground(Color.clear)
                        .listRowSeparator(.hidden)
                        .accessibilityHidden(true)
                }
            } else {
                searchResults
            }
        }
        .navigationTitle("Settings")
        #if os(iOS)
        .navigationBarTitleDisplayMode(.large)
        #endif
        .settingsSearch(text: $query)
    }

    @ViewBuilder private var searchResults: some View {
        Section {
            if results.isEmpty {
                SettingsEmptySearchRow()
            } else {
                ForEach(results) { result in
                    SettingsRouteLink(
                        route: result.route,
                        title: result.title,
                        breadcrumb: result.breadcrumb
                    )
                }
            }
        } header: {
            Text("Search Results")
        }
    }
}

private struct SettingsRouteLink: View {
    let route: SettingsRouteID
    let title: String
    let value: String?
    let breadcrumb: String?

    init(
        route: SettingsRouteID,
        title: String,
        value: String? = nil,
        breadcrumb: String? = nil
    ) {
        self.route = route
        self.title = title
        self.value = value
        self.breadcrumb = breadcrumb
    }

    var body: some View {
        NavigationLink(value: route) {
            HStack(spacing: 12) {
                VStack(alignment: .leading, spacing: 1) {
                    Text(title)
                        .font(.caption)
                        .foregroundStyle(.primary)
                    if let breadcrumb {
                        Text(breadcrumb)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                }

                Spacer(minLength: 8)

                if let value, !value.isEmpty {
                    Text(value)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .multilineTextAlignment(.trailing)
                }

            }
            .frame(minHeight: 44, alignment: .center)
            .contentShape(Rectangle())
        }
        .listRowInsets(EdgeInsets(top: 0, leading: 16, bottom: 0, trailing: 16))
        .accessibilityLabel(accessibilityLabel)
    }

    private var accessibilityLabel: String {
        if let breadcrumb {
            return "\(title), \(breadcrumb)"
        }
        if let value, !value.isEmpty {
            return "\(title), \(value)"
        }
        return title
    }
}

private struct SettingsEmptySearchRow: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("No settings found")
                .font(.caption)
                .foregroundStyle(.primary)
            Text("Try a setting, device, permission, or action name.")
                .font(.footnote)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.vertical, 4)
        .frame(minHeight: 44)
        .listRowInsets(EdgeInsets(top: 0, leading: 16, bottom: 0, trailing: 16))
        .accessibilityElement(children: .combine)
    }
}

private extension View {
    @ViewBuilder
    func settingsSearch(text: Binding<String>) -> some View {
        #if os(iOS)
        searchable(
            text: text,
            placement: .navigationBarDrawer(displayMode: .always),
            prompt: "Search Settings"
        )
        #else
        searchable(text: text, prompt: "Search Settings")
        #endif
    }
}
