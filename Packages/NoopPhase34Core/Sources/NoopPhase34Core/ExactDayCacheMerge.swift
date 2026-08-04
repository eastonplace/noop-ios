import Foundation

/// Replace every authoritative key, including authoritative absence. Existing rows outside the exact key set
/// remain untouched. This is the cache primitive required for exact-day Repository publication.
public enum ExactDayCacheMerge {
    public static func replacing<Key: Hashable, Value>(
        existing: [Value],
        incoming: [Value],
        authoritativeKeys: Set<Key>,
        key: (Value) -> Key,
        areInIncreasingOrder: (Value, Value) -> Bool
    ) -> [Value] {
        var byKey = Dictionary(
            existing.filter { !authoritativeKeys.contains(key($0)) }.map { (key($0), $0) },
            uniquingKeysWith: { _, last in last }
        )
        for value in incoming where authoritativeKeys.contains(key(value)) {
            byKey[key(value)] = value
        }
        return byKey.values.sorted(by: areInIncreasingOrder)
    }
}
