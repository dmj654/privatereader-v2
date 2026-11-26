import Foundation

/// 书架筛选条件。把「筛什么」抽成值类型，方便测试，也让 UI 只负责展示。
public enum ShelfFilter: Equatable, Sendable {
    case all
    case novel
    case comic
    case group(String)

    public var title: String {
        switch self {
        case .all: return "全部"
        case .novel: return "小说"
        case .comic: return "漫画"
        case .group: return "分组"
        }
    }

    public func apply(to books: [Book]) -> [Book] {
        switch self {
        case .all:
            return books
        case .novel:
            return books.filter { $0.type == .novel }
        case .comic:
            return books.filter { $0.type == .comic }
        case .group(let id):
            return books.filter { $0.groupId == id }
        }
    }
}

public enum ShelfSort: String, CaseIterable, Sendable {
    case lastRead
    case added
    case title

    public func apply(to books: [Book]) -> [Book] {
        switch self {
        case .lastRead:
            return books.sorted {
                let lhs = $0.lastReadAt ?? 0
                let rhs = $1.lastReadAt ?? 0
                if lhs != rhs { return lhs > rhs }
                return $0.addedAt > $1.addedAt
            }
        case .added:
            return books.sorted { $0.addedAt > $1.addedAt }
        case .title:
            return books.sorted { $0.title.localizedStandardCompare($1.title) == .orderedAscending }
        }
    }
}
