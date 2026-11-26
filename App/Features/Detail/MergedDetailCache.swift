import Foundation
import ReaderCore

/// 搜索详情页的源选择缓存（仅本次运行有效）。
///
/// 详情页是 push 出来的，退出就销毁；没有缓存的话，每点一本书都要重新
/// 取四份目录再验首章，用户感觉就是「换了本书又转半天」。
@MainActor
final class MergedDetailCache {
    static let shared = MergedDetailCache()

    struct Snapshot {
        var chosen: OnlineBook
        var source: SearchTarget
        var sourceName: String
        var chapters: [OnlineChapter]
        var intro: String
        var coverUrl: String
        var name: String
        var author: String
        var lastChapter: String
        var savedAt: Date
    }

    private var storage: [String: Snapshot] = [:]
    private var order: [String] = []
    private let limit = 12

    private init() {}

    func key(for book: SearchViewModel.MergedBook) -> String {
        "\(book.isComic ? "c" : "n")|\(book.id)"
    }

    func snapshot(for book: SearchViewModel.MergedBook) -> Snapshot? {
        let key = key(for: book)
        guard let snapshot = storage[key] else { return nil }
        // 触摸一下，保持最近使用的在后面
        order.removeAll { $0 == key }
        order.append(key)
        return snapshot
    }

    func store(_ snapshot: Snapshot, for book: SearchViewModel.MergedBook) {
        let key = key(for: book)
        storage[key] = snapshot
        order.removeAll { $0 == key }
        order.append(key)

        while order.count > limit {
            let oldest = order.removeFirst()
            storage[oldest] = nil
        }
    }

    func clear() {
        storage.removeAll()
        order.removeAll()
    }
}
