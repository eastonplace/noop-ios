import SwiftUI
import StrandDesign

/// The Settings root, in the idiom of the iOS Settings app: a large "Settings" title, a search field under it, an
/// Apple-ID-style row for the person's profile, and grouped lists of rows that each start with a coloured rounded-square
/// tile. Everything is a native List, NavigationLink and `.searchable`; the only custom drawing is the tile.
struct SettingsRootView: View {
    let status: SettingsRootStatus
    @State private var query = ""

    private var results: [SettingsSearchItem] {
        SettingsRouteCatalog.search(query)
    }

    var body: some View {
        NativeSettingsList {
            if query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                Section {
                    SettingsProfileRow()
                }
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
                        Text(LocalizedStringKey(section.title))
                    }
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
        if results.isEmpty {
            ContentUnavailableView.search(text: query)
        } else {
            Section {
                ForEach(results) { result in
                    SettingsRouteLink(
                        route: result.route,
                        title: result.title,
                        breadcrumb: Self.localizedBreadcrumb(result.breadcrumb)
                    )
                }
            } header: {
                Text("Search Results")
            }
        }
    }

    /// A breadcrumb keeps its " › " separators and each part is translated on its own ("Device & Sync › Sync & battery").
    static func localizedBreadcrumb(_ breadcrumb: String, in bundle: Bundle = .main) -> String {
        breadcrumb
            .components(separatedBy: " › ")
            .map { bundle.localizedString(forKey: $0, value: $0, table: nil) }
            .joined(separator: " › ")
    }
}

// MARK: - Rows

/// The row Apple's Settings opens with for the Apple ID: the person's photo, what the page is, one line of what it holds,
/// and a chevron. It opens Personal profile. Its own leaf, so a profile edit redraws this row and not the whole root.
private struct SettingsProfileRow: View {
    @EnvironmentObject private var profile: ProfileStore
    @AppStorage(UnitPrefs.systemKey) private var unitSystemRaw = UnitSystem.metric.rawValue
    @ScaledMetric(relativeTo: .title) private var avatarSide: CGFloat = 60
    @Environment(\.dynamicTypeSize) private var typeSize

    private var summary: String {
        let system = UnitSystem(rawValue: unitSystemRaw) ?? .metric
        let age = "\(String(localized: "Age")) \(profile.age)"
        let maxHR = "\(String(localized: "Max HR")) \(profile.hrMax)"
        let weight = UnitFormatter.massFromKilograms(profile.weightKg, system: system)
        return [age, maxHR, weight].joined(separator: " · ")
    }

    var body: some View {
        NavigationLink(value: SettingsRouteID.personalProfile) {
            // At accessibility sizes the avatar sits above the name so "Personal profile" keeps the row's width
            // instead of breaking across lines beside it.
            let layout = typeSize.isAccessibilitySize
                ? AnyLayout(VStackLayout(alignment: .leading, spacing: 10))
                : AnyLayout(HStackLayout(spacing: 14))
            layout {
                avatar
                VStack(alignment: .leading, spacing: 2) {
                    Text("Personal profile")
                        .font(.title3)
                    Text(summary)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
            }
            .padding(.vertical, 6)
            .frame(minHeight: 60, alignment: .leading)
        }
        .accessibilityIdentifier("settings.profileRow")
        .accessibilityLabel(Text("Personal profile") + Text(", ") + Text(summary))
    }

    private var avatar: some View {
        let side = min(avatarSide, typeSize.isAccessibilitySize ? 64 : 90)
        return Group {
            if let image = profile.avatarImage {
                image
                    .resizable()
                    .scaledToFill()
            } else {
                Color(.systemGray3)
                    .overlay {
                        Image(systemName: "person.fill")
                            .font(.system(size: side * 0.5))
                            .foregroundStyle(.white)
                    }
            }
        }
        .frame(width: side, height: side)
        .clipShape(Circle())
        .accessibilityHidden(true)
    }
}

/// One row of the root or of the search results: the route's tile, its title, its value (or, in a search result, where
/// it lives), and the NavigationLink's own chevron. At accessibility sizes the value drops under the title.
private struct SettingsRouteLink: View {
    let route: SettingsRouteID
    let title: String
    let value: String?
    let breadcrumb: String?
    @Environment(\.dynamicTypeSize) private var typeSize
    @ScaledMetric(relativeTo: .body) private var tileSide: CGFloat = 29

    init(route: SettingsRouteID, title: String, value: String? = nil, breadcrumb: String? = nil) {
        self.route = route
        self.title = title
        self.value = value
        self.breadcrumb = breadcrumb
    }

    private var side: CGFloat { min(tileSide, 44) }

    var body: some View {
        let separatorInset = side + 12
        return NavigationLink(value: route) {
            HStack(spacing: 12) {
                SettingsIconTile(route: route, side: side)
                if typeSize.isAccessibilitySize {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(LocalizedStringKey(title))
                        detail
                    }
                } else if let breadcrumb {
                    VStack(alignment: .leading, spacing: 1) {
                        Text(LocalizedStringKey(title))
                        Text(breadcrumb)
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                } else {
                    Text(LocalizedStringKey(title))
                    Spacer(minLength: 8)
                    if let value, !value.isEmpty {
                        Text(value)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .multilineTextAlignment(.trailing)
                    }
                }
            }
            .frame(minHeight: 44, alignment: .center)
        }
        // The separator starts at the text, as in Apple's Settings, not under the tile.
        .alignmentGuide(.listRowSeparatorLeading) { $0[.leading] + separatorInset }
        .accessibilityIdentifier("settings.row.\(route.rawValue)")
        .accessibilityLabel(accessibilityLabel)
    }

    @ViewBuilder private var detail: some View {
        if let breadcrumb {
            Text(breadcrumb)
                .font(.subheadline)
                .foregroundStyle(.secondary)
        } else if let value, !value.isEmpty {
            Text(value)
                .font(.subheadline)
                .foregroundStyle(.secondary)
        }
    }

    private var accessibilityLabel: Text {
        let name = Text(LocalizedStringKey(title))
        if let breadcrumb { return name + Text(", ") + Text(breadcrumb) }
        if let value, !value.isEmpty { return name + Text(", ") + Text(value) }
        return name
    }
}

/// Apple's Settings tile: a white symbol on a rounded square, 29 pt at the default text size and growing with it.
private struct SettingsIconTile: View {
    let route: SettingsRouteID
    let side: CGFloat

    var body: some View {
        Image(systemName: route.tileSymbol)
            .font(.system(size: side * 0.55, weight: .medium))
            .foregroundStyle(.white)
            .frame(width: side, height: side)
            .background(route.tileColor, in: RoundedRectangle(cornerRadius: side * 0.24, style: .continuous))
            .accessibilityHidden(true)
    }
}

extension SettingsRouteID {
    /// The symbol on the route's tile.
    var tileSymbol: String {
        switch self {
        case .personalProfile: "person.crop.circle.fill"
        case .whoop: "dot.radiowaves.left.and.right"
        case .syncBattery: "battery.100percent"
        case .appleHealth: "heart.fill"
        case .dataSources: "tray.and.arrow.down.fill"
        case .backupExport: "externaldrive.fill.badge.icloud"
        case .notificationsAlerts: "bell.badge.fill"
        case .appearanceUnits: "textformat.size"
        case .todayDashboard: "square.grid.2x2.fill"
        case .workouts: "figure.run"
        case .quickActions: "plus.circle.fill"
        case .sleepAlarm: "bed.double.fill"
        case .siriShortcuts: "waveform"
        case .diagnosticsExperimental: "wrench.and.screwdriver.fill"
        case .testCentre: "testtube.2"
        case .privacyDeletion: "hand.raised.fill"
        case .about: "info.circle.fill"
        }
    }

    /// The tile's colour: one of the system colours Apple's own Settings uses, so it follows light and dark.
    var tileColor: Color {
        switch self {
        case .personalProfile: .gray
        case .whoop: .blue
        case .syncBattery: .green
        case .appleHealth: .red
        case .dataSources: .teal
        case .backupExport: .indigo
        case .notificationsAlerts: .red
        case .appearanceUnits: .blue
        case .todayDashboard: .cyan
        case .workouts: .orange
        case .quickActions: .green
        case .sleepAlarm: .indigo
        case .siriShortcuts: .purple
        case .diagnosticsExperimental: .gray
        case .testCentre: .teal
        case .privacyDeletion: .blue
        case .about: .gray
        }
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
