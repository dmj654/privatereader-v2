import Foundation

/// 文件名自然排序：1, 2, 10 而不是 1, 10, 2。
public enum NaturalSort {
    public static func sorted(_ names: [String]) -> [String] {
        names.sorted { lhs, rhs in
            lhs.localizedStandardCompare(rhs) == .orderedAscending
        }
    }

    public static func isOrderedBefore(_ lhs: String, _ rhs: String) -> Bool {
        lhs.localizedStandardCompare(rhs) == .orderedAscending
    }
}
