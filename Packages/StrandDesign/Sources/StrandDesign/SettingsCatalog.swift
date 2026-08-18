import SwiftUI

/// Stable, value-only metadata for Settings and More search.
///
/// Destinations remain closure-owned by the feature views, while the route ID and
/// breadcrumb stay stable for search, QA, and future routing work. Filtering never
/// mutates the original sections or their stored bindings/actions.
public struct SettingsCatalogItem: Identifiable, Equatable, Sendable {
    public let id: String
    public let routeID: String
    public let sectionID: String
    public let breadcrumb: String
    public let title: String
    public let subtitle: String
    public let keywords: [String]

    public init(
        id: String,
        routeID: String,
        sectionID: String,
        breadcrumb: String,
        title: String,
        subtitle: String,
        keywords: [String] = []
    ) {
        self.id = id
        self.routeID = routeID
        self.sectionID = sectionID
        self.breadcrumb = breadcrumb
        self.title = title
        self.subtitle = subtitle
        self.keywords = keywords
    }

    fileprivate var searchText: String {
        ([breadcrumb, title, subtitle, routeID] + keywords)
            .joined(separator: " ")
            .folding(options: [.diacriticInsensitive, .caseInsensitive], locale: .current)
    }
}

public enum SettingsCatalog {
    public static func items(from sections: [SettingsSectionModel]) -> [SettingsCatalogItem] {
        sections.flatMap { section in
            section.rows.map { row in
                SettingsCatalogItem(
                    id: "\(section.id)/\(row.id)",
                    routeID: row.id,
                    sectionID: section.id,
                    breadcrumb: section.header,
                    title: row.searchTitle,
                    subtitle: row.searchSubtitle,
                    keywords: row.searchKeywords
                )
            }
        }
    }

    /// Preserve a curated category index for an empty query, but search a separate
    /// flattened set of navigable leaf rows once the user types.
    public static func searchSections(
        indexSections: [SettingsSectionModel],
        resultSections: [SettingsSectionModel],
        query: String
    ) -> [SettingsSectionModel] {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty
            ? indexSections
            : filteredSections(resultSections, query: trimmed)
    }

    public static func filteredSections(
        _ sections: [SettingsSectionModel],
        query: String
    ) -> [SettingsSectionModel] {
        let terms = query
            .split(whereSeparator: { $0.isWhitespace || $0 == "," })
            .map {
                String($0).folding(options: [.diacriticInsensitive, .caseInsensitive], locale: .current)
            }
            .filter { !$0.isEmpty }
        guard !terms.isEmpty else { return sections }

        return sections.compactMap { section in
            let filteredRows = section.rows.filter { row in
                let item = SettingsCatalogItem(
                    id: "\(section.id)/\(row.id)",
                    routeID: row.id,
                    sectionID: section.id,
                    breadcrumb: section.header,
                    title: row.searchTitle,
                    subtitle: row.searchSubtitle,
                    keywords: row.searchKeywords
                )
                return terms.allSatisfy { item.searchText.contains($0) }
            }
            guard !filteredRows.isEmpty else { return nil }
            return SettingsSectionModel(
                id: section.id,
                header: section.header,
                footer: section.footer,
                rows: filteredRows
            )
        }
    }
}

public extension SettingsRowModel {
    var searchTitle: String {
        switch self {
        case .nav(_, _, _, let title, _, _),
             .navDetail(_, _, _, let title, _, _, _),
             .toggle(_, _, _, let title, _, _),
             .segmented(_, _, _, let title, _, _),
             .stepper(_, _, _, let title, _, _, _, _, _),
             .info(_, _, _, let title, _),
             .link(_, _, _, let title, _),
             .destructive(_, _, let title, _):
            return title
        case .custom(let id, _):
            return id
        }
    }

    var searchSubtitle: String {
        switch self {
        case .nav:
            return ""
        case .navDetail(_, _, _, _, let subtitle, _, _):
            return subtitle
        case .toggle(_, _, _, _, let subtitle, _):
            return subtitle ?? ""
        case .segmented, .stepper, .info, .link, .destructive, .custom:
            return ""
        }
    }

    var searchKeywords: [String] {
        switch self {
        case .nav(let id, _, _, _, _, _),
             .navDetail(let id, _, _, _, _, _, _),
             .toggle(let id, _, _, _, _, _),
             .segmented(let id, _, _, _, _, _),
             .stepper(let id, _, _, _, _, _, _, _, _),
             .info(let id, _, _, _, _),
             .link(let id, _, _, _, _),
             .destructive(let id, _, _, _),
             .custom(let id, _):
            return [id.replacingOccurrences(of: "-", with: " ")]
        }
    }
}
