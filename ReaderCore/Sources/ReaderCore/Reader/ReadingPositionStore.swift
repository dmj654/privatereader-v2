import Foundation

/// 阅读位置：全书第几章、章内第几页。
public struct ReadingPosition: Equatable, Sendable {
    public var chapterIndex: Int
    public var pageIndex: Int

    public init(chapterIndex: Int, pageIndex: Int) {
        self.chapterIndex = chapterIndex
        self.pageIndex = pageIndex
    }
}

/// 阅读位置的读写。
///
/// 单独抽出来是为了可以被单元测试覆盖——"读到第 4 章、下次进来还在第 4 章"
/// 这件事以前散在视图模型里，既测不到，出错也看不见（`try?` 把错误吞了）。
public struct ReadingPositionStore {
    private let repo: ProgressRepository

    public init(repo: ProgressRepository) {
        self.repo = repo
    }

    /// 读回上次的位置。章数变了（换了文件、重新分章）会夹到合法范围内。
    /// 没有任何记录时返回 nil，调用方应从头开始，**而不是把 0 当成有效进度**。
    public func restore(bookId: String, chapterCount: Int) -> ReadingPosition? {
        guard chapterCount > 0 else { return nil }
        guard let saved = try? repo.fetch(bookId: bookId) else { return nil }

        let chapter = min(max(saved.chapterIndex, 0), chapterCount - 1)
        let page = max(saved.offset, 0)
        return ReadingPosition(chapterIndex: chapter, pageIndex: page)
    }

    /// 写入位置。返回真正落库的值，便于调用方确认写成功了。
    ///
    /// 两条保护：
    /// 1. 章数为 0（正文还没解析出来）时**不写**，否则会把读到一半的位置覆盖成 0。
    /// 2. `pageCount` 为 0 时百分比按 0 算，但章号仍然保留。
    @discardableResult
    public func save(bookId: String,
                     position: ReadingPosition,
                     pageCount: Int,
                     chapterCount: Int,
                     timestamp: Int = Int(Date().timeIntervalSince1970)) throws -> ReadingProgress? {
        guard chapterCount > 0 else { return nil }

        let chapter = min(max(position.chapterIndex, 0), chapterCount - 1)
        let pages = max(pageCount, 1)
        let within = pages > 1 ? Double(min(max(position.pageIndex, 0), pages - 1)) / Double(pages - 1) : 0
        let percent = ProgressMath.percent(chapterIndex: chapter,
                                           chapterCount: chapterCount,
                                           chapterProgress: within)

        let record = ReadingProgress(
            bookId: bookId,
            chapterIndex: chapter,
            offset: min(max(position.pageIndex, 0), pages - 1),
            percent: percent,
            updatedAt: timestamp
        )
        try repo.save(record)
        return record
    }

    /// 写完读回来核对。返回 nil 表示读不到，返回 false 表示读到的和写进去的不一致。
    public func verify(bookId: String, expecting record: ReadingProgress) -> Bool {
        guard let stored = try? repo.fetch(bookId: bookId) else { return false }
        return stored.chapterIndex == record.chapterIndex
            && stored.offset == record.offset
    }
}
