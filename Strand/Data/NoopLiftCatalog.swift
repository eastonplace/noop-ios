import Foundation

/// Local exercise reference copied from Lift. Exercise history retains the user's exact stored name.
enum NoopLiftCatalog {
    struct Entry: Decodable, Identifiable, Sendable {
        let id: String
        let name: String
        let equipment: String
        let target: String
        let bodyPart: String
        let localizedInstructions: [String: String]
        let image: String?
        var muscle: String { target.isEmpty ? bodyPart : target }
        var instructions: String { localizedInstructions["en"] ?? "" }
        var imageURL: URL? {
            guard let image else { return nil }
            let filename = URL(fileURLWithPath: image).lastPathComponent
            return NoopLiftCatalog.resourceBundle.url(forResource: filename, withExtension: nil, subdirectory: "LiftCatalog/images")
        }
        enum CodingKeys: String, CodingKey {
            case id, name, equipment, target, image
            case bodyPart = "body_part"
            case localizedInstructions = "instructions"
        }
    }
    private static var resourceBundle: Bundle {
        #if SWIFT_PACKAGE
        Bundle.module
        #else
        Bundle.main
        #endif
    }
    static let entries: [Entry] = {
        guard let url = resourceBundle.url(forResource: "catalog", withExtension: "json", subdirectory: "LiftCatalog"),
              let data = try? Data(contentsOf: url),
              let rows = try? JSONDecoder().decode([Entry].self, from: data) else { return [] }
        return rows.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }()
    private static let byName = Dictionary(entries.map { (normalized($0.name), $0) }, uniquingKeysWith: { first, _ in first })
    private static let byImage = Dictionary(entries.compactMap { row -> (String, Entry)? in
        guard let path = row.image else { return nil }
        return (URL(fileURLWithPath: path).lastPathComponent, row)
    }, uniquingKeysWith: { first, _ in first })
    // Exact existing Lift aliases. No fuzzy image matching across movement variants.
    private static let aliases: [String: String] = [
        "bench press": "0025-EIeI8Vf.jpg",
        "lat pulldown": "2330-LEprlgG.jpg",
        "romanian deadlift": "0085-wQ2c4XD.jpg",
        "machine shoulder press": "0603-67n3r98.jpg",
        "machine row or cable row": "0861-fUBheHs.jpg",
        "incline dumbbell press": "0314-ns0SIbU.jpg",
        "leg press": "0739-10Z2DXU.jpg",
        "leg extension": "0585-my33uHU.jpg",
        "seated leg curl": "0599-Zg3XY7P.jpg",
        "hammer curl": "1678-IGtBdNT.jpg",
        "hip thrust": "3236-Pjbc0Kt.jpg",
        "bulgarian split squat": "0410-qx4fgX7.jpg",
        "rope pushdown": "0200-dU605di.jpg",
    ]
    static func resolve(name: String) -> Entry? {
        let key = normalized(name)
        return byName[key] ?? aliases[key].flatMap { byImage[$0] }
    }
    private static func normalized(_ value: String) -> String {
        value.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: Locale(identifier: "en_US_POSIX"))
            .components(separatedBy: CharacterSet.alphanumerics.inverted).filter { !$0.isEmpty }.joined(separator: " ")
    }
}
