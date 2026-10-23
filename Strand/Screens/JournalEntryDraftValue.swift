import Foundation
import StrandAnalytics

struct JournalEntryEditableValue: Identifiable {
    let field: JournalEntryParser.Field
    let excerpt: String
    var included = true
    var boolean = true
    var quantity = ""
    var id: String { field.canonical }

    init(field: JournalEntryParser.Field, suggestion: JournalEntryParser.Suggestion) {
        self.field = field
        excerpt = suggestion.excerpt
        switch suggestion.value {
        case .boolean(let value): boolean = value
        case .quantity(let value):
            let formatter = NumberFormatter()
            formatter.numberStyle = .decimal
            formatter.usesGroupingSeparator = false
            formatter.usesSignificantDigits = true
            formatter.minimumSignificantDigits = 1
            formatter.maximumSignificantDigits = 17
            formatter.maximumFractionDigits = 340
            quantity = formatter.string(from: NSNumber(value: value)) ?? String(value)
        }
    }

    var suggestion: JournalEntryParser.Suggestion? {
        let value: JournalEntryParser.Value
        switch field.kind {
        case .boolean: value = .boolean(boolean)
        case .quantity:
            let formatter = NumberFormatter()
            formatter.numberStyle = .decimal
            formatter.isLenient = false
            formatter.usesGroupingSeparator = false
            let text = quantity.trimmingCharacters(in: .whitespacesAndNewlines)
            let separator = Locale.current.decimalSeparator ?? "."
            let escaped = NSRegularExpression.escapedPattern(for: separator)
            guard text.range(of: "^\\d+(?:" + escaped + "\\d+)?$", options: .regularExpression) != nil,
                  let number = formatter.number(from: text)?.doubleValue,
                  number.isFinite, (0...1_000_000_000).contains(number) else { return nil }
            value = .quantity(number)
        }
        return .init(canonical: field.canonical, value: value, excerpt: excerpt)
    }
}
